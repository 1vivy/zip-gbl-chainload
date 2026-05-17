# shellcheck shell=sh
# shellcheck disable=SC2034
# core/partition.sh — by-name partition resolution and A/B slot helpers.
# Sourced by update-binary. See zip-methodology.md A5.
# Plumbing patterns from AnyKernel3 (osm0sis, MIT-style license).

# BYNAME: directory of by-name partition symlinks.
BYNAME=/dev/block/by-name
[ -d "$BYNAME" ] || BYNAME=/dev/block/bootdevice/by-name
[ -d "$BYNAME" ] || BYNAME=$(find /dev/block/platform -type d -name by-name 2>/dev/null | head -1)

# byname <partition>: echo the block-device path, or nothing if absent.
byname() {
  [ -n "$BYNAME" ] && [ -e "$BYNAME/$1" ] && echo "$BYNAME/$1"
}

# A/B slot. SLOT and INACTIVE are "a"/"b", or empty on a non-A/B device.
SLOT=$(getprop ro.boot.slot_suffix 2>/dev/null)
SLOT=${SLOT#_}
case "$SLOT" in
  a) INACTIVE=b ;;
  b) INACTIVE=a ;;
  *) SLOT=""; INACTIVE="" ;;
esac
