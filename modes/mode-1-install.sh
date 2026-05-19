# shellcheck shell=sh
# shellcheck disable=SC2154,SC2034,SC1091
# modes/mode-1-install.sh — install gbl-chainload mode-1 (VerifiedBoot
# fakelock). Renamed from the SP3 install mode.
#
# Thin wrapper: sources the shared install body (modes/install-common.sh) and
# declares the mode-1 parameters. mode-1 caches a plain-patched ABL (abl-patcher
# with no flags -> the universal + mode_1 patch groups). The whole install body
# (preflight / build_payload / commit_efisp / mode_main) lives in
# install-common.sh; this file adds no logic.

. "$WORKDIR/modes/install-common.sh"

M_EFI=mode-1.efi
M_LABEL=mode-1-install
M_PATCHER_ARGS=""
M_PACK_ARGS=""
