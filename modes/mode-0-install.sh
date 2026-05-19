# shellcheck shell=sh
# shellcheck disable=SC2154,SC2034,SC1091
# modes/mode-0-install.sh — install gbl-chainload mode-0 (honest observation).
#
# Thin wrapper: sources the shared install body (modes/install-common.sh) and
# declares the mode-0 parameters. mode-0 caches a UNIVERSAL-patched ABL only
# (abl-patcher --no-mode1, no --oem) — no fakelock, no spoof. The whole
# install body (preflight / build_payload / commit_efisp / mode_main) lives in
# install-common.sh; this file adds no logic.

. "$WORKDIR/modes/install-common.sh"

M_EFI=mode-0.efi
M_LABEL=mode-0-install
M_PATCHER_ARGS="--no-mode1"
M_PACK_ARGS=""
