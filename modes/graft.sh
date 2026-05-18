# shellcheck shell=sh
# shellcheck disable=SC2154
# modes/graft.sh — graft stock vbmeta onto custom partition image(s).
#
# For each /sdcard/gbl_<part>.img: resolve a suitable stock vbmeta (the
# picked slot first, then /sdcard/stock_<part>.img, then the other slot),
# graft it on, and flash the result to <part>_<slot>. See the SP4 spec.

# vol_key <timeout> -> UP | DOWN | TIMEOUT  (200 events: see zip-methodology A2)
vol_key() {
  _k=$(timeout "$1" getevent -lqc 200 2>/dev/null \
         | grep -m1 -oE 'KEY_(VOLUMEUP|VOLUMEDOWN)' || true)
  case "$_k" in
    KEY_VOLUMEUP)   echo UP ;;
    KEY_VOLUMEDOWN) echo DOWN ;;
    *)              echo TIMEOUT ;;
  esac
}

# pick_slot -> sets SLOT_SUF (a|b). Recovery prompts; BOOTMODE = inactive.
pick_slot() {
  if [ -z "$SLOT" ] || [ -z "$INACTIVE" ]; then abort "not an A/B device"; fi
  if $BOOTMODE; then
    SLOT_SUF="$INACTIVE"
    ui_print "[*] booted-Android: assuming post-OTA -> slot $SLOT_SUF"
    return 0
  fi
  ui_print "Please select slot to perform graft and flash on:"
  ui_print "  Vol-UP = A    Vol-DOWN = B"
  ui_print "  (If the OTA was flashed from recovery or you know it's on"
  ui_print "   the inactive slot, select that one.)"
  case "$(vol_key 15)" in
    UP)   SLOT_SUF=a ;;
    DOWN) SLOT_SUF=b ;;
    *)    abort "no slot selected" ;;
  esac
  ui_print "[*] target slot: $SLOT_SUF"
}

# graft_one <part> -> graft /sdcard/gbl_<part>.img onto <part>_$SLOT_SUF.
graft_one() {
  _part="$1"
  _custom="/sdcard/gbl_$_part.img"
  _target=$(byname "${_part}_${SLOT_SUF}")
  _mainvb=$(byname "vbmeta_${SLOT_SUF}")
  [ -n "$_target" ] || abort "partition ${_part}_${SLOT_SUF} not found"
  [ -n "$_mainvb" ] || abort "partition vbmeta_${SLOT_SUF} not found"

  ui_print "[*] $_part: selecting a suitable stock vbmeta"
  dd if="$_mainvb" of="$WORKDIR/main_vbmeta.img" bs=1M 2>/dev/null \
    || abort "cannot read vbmeta_${SLOT_SUF}"

  # candidate priority: picked slot, /sdcard/stock, other slot.
  _other=a; [ "$SLOT_SUF" = a ] && _other=b
  _stock=""
  for _cand in "$_target" "/sdcard/stock_$_part.img" "$(byname "${_part}_${_other}")"; do
    if [ -z "$_cand" ] || [ ! -e "$_cand" ]; then continue; fi
    dd if="$_cand" of="$WORKDIR/cand.img" bs=1M 2>/dev/null || continue
    if vbmeta-graft check "$WORKDIR/cand.img" "$WORKDIR/main_vbmeta.img" \
         "$_part" >/dev/null 2>&1; then
      cp "$WORKDIR/cand.img" "$WORKDIR/stock_$_part.img"
      _stock="$WORKDIR/stock_$_part.img"
      ui_print "    using stock vbmeta from: $_cand"
      break
    fi
  done
  [ -n "$_stock" ] || abort "$_part: no suitable stock vbmeta candidate"

  _psz=$(blockdev --getsize64 "$_target") || abort "cannot size $_target"
  ui_print "[*] $_part: grafting"
  vbmeta-graft graft --stock "$_stock" --custom "$_custom" \
    --part-size "$_psz" --out "$WORKDIR/grafted_$_part.img" \
    || abort "$_part: vbmeta-graft graft failed"

  ui_print "[*] $_part: writing ${_part}_${SLOT_SUF} (backup + verify)"
  commit_verified "$WORKDIR/grafted_$_part.img" "$_target" \
    "/sdcard/${_part}_${SLOT_SUF}.bak"
}

mode_main() {
  ui_print "graft: vbmeta graft installer"
  ui_print ""

  # collect the custom images present
  _parts=""
  for _f in /sdcard/gbl_*.img; do
    [ -e "$_f" ] || continue
    _b=$(basename "$_f" .img)        # gbl_<part>
    _parts="$_parts ${_b#gbl_}"
  done
  [ -n "$_parts" ] || abort "no /sdcard/gbl_<part>.img found"
  ui_print "[*] custom images:$_parts"

  pick_slot
  for _p in $_parts; do
    graft_one "$_p"
  done

  ui_print ""
  ui_print "graft: done - reboot to use the grafted partition(s)."
}
