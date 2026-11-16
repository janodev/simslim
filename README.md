# SimSlim

It reduces the idle cost of an iOS Simulator by recording persistent,
per-device `launchd` overrides for background services that development and CI
workflows do not need.

This is a native Swift port of [MobAI SimSlim](https://github.com/MobAI-App/simslim). This repository ports the Go library and CLI as a SwiftPM library plus a native
`simslim` executable. The behavioral baseline is upstream commit
[`d8adb45`](https://github.com/MobAI-App/simslim/commit/d8adb4508452c92d36db8ef8a281ac68c38108bd).
The upstream SwiftUI app is not part of this port.

## Companion tools

Run multiple coding agents on one Mac with less resource contention, lighter
simulators, and less disk clutter. Competing builds and desktop UI tests take
turns while independent work continues in parallel.

- [AgentBuild](https://github.com/janodev/agentbuild) coordinates builds and tests, reuses caches, and records results.
- [AgentLease](https://github.com/janodev/agentlease) coordinates access to shared resources, reducing contention and preventing conflicting work.
- [SimLease](https://github.com/janodev/simlease) provides disposable simulators, cleans them up afterward, and queues macOS UI automation.
- [SimSlim](https://github.com/janodev/simslim) disables unneeded Simulator background services to reduce memory use.

AgentLease, SimLease, and SimSlim work independently. AgentBuild is a build driver
that runs supported project workflows and coordinates the other tools as needed.

## Requirements

- macOS 27 or newer.
- Swift 6.2 or newer.
- Xcode with at least one iOS Simulator runtime.

SimSlim controls Simulator through `xcrun simctl`; it does not modify the host
Mac's `launchd` state or a shared iOS runtime.

## Install with Homebrew

Yes, a private repository can be a Homebrew tap. Homebrew accepts an explicit
Git remote for a tap, and Git supplies the authentication. Every machine or CI
runner installing this formula needs an SSH key with read access to the private
repository.

Verify access, add this repository as a custom tap, and install its formula:

```sh
git ls-remote ssh://git@github.com/janodev/simslim.git HEAD
brew tap janodev/simslim ssh://git@github.com/janodev/simslim.git
brew install janodev/simslim/simslim
```

The explicit remote is required. The shorter
`brew tap janodev/simslim` command would look for a different repository named
`janodev/homebrew-simslim`.

If the public MobAI Go formula is already installed, remove it before installing
this private Swift formula because both provide the `simslim` executable:

```sh
brew uninstall mobai-app/tap/simslim
brew install janodev/simslim/simslim
```

The formula builds from the pinned private Git revision rather than a public
archive. Normal Homebrew updates then apply:

```sh
brew update
brew upgrade janodev/simslim/simslim
```

See Homebrew's [tap documentation](https://docs.brew.sh/Taps) and GitHub's
[SSH authentication guide](https://docs.github.com/en/authentication/connecting-to-github-with-ssh)
for the underlying authentication model.

## Build and test from source

```sh
git clone git@github.com:janodev/simslim.git
cd simslim
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
install -d "$HOME/Developer/tools"
install -m 0755 .build/release/simslim "$HOME/Developer/tools/simslim"
```

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
