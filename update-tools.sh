#!/usr/bin/env bash
# update-tools.sh — refresh the vendored tool binaries and base EFIs
# from a gbl-chainload parent checkout, and (re)write bin/MANIFEST.
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

echo "==> building recovery tools from $PARENT"
bash "$PARENT/scripts/build-recovery-tools.sh"
echo "==> building base EFIs"
bash "$PARENT/scripts/build.sh" --mode 1
bash "$PARENT/scripts/build.sh" --mode 2

echo "==> copying artifacts into bin/ and base/"
mkdir -p "$SELF_DIR/bin" "$SELF_DIR/base"
for t in fv-unwrap abl-patcher gbl-pack gbl-commit; do
  cp "$PARENT/dist/recovery/$t" "$SELF_DIR/bin/$t"
done
cp "$PARENT/dist/mode-1.efi" "$SELF_DIR/base/mode-1.efi"
cp "$PARENT/dist/mode-2.efi" "$SELF_DIR/base/mode-2.efi"

[ -f "$SELF_DIR/bin/busybox-arm64" ] \
  || { echo "error: bin/busybox-arm64 missing - vendor it once at bootstrap" >&2; exit 1; }

echo "==> writing bin/MANIFEST"
PCOMMIT=$(git -C "$PARENT" rev-parse HEAD)
if git -C "$PARENT" diff --quiet && git -C "$PARENT" diff --cached --quiet; then
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
      bin/fv-unwrap bin/abl-patcher bin/gbl-pack bin/gbl-commit \
      bin/busybox-arm64 base/mode-1.efi base/mode-2.efi )
} > "$SELF_DIR/bin/MANIFEST"

echo "==> done. Review, commit the submodule, and bump its pointer in the parent."
