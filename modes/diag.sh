# shellcheck shell=sh
# shellcheck disable=SC2154,SC2012
# modes/diag.sh — no-op diagnostic mode.
# Exercises the whole core (env, ui, busybox, partition, safety) with
# zero device writes. Safe to flash on any device. It is also the
# worked reference for SP3/SP4 mode authors: define mode_main, use the
# core helpers, never write outside commit_verified.

mode_main() {
  ui_print "diag: environment report"
  ui_print ""

  if $BOOTMODE; then
    ui_print "  boot mode  : booted Android (flash-from-system)"
  else
    ui_print "  boot mode  : recovery"
  fi
  ui_print "  work dir   : $DIR"

  bb=$(command -v busybox 2>/dev/null)
  if [ -n "$bb" ]; then
    ui_print "  busybox    : $bb"
  else
    ui_print "  busybox    : (none on PATH)"
  fi

  if [ -n "$SLOT" ]; then
    ui_print "  slot       : active=$SLOT inactive=$INACTIVE"
  else
    ui_print "  slot       : not an A/B device"
  fi

  if $OTA_POSTINSTALL; then
    ui_print "  ota state  : update_engine postinstall ACTIVE"
  else
    ui_print "  ota state  : no postinstall window"
  fi

  if [ -n "$BYNAME" ]; then
    n=$(ls "$BYNAME" 2>/dev/null | wc -l)
    ui_print "  by-name dir: $BYNAME ($n partitions)"
    # Static list of the partitions this project touches: efisp (install
    # target), abl (cache source + loader-restore), vbmeta (graft target).
    for p in efisp abl_a abl_b vbmeta_a vbmeta_b; do
      if [ -e "$BYNAME/$p" ]; then
        ui_print "    [present] $p"
      else
        ui_print "    [absent ] $p"
      fi
    done

    # vbmeta descriptor walk: list the partitions the active slot's main
    # vbmeta covers (handy context for the graft mode).
    if [ -e "$BYNAME/vbmeta_$SLOT" ] && command -v vbmeta-graft >/dev/null 2>&1; then
      dd if="$BYNAME/vbmeta_$SLOT" of="$WORKDIR/diag_vbmeta.img" bs=1M 2>/dev/null
      ui_print "  vbmeta_$SLOT covers:"
      vbmeta-graft list "$WORKDIR/diag_vbmeta.img" 2>/dev/null \
        | while read -r line; do ui_print "    $line"; done
    fi
  else
    ui_print "  by-name dir: NOT FOUND"
  fi

  ui_print ""
  ui_print "diag: core OK - no writes performed"
}
