# zip-gbl-chainload

Flashable-ZIP packaging for [gbl-chainload](https://github.com/1vivy/gbl-chainload).
This repo is a **submodule** of gbl-chainload, mounted at `zip/`.

## What this is

A single mode-agnostic installer core (`META-INF/com/google/android/update-binary`
+ `core/*.sh`) plus per-mode config. One ZIP carries one mode, named in
`modes/SELECTED` (generated at assembly time). Modes:

- `diag` — no-op environment diagnostic (no writes).
- `graft` — namespaced custom-recovery vbmeta graft
  (`/sdcard/gbl-chainload/graft-candidate/recovery.img`, with optional stock
  metadata at `/sdcard/gbl-chainload/graft-target/recovery.img`).
- `mode-0-install` — gbl-chainload mode-0 (honest) EFISP install.
- `mode-1-install` — gbl-chainload mode-1 (VerifiedBoot fakelock) EFISP install;
  on the OTA/inactive-slot pathway from recovery, it also grafts the active
  custom recovery onto the target slot's recovery partition when present.
- `mode-2-install` — gbl-chainload mode-2 (QSEE/SPSS spoof) EFISP install.

The three `mode-N-install` modes share a common body
(`modes/install-common.sh`); each `modes/mode-N-install.sh` is a thin file
that sources it and declares per-mode parameters.

## On-device file layout

All operator-provided inputs and installer-created backups live under one
namespace on shared storage:

```text
/sdcard/gbl-chainload/
  graft-candidate/
    recovery.img        # custom recovery image to graft/install explicitly
  graft-target/
    recovery.img        # optional stock recovery image used as graft metadata
  backups/latest/
    efisp.img           # pre-write EFISP backup
    abl_<slot>.img      # pre-write ABL backup when an ABL slot is written
    recovery_<slot>.img # pre-write recovery backup when recovery is written
    backup_abl.img      # saved vulnerable/exploit ABL for later OTA installs
    latest_abl.img      # saved OTA target ABL used as reinstall cache source
```

`graft-candidate/recovery.img` is the recovery you want to keep or install.
`graft-target/recovery.img` is optional: provide it when the target slot's
current recovery image cannot supply stock vbmeta metadata for the graft.

## Install walkthrough

### Normal OTA from recovery: mode-1

1. Boot into the custom recovery currently installed on the active slot.
2. Flash the ROM/OTA to the inactive slot.
3. Before rebooting, flash `gbl-chainload-mode-1-install.zip`.
4. At the prompt, choose:

   ```text
   Vol-UP = OTA install
   ```

The ZIP targets the inactive slot. In recovery, mode-1 automatically copies the
active slot's recovery image, grafts it against the target slot's vbmeta chain,
checks the final grafted image, writes `recovery_<inactive>` first, then writes
EFISP and the loader ABL. This replaces the usual custom-recovery step of
"flash recovery again after OTA".

### First install / repair from recovery: mode-1

Flash `gbl-chainload-mode-1-install.zip` and choose:

```text
Vol-DOWN = reinstall/repair current slot
```

The ZIP targets the active slot. It first checks whether active
`recovery_<active>` already matches the active slot's vbmeta chain. If yes, it
continues without a recovery write. If not, it tries to graft the active recovery
in place. If the on-device images cannot supply matching stock metadata, place a
stock recovery image at:

```text
/sdcard/gbl-chainload/graft-target/recovery.img
```

then rerun the ZIP. If you want to install a specific custom recovery instead of
using the active recovery partition, place it at:

```text
/sdcard/gbl-chainload/graft-candidate/recovery.img
```

The graft, when needed, is prepared and verified before any EFISP/ABL write.
For reinstall/repair, the active ABL is only checked for the loader path; the ZIP
does not rewrite `abl_<active>` onto itself. If a previous OTA install saved
`backups/latest/latest_abl.img`, reinstall/repair uses that fresh ABL as the
cached payload source instead of re-caching the loader ABL from the active slot.

### Booted-system / AnyKernel3-style flashing

When run from booted Android/root, install ZIPs are non-interactive and assume a
post-OTA install to the inactive slot. If
`/sdcard/gbl-chainload/graft-candidate/recovery.img` exists, mode-1 grafts it to
the inactive recovery slot first. If it is absent, BOOTMODE mode-1 skips recovery
graft and continues with the boot-chain install.

## Diagnostic ZIP

`gbl-chainload-diag.zip` performs no writes. It inspects the current slot state,
EFISP/GBLP1 contents, loader-ABL status, vbmeta/graft compatibility, and recovery
environment. It writes a bundle like:

```text
/sdcard/gbl-chainload-diag-<timestamp>.tar.gz
```

Run this before rebooting when you want to confirm whether the install state is
coherent or to collect a report for debugging.

## Graft ZIP

`gbl-chainload-graft.zip` is the manual recovery graft/repair path. It expects:

```text
/sdcard/gbl-chainload/graft-candidate/recovery.img
```

and optionally:

```text
/sdcard/gbl-chainload/graft-target/recovery.img
```

It prompts for the slot, grafts the candidate recovery against that slot's vbmeta
chain, checks the final grafted image against the target slot vbmeta, then writes
`recovery_<slot>` with a backup in `backups/latest/`. Use this when you need to
repair or prepare recovery independently of a mode-1 install.

## Building a ZIP

ZIPs are assembled from the **parent** gbl-chainload checkout:

```
scripts/build-recovery-zip.sh --mode diag    # -> dist/gbl-chainload-diag.zip
```

## Refreshing vendored tools

`bin/` (recovery tools, busybox) and `base/` (base EFIs) are committed.
After a gbl-chainload change that affects the tools or EFIs:

```
cd zip && ./update-tools.sh        # rebuilds + rewrites bin/MANIFEST
```

then commit this submodule and bump its pointer in the parent. The parent's
`build-recovery-zip.sh` hard-fails if the vendored binaries drift from
`bin/MANIFEST`.

## Attribution

The recovery-environment plumbing in `core/*.sh` (the `ui_print` path-write,
`BOOTMODE` detection, SELinux elevation, by-name resolution) is a partial
fork of [AnyKernel3](https://github.com/osm0sis/AnyKernel3) by osm0sis,
used under its MIT-style license. AnyKernel3's boot-image machinery is not
used — gbl-chainload's modes touch only raw firmware partitions. See
`docs/project/zip-methodology.md` in the parent repo.
