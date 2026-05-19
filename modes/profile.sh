# shellcheck shell=sh
# shellcheck disable=SC2154,SC2015
# modes/profile.sh — install gbl-chainload mode-2.
#
# Like install, but for mode-2: the cached ABL is OEM-patched (--oem <id>
# --no-mode1) and the GBLP1 overlay also carries a 120-byte mode2_profile
# derived on-device from a stock OEM vbmeta. The loader ABL written to the
# target slot is unchanged from install — vulnerable, retains the GBL/EFISP
# loader path.
#
# Loader-ABL machinery (vol_key, abl_marker, pick_scenario,
# resolve_restore_source, restore_abl, save_backup_abl, BACKUP) lives in
# core/install_abl.sh, sourced by update-binary before this file.

STOCK_VBMETA=/sdcard/stock_vbmeta.img
PROFILE_TOML=/sdcard/gbl-chainload_profile.toml

# detect_oem -> sets OEM_ID from build.prop. Aborts on an unsupported OEM.
detect_oem() {
  _bp=""
  for _p in /system/system/build.prop /system/build.prop /vendor/build.prop; do
    [ -f "$_p" ] && { _bp="$_p"; break; }
  done
  [ -n "$_bp" ] || abort "build.prop not found (mount system/vendor first)"
  _mfr=$(grep -m1 '^ro\.product\..*manufacturer=' "$_bp" \
           | cut -d= -f2 | tr -d ' \t\r' | tr '[:upper:]' '[:lower:]')
  case "$_mfr" in
    *oneplus*|*oppo*) OEM_ID=oneplus ;;
    *) abort "unsupported OEM (build.prop manufacturer='$_mfr')" ;;
  esac
  ui_print "[*] OEM detected: $OEM_ID"
}

# preflight -> resolves device paths and gates everything before any write.
# Sets the globals core/install_abl.sh consumes: TARGET_DEV, EFISP_DEV,
# ACTIVE_DEV. pick_scenario must have set TARGET first.
preflight() {
  TARGET_DEV=$(byname "abl_$TARGET")
  EFISP_DEV=$(byname efisp)
  ACTIVE_DEV=$(byname "abl_$SLOT")
  [ -n "$TARGET_DEV" ] || abort "abl_$TARGET partition not found"
  [ -n "$EFISP_DEV" ]  || abort "efisp partition not found"
  [ -n "$ACTIVE_DEV" ] || abort "abl_$SLOT partition not found"
  [ -f "$WORKDIR/base/mode-2.efi" ] || abort "base/mode-2.efi missing from ZIP"
  [ -f "$STOCK_VBMETA" ] \
    || abort "$STOCK_VBMETA required — place the stock OEM vbmeta there"
  _mz=$(dd if="$EFISP_DEV" bs=1 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$_mz" = 4d5a ] || abort "EFISP does not currently hold a PE (got '$_mz')"
}

# build_profile -> derives + compiles the 120-byte mode2_profile binary.
build_profile() {
  ui_print "[1/5] deriving mode-2 profile from stock vbmeta"
  mode2-profile derive "$STOCK_VBMETA" -o "$PROFILE_TOML" \
    || abort "mode2-profile derive failed"
  ui_print "[2/5] compiling profile"
  mode2-profile compile "$PROFILE_TOML" -o "$WORKDIR/profile.bin" \
    || abort "mode2-profile compile failed"
}

# build_payload -> reads abl_<target>, OEM-patches it, builds the GBLP1
# overlay (cached_abl + mode2_profile), produces $WORKDIR/installed.efi
# (base mode-2 EFI + payload).
build_payload() {
  ui_print "[3/5] caching abl_$TARGET (OEM-patched, --oem $OEM_ID)"
  dd if="$TARGET_DEV" of="$WORKDIR/cache_abl.img" bs=1M 2>/dev/null \
    || abort "failed to read abl_$TARGET"
  fv-unwrap "$WORKDIR/cache_abl.img" "$WORKDIR/extracted.efi" >/dev/null 2>&1 \
    || abort "fv-unwrap failed on the cache-source ABL"
  abl-patcher --oem "$OEM_ID" --no-mode1 \
    --in "$WORKDIR/extracted.efi" --out "$WORKDIR/patched.efi" \
    || abort "abl-patcher failed (no matching signatures?)"
  ui_print "[4/5] packing GBLP1 overlay (cached_abl + mode2_profile)"
  gbl-pack --cached-abl "$WORKDIR/patched.efi" \
           --source "$WORKDIR/cache_abl.img" \
           --extracted "$WORKDIR/extracted.efi" \
           --mode2-profile "$WORKDIR/profile.bin" \
           --out "$WORKDIR/payload.bin" \
    || abort "gbl-pack failed"
  cat "$WORKDIR/base/mode-2.efi" "$WORKDIR/payload.bin" > "$WORKDIR/installed.efi"
}

# commit_efisp -> verified write of installed.efi onto EFISP.
commit_efisp() {
  ui_print "[5/5] writing EFISP (backup + verify)"
  commit_verified "$WORKDIR/installed.efi" "$EFISP_DEV" /sdcard/efisp.bak
}

mode_main() {
  ui_print "profile: gbl-chainload mode-2 installer"
  ui_print ""
  detect_oem
  pick_scenario
  preflight
  resolve_restore_source
  build_profile
  build_payload
  commit_efisp
  restore_abl
  save_backup_abl
  ui_print ""
  ui_print "profile: done - reboot. mode-2 active."
  ui_print "backups kept: /sdcard/efisp.bak, /sdcard/abl_$TARGET.bak"
}
