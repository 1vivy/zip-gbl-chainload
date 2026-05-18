# shellcheck shell=sh
# shellcheck disable=SC2154,SC2015
# modes/install.sh — install gbl-chainload onto EFISP.
#
# Caches a patched ABL into the GBLP1 overlay appended to gbl-chainload on
# EFISP, and writes a known-vulnerable loader ABL onto the target slot so
# that slot loads gbl-chainload. See the SP3 design spec.
#
# Two ABLs, kept distinct:
#   cached  ABL -> patched + packed into the EFISP overlay; gbl-chainload runs it.
#   restore ABL -> written verbatim to abl_<target>; MUST be vulnerable (retain
#                  the GBL/EFISP loader path) so that on-disk ABL loads
#                  gbl-chainload.

BACKUP=/sdcard/backup_abl.img

# vol_key <timeout-seconds> -> echoes UP | DOWN | TIMEOUT
vol_key() {
  _k=$(timeout "$1" getevent -lqc 5 2>/dev/null \
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

# preflight -> resolves device paths and gates everything before any write.
preflight() {
  TARGET_DEV=$(byname "abl_$TARGET")
  EFISP_DEV=$(byname efisp)
  ACTIVE_DEV=$(byname "abl_$SLOT")
  [ -n "$TARGET_DEV" ] || abort "abl_$TARGET partition not found"
  [ -n "$EFISP_DEV" ]  || abort "efisp partition not found"
  [ -n "$ACTIVE_DEV" ] || abort "abl_$SLOT partition not found"
  [ -f "$WORKDIR/base/mode-1.efi" ] || abort "base/mode-1.efi missing from ZIP"
  _mz=$(dd if="$EFISP_DEV" bs=1 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$_mz" = 4d5a ] || abort "EFISP does not currently hold a PE (got '$_mz')"
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

# build_payload -> reads abl_<target>, builds the GBLP1 overlay, produces
# $WORKDIR/installed.efi (base mode-1 EFI + payload).
build_payload() {
  ui_print "[1/4] reading abl_$TARGET (cache source)"
  dd if="$TARGET_DEV" of="$WORKDIR/cache_abl.img" bs=1M 2>/dev/null \
    || abort "failed to read abl_$TARGET"
  ui_print "[2/4] fv-unwrap + abl-patcher + gbl-pack"
  fv-unwrap "$WORKDIR/cache_abl.img" "$WORKDIR/extracted.efi" >/dev/null 2>&1 \
    || abort "fv-unwrap failed on the cache-source ABL"
  abl-patcher --in "$WORKDIR/extracted.efi" --out "$WORKDIR/patched.efi" \
    || abort "abl-patcher failed (no matching signatures?)"
  gbl-pack --cached-abl "$WORKDIR/patched.efi" \
           --source "$WORKDIR/cache_abl.img" \
           --extracted "$WORKDIR/extracted.efi" \
           --out "$WORKDIR/payload.bin" \
    || abort "gbl-pack failed"
  cat "$WORKDIR/base/mode-1.efi" "$WORKDIR/payload.bin" > "$WORKDIR/installed.efi"
}

# commit_efisp -> verified write of installed.efi onto EFISP.
commit_efisp() {
  ui_print "[3/4] writing EFISP (backup + verify)"
  commit_verified "$WORKDIR/installed.efi" "$EFISP_DEV" /sdcard/efisp.bak
}

# restore_abl -> verified write of the restore source onto abl_<target>.
restore_abl() {
  ui_print "[4/4] restoring loader ABL to abl_$TARGET (backup + verify)"
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

mode_main() {
  ui_print "install: gbl-chainload installer"
  ui_print ""
  pick_scenario
  preflight
  resolve_restore_source
  build_payload
  commit_efisp
  restore_abl
  save_backup_abl
  ui_print ""
  ui_print "install: done - reboot to use the cached ABL."
}
