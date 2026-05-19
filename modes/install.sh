# shellcheck shell=sh
# shellcheck disable=SC2154,SC2015
# modes/install.sh — install gbl-chainload onto EFISP.
#
# Caches a patched ABL into the GBLP1 overlay appended to gbl-chainload on
# EFISP, and writes a known-vulnerable loader ABL onto the target slot so
# that slot loads gbl-chainload. See the SP3 design spec.
#
# Two ABLs, kept distinct:
#   cached  ABL -> patched + packed into the EFISP overlay; gbl-chainload runs it.
#   restore ABL -> written verbatim to abl_<target>; MUST be vulnerable (retain
#                  the GBL/EFISP loader path) so that on-disk ABL loads
#                  gbl-chainload.
#
# Loader-ABL machinery (vol_key, abl_marker, pick_scenario,
# resolve_restore_source, restore_abl, save_backup_abl, BACKUP) lives in
# core/install_abl.sh, sourced by update-binary before this file.

# preflight -> resolves device paths and gates everything before any write.
preflight() {
  TARGET_DEV=$(byname "abl_$TARGET")
  EFISP_DEV=$(byname efisp)
  ACTIVE_DEV=$(byname "abl_$SLOT")
  [ -n "$TARGET_DEV" ] || abort "abl_$TARGET partition not found"
  [ -n "$EFISP_DEV" ]  || abort "efisp partition not found"
  [ -n "$ACTIVE_DEV" ] || abort "abl_$SLOT partition not found"
  [ -f "$WORKDIR/base/mode-1.efi" ] || abort "base/mode-1.efi missing from ZIP"
  _mz=$(dd if="$EFISP_DEV" bs=1 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$_mz" = 4d5a ] || abort "EFISP does not currently hold a PE (got '$_mz')"
}

# build_payload -> reads abl_<target>, builds the GBLP1 overlay, produces
# $WORKDIR/installed.efi (base mode-1 EFI + payload).
build_payload() {
  ui_print "[1/4] reading abl_$TARGET (cache source)"
  dd if="$TARGET_DEV" of="$WORKDIR/cache_abl.img" bs=1M 2>/dev/null \
    || abort "failed to read abl_$TARGET"
  ui_print "[2/4] fv-unwrap + abl-patcher + gbl-pack"
  fv-unwrap "$WORKDIR/cache_abl.img" "$WORKDIR/extracted.efi" >/dev/null 2>&1 \
    || abort "fv-unwrap failed on the cache-source ABL"
  abl-patcher --in "$WORKDIR/extracted.efi" --out "$WORKDIR/patched.efi" \
    || abort "abl-patcher failed (no matching signatures?)"
  gbl-pack --cached-abl "$WORKDIR/patched.efi" \
           --source "$WORKDIR/cache_abl.img" \
           --extracted "$WORKDIR/extracted.efi" \
           --out "$WORKDIR/payload.bin" \
    || abort "gbl-pack failed"
  cat "$WORKDIR/base/mode-1.efi" "$WORKDIR/payload.bin" > "$WORKDIR/installed.efi"
}

# commit_efisp -> verified write of installed.efi onto EFISP.
commit_efisp() {
  ui_print "[3/4] writing EFISP (backup + verify)"
  commit_verified "$WORKDIR/installed.efi" "$EFISP_DEV" /sdcard/efisp.bak
}

mode_main() {
  ui_print "install: gbl-chainload installer"
  ui_print ""
  pick_scenario
  preflight
  resolve_restore_source
  build_payload
  commit_efisp
  restore_abl
  save_backup_abl
  ui_print ""
  ui_print "install: done - reboot to use the cached ABL."
  ui_print "backups kept: /sdcard/efisp.bak, /sdcard/abl_$TARGET.bak"
}
