# shellcheck shell=sh
# shellcheck disable=SC2154,SC2009,SC2034
# core/env.sh — environment detection and SELinux setup.
# Sourced by update-binary. See zip-methodology.md A4.
# Plumbing patterns from AnyKernel3 (osm0sis, MIT-style license).

# Boot mode: zygote in the process list => full Android is running
# (flash-from-system); otherwise we are in recovery.
BOOTMODE=false
ps | grep zygote | grep -v grep >/dev/null 2>&1 && BOOTMODE=true
$BOOTMODE || ps -A 2>/dev/null | grep zygote | grep -v grep >/dev/null 2>&1 && BOOTMODE=true

# Working directory for any mode output.
DIR=/sdcard
$BOOTMODE || DIR=$(dirname "$ZIPFILE")
[ "$DIR" = /sideload ] && DIR=/tmp

# SELinux: elevate so raw block writes are permitted under a booted
# enforcing system; a harmless no-op in a permissive recovery. The
# original context is saved in $shcon and restored by core/safety.sh.
shcon=$(cat /proc/self/attr/current 2>/dev/null)
echo "u:r:su:s0" > /proc/self/attr/current 2>/dev/null
