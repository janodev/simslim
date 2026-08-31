# swift-simslim

A native Swift port of [MobAI SimSlim](https://github.com/MobAI-App/simslim).
It reduces the idle cost of an iOS Simulator by recording persistent,
per-device `launchd` overrides for background services that development and CI
workflows do not need.

This repository ports the Go library and CLI as a SwiftPM library plus a native
`simslim` executable. The behavioral baseline is upstream commit
[`d8adb45`](https://github.com/MobAI-App/simslim/commit/d8adb4508452c92d36db8ef8a281ac68c38108bd).
The upstream SwiftUI app is not part of this port.

## Requirements

- macOS 27 or newer.
- Swift 6.2 or newer.
- Xcode with at least one iOS Simulator runtime.

SimSlim controls Simulator through `xcrun simctl`; it does not modify the host
Mac's `launchd` state or a shared iOS runtime.

## Build and test

```sh
git clone git@github.com:janodev/swift-simslim.git
cd swift-simslim
make build
make test
```

For an optimized executable:

```sh
swift build -c release --product simslim
.build/release/simslim --help
```

Install that build in a user-owned directory on `PATH` if desired:

```sh
install -d "$HOME/.local/bin"
install -m 0755 .build/release/simslim "$HOME/.local/bin/simslim"
```

This repository does not currently publish its own Homebrew formula; a
Homebrew-installed `simslim` may still be the upstream Go executable. Use an
explicit path when comparing the two implementations.

The package exposes `SimSlimCore` for Swift callers and the `simslim` command
for shell workflows. External commands are executed through
[`swift-subprocess`](https://github.com/swiftlang/swift-subprocess), pinned in
`Package.resolved`.

## Quick start

Use an exact simulator UDID from `simslim list`:

```sh
simslim list
simslim profiles
simslim on <udid>
simslim status <udid>
simslim measure <udid>
```

Keep a capability that a test needs:

```sh
simslim on <udid> --except search
simslim on <udid> --keep com.apple.apsd
```

Or use a checked-in profile:

```json
{
  "name": "ci",
  "description": "UI test runs",
  "except": ["search", "store"],
  "keep": ["com.apple.apsd"]
}
```

```sh
simslim on <udid> --profile ci.json
simslim verify <udid> --profile ci.json
simslim doctor <udid> --requires push,storekit,universal-links
```

`on` and `off` reboot the selected simulator because an override does not stop
an already-running process. The post-reboot state is read back before the
operation reports success. On older runtimes that do not persist overrides,
the command fails instead of reporting a false slim state.

## Command map

| Purpose | Commands |
|---|---|
| Discover and configure | `list`, `profiles`, `profile`, `status`, `on`, `off` |
| Validate and observe | `verify`, `doctor`, `measure`, `top` |
| Inspect and clean disk | `size`, `disk-categories`, `disk-plan`, `disk-clean` |
| Manage devices | `clone`, `repair-clone`, `rename`, `boot`, `shutdown`, `erase`, `delete` |

Read-only and simulator-management commands support `--json` where applicable.
Use `simslim <command> --help` for its exact arguments. Global
`--boot-timeout`, `--spawn-timeout`, and `--set` options work before or after a
subcommand.

`status` counts only the allowlisted `launchd` labels managed by SimSlim. It is
not a process count. `measure` walks the selected simulator's process tree and
sums `phys_footprint`, which is the useful number for simulator density.

## Safety

- Service slimming is limited to a static allowlist and is reversible with
  `simslim off`.
- `disk-plan` is read-only. `disk-clean` permanently deletes only selected,
  allowlisted content below one simulator's data directory and requires
  `--confirm`.
- `clone` sanitizes simulator-local references, reapplies the source's managed
  service profile, and audits the running clone for open paths into the source.
- `erase` and `delete` are destructive. An erased or recreated simulator starts
  with stock service state and must be slimmed again.

When a simulator may be shared by concurrent agents, run the entire workflow
inside one SimLease session and use only its exported UDID:

```sh
simlease run --label "<task>" -- zsh -lc '
  set -euo pipefail
  simslim on "$SIMULATOR_ID"
  # Build, install, test, inspect, and collect evidence here.
'
```

## Documentation

Start with [Docs/index.md](Docs/index.md):

- [Getting started](Docs/getting-started.md)
- [Architecture and launchd mechanism](Docs/architecture.md)
- [Safety, cloning, and disk cleanup](Docs/safety.md)
- [Port baseline and parity](Docs/parity.md)

## License

MIT. The original project is Copyright (c) 2026 Interlap. See
[LICENSE](LICENSE) and [NOTICE](NOTICE) for attribution and the pinned source
baseline.
