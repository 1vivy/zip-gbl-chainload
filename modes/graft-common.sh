# shellcheck shell=sh
# shellcheck disable=SC2154,SC2034
# modes/graft-common.sh — reusable recovery vbmeta-graft helper.

GRAFT_CANDIDATE_ROOT=/sdcard/gbl-chainload/graft-candidate
GRAFT_TARGET_ROOT=/sdcard/gbl-chainload/graft-target
GRAFT_PARTS="recovery"
GRAFT_ENABLED=0

graft_backup_path() {
  echo "$GBL_BACKUP_DIR/$1_$2.img"
}

graft_find_stock() {
  _part=$1
  _target_slot=$2
  _target_dev=$3
  _mainvb=$4
  _other=a; [ "$_target_slot" = a ] && _other=b
  _stock=""
  _candidates="$_target_dev"
  [ -f "$GRAFT_TARGET_ROOT/${_part}.img" ] \
    && _candidates="$_candidates $GRAFT_TARGET_ROOT/${_part}.img"
  [ "${GRAFT_STOCK_TARGET_ONLY:-0}" = 1 ] \
    || _candidates="$_candidates $(byname "${_part}_${_other}")"
  for _cand in $_candidates; do
    [ -n "$_cand" ] || continue
    dd if="$_cand" of="$WORKDIR/cand_${_part}.img" bs=1M 2>/dev/null || continue
    if vbmeta-graft check "$WORKDIR/cand_${_part}.img" "$_mainvb" \
         "$_part" >/dev/null 2>&1; then
      cp "$WORKDIR/cand_${_part}.img" "$WORKDIR/stock_${_part}.img"
      _stock="$WORKDIR/stock_${_part}.img"
      ui_print "    $_part stock vbmeta: $_cand"
      break
    fi
  done
  [ -n "$_stock" ] || abort "$_part: no stock target matches vbmeta_${_target_slot}; provide $GRAFT_TARGET_ROOT/${_part}.img and rerun"
  echo "$_stock"
}

graft_check_slot() {
  _part=$1
  _candidate=$2
  _slot=$3
  _mainvb=$(byname "vbmeta_${_slot}")
  [ -n "$_mainvb" ] || return 1
  dd if="$_mainvb" of="$WORKDIR/check_vbmeta_${_part}_${_slot}.img" bs=1M 2>/dev/null \
    || return 1
  vbmeta-graft check "$_candidate" "$WORKDIR/check_vbmeta_${_part}_${_slot}.img" \
    "$_part" >/dev/null 2>&1
}

graft_prepare_one() {
  _part=$1
  _source=$2
  _target_slot=$3
  _target=$(byname "${_part}_${_target_slot}")
  _mainvb=$(byname "vbmeta_${_target_slot}")
  [ -n "$_target" ] || abort "partition ${_part}_${_target_slot} not found"
  [ -n "$_mainvb" ] || abort "partition vbmeta_${_target_slot} not found"
  if [ -z "$_source" ] || [ ! -e "$_source" ]; then
    abort "$_part graft source missing: $_source"
  fi

  ui_print "[*] $_part: preparing graft for slot $_target_slot"
  dd if="$_mainvb" of="$WORKDIR/main_vbmeta_${_part}.img" bs=1M 2>/dev/null \
    || abort "cannot read vbmeta_${_target_slot}"

  _stock=$(graft_find_stock "$_part" "$_target_slot" "$_target" "$WORKDIR/main_vbmeta_${_part}.img")
  _psz=$(blockdev --getsize64 "$_target") || abort "cannot size $_target"
  vbmeta-graft graft --stock "$_stock" --custom "$_source" \
    --part-size "$_psz" --out "$WORKDIR/grafted_${_part}.img" \
    || abort "$_part: vbmeta-graft graft failed"
  vbmeta-graft check "$WORKDIR/grafted_${_part}.img" \
    "$WORKDIR/main_vbmeta_${_part}.img" "$_part" >/dev/null 2>&1 \
    || abort "$_part: grafted image does not match vbmeta_${_target_slot}"

  eval "GRAFT_TARGET_${_part}='$_target'"
  eval "GRAFT_SLOT_${_part}='$_target_slot'"
  GRAFT_ENABLED=1
}

graft_commit_one() {
  _part=$1
  eval "_target=\${GRAFT_TARGET_${_part}:-}"
  eval "_slot=\${GRAFT_SLOT_${_part}:-}"
  [ -n "$_target" ] || return 0
  _step "grafting ${_part}_${_slot} (backup + verify)"
  commit_verified "$WORKDIR/grafted_${_part}.img" "$_target" \
    "$(graft_backup_path "$_part" "$_slot")"
}

graft_commit_prepared() {
  for _part in $GRAFT_PARTS; do
    graft_commit_one "$_part"
  done
}
