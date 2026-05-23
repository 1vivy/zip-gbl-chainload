# shellcheck shell=sh
# shellcheck disable=SC2154,SC2034,SC1091,SC2153
# modes/mode-2-install.sh — install gbl-chainload mode-2 (QSEE/SPSS TA-payload
# spoof). Renamed from the SP5 profile mode.
#
# Like the other install modes, but for mode-2: the cached ABL is OEM-patched
# (--oem <id>) and the GBLP1 overlay also carries a 120-byte mode2_profile
# derived on-device from a stock OEM vbmeta plus a manifest with the
# mode2_spoof capability bit set. The loader ABL written to the target slot
# is unchanged from the other install modes — vulnerable, retains the
# GBL/EFISP loader path.
#
# Thin wrapper: sources the shared install body (modes/install-common.sh) and
# declares the mode-2 parameters. The mode-2-only logic is build_profile plus
# two hook overrides:
#   mode_preflight  adds the stock-vbmeta pre-write gate.
#   mode_prepare    detects the OEM (shared install-common.sh helper),
#                   derives/compiles the profile, and populates
#                   M_PATCHER_ARGS / M_PACK_ARGS before the shared
#                   build_payload.
# detect_oem itself lives in install-common.sh now (engine rework: --oem is
# orthogonal to mode, so any future install mode can call detect_oem too).
# The rest of the install body lives in install-common.sh.

. "$WORKDIR/modes/install-common.sh"

M_EFI=gbl-chainload.efi
M_LABEL=mode-2-install
M_WANT_PROFILE=1
M_MANIFEST_BITS=0x02

STOCK_VBMETA=$GBL_STATE_DIR/mode-2/stock_vbmeta.img
PROFILE_TOML=$GBL_STATE_DIR/mode-2/profile.toml

# build_profile -> derives + compiles the 120-byte mode2_profile binary.
# Kept as two steps (derive → compile) so the intermediate TOML stays
# observable at $PROFILE_TOML for operator inspection / diffs; the
# multicall's `gbl mode2 build` composite buffers the TOML in-memory
# and would hide that, so we don't switch to it here.
build_profile() {
  _step "deriving + compiling mode-2 profile from stock vbmeta"
  gbl mode2 derive "$STOCK_VBMETA" -o "$PROFILE_TOML" \
    || abort "gbl mode2 derive failed"
  gbl mode2 compile "$PROFILE_TOML" -o "$WORKDIR/profile.bin" \
    || abort "gbl mode2 compile failed"
}

# mode_prepare -> mode-2 hook override. Runs after resolve_restore_source and
# before build_payload: detect the OEM (shared install-common.sh helper),
# derive/compile the profile, then populate the patch/pack args the shared
# build_payload consumes.
mode_prepare() {
  detect_oem
  build_profile
  M_PATCHER_ARGS="--oem $OEM_ID"
  M_PACK_ARGS="--mode2-profile $WORKDIR/profile.bin"
}

# mode_preflight -> mode-2 hook override: gate on the stock vbmeta being
# present. Runs at the end of the shared preflight, before any write.
mode_preflight() {
  [ -f "$STOCK_VBMETA" ] \
    || abort "$STOCK_VBMETA required — place the stock OEM vbmeta there"
}
