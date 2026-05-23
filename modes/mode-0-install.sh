# shellcheck shell=sh
# shellcheck disable=SC2154,SC2034,SC1091
# modes/mode-0-install.sh — install gbl-chainload mode-0 (honest observation).
#
# Thin wrapper: sources the shared install body (modes/install-common.sh) and
# declares the mode-0 parameters. mode-0 caches an unmodified-by-default ABL
# (abl-patcher with no flags — abl_permissive is gated on --oem, which mode-0
# does not pass) and ships a manifest with no capability bits set: no
# fakelock, no profile spoof. The whole install body (preflight /
# build_payload / commit_efisp / mode_main) lives in install-common.sh; this
# file adds no logic.

. "$WORKDIR/modes/install-common.sh"

M_EFI=gbl-chainload.efi
M_LABEL=mode-0-install
M_PATCHER_ARGS=""
M_PACK_ARGS=""
M_MANIFEST_BITS=0x00
