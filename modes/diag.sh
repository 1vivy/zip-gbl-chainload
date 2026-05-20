# shellcheck shell=sh
# shellcheck disable=SC2154,SC2012
# modes/diag.sh — pre-reboot EFISP-install confidence + state-bundle.
# Zero device writes. Produces /sdcard/gbl-chainload-diag-<ts>/ and a
# sibling .tar.gz that off-device analysis can chew on. See
# docs/superpowers/specs/2026-05-19-diag-confidence-design.md.

TS=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)
BUNDLE_ROOT="${BUNDLE_ROOT:-/sdcard}"
BUNDLE_DIR="$BUNDLE_ROOT/gbl-chainload-diag-$TS"
BUNDLE_TGZ="$BUNDLE_ROOT/gbl-chainload-diag-$TS.tar.gz"

# Track scalar state for the confidence-tier decision.
EFISP_PE=0              # 1 if EFISP starts with MZ
GBLP1_OK=0              # 1 if gblp1-inspect ended with result: ok
BASE_EFI_MODE=""        # mode-0 / mode-1 / mode-2 / unknown
LOADER_PATH_A=0         # 1 if abl_a retains loader path
LOADER_PATH_B=0         # 1 if abl_b retains loader path
GRAFT_NEEDED_LIST=""    # space-separated partitions needing graft mode
FAKELOCK_NEEDED_LIST="" # space-separated partitions needing fakelock (hash mismatch)
LOGFS_HISTORY=0         # count of prior GblChainload_BootN.txt
LOGFS_NEWEST=""         # newest filename

# ----- bundle plumbing ------------------------------------------------

prepare_bundle() {
  mkdir -p "$BUNDLE_DIR" || abort "cannot create $BUNDLE_DIR"
  # Free-space gate: warn if less than 100 MiB available.
  _free_kb=$(df -k "$BUNDLE_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')
  case "$_free_kb" in
    ''|*[!0-9]*) ;;
    *) [ "$_free_kb" -lt 102400 ] && abort "less than 100 MiB free on $BUNDLE_ROOT" ;;
  esac
  : > "$BUNDLE_DIR/report.txt"
}

# Override ui_print to tee to report.txt while still writing to recovery I/O.
ui_print() {
  echo "$1" >> "$BUNDLE_DIR/report.txt"
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

  # Fingerprint the base-EFI region (bytes before GBLP1) against MANIFEST.
  if command -v sha256sum >/dev/null 2>&1; then
    # Parse total_size from gblp1-inspect output.
    _ts=$(awk '/^header:/ { for(i=1;i<=NF;i++) { if ($i ~ /^total_size=/) { sub(/^total_size=/, "", $i); print $i; exit } } }' "$BUNDLE_DIR/gblp1-inspect.txt")
    if [ -n "$_ts" ] && [ "$_ts" -gt 0 ] 2>/dev/null; then
      _total=$(stat -c%s "$BUNDLE_DIR/efisp.img" 2>/dev/null || wc -c < "$BUNDLE_DIR/efisp.img" | tr -d ' ')
      _prefix_len=$((_total - _ts))
      if [ "$_prefix_len" -gt 0 ] 2>/dev/null; then
        _prefix_sha=$(dd if="$BUNDLE_DIR/efisp.img" bs=1 count="$_prefix_len" 2>/dev/null \
                       | sha256sum | awk '{print $1}')
        # Match against MANIFEST entries.
        if [ -f "$WORKDIR/bin/MANIFEST" ]; then
          while IFS= read -r _line; do
            _h=$(echo "$_line" | awk '{print $1}')
            _f=$(echo "$_line" | awk '{print $2}')
            case "$_f" in
              base/mode-0.efi) [ "$_h" = "$_prefix_sha" ] && BASE_EFI_MODE=mode-0 ;;
              base/mode-1.efi) [ "$_h" = "$_prefix_sha" ] && BASE_EFI_MODE=mode-1 ;;
              base/mode-2.efi) [ "$_h" = "$_prefix_sha" ] && BASE_EFI_MODE=mode-2 ;;
            esac
          done < "$WORKDIR/bin/MANIFEST"
        fi
      fi
    fi
  fi

  if [ "$GBLP1_OK" = 1 ]; then
    ui_print "  EFISP        : ${BASE_EFI_MODE:-unknown-base} + GBLP1 v1 ok"
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
      eval "LOADER_PATH_$(echo "$_slot" | tr 'a-z' 'A-Z')=1"
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
    ui_print "  graft needed : UNKNOWN (no active vbmeta)"
    ui_print "  fakelock req : UNKNOWN (no active vbmeta)"
    : > "$BUNDLE_DIR/graft-verdict.txt"
    return
  fi
  GBL_VBMETA_SLOT="$SLOT" vbmeta-graft list-hash \
    "$BUNDLE_DIR/vbmeta_$SLOT.img" "$BYNAME" > "$BUNDLE_DIR/graft-verdict.txt" 2>&1 || true

  # Bucket mismatches: graft=missing -> graft mode; graft=n/a -> fakelock.
  GRAFT_NEEDED_LIST=$(awk '/verdict=mismatch/ && /graft=missing/ {
    for(i=1;i<=NF;i++) if($i ~ /^partition=/) {split($i,a,"="); printf "%s ",a[2]}
  }' "$BUNDLE_DIR/graft-verdict.txt" | sed 's/ $//')
  FAKELOCK_NEEDED_LIST=$(awk '/verdict=mismatch/ && /graft=n\/a/ {
    for(i=1;i<=NF;i++) if($i ~ /^partition=/) {split($i,a,"="); printf "%s ",a[2]}
  }' "$BUNDLE_DIR/graft-verdict.txt" | sed 's/ $//')

  if [ -n "$GRAFT_NEEDED_LIST" ]; then
    ui_print "  graft needed : YES — $GRAFT_NEEDED_LIST"
  else
    ui_print "  graft needed : NO   (no chained-partition mismatches without a valid graft)"
  fi
  if [ -n "$FAKELOCK_NEEDED_LIST" ]; then
    ui_print "  fakelock req : YES — $FAKELOCK_NEEDED_LIST"
  else
    ui_print "  fakelock req : NO   (no direct-hash mismatches in main vbmeta)"
  fi
}

