---
type: Porting Reference
title: Port baseline and parity
description: Records the exact Go baseline, native Swift scope, compatibility goals, known exclusions, and review method.
tags: [swift, go, parity, provenance, maintenance]
---

# Source baseline

The native port began from MobAI SimSlim commit:

```text
d8adb4508452c92d36db8ef8a281ac68c38108bd
fix: clarify slimming status and memory accounting (#36)
```

The upstream MIT license is reproduced in [`LICENSE`](../LICENSE), and
[`NOTICE`](../NOTICE) records attribution and the baseline. Keep this commit
stable when evaluating parity; a later upstream change is a separate review,
not evidence that the original port was incomplete.

# Included scope

The parity target is the Go package and `cmd/simslim` CLI at the baseline:

- Service categories, descriptions, profiles, profile files, and feature
  diagnosis.
- Device-set discovery and exact-UDID Simulator lifecycle operations.
- Persistent launchctl reconciliation, retries, reboot, status, and
  post-reboot verification.
- Memory/process measurement, fleet snapshots, and terminal `top` views.
- Allocated disk sizing, read-only inventory, allowlisted cleanup, and storage
  breakdown.
- Clone creation, source-reference rebasing, clone independence audits, and
  in-place repair.
- Human-readable CLI output, machine-readable JSON, global timeout/set options,
  and the interactive profile builder.

The Swift implementation separates reusable behavior into `SimSlimCore` and
presentation into `SimSlimCLI`. It uses Swift concurrency and Swift Subprocess
instead of mirroring Go's goroutines, contexts, and `os/exec` types.

# Compatibility goals

Parity means the two implementations should produce equivalent operational
results for the same device state, except where this port deliberately fails
more safely as documented below:

- The same categories, labels, always-enabled exceptions, feature mappings,
  and profile validation rules.
- The same managed desired-state delta and persistence checks.
- The same baseline destructive-operation boundaries and clone behavior,
  strengthened by the Swift-specific safeguards below.
- Equivalent JSON fields and exit success/failure for automation-facing
  commands.
- Equivalent acceptance of global options before or after the subcommand.

Text spacing, Swift error type names, internal scheduling, and library APIs do
not need to be source-identical. Go callers do not get a drop-in library
replacement; Swift callers use the native `SimSlimCore` API.

# Deliberate safety hardenings

The Swift port retains the pinned Go behavior but closes several failure windows
found during review:

- Raw clones use a unique temporary name. Their identity is recovered through
  a bounded, cancellation-independent device-set inventory after both success
  and uncertain command failure, and is validated before rename or cleanup.
- Clone symlinks are resolved component by component in POSIX order. Indirect
  chains, cycles, parent traversal after a symlink, source-log references, and
  chains that pass through the source before reaching shared storage are
  handled explicitly.
- The offline clone audit compares filesystem device/inode identities against
  the complete source tree, so a hard link is detected even at a different
  relative path.
- Clone repair shuts down after its live audit and repeats the static audit. An
  originally booted clone is then restored and live-audited again.
- Disk cleanup rejects transitional `Booting` and `Shutting Down` states before
  deleting anything.
- Cancellation tears down subprocess process groups and waits for bounded clone
  cleanup and source-state restoration before returning.

# Known scope boundaries

- This repository ports the Go core and CLI. The separate SwiftUI application
  under upstream `gui/` is not included.
- The package deliberately targets macOS 27 or newer, while the upstream Go
  project has a broader historical macOS build surface.
- The private formula in [`Formula/simslim.rb`](../Formula/simslim.rb) is
  independent of the published upstream Homebrew formula. It builds a pinned
  Swift revision from an authenticated Git checkout; it does not replace or
  update the public MobAI tap.
- Simulator service labels are Apple-internal implementation details. Parity
  with a pinned commit does not guarantee compatibility with a later iOS
  runtime.
- Mocked and fixture-based tests validate algorithms and command construction;
  a real disposable simulator is still required to validate runtime persistence,
  memory results, and feature behavior.

# Review procedure

When importing an upstream change:

1. Record both the old and candidate upstream commit hashes.
2. Inspect upstream changes to Go source, tests, CLI output, documentation,
   profiles, feature mappings, and safety allowlists.
3. Port behavior into the corresponding Swift library layer before adjusting
   CLI presentation.
4. Add focused Swift Testing coverage for parsing, desired-state changes,
   subprocess arguments, JSON shape, and failure cleanup.
5. Run `make test` and compare representative Go/Swift CLI and JSON results.
6. Use a disposable SimLease simulator for launchd, clone, disk, or measurement
   integration checks.
7. Update [`NOTICE`](../NOTICE), this baseline document, and other affected
   concepts only after parity is reviewed.

# Source map

| Behavior | Swift implementation | Go baseline |
|---|---|---|
| Profiles and feature checks | [`Profiles.swift`](../Sources/SimSlimCore/Profiles.swift), [`Features.swift`](../Sources/SimSlimCore/Features.swift) | `profiles.go`, `features.go` |
| Device and launchctl control | [`SimCtl.swift`](../Sources/SimSlimCore/SimCtl.swift) | `simctl.go` |
| Reconciliation and status | [`Slimming.swift`](../Sources/SimSlimCore/Slimming.swift) | `slim.go` |
| Measurement and fleet | [`Measurement.swift`](../Sources/SimSlimCore/Measurement.swift), [`Fleet.swift`](../Sources/SimSlimCore/Fleet.swift) | `measure.go`, `fleet.go` |
| Clone safety | [`Clone.swift`](../Sources/SimSlimCore/Clone.swift) | `clone.go` |
| Disk safety | [`DiskCleanup.swift`](../Sources/SimSlimCore/DiskCleanup.swift), [`DiskInventory.swift`](../Sources/SimSlimCore/DiskInventory.swift) | `disk_cleanup.go`, `disk_inventory.go` |
| CLI | [`SimSlimCLI`](../Sources/SimSlimCLI) | `cmd/simslim/` |

# Related concepts

- [Getting started](getting-started.md)
- [Architecture and launchd mechanism](architecture.md)
- [Safety, cloning, and disk cleanup](safety.md)

# Citations

[1] [MobAI SimSlim pinned source tree](https://github.com/MobAI-App/simslim/tree/d8adb4508452c92d36db8ef8a281ac68c38108bd)
[2] [Swift Subprocess](https://github.com/swiftlang/swift-subprocess)
