# shellcheck shell=sh
# shellcheck disable=SC2154,SC2034
# core/safety.sh — abort / cleanup / verified-write, and the EXIT trap.
# Sourced by update-binary. See zip-methodology.md A6.
# Plumbing patterns from AnyKernel3 (osm0sis, MIT-style license).

# restore_env: undo the SELinux elevation core/env.sh applied.
restore_env() {
  [ -n "$shcon" ] && echo "$shcon" > /proc/self/attr/current 2>/dev/null
}

# cleanup: runs on every exit, success or failure.
cleanup() {
  restore_env
  [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
}

# abort: the loud failure path.
abort() {
  ui_print "ABORT: $1"
  cleanup
  exit 1
}

trap cleanup EXIT

GBL_STATE_DIR=/sdcard/gbl-chainload
GBL_BACKUP_DIR=$GBL_STATE_DIR/backups/latest

ensure_parent_dir() {
  _p=$1
  _d=${_p%/*}
  [ "$_d" = "$_p" ] && return 0
  mkdir -p "$_d" || abort "cannot create backup directory $_d"
}

# commit_verified <src-file> <dst-block> <backup-path>
# backup -> write -> verify -> restore-on-mismatch, via the bundled
# gbl-commit. A writing mode MUST use this, never a bare dd. SP2 ships
# no writing mode; this is the contract SP3/SP4 build on.
commit_verified() {
  command -v gbl-commit >/dev/null 2>&1 || abort "gbl-commit not on PATH"
  ensure_parent_dir "$3"
  gbl-commit --src "$1" --dst "$2" --backup "$3" --verify \
    || abort "verified write to $2 failed (backup at $3)"
}
