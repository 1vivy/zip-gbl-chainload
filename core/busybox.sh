# shellcheck shell=sh
# shellcheck disable=SC2154
# core/busybox.sh — bundled-tool setup.
# Sourced by update-binary. See zip-methodology.md A3.
#
# Targets are aarch64-only, so there is no multi-arch probe (cf.
# AnyKernel3): the bundled aarch64 static tools in bin/ are made
# executable and put first on PATH. The recovery's own busybox is
# relied on for ubiquitous applets; bin/busybox-arm64, when present,
# backstops applets a given recovery's busybox may lack.

if [ -d "$WORKDIR/bin" ]; then
  chmod 755 "$WORKDIR"/bin/* 2>/dev/null
  PATH="$WORKDIR/bin:$PATH"
  export PATH
fi
