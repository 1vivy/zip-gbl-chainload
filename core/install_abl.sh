# shellcheck shell=sh
# shellcheck disable=SC2154,SC2015,SC2153
# SC2153: STEP/STEPS in _step are set by modes/install-common.sh's mode_main.
# core/install_abl.sh — partition/slot-generic loader-ABL machinery.
# Sourced by update-binary. Shared by the mode-N-install modes (via
# modes/install-common.sh).
# Functions: vol_key, abl_marker, pick_scenario, resolve_restore_source,
#            restore_abl, save_backup_abl, _step. Constant: BACKUP.

BACKUP=$GBL_BACKUP_DIR/backup_abl.img

# _step <message> -> advance the [N/STEPS] counter and announce the step.
# STEP/STEPS are the running install counter set by modes/install-common.sh's
# mode_main; defined here (sourced early by update-binary) so restore_abl and
# the mode-N-install bodies all see it.
_step() { STEP=$((STEP + 1)); ui_print "[$STEP/$STEPS] $1"; }

# vol_key -> echoes UP | DOWN | TIMEOUT.
# Prompting intentionally has no timeout: recovery installs should wait for an
# explicit choice, while BOOTMODE/update_engine paths avoid prompts entirely.
vol_key() {
  _k=$(getevent -lq 2>/dev/null \
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
    ui_print "  Vol-UP   = OTA install: ROM/OTA was just flashed; target inactive slot"
    ui_print "  Vol-DOWN = reinstall/repair current slot"
    ui_print "  First-time active-slot installs: choose reinstall/repair after loading"
    ui_print "  custom recovery for this slot. OTA recovery retention is automatic only"
    ui_print "  for the OTA/inactive-slot pathway."
    case "$(vol_key)" in
      UP) SCENARIO=ota ;;
      *)  SCENARIO=reinstall ;;
    esac
  fi
  if [ "$SCENARIO" = ota ]; then TARGET="$INACTIVE"; else TARGET="$SLOT"; fi
  ui_print "[*] scenario=$SCENARIO  target slot=$TARGET"
}

# resolve_restore_source -> sets RESTORE_SRC, SAVED_FROM_BACKUP, RESTORE_SKIP.
# Candidate X = the active-slot ABL; exploit-check it; P3 prompt; fall to
# $BACKUP; abort if no vulnerable source exists.
resolve_restore_source() {
  RESTORE_SKIP=false
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

  if [ "$SCENARIO" = reinstall ]; then
    $_xvuln || abort "active-slot ABL is not vulnerable; reinstall/repair cannot restore abl_$SLOT to itself"
    RESTORE_SRC="$WORKDIR/active_abl.img"
    SAVED_FROM_BACKUP=false
    RESTORE_SKIP=true
    ui_print "[*] active-slot ABL already provides the loader path; no ABL write needed"
    return 0
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
      ui_print "  Vol-UP = yes   Vol-DOWN = use $BACKUP instead"
      case "$(vol_key)" in
        DOWN) RESTORE_SRC="$BACKUP" ;;
        *)    RESTORE_SRC="$WORKDIR/active_abl.img" ;;
      esac
    fi
  else
    ui_print "[*] active-slot ABL not vulnerable - using $BACKUP"
    RESTORE_SRC="$BACKUP"
  fi

  if [ "$RESTORE_SRC" = "$BACKUP" ]; then
    [ -f "$BACKUP" ] || abort "no vulnerable restore source: $BACKUP is missing"
    [ "$(abl_marker "$BACKUP" "$WORKDIR/backup_pe.efi")" = present ] \
      || abort "$BACKUP is not a vulnerable ABL"
    SAVED_FROM_BACKUP=true
  else
    SAVED_FROM_BACKUP=false
  fi
  ui_print "[*] restore source: $RESTORE_SRC"
}

# restore_abl -> verified write of the restore source onto abl_<target>.
# STEP/STEPS are the running step counter set by modes/install-common.sh.
restore_abl() {
  if $RESTORE_SKIP; then
    _step "active-slot loader ABL verified; skipping ABL restore"
    return 0
  fi
  _step "restoring loader ABL to abl_$TARGET (backup + verify)"
  commit_verified "$RESTORE_SRC" "$TARGET_DEV" "$GBL_BACKUP_DIR/abl_$TARGET.img"
}

# save_backup_abl -> P4: offer to save the exploit ABL to $BACKUP.
save_backup_abl() {
  $SAVED_FROM_BACKUP && return 0
  if $BOOTMODE; then
    [ -f "$BACKUP" ] && return 0
    mkdir -p "$GBL_BACKUP_DIR" || abort "cannot create $GBL_BACKUP_DIR"
    cp "$RESTORE_SRC" "$BACKUP" && ui_print "[*] saved exploit ABL to $BACKUP"
  else
    ui_print "Save the exploit ABL just used to $BACKUP?"
    ui_print "  Vol-UP = yes   Vol-DOWN = skip"
    if [ "$(vol_key)" = UP ]; then
      mkdir -p "$GBL_BACKUP_DIR" || abort "cannot create $GBL_BACKUP_DIR"
      cp "$RESTORE_SRC" "$BACKUP" && ui_print "[*] saved exploit ABL to $BACKUP"
    fi
  fi
}
