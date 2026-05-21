# shellcheck shell=sh
# shellcheck disable=SC2154,SC1091
# modes/graft.sh — graft stock vbmeta onto the namespaced custom recovery image.
#
# /sdcard/gbl-chainload/graft/recovery.img is grafted and flashed to the
# selected recovery_<slot>. Mode-1 OTA installs reuse graft-common.sh to do the
# same operation automatically from the active recovery partition.

. "$WORKDIR/modes/graft-common.sh"

# vol_key -> UP | DOWN | TIMEOUT. No timeout: recovery prompts wait for an
# explicit choice; BOOTMODE avoids this prompt.
vol_key() {
  _k=$(getevent -lq 2>/dev/null \
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
  ui_print "Please select slot to graft and flash recovery onto:"
  ui_print "  Vol-UP = A    Vol-DOWN = B"
  ui_print "  (If the OTA was flashed from recovery or you know it's on"
  ui_print "   the inactive slot, select that one.)"
  case "$(vol_key)" in
    UP)   SLOT_SUF=a ;;
    DOWN) SLOT_SUF=b ;;
    *)    abort "no slot selected" ;;
  esac
  ui_print "[*] target slot: $SLOT_SUF"
}

mode_main() {
  ui_print "graft: vbmeta graft installer"
  ui_print ""

  [ -f "$GRAFT_ROOT/recovery.img" ] \
    || abort "no namespaced graft input: $GRAFT_ROOT/recovery.img"
  ui_print "[*] custom recovery image: $GRAFT_ROOT/recovery.img"

  pick_slot
  graft_prepare_one recovery "$GRAFT_ROOT/recovery.img" "$SLOT_SUF"
  graft_commit_prepared

  ui_print ""
  ui_print "graft: done - reboot to use the grafted partition(s)."
  ui_print "backups kept: $GBL_BACKUP_DIR"
}
