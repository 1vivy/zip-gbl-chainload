# shellcheck shell=sh
# shellcheck disable=SC2154,SC2012,SC2034
# modes/diag.sh — pre-reboot EFISP-install state check + state-bundle.
# Zero device writes. Stages a working dir at $BUNDLE_WORKDIR (default
# /tmp — recovery tmpfs, lost on reboot) and produces a single
# $BUNDLE_ROOT/gbl-chainload-diag-<ts>.tar.gz (default /sdcard) for the
# operator to keep. The working dir is removed once the tarball is in
# place. See docs/superpowers/specs/2026-05-19-diag-confidence-design.md.

TS=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)
BUNDLE_ROOT="${BUNDLE_ROOT:-/sdcard}"          # where the .tar.gz lands
BUNDLE_WORKDIR="${BUNDLE_WORKDIR:-/tmp}"       # where the staging dir lives
BUNDLE_DIR="$BUNDLE_WORKDIR/gbl-chainload-diag-$TS"
BUNDLE_TGZ="$BUNDLE_ROOT/gbl-chainload-diag-$TS.tar.gz"

# Track scalar state for the rendered lines.
EFISP_PE=0              # 1 if EFISP starts with MZ
GBLP1_OK=0              # 1 if gblp1-inspect ended with result: ok
HAS_MODE2_PROFILE=0     # 1 if the GBLP1 overlay carries a MODE2_PROFILE entry
LOADER_PATH_A=0         # 1 if abl_a retains loader path
LOADER_PATH_B=0         # 1 if abl_b retains loader path
# Chain-broken bucket out of `vbmeta-graft list-hash`, populated in
# check_graft. This is the AOSP first-stage init boot-blocker set:
# AvbFooter missing OR vbmeta sig won't verify against the OEM chain key
# (graft=no_vbmeta / graft=key_mismatch). Only mode-1 surfaces it on
# the UI — mode-0 / mode-2 keep ABL honest about unlock state so
# AVB's allow_verification_error=true tolerates everything; mode-1's
# patch10 reaches ABL libavb but NOT the userspace init re-verify
# (vbmeta-graft-vs-construct.md §2b). The hash bucket (digest=mismatch
# rows) is tolerated by every installed mode (mode-1 via patch10 +
# init's locked-state vbmeta skim) so we don't bother computing or
# rendering it — graft-verdict.txt in the bundle has the raw rows for
# anyone who wants them.
CHAIN_BROKEN_LIST=""

# ----- bundle plumbing ------------------------------------------------

prepare_bundle() {
  mkdir -p "$BUNDLE_DIR" || abort "cannot create $BUNDLE_DIR"
  # Free-space gate on $BUNDLE_ROOT for the .tar.gz artifact.
  _free_kb=$(df -k "$BUNDLE_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')
  case "$_free_kb" in
    ''|*[!0-9]*) ;;
    *) [ "$_free_kb" -lt 102400 ] && abort "less than 100 MiB free on $BUNDLE_ROOT" ;;
  esac
  : > "$BUNDLE_DIR/report.txt"
}

# Override ui_print to tee to report.txt while still writing to recovery I/O.
# Both echoes tolerate a missing $BUNDLE_DIR: update-binary brackets mode_main
# with its own ui_print calls (the version banner before prepare_bundle creates
# the dir, and the trailing ""/"DONE." after finalize_bundle rm -rf's it), so an
# unsuppressed report.txt append would leak "No such file or directory" lines.
ui_print() {
  echo "$1" >> "$BUNDLE_DIR/report.txt" 2>/dev/null || true
  echo "ui_print $1
ui_print" >> /proc/self/fd/"$OUTFD" 2>/dev/null || true
}

# ----- env --------------------------------------------------------------

collect_env() {
  {
    if $BOOTMODE; then
      echo "boot mode  : booted Android (flash-from-system)"
    else
      echo "boot mode  : recovery"
    fi
    echo "slot       : active=$SLOT inactive=$INACTIVE"
    echo "byname dir : $BYNAME"
    ls -1 "$BYNAME" 2>/dev/null | sort
    echo "---"
    busybox 2>&1 | head -1 || true
  } > "$BUNDLE_DIR/env.txt"
  getprop > "$BUNDLE_DIR/getprop.boot.txt" 2>/dev/null || true
}

