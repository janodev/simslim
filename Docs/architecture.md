# Outcome

SimSlim does not kill arbitrary processes, remove daemon definitions, or patch
an iOS runtime. It asks the selected simulator's own `launchd` to persist
disabled-job overrides, then reboots that simulator so those jobs are skipped
during the next boot.

The primitive operation for one label is:

```sh
xcrun simctl spawn <UDID> launchctl disable system/<label>
```

Restoration uses `launchctl enable system/<label>`. `simctl spawn <UDID>`
selects one simulator; `system/<label>` selects that simulator's launchd system
domain. Host launchd is never the target.

# Components

| Component | Responsibility |
|---|---|
| [`SimSlimCore`](../Sources/SimSlimCore) | Profiles, feature diagnosis, Simulator control, reconciliation, measurement, fleet status, cloning, and disk operations. |
| [`SimSlimCLI`](../Sources/SimSlimCLI) | Argument validation, text and JSON presentation, profile wizard, and fleet terminal UI. |
| [`CommandRunning`](../Sources/SimSlimCore/CommandRunner.swift) | Injectable async boundary for every external command. Tests replace it with deterministic runners. |
| [`SubprocessCommandRunner`](../Sources/SimSlimCore/CommandRunner.swift) | Production implementation backed by Swift Subprocess. |

Core values are immutable `Sendable` structures where practical. Shared
device-set registration is isolated in an actor. Independent measurement and
transition work uses bounded throwing task groups rather than unstructured
background work.

# Desired-state reconciliation

The service model is explicit:

1. [`Profiles.swift`](../Sources/SimSlimCore/Profiles.swift) groups known labels
   into user-facing capability categories.
2. The complete slimmable set is the only set that a profile may disable.
3. A profile starts with that set, removes `--except` categories, then removes
   individual `--keep` labels.
4. Compatibility labels that must remain enabled are part of the managed state
   but never part of the desired disabled set.
5. The current managed state is compared with the desired state. Only the
   missing disable and enable transitions are executed.

Labels outside the static managed allowlist are never changed. JSON profile
files reject unknown fields, categories, and labels. CLI category flags are
also validated; as in the Go baseline, an unknown `--keep` label has no effect.

# Reboot and verification sequence

[`SlimmingService`](../Sources/SimSlimCore/Slimming.swift) brings a device to an
exact desired state:

1. Resolve the exact UDID and its CoreSimulator device set.
2. Boot the simulator and wait for boot readiness.
3. Read `launchctl print-disabled system` inside that simulator.
4. Compute the managed delta and write only changed overrides.
5. Shut down, wait until shutdown completes, boot again, and wait for readiness.
6. Read the disabled overrides again and compare them with the desired state.

`launchctl disable` records an override but does not guarantee that a process
already running exits. The reboot makes launchd consult its override database
during startup. The final readback prevents a runtime that discarded the
overrides from being reported as slim. The upstream baseline observed this
loss on iOS 17; persistent slimming therefore requires iOS 18 or newer.

Repeated `on` calls are idempotent: when the managed state already matches, no
reconfiguration reboot is needed.

# Transition batching

A fresh simulator is busy, and writing roughly 170 labels serially is slow.
[`SimCtl`](../Sources/SimSlimCore/SimCtl.swift) applies labels in chunks of 40,
with eight launchctl operations active in each shell wave. Only explicit
success markers count as complete. Missing or failed labels are retried as
individual operations for precise diagnostics, for up to three passes.

The simulator shell can strip `DYLD_ROOT_PATH`. The batch script reconstructs
it from `SIMULATOR_ROOT` before invoking the nested simulator `launchctl`, so
the command resolves against the selected runtime.

# Swift Subprocess boundary

The port uses
[`swiftlang/swift-subprocess`](https://github.com/swiftlang/swift-subprocess)
instead of Go's `os/exec`. The wrapper captures stdout, stderr, and a typed exit
or signal status for `xcrun`, `ps`, `pgrep`, `top`, `du`, and `lsof`.

Each child starts in its own process session. Cancellation uses a process-group
kill, which matters for chains such as
`xcrun -> simctl -> spawned shell`: a timeout can stop descendants without
signalling SimSlim's own process group. Immediate group termination avoids a
Swift Subprocess 1.0 edge case where a leader that exits on `SIGTERM` can leave
a descendant alive. The wrapper enforces output limits and supports environment
overrides and working directories. It reports launch failures and timeouts as
errors; callers add operation context when a completed command exits nonzero.

Timeout racing and cancellation are implemented with structured concurrency.
`SIGINT` cancels the root command, waits for structured rollback, then exits
with status 130. Clone and repair share one deadline covering their complete
workflow, including safety audits and restoration.
The `CommandRunning` protocol keeps process execution replaceable in tests and
prevents simulator logic from depending directly on a global shell.

# State and measurement semantics

`status` reads managed launchd overrides. Its numerator is the number of
managed labels disabled; its denominator is the managed allowlist size. It
does not assert that exactly that many processes are absent.

`verify` compares those overrides with one exact profile. `doctor` maps
workflow capabilities such as push or universal links to their required labels
and reports which are disabled.

`measure` is a process-tree observation. It finds the simulator's
`launchd_sim`, walks descendants from a `ps` snapshot, and sums their
`phys_footprint` from `top`. This matches the memory pressure visible in
Activity Monitor more closely than summing RSS, which double-counts shared
mappings.

# Runtime maintenance

Apple-internal labels and dependencies can change with a new Simulator runtime.
After an Xcode/runtime update:

1. Work on a disposable SimLease simulator.
2. Record a settled stock process count and `phys_footprint`.
3. Apply and verify the intended profile.
4. Record the slim process count and footprint under the same conditions.
5. Inspect unexpected high-footprint processes and exercise retained features.
6. Update categories, descriptions, feature mappings, and forbidden-label
   tests together if the runtime changed.

# Related concepts

- [Getting started](getting-started.md)
- [Safety, cloning, and disk cleanup](safety.md)
- [Port baseline and parity](parity.md)

# Citations

[1] [MobAI SimSlim source baseline](https://github.com/MobAI-App/simslim/tree/d8adb4508452c92d36db8ef8a281ac68c38108bd)
[2] [Swift Subprocess](https://github.com/swiftlang/swift-subprocess)
