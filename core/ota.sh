# shellcheck shell=sh
# shellcheck disable=SC2034
# core/ota.sh — OTA-state detection.
# Sourced by update-binary. See zip-methodology.md A4.
# Pattern adapted from AnyKernel3 (osm0sis, MIT-style license).
#
# /postinstall is the mount point AOSP update_engine uses during the
# post-install phase of an A/B OTA; /postinstall/tmp present means a
# system OTA has been applied to the inactive slot and is in its
# post-install window. This is a signal only — modes decide how to act
# on it. It does NOT detect an OTA .zip flashed by hand in recovery.

OTA_POSTINSTALL=false
[ -d /postinstall/tmp ] && OTA_POSTINSTALL=true
