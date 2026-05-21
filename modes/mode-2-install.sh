# shellcheck shell=sh
# shellcheck disable=SC2154,SC2034,SC1091,SC2153
# modes/mode-2-install.sh — install gbl-chainload mode-2 (QSEE/SPSS TA-payload
# spoof). Renamed from the SP5 profile mode.
#
# Like the other install modes, but for mode-2: the cached ABL is OEM-patched
# (--oem <id> --no-mode1) and the GBLP1 overlay also carries a 120-byte
# mode2_profile derived on-device from a stock OEM vbmeta. The loader ABL
# written to the target slot is unchanged from the other install modes —
# vulnerable, retains the GBL/EFISP loader path.
#
# Thin wrapper: sources the shared install body (modes/install-common.sh) and
# declares the mode-2 parameters. The mode-2-only logic is the detect_oem and
# build_profile functions below plus two hook overrides:
#   mode_preflight  adds the stock-vbmeta pre-write gate.
#   mode_prepare    detects the OEM, derives/compiles the profile, and
#                   populates M_PATCHER_ARGS / M_PACK_ARGS before the shared
#                   build_payload.
# The rest of the install body lives in install-common.sh.

. "$WORKDIR/modes/install-common.sh"

M_EFI=mode-2.efi
M_LABEL=mode-2-install
M_WANT_PROFILE=1

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
    *oneplus*|*oppo*|*oplus*|*realme*) OEM_ID=oneplus ;;
    *) abort "unsupported OEM (build.prop manufacturer='$_mfr')" ;;
  esac
  ui_print "[*] OEM detected: $OEM_ID"
}

# build_profile -> derives + compiles the 120-byte mode2_profile binary.
build_profile() {
  _step "deriving + compiling mode-2 profile from stock vbmeta"
  mode2-profile derive "$STOCK_VBMETA" -o "$PROFILE_TOML" \
    || abort "mode2-profile derive failed"
  mode2-profile compile "$PROFILE_TOML" -o "$WORKDIR/profile.bin" \
    || abort "mode2-profile compile failed"
}

# mode_prepare -> mode-2 hook override. Runs after resolve_restore_source and
# before build_payload: detect the OEM, derive/compile the profile, then
# populate the patch/pack args the shared build_payload consumes.
mode_prepare() {
  detect_oem
  build_profile
  M_PATCHER_ARGS="--oem $OEM_ID --no-mode1"
  M_PACK_ARGS="--mode2-profile $WORKDIR/profile.bin"
}

# mode_preflight -> mode-2 hook override: gate on the stock vbmeta being
# present. Runs at the end of the shared preflight, before any write.
mode_preflight() {
  [ -f "$STOCK_VBMETA" ] \
    || abort "$STOCK_VBMETA required — place the stock OEM vbmeta there"
}
