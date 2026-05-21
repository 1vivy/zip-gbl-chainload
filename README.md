# zip-gbl-chainload

Flashable-ZIP packaging for [gbl-chainload](https://github.com/1vivy/gbl-chainload).
This repo is a **submodule** of gbl-chainload, mounted at `zip/`.

## What this is

A single mode-agnostic installer core (`META-INF/com/google/android/update-binary`
+ `core/*.sh`) plus per-mode config. One ZIP carries one mode, named in
`modes/SELECTED` (generated at assembly time). Modes:

- `diag` — no-op environment diagnostic (no writes).
- `graft` — namespaced custom-recovery vbmeta graft
  (`/sdcard/gbl-chainload/graft/recovery.img`).
- `mode-0-install` — gbl-chainload mode-0 (honest) EFISP install.
- `mode-1-install` — gbl-chainload mode-1 (VerifiedBoot fakelock) EFISP install;
  on the OTA/inactive-slot pathway from recovery, it also grafts the active
  custom recovery onto the target slot's recovery partition when present.
- `mode-2-install` — gbl-chainload mode-2 (QSEE/SPSS spoof) EFISP install.

The three `mode-N-install` modes share a common body
(`modes/install-common.sh`); each `modes/mode-N-install.sh` is a thin file
that sources it and declares per-mode parameters.

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
