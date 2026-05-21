# shellcheck shell=sh
# shellcheck disable=SC2154,SC2034,SC1091
# modes/mode-1-install.sh — install gbl-chainload mode-1 (VerifiedBoot
# fakelock). Renamed from the SP3 install mode.
#
# Sources the shared install body (modes/install-common.sh), declares the mode-1
# parameters, and hooks the optional recovery graft flow. mode-1 caches a
# plain-patched ABL (abl-patcher with no flags -> the universal + mode_1 patch
# groups). The boot-chain install body still lives in install-common.sh.

. "$WORKDIR/modes/graft-common.sh"
. "$WORKDIR/modes/install-common.sh"

M_EFI=mode-1.efi
M_LABEL=mode-1-install
M_PATCHER_ARGS=""
M_PACK_ARGS=""

mode_preflight() {
  GRAFT_ENABLED=0

  if [ "$SCENARIO" = ota ] && ! $BOOTMODE; then
    _src=$(byname "recovery_$SLOT")
    if [ -n "$_src" ]; then
      ui_print "[*] OTA recovery retention: using active recovery_$SLOT as custom source"
      dd if="$_src" of="$WORKDIR/custom_recovery.img" bs=1M 2>/dev/null \
        || abort "cannot read recovery_$SLOT"
      GRAFT_STOCK_TARGET_ONLY=1
      graft_prepare_one recovery "$WORKDIR/custom_recovery.img" "$TARGET"
      GRAFT_STOCK_TARGET_ONLY=0
    else
      ui_print "[*] OTA recovery retention: no recovery_$SLOT partition; skipping graft"
    fi
    return 0
  fi

  if [ -f "$GRAFT_ROOT/recovery.img" ]; then
    ui_print "[*] namespaced recovery graft input: $GRAFT_ROOT/recovery.img"
    graft_prepare_one recovery "$GRAFT_ROOT/recovery.img" "$TARGET"
  else
    ui_print "[*] no optional graft input at $GRAFT_ROOT/recovery.img"
  fi
}

mode_preinstall_write() {
  [ "${GRAFT_ENABLED:-0}" = 1 ] || return 0
  graft_commit_prepared
}