# ----- logfs history ----------------------------------------------------

collect_logfs() {
  _dev=$(byname logfs)
  if [ -z "$_dev" ]; then
    ui_print "  logfs history: NO logfs partition"
    : > "$BUNDLE_DIR/logfs.img"
    return
  fi
  dd if="$_dev" of="$BUNDLE_DIR/logfs.img" bs=1M 2>/dev/null
  LOGFS_HISTORY=$(grep -aoE 'GblChainload_Boot[0-9]+\.txt' "$BUNDLE_DIR/logfs.img" 2>/dev/null \
    | sort -u | wc -l | tr -d ' ')
  LOGFS_NEWEST=$(grep -aoE 'GblChainload_Boot[0-9]+\.txt' "$BUNDLE_DIR/logfs.img" 2>/dev/null \
    | sort -t'_' -k3 -n | tail -1)
  if [ "$LOGFS_HISTORY" -gt 0 ] 2>/dev/null; then
    ui_print "  logfs history: $LOGFS_HISTORY prior gbl-chainload boots (newest: $LOGFS_NEWEST)"
  else
    ui_print "  logfs history: no prior gbl-chainload boots recorded"
  fi
}

# ----- confidence tier --------------------------------------------------

decide_tier() {
  if [ "$EFISP_PE" = 0 ]; then
    echo "NONE — EFISP is not a PE"
    return
  fi
  if [ "$GBLP1_OK" = 0 ]; then
    echo "LOW — GBLP1 invalid or unverified"
    return
  fi
  if [ "$LOADER_PATH_A" = 1 ] || [ "$LOADER_PATH_B" = 1 ]; then
    echo "HIGH — safe to reboot into chainload"
  else
    echo "MEDIUM — GBLP1 valid; neither slot's ABL retains loader path (EFISP won't be loaded)"
  fi
}

# ----- finalize --------------------------------------------------------

finalize_bundle() {
  (cd "$BUNDLE_ROOT" && tar -czf "$(basename "$BUNDLE_TGZ")" "$(basename "$BUNDLE_DIR")") 2>/dev/null \
    || ui_print "  (tar.gz creation failed — directory at $BUNDLE_DIR/ is intact)"
}

# ----- entry point ------------------------------------------------------

mode_main() {
  prepare_bundle
  ui_print "diag: pre-reboot install confidence"
  collect_env
  collect_efisp
  collect_abl
  collect_vbmeta
  check_graft
  collect_logfs
  ui_print "  confidence   : $(decide_tier)"
  ui_print ""
  finalize_bundle
  ui_print "  bundle saved : $BUNDLE_TGZ"
  ui_print "                 directory:  $BUNDLE_DIR/"
}
