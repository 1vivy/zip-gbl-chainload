# shellcheck shell=sh
# shellcheck disable=SC2154,SC2015
# core/install_abl.sh — partition/slot-generic loader-ABL machinery.
# Sourced by update-binary. Shared by the mode-N-install modes (via
# modes/install-common.sh).
# Functions: vol_key, abl_marker, pick_scenario, resolve_restore_source,
#            restore_abl, save_backup_abl. Constant: BACKUP.

BACKUP=/sdcard/backup_abl.img

# vol_key <timeout-seconds> -> echoes UP | DOWN | TIMEOUT.
# -lqc 200: read enough events that the key press is not missed amid
# unrelated input (a press is paired down/up + EV_SYN, plus other input
# devices); grep -m1 stops getevent at the first vol-key match.
vol_key() {
  _k=$(timeout "$1" getevent -lqc 200 2>/dev/null \
         | grep -m1 -oE 'KEY_(VOLUMEUP|VOLUMEDOWN)' || true)
  case "$_k" in
    KEY_VOLUMEUP)   echo UP ;;
    KEY_VOLUMEDOWN) echo DOWN ;;
    *)              echo TIMEOUT ;;
  esac
}

# abl_marker <abl-image> <scratch-pe-out> -> echoes present | absent.
# Aborts if the image has no extractable PE. The bundled fv-unwrap prints
# 'efisp-marker: present|absent' on stdout after a successful extraction.
abl_marker() {
  _m=$(fv-unwrap "$1" "$2" 2>/dev/null) \
    || abort "fv-unwrap failed on $1 (unrecognised ABL format?)"
  case "$_m" in
    *"efisp-marker: present"*) echo present ;;
    *)                         echo absent  ;;
  esac
}

# pick_scenario -> sets SCENARIO (ota|reinstall) and TARGET (slot suffix).
pick_scenario() {
  [ -n "$SLOT" ] && [ -n "$INACTIVE" ] || abort "not an A/B device (no slot suffix)"
  if $BOOTMODE; then
    SCENARIO=ota
    ui_print "[*] booted-Android install - assuming post-OTA"
  elif $OTA_POSTINSTALL; then
    SCENARIO=ota
    ui_print "[*] update_engine postinstall detected - OTA install"
  else
    ui_print "Which install is this?"
    ui_print "  Vol-UP   = OTA install (an OTA was just flashed)"
    ui_print "  Vol-DOWN = re-install gbl-chainload   (no key in 10s = re-install)"
    case "$(vol_key 10)" in
      UP) SCENARIO=ota ;;
      *)  SCENARIO=reinstall ;;
    esac
  fi
  if [ "$SCENARIO" = ota ]; then TARGET="$INACTIVE"; else TARGET="$SLOT"; fi
  ui_print "[*] scenario=$SCENARIO  target slot=$TARGET"
}

# resolve_restore_source -> sets RESTORE_SRC and SAVED_FROM_BACKUP.
# Candidate X = the active-slot ABL; exploit-check it; P3 prompt; fall to
# /sdcard/backup_abl.img; abort if no vulnerable source exists.
resolve_restore_source() {
  ui_print "[*] checking active-slot ABL (abl_$SLOT) for the GBL loader path"
  dd if="$ACTIVE_DEV" of="$WORKDIR/active_abl.img" bs=1M 2>/dev/null \
    || abort "failed to read abl_$SLOT"
  if [ "$(abl_marker "$WORKDIR/active_abl.img" "$WORKDIR/active_pe.efi")" = present ]; then
    _xvuln=true
    ui_print "    active-slot ABL: vulnerable"
  else
    _xvuln=false
    ui_print "    active-slot ABL: NOT vulnerable"
  fi

  if $_xvuln; then
    if $BOOTMODE; then
      if [ -f "$BACKUP" ]; then
        RESTORE_SRC="$BACKUP"
      else
        RESTORE_SRC="$WORKDIR/active_abl.img"
      fi
    else
      ui_print "Restore the active-slot ABL to abl_$TARGET? (confirmed vulnerable)"
      ui_print "  Vol-UP = yes   Vol-DOWN = use /sdcard/backup_abl.img instead"
      case "$(vol_key 10)" in
        DOWN) RESTORE_SRC="$BACKUP" ;;
        *)    RESTORE_SRC="$WORKDIR/active_abl.img" ;;
      esac
    fi
  else
    ui_print "[*] active-slot ABL not vulnerable - using /sdcard/backup_abl.img"
    RESTORE_SRC="$BACKUP"
  fi

  if [ "$RESTORE_SRC" = "$BACKUP" ]; then
    [ -f "$BACKUP" ] || abort "no vulnerable restore source: /sdcard/backup_abl.img is missing"
    [ "$(abl_marker "$BACKUP" "$WORKDIR/backup_pe.efi")" = present ] \
      || abort "/sdcard/backup_abl.img is not a vulnerable ABL"
    SAVED_FROM_BACKUP=true
  else
    SAVED_FROM_BACKUP=false
  fi
  ui_print "[*] restore source: $RESTORE_SRC"
}

# restore_abl -> verified write of the restore source onto abl_<target>.
# STEP/STEPS are the running step counter set by modes/install-common.sh; if
# unset (no install-common consumer) the prefix degrades gracefully.
restore_abl() {
  ui_print "[$((${STEP:-0}+1))/${STEPS:-?}] restoring loader ABL to abl_$TARGET (backup + verify)"
  STEP=$((${STEP:-0}+1))
  commit_verified "$RESTORE_SRC" "$TARGET_DEV" "/sdcard/abl_$TARGET.bak"
}

# save_backup_abl -> P4: offer to save the exploit ABL to /sdcard/backup_abl.img.
save_backup_abl() {
  $SAVED_FROM_BACKUP && return 0
  if $BOOTMODE; then
    [ -f "$BACKUP" ] && return 0
    cp "$RESTORE_SRC" "$BACKUP" && ui_print "[*] saved exploit ABL to $BACKUP"
  else
    ui_print "Save the exploit ABL just used to /sdcard/backup_abl.img?"
    ui_print "  Vol-UP = yes, else skip"
    if [ "$(vol_key 10)" = UP ]; then
      cp "$RESTORE_SRC" "$BACKUP" && ui_print "[*] saved exploit ABL to $BACKUP"
    fi
  fi
}
