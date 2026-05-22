# shellcheck shell=sh
# shellcheck disable=SC2154,SC2015,SC2034
# SC2034: STEP/STEPS are set here, consumed by core/install_abl.sh's _step.
# modes/install-common.sh — shared body for the three mode-N-install modes.
#
# The mode-0/1/2 install modes share ~90% of their script: cache a patched ABL
# into the GBLP1 overlay appended to gbl-chainload on EFISP, and write a
# known-vulnerable loader ABL onto the target slot so that slot loads
# gbl-chainload. This file factors that common body out; each
# modes/mode-N-install.sh is a thin wrapper that sources this lib and declares
# the per-mode parameters below.
#
# This is a mode-specific shared lib (it lives in modes/, not core/): core/ is
# generic flashable-ZIP framework infrastructure, whereas an install-mode body
# is gbl-chainload-specific. core/install_abl.sh holds the truly generic
# loader-ABL machinery this builds on top of.
#
# Two ABLs, kept distinct:
#   cached  ABL -> patched + packed into the EFISP overlay; gbl-chainload runs it.
#   restore ABL -> written verbatim to abl_<target>; MUST be vulnerable (retain
#                  the GBL/EFISP loader path) so that on-disk ABL loads
#                  gbl-chainload.
#
# Loader-ABL machinery (vol_key, abl_marker, pick_scenario,
# resolve_restore_source, restore_abl, save_backup_abl, BACKUP, CACHE_BACKUP) lives in
# core/install_abl.sh, sourced by update-binary before this file.
#
# Per-mode parameters (set by the thin modes/mode-N-install.sh before sourcing,
# or by mode_prepare for the mode-2 derived values):
#   M_EFI          base EFI filename in base/ (mode-0.efi / mode-1.efi / mode-2.efi).
#   M_LABEL        mode name, used in ui_print lines.
#   M_PATCHER_ARGS extra args passed to abl-patcher ("" / "--no-mode1" /
#                  "--oem <id> --no-mode1").
#   M_PACK_ARGS    extra args passed to gbl-pack ("" / "--mode2-profile <path>").
#   M_WANT_PROFILE 1 if this mode runs the mode_prepare profile hook, else unset.
#
# Two hooks, both no-op by default, both overridable by a thin mode file:
#   mode_preflight  runs at the end of preflight (extra pre-write abort gates).
#   mode_prepare    runs after resolve_restore_source, before build_payload
#                   (per-mode preparation that populates M_PATCHER_ARGS /
#                   M_PACK_ARGS). mode-2-install.sh overrides both.
#   mode_preinstall_write runs after payload construction, before EFISP/ABL
#                   writes, for optional companion writes that should fail
#                   before the boot-chain install (mode-1 OTA recovery graft).
#   mode_postinstall runs after the loader ABL restore for final no-op/status
#                   hooks.
# Both hooks run AFTER pick_scenario's interactive scenario prompt — a mode
# that wants an early abort (e.g. unsupported-OEM in mode_prepare) will still
# pay the vol-key scenario prompt first.

# mode_preflight -> extra pre-flight gate hook. Default: no-op. Runs as the last
# step of preflight, so an override's abort still fires before any write.
mode_preflight() { :; }

# mode_prepare -> per-mode preparation hook. Default: no-op. Runs after the
# loader-ABL source is resolved and before any payload is built; a mode that
# needs to populate M_PATCHER_ARGS / M_PACK_ARGS overrides this.
mode_prepare() { :; }
mode_preinstall_write() { :; }
mode_postinstall() { :; }

# preflight -> resolves device paths and gates everything before any write.
preflight() {
  TARGET_DEV=$(byname "abl_$TARGET")
  EFISP_DEV=$(byname efisp)
  ACTIVE_DEV=$(byname "abl_$SLOT")
  [ -n "$TARGET_DEV" ] || abort "abl_$TARGET partition not found"
  [ -n "$EFISP_DEV" ]  || abort "efisp partition not found"
  [ -n "$ACTIVE_DEV" ] || abort "abl_$SLOT partition not found"
  [ -f "$WORKDIR/base/$M_EFI" ] || abort "base/$M_EFI missing from ZIP"
  efisp_precondition
  mode_preflight
}