# ----- EFISP -----------------------------------------------------------

# Map a GBLP1 entry type-name (as printed by gblp1-inspect, e.g. CACHED_ABL)
# to an operator-friendly label. Unknown types are echoed as-is so a future
# entry-type addition still surfaces something rather than nothing.
_entry_pretty_label() {
  case "$1" in
    CACHED_ABL)    echo "cached patched ABL" ;;
    SOURCE_META)   echo "source metadata"    ;;
    MODE2_PROFILE) echo "mode-2 profile"     ;;
    *)             echo "$1"                 ;;
  esac
}

collect_efisp() {
  # Always create these files so the bundle is complete regardless of result.
  : > "$BUNDLE_DIR/gblp1-inspect.txt"
  _efisp=$(byname efisp)
  if [ -z "$_efisp" ]; then
    ui_print "  EFISP        : partition not found"
    : > "$BUNDLE_DIR/efisp.img"
    return
  fi
  dd if="$_efisp" of="$BUNDLE_DIR/efisp.img" bs=1M 2>/dev/null
  # Check MZ magic (first two bytes: 4d 5a)
  _mz=$(dd if="$BUNDLE_DIR/efisp.img" bs=1 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
  if [ "$_mz" != "4d5a" ]; then
    ui_print "  EFISP        : not a PE (first 2 bytes = $_mz)"
    return
  fi
  EFISP_PE=1
  gblp1-inspect "$BUNDLE_DIR/efisp.img" > "$BUNDLE_DIR/gblp1-inspect.txt" 2>&1 \
    && GBLP1_OK=1 || GBLP1_OK=0

  # Mode is read from the overlay contents, not a base-EFI hash: a mode-2
  # install carries a MODE2_PROFILE entry; mode-0/1 do not. This avoids a
  # per-build base-EFI SHA list (which went stale across versions/branches
  # and forced a vendored-tool rebuild on every EFI change).
  if grep -q '(MODE2_PROFILE)' "$BUNDLE_DIR/gblp1-inspect.txt" 2>/dev/null; then
    HAS_MODE2_PROFILE=1
  fi

  if [ "$GBLP1_OK" = 1 ]; then
    ui_print "  EFISP        : GBLP1 v1 ok"
    # Sub-line per GBLP1 entry, in the order gblp1-inspect emitted them.
    # awk over `entry:` lines, pluck the parenthesised type name, label it.
    awk '/^entry:/ {
      for(i=1;i<=NF;i++) if ($i ~ /^\(/) {
        gsub(/[()]/, "", $i); print $i; next
      }
    }' "$BUNDLE_DIR/gblp1-inspect.txt" | while IFS= read -r _type; do
      [ -n "$_type" ] || continue
      _label=$(_entry_pretty_label "$_type")
      # Indent so the dash sits under the EFISP value column.
      ui_print "                 - $_label: attached"
    done
  else
    _why=$(awk -F': ' '/^result: /{print $2; exit}' "$BUNDLE_DIR/gblp1-inspect.txt")
    ui_print "  EFISP        : PE present, GBLP1 ${_why:-error}"
  fi
}

# ----- loader-ABL ------------------------------------------------------

# 10-byte UTF-16 LE "efisp" pattern: 65 00 66 00 69 00 73 00 70 00
EFISP_HEX='65006600690073007000'

scan_for_loader_path() {  # $1 = path to PE or raw image
  od -An -tx1 -v "$1" 2>/dev/null | tr -d ' \n' | grep -q "$EFISP_HEX"
}

collect_abl() {
  : > "$BUNDLE_DIR/loader-abl.txt"
  for _slot in a b; do
    _dev=$(byname "abl_$_slot")
    [ -n "$_dev" ] || continue
    dd if="$_dev" of="$BUNDLE_DIR/abl_$_slot.img" bs=1M 2>/dev/null
    # Try fv-unwrap to extract the PE; fall back to scanning the raw image.
    _pe_path="$WORKDIR/abl_$_slot.pe"
    if fv-unwrap "$BUNDLE_DIR/abl_$_slot.img" "$_pe_path" >/dev/null 2>&1; then
      _scan_target="$_pe_path"
    else
      _scan_target="$BUNDLE_DIR/abl_$_slot.img"
    fi
    if scan_for_loader_path "$_scan_target"; then
      eval "LOADER_PATH_$(echo "$_slot" | tr '[:lower:]' '[:upper:]')=1"
      echo "abl_$_slot: retains loader path" >> "$BUNDLE_DIR/loader-abl.txt"
    else
      echo "abl_$_slot: does NOT retain loader path — WON'T LOAD EFISP" >> "$BUNDLE_DIR/loader-abl.txt"
    fi
  done
  _a=$([ "$LOADER_PATH_A" = 1 ] && echo "abl_a retains loader path" || echo "abl_a does NOT — WON'T LOAD EFISP")
  _b=$([ "$LOADER_PATH_B" = 1 ] && echo "abl_b retains loader path" || echo "abl_b does NOT — WON'T LOAD EFISP")
  ui_print "  loader-ABL   : $_a ; $_b"
}

# ----- vbmeta + graft --------------------------------------------------

collect_vbmeta() {
  for _slot in a b; do
    _dev=$(byname "vbmeta_$_slot")
    [ -n "$_dev" ] || continue
    dd if="$_dev" of="$BUNDLE_DIR/vbmeta_$_slot.img" bs=1M 2>/dev/null
  done
  if [ -f "$BUNDLE_DIR/vbmeta_$SLOT.img" ]; then
    vbmeta-graft list "$BUNDLE_DIR/vbmeta_$SLOT.img" > "$BUNDLE_DIR/vbmeta-descriptors.txt" 2>&1 || true
  else
    : > "$BUNDLE_DIR/vbmeta-descriptors.txt"
  fi
}

check_graft() {
  if [ ! -f "$BUNDLE_DIR/vbmeta_$SLOT.img" ]; then
    ui_print "  avb chain    : unknown (no active vbmeta)"
    : > "$BUNDLE_DIR/graft-verdict.txt"
    return
  fi
  GBL_VBMETA_SLOT="$SLOT" vbmeta-graft list-hash \
    "$BUNDLE_DIR/vbmeta_$SLOT.img" "$BYNAME" > "$BUNDLE_DIR/graft-verdict.txt" 2>&1 || true

  # Pull AOSP-init boot-blocker rows from `vbmeta-graft list-hash`:
  # chain partitions whose AvbFooter is absent (no_vbmeta → init returns
  # ok_not_signed) or whose embedded vbmeta won't sig-verify against the
  # chain descriptor's OEM pubkey (key_mismatch → init libavb rejects).
  # Hash-descriptor rows (`type=hash digest=mismatch`) are NOT extracted:
  # every installed mode tolerates them. The raw per-row data lives in
  # `graft-verdict.txt` in the bundle.
  # Stock chained sub-vbmeta partitions (vbmeta_system, vbmeta_vendor, ...)
  # are OEM-signed and never grafted by gbl-chainload, so exclude them — they
  # are not actionable. Real graft targets (boot, dtbo, recovery, init_boot,
  # vendor_boot) remain.
  CHAIN_BROKEN_LIST=$(awk '/type=chain/ && (/graft=no_vbmeta/ || /graft=key_mismatch/) {
    for(i=1;i<=NF;i++) if($i ~ /^partition=/) {
      split($i,a,"="); p=a[2];
      if (p !~ /^vbmeta/) printf "%s ",p
    }
  }' "$BUNDLE_DIR/graft-verdict.txt" | sed 's/ $//')

  # AVB-chain state — descriptive, not prescriptive. Only a mode-1
  # (locked-presenting) boot makes AOSP init re-verify the on-disk vbmeta
  # chain, so a broken chain is a *potential* blocker there; mode-2 (and
  # mode-0) tolerate every mismatch. We can tell mode-2 from the overlay but
  # not mode-1 from mode-0, so we report the observation + the mode-1
  # condition rather than ordering a graft. Raw per-partition rows are in
  # graft-verdict.txt.
  if [ "$HAS_MODE2_PROFILE" = 1 ] || [ -z "$CHAIN_BROKEN_LIST" ]; then
    ui_print "  avb chain    : ok"
  else
    ui_print "  avb chain    : $CHAIN_BROKEN_LIST fail verified-boot — could require graft (mode-1 only)"
  fi
}

# ----- logfs blob ------------------------------------------------------

# Capture the raw logfs partition for off-device inspection. We use the
# uefilog rotation mechanism for the durable copies; the on-screen "N prior
# boots" tally was noise (operator can't act on it pre-reboot) and is gone.
collect_logfs() {
  _dev=$(byname logfs)
  if [ -z "$_dev" ]; then
    : > "$BUNDLE_DIR/logfs.img"
    return
  fi
  dd if="$_dev" of="$BUNDLE_DIR/logfs.img" bs=1M 2>/dev/null
}

# ----- finalize --------------------------------------------------------

# Seal the working dir into $BUNDLE_TGZ, emit the `bundle saved` UI line
# (which tees into report.txt inside the bundle), then remove the
# working dir. The tarball is the persistent artifact.
#
# Ordering trick: `ui_print` appends to $BUNDLE_DIR/report.txt, so the
# `bundle saved` line only lands inside the archive if we tar AFTER
# printing it. We do that, but write the re-seal to $BUNDLE_TGZ.tmp and
# atomic-mv it into place. Two failure modes that an in-place re-tar
# couldn't handle cleanly are then both safe:
#   1. Re-seal fails (rare — ENOSPC mid-stream, signal, IO error) →
#      the first-seal .tar.gz is untouched and the working dir is kept
#      for retry. No corrupt artifact is left under $BUNDLE_TGZ.
#   2. Operator pulls $BUNDLE_TGZ mid-run → never sees a half-written
#      archive (mv is atomic on the same filesystem).
# Only when the first seal itself fails do we leave the working dir as
# the last resort.
#
# `tar -C` (not a subshell `cd`) so $BUNDLE_TGZ works whether the
# caller passed an absolute or relative path.
_seal_tar_gz_to() {  # $1 = output path
  tar -czf "$1" -C "$BUNDLE_WORKDIR" "$(basename "$BUNDLE_DIR")" 2>/dev/null
}
_seal_tar_plain_to() {  # $1 = output path
  tar -cf  "$1" -C "$BUNDLE_WORKDIR" "$(basename "$BUNDLE_DIR")" 2>/dev/null
}

finalize_bundle() {
  if _seal_tar_gz_to "$BUNDLE_TGZ"; then
    ui_print "  bundle saved : $BUNDLE_TGZ"
    if _seal_tar_gz_to "$BUNDLE_TGZ.tmp"; then
      mv "$BUNDLE_TGZ.tmp" "$BUNDLE_TGZ"
      rm -rf "$BUNDLE_DIR"
    else
      rm -f "$BUNDLE_TGZ.tmp"
      ui_print "  (re-seal failed — original .tar.gz intact but missing"
      ui_print "   the 'bundle saved' line; $BUNDLE_DIR kept for retry)"
    fi
    return
  fi
  BUNDLE_TAR="${BUNDLE_TGZ%.gz}"
  if _seal_tar_plain_to "$BUNDLE_TAR"; then
    BUNDLE_TGZ="$BUNDLE_TAR"
    ui_print "  (gzip absent — plain tar saved instead)"
    ui_print "  bundle saved : $BUNDLE_TGZ"
    if _seal_tar_plain_to "$BUNDLE_TGZ.tmp"; then
      mv "$BUNDLE_TGZ.tmp" "$BUNDLE_TGZ"
      rm -rf "$BUNDLE_DIR"
    else
      rm -f "$BUNDLE_TGZ.tmp"
      ui_print "  (re-seal failed — original .tar intact but missing"
      ui_print "   the 'bundle saved' line; $BUNDLE_DIR kept for retry)"
    fi
    return
  fi
  ui_print "  (tar creation failed — working dir at $BUNDLE_DIR/ left intact)"
}

# ----- entry point ------------------------------------------------------

mode_main() {
  prepare_bundle
  ui_print "diag: pre-reboot install state"
  collect_env
  collect_efisp
  collect_abl
  collect_vbmeta
  check_graft
  collect_logfs                  # captures logfs.img into the bundle; no UI
  ui_print ""
  finalize_bundle                # emits the `bundle saved` line itself
}
