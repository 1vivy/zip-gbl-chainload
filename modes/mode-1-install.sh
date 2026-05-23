# shellcheck shell=sh
# shellcheck disable=SC2154,SC2034,SC1091
# modes/mode-1-install.sh — install gbl-chainload mode-1 (VerifiedBoot
# fakelock). Renamed from the SP3 install mode.
#
# Sources the shared install body (modes/install-common.sh), declares the mode-1
# parameters, and hooks the optional recovery graft flow. mode-1 caches a
# plain-patched ABL (abl-patcher with no flags — abl_permissive is gated on
# --oem, which mode-1 does not pass) and ships a manifest with the fakelock
# capability bit set so the single gbl-chainload.efi engages the VerifiedBoot
# fakelock at runtime. The boot-chain install body still lives in
# install-common.sh.

. "$WORKDIR/modes/graft-common.sh"
. "$WORKDIR/modes/install-common.sh"

M_EFI=gbl-chainload.efi
M_LABEL=mode-1-install
M_PATCHER_ARGS=""
M_PACK_ARGS=""
M_MANIFEST_BITS=0x01

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

  if ! $BOOTMODE; then
    if [ -f "$GRAFT_CANDIDATE_ROOT/recovery.img" ]; then
      ui_print "[*] first-time/reinstall recovery candidate: $GRAFT_CANDIDATE_ROOT/recovery.img"
      graft_prepare_one recovery "$GRAFT_CANDIDATE_ROOT/recovery.img" "$TARGET"
      return 0
    fi

    _src=$(byname "recovery_$SLOT")
    [ -n "$_src" ] || abort "recovery_$SLOT partition not found"
    dd if="$_src" of="$WORKDIR/active_recovery.img" bs=1M 2>/dev/null \
      || abort "cannot read recovery_$SLOT"
    if graft_check_slot recovery "$WORKDIR/active_recovery.img" "$SLOT"; then
      ui_print "[*] active recovery_$SLOT already matches active vbmeta; no recovery graft needed"
      return 0
    fi

    ui_print "[*] active recovery_$SLOT is not graft-valid; trying to graft it in-place"
    graft_prepare_one recovery "$WORKDIR/active_recovery.img" "$TARGET"
    return 0
  fi

  if [ -f "$GRAFT_CANDIDATE_ROOT/recovery.img" ]; then
    ui_print "[*] booted-system recovery graft input: $GRAFT_CANDIDATE_ROOT/recovery.img"
    graft_prepare_one recovery "$GRAFT_CANDIDATE_ROOT/recovery.img" "$TARGET"
  else
    ui_print "[*] booted-system install: no recovery graft input; skipping graft"
  fi
}

mode_preinstall_write() {
  [ "${GRAFT_ENABLED:-0}" = 1 ] || return 0
  graft_commit_prepared
}
