# shellcheck shell=sh
# shellcheck disable=SC2154
# core/ui.sh — canonical recovery on-screen output.
# Sourced by update-binary. See gbl-chainload docs/project/zip-methodology.md A2.
# Plumbing pattern from AnyKernel3 (osm0sis, MIT-style license).
#
# Writes to the recovery's OUTFD via its /proc path — never `>&$fd`
# (busybox ash rejects a quoted fd; an unquoted one varies across builds).
# The literal newline inside the quoted string is the blank spacer line;
# never `echo -e` (busybox echo -e support is inconsistent).

ui_print() {
  echo "ui_print $1
ui_print" >> /proc/self/fd/"$OUTFD"
}
