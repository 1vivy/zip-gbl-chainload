#!/usr/bin/env bash
# update-tools.sh — refresh the vendored tool binary and the single base
# EFI (gbl-chainload.efi) from a gbl-chainload parent checkout, and
# (re)write bin/MANIFEST.
#
# Engine rework: one EFI replaces the three per-mode EFIs.
# PR2 Task 9: the 7 per-tool C binaries collapsed into a single `gbl`
# Rust multicall (cross-built for aarch64-linux-android), so this
# script copies one binary into bin/ rather than seven.
#
# Run from inside the submodule checkout. The parent gbl-chainload repo
# is the directory containing this submodule; override with --parent.
#
#   ./update-tools.sh [--parent /path/to/gbl-chainload]
#
# bin/busybox-arm64 is vendored once at bootstrap and NOT rebuilt here;
# it is preserved and re-hashed into the manifest.
set -euo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
PARENT=$(cd "$SELF_DIR/.." && pwd)
if [ "${1:-}" = --parent ]; then
  PARENT=$(cd "$2" && pwd); shift 2
fi

[ -f "$PARENT/scripts/build-recovery-tools.sh" ] \
  || { echo "error: $PARENT is not a gbl-chainload checkout" >&2; exit 1; }

echo "==> building recovery tool (gbl multicall) from $PARENT"
bash "$PARENT/scripts/build-recovery-tools.sh"
echo "==> building the base EFI"
bash "$PARENT/scripts/build.sh"

echo "==> copying artifacts into bin/ and base/"
mkdir -p "$SELF_DIR/bin" "$SELF_DIR/base"
cp "$PARENT/dist/recovery/gbl" "$SELF_DIR/bin/gbl"
cp "$PARENT/dist/gbl-chainload.efi" "$SELF_DIR/base/gbl-chainload.efi"
# Drop the legacy per-mode EFIs left from a prior update-tools run, so the
# disk -> MANIFEST audit in build-recovery-zip.sh does not flag them.
rm -f "$SELF_DIR/base/mode-0.efi" \
      "$SELF_DIR/base/mode-1.efi" \
      "$SELF_DIR/base/mode-2.efi"
# Drop the legacy per-tool C binaries (collapsed into bin/gbl in PR2 Task 9).
# Without this, an in-place update from a pre-Task-9 zip checkout would
# leave the old binaries on disk and fail the MANIFEST disk-coverage audit.
rm -f "$SELF_DIR/bin/fv-unwrap" \
      "$SELF_DIR/bin/abl-patcher" \
      "$SELF_DIR/bin/gbl-pack" \
      "$SELF_DIR/bin/gbl-commit" \
      "$SELF_DIR/bin/vbmeta-graft" \
      "$SELF_DIR/bin/mode2-profile" \
      "$SELF_DIR/bin/gblp1-inspect"

[ -f "$SELF_DIR/bin/busybox-arm64" ] \
  || { echo "error: bin/busybox-arm64 missing - vendor it once at bootstrap" >&2; exit 1; }

echo "==> writing bin/MANIFEST"
PCOMMIT=$(git -C "$PARENT" rev-parse HEAD)
# Dirty = the parent's own tracked sources are modified (tools/EFI built
# from an uncommitted state). The zip submodule is excluded: update-tools.sh
# writes into zip/bin and zip/base, so it is dirty by construction here and
# is not a build input.
if git -C "$PARENT" diff --quiet -- ':!zip' \
   && git -C "$PARENT" diff --cached --quiet -- ':!zip'; then
  PDIRTY=0
else
  PDIRTY=1
  echo "WARNING: parent tree is dirty - MANIFEST marked parent-dirty: 1" >&2
fi
{
  echo "# zip-gbl-chainload vendored-artifact manifest"
  echo "# parent-commit: $PCOMMIT"
  echo "# parent-dirty: $PDIRTY"
  ( cd "$SELF_DIR" && sha256sum \
      bin/gbl bin/busybox-arm64 \
      base/gbl-chainload.efi )
} > "$SELF_DIR/bin/MANIFEST"

echo "==> done. Review, commit the submodule, and bump its pointer in the parent."