# efisp_precondition -> classify EFISP content and gate accordingly. Three
# states, because the write (commit_efisp) replaces EFISP wholesale and the
# old "must already be a PE" rule wrongly blocked a first-time install onto a
# factory-blank EFISP:
#   PE (MZ)          reinstall / OTA over an existing install — proceed.
#   all-zero (blank) first-time install (or a wiped EFISP) — proceed, and set
#                    EFISP_FIRST_INSTALL=1 so the operator is warned a /data
#                    format may follow on next boot (verified-boot state change).
#   anything else    EFISP holds unrecognised content (wrong partition, or a
#                    partial/corrupt write). Refuse to silently clobber it: an
#                    interactive recovery install requires an explicit vol-up;
#                    a non-interactive (BOOTMODE / update_engine) install aborts.
# "blank" is the WHOLE partition being zero — two leading zero bytes don't
# prove it — so we scan all of EFISP (cheap: a few MiB read once).
efisp_precondition() {
  EFISP_FIRST_INSTALL=0
  _mz=$(dd if="$EFISP_DEV" bs=1 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
  if [ "$_mz" = 4d5a ]; then
    return 0
  fi
  if [ "$(dd if="$EFISP_DEV" bs=1M 2>/dev/null | tr -d '\0' | wc -c)" = 0 ]; then
    EFISP_FIRST_INSTALL=1
    ui_print "[*] EFISP is blank — first-time install onto this slot"
    ui_print "    note: a /data format may be required on next boot, since this"
    ui_print "          may be the first change to the verified-boot state."
    return 0
  fi
  ui_print "WARNING: EFISP holds unrecognised content (first 2 bytes = '$_mz' —"
  ui_print "         not a PE, not blank). Installing will overwrite it."
  if $BOOTMODE || $OTA_POSTINSTALL; then
    abort "refusing to overwrite unrecognised EFISP content in a non-interactive install"
  fi
  ui_print "  Vol-UP = overwrite and continue   Vol-DOWN = abort"
  [ "$(vol_key)" = UP ] || abort "aborted: EFISP holds unrecognised content"
}

# build_payload -> reads abl_<target>, builds the GBLP1 overlay, produces
# $WORKDIR/installed.efi (base EFI + payload). abl-patcher and gbl-pack get the
# per-mode M_PATCHER_ARGS / M_PACK_ARGS appended.
build_payload() {
  _step "caching abl_$TARGET (patch args: ${M_PATCHER_ARGS:-none})"
  if [ "$SCENARIO" = reinstall ] && [ -f "$CACHE_BACKUP" ]; then
    ui_print "[*] using saved latest ABL cache source: $CACHE_BACKUP"
    cp "$CACHE_BACKUP" "$WORKDIR/cache_abl.img" \
      || abort "failed to copy $CACHE_BACKUP"
  else
    dd if="$TARGET_DEV" of="$WORKDIR/cache_abl.img" bs=1M 2>/dev/null \
      || abort "failed to read abl_$TARGET"
    if [ "$SCENARIO" = ota ]; then
      mkdir -p "$GBL_BACKUP_DIR" || abort "cannot create $GBL_BACKUP_DIR"
      cp "$WORKDIR/cache_abl.img" "$CACHE_BACKUP" \
        || abort "failed to save latest ABL cache source to $CACHE_BACKUP"
      ui_print "[*] saved latest ABL cache source to $CACHE_BACKUP"
    fi
  fi
  fv-unwrap "$WORKDIR/cache_abl.img" "$WORKDIR/extracted.efi" >/dev/null 2>&1 \
    || abort "fv-unwrap failed on the cache-source ABL"
  # M_PATCHER_ARGS / M_PACK_ARGS are intentionally word-split.
  # shellcheck disable=SC2086
  abl-patcher $M_PATCHER_ARGS \
    --in "$WORKDIR/extracted.efi" --out "$WORKDIR/patched.efi" \
    || abort "abl-patcher failed (no matching signatures?)"
  _step "packing GBLP1 overlay"
  # shellcheck disable=SC2086
  gbl-pack --cached-abl "$WORKDIR/patched.efi" \
           --source "$WORKDIR/cache_abl.img" \
           --extracted "$WORKDIR/extracted.efi" \
           $M_PACK_ARGS \
           --out "$WORKDIR/payload.bin" \
    || abort "gbl-pack failed"
  cat "$WORKDIR/base/$M_EFI" "$WORKDIR/payload.bin" > "$WORKDIR/installed.efi"
}

# commit_efisp -> verified write of installed.efi onto EFISP.
commit_efisp() {
  _step "writing EFISP (backup + verify)"
  commit_verified "$WORKDIR/installed.efi" "$EFISP_DEV" "$GBL_BACKUP_DIR/efisp.img"
}

mode_main() {
  ui_print "$M_LABEL: gbl-chainload installer"
  ui_print ""
  # Step counter: prepare(?) + cache + pack + EFISP write + loader-ABL restore.
  # mode_prepare contributes one step only when a mode overrides it (mode-2).
  if [ "${M_WANT_PROFILE:-0}" = 1 ]; then STEPS=5; else STEPS=4; fi
  STEP=0
  pick_scenario
  preflight
  [ "${GRAFT_ENABLED:-0}" = 1 ] && STEPS=$((STEPS + 1))
  resolve_restore_source
  mode_prepare
  build_payload
  mode_preinstall_write
  commit_efisp
  restore_abl
  mode_postinstall
  save_backup_abl
  ui_print ""
  ui_print "$M_LABEL: done - reboot to use the cached ABL."
  ui_print "backups kept: $GBL_BACKUP_DIR"
}
