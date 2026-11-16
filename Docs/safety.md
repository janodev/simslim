---
type: Safety Reference
title: Safety, cloning, and disk cleanup
description: Defines mutation boundaries, clone independence checks, permanent cleanup behavior, and recovery expectations.
tags: [simulator, safety, clone, disk, cleanup]
---

# Safety boundaries

SimSlim accepts one exact simulator UDID for mutation. It resolves that UDID
through CoreSimulator, retains its device-set identity, and routes simulator
commands through `xcrun simctl`. Aliases such as `all` are not mutation targets.

Service slimming and filesystem cleanup have different recovery models:

- Managed launchd overrides are reversible with `simslim off`.
- Deleted cache, log, temporary, and on-demand language data is not restored by
  `off` or by an erase. New generated data may appear later.
- `erase` deletes apps, settings, credentials, and user data and resets the
  device to stock service state.
- `delete` permanently removes the simulator.

Core workflow and known boot-breaking services are excluded from the
slimmable allowlist. This reduces risk but does not make every application
feature compatible with the default profile. Preserve required categories or
labels and use `doctor` before a dependent test suite.

# Clone lifecycle

CoreSimulator cloning copies installed apps, app data, settings, and filesystem
references that can still point at the source device. `simslim clone` therefore
does more than invoke `simctl clone`:

1. Record whether the source began booted and read its SimSlim-managed profile.
2. Shut down the source and ask CoreSimulator to create the clone under a
   unique temporary name. Match that name, runtime, and device set against a
   before/after inventory before trusting the returned UDID, then apply the
   requested name.
3. Rebase simulator-local property-list paths and symbolic links from the
   source's data, device, and log roots to the clone's roots. Symbolic-link
   chains are resolved in filesystem order, including parent traversal and
   chains that enter and later leave a source path.
4. Clear copied system caches and temporary state that can retain source-bound
   data, and rebuild application registration state while retaining app-owned
   data and caches.
5. Boot the clone, apply the source's managed disabled-label profile, and
   verify persistence.
6. Inspect the clone's running processes with `ps` and `lsof`; fail if any open
   path points into the source.
7. Shut down the verified clone, perform a final scoped independence audit,
   and restore the source's original boot state.

The static audit resolves symbolic-link chains and compares every regular clone
file against source file identities to catch hard links even when their
relative paths differ. The live audit checks open paths for clone processes.
These checks cannot prove that an arbitrary opaque store contains no dormant
source reference, so a clone is accepted when it passes SimSlim's scoped
independence checks. If it does not, SimSlim attempts to shut it down and delete
it. An error reports both the original failure and any cleanup or
source-restoration failure rather than hiding either one.

# Repairing an existing clone

```sh
simslim repair-clone <source-udid> <clone-udid>
```

Repair requires distinct devices in the same device set and on the same iOS
runtime. It preserves the clone's current managed profile and intended boot
state. The source remains shut down while source-bound paths are rebuilt.

CoreSimulator does not expose clone lineage. The caller must supply the exact
source UDID; SimSlim verifies references against that source. Repair always
shuts the clone down for a post-boot static audit. If it originally ran, repair
boots it again and repeats the live open-file audit. If any scoped check fails,
the clone is left shut down rather than restarted.

# Disk boundary

Disk analysis and cleanup are limited to the selected device's data directory.
A default device-set path looks like:

```text
~/Library/Developer/CoreSimulator/Devices/<UDID>/data
```

The shared, signed iOS runtime is outside this boundary. Built-in apps and core
OS assets are therefore neither counted as per-device app storage nor selected
for deletion.

`disk-plan` is read-only and reports both cleanable categories and durable
storage rows. Durable rows explain usage but are never eligible for bulk
cleanup:

- Installed developer apps and test runners.
- App and app-group Documents.
- Preferences, databases, and other app data.
- User media.

# Cleanup categories

| Category ID | Behavior | Recovery expectation |
|---|---|---|
| `caches` | Clears contents of discovered system and app `Caches` directories. | Old cache content stays deleted; apps regenerate needed caches. |
| `logs` | Clears allowlisted logs, diagnostics, and UUID text. | Existing history stays deleted; future runs create new logs. |
| `temporary` | Clears contents of simulator and app `tmp` directories. | Old temporary state stays deleted; apps create new files as needed. |
| `linguistic-data` | Opt-in removal of the exact per-device on-demand LinguisticData catalog. | iOS may download the package again when a feature needs it. |
| `required-siri-assets` | Measured for visibility only. | It cannot be selected because iOS restores required assets and manual deletion is unsupported. |

Cleanup requires an explicit nonempty category selection and `--confirm`:

```sh
simslim disk-plan <udid>
simslim disk-clean --categories caches,logs,temporary --confirm <udid>
```

A booted device is shut down before deletion. By default it remains shut down;
`--preserve-boot-state` asks SimSlim to reboot a device that was previously
booted. The cleanup result records the before, after, reclaimed-byte, and boot
restoration state.

# Filesystem safeguards

- Candidate paths come from fixed cleanup categories.
- Every target and intermediate path is checked to remain below the device
  data root after symbolic-link resolution.
- Discovery excludes Documents, media, and MobileAsset trees from broad
  name-based cache/log/temp scans.
- Language cleanup uses one exact MobileAsset catalog boundary.
- Required container directories remain; only their contents are cleared.
- Child symbolic links are unlinked without following their targets.
- Analysis and byte estimates perform no deletion.

# Failure and recovery guidance

- Run `disk-plan` immediately before cleanup; sizes change as iOS and apps run.
- Clone a valuable simulator before permanent cleanup.
- If cleanup removes generated state, reopening the relevant app or feature may
  recreate it, but the old contents cannot be recovered by SimSlim.
- Erasing can return a damaged per-device tree to a fresh usable device, but it
  is not an undo operation for apps or data.
- A failure to verify clone independence should be treated as unsafe even when
  the clone appears to boot.

# Related concepts

- [Getting started](getting-started.md)
- [Architecture and launchd mechanism](architecture.md)
- [Port baseline and parity](parity.md)

# Citations

[1] [Upstream disk cleanup safety model at the pinned baseline](https://github.com/MobAI-App/simslim/blob/d8adb4508452c92d36db8ef8a281ac68c38108bd/docs/disk-cleanup.md)
[2] [Apple: Adding additional simulators](https://developer.apple.com/documentation/safari-developer-tools/adding-additional-simulators)
