---
type: User Guide
title: Getting started
description: Builds and operates the native Swift SimSlim CLI safely in local and automated simulator workflows.
tags: [swift, simulator, cli, profiles, testing]
---

# Requirements

The package targets macOS 27 or newer and Swift 6.2 or newer. Xcode must be
installed with an iOS Simulator runtime because every device operation is
routed through `xcrun simctl`.

# Homebrew installation

This private repository also acts as a custom Homebrew tap. Git authentication
must already grant the current machine or CI runner read access through SSH:

```sh
git ls-remote ssh://git@github.com/janodev/swift-simslim.git HEAD
brew tap janodev/swift-simslim ssh://git@github.com/janodev/swift-simslim.git
brew install janodev/swift-simslim/simslim
```

The two-argument `brew tap` form is required because this repository is not
named `homebrew-swift-simslim`. The fully qualified install also selects this
private formula instead of the public MobAI formula with the same name.

If that public formula is already installed, replace it explicitly:

```sh
brew uninstall mobai-app/tap/simslim
brew install janodev/swift-simslim/simslim
```

The formula fetches a pinned revision over authenticated Git and builds the
release executable with SwiftPM. Update it with:

```sh
brew update
brew upgrade janodev/swift-simslim/simslim
```

# Build from a source checkout

From the repository root:

```sh
make build
make test
```

Build an optimized binary with:

```sh
swift build -c release --product simslim
.build/release/simslim --help
```

Optionally install the result into a user-owned directory already on `PATH`:

```sh
install -d "$HOME/.local/bin"
install -m 0755 .build/release/simslim "$HOME/.local/bin/simslim"
```

During parity checks, use `.build/release/simslim` explicitly so an installed
public Go formula cannot be selected accidentally.

The SwiftPM products are:

- `SimSlimCore`, the reusable native Swift library.
- `simslim`, the command-line application.

# First run

List devices, inspect the profile categories, then slim one exact UDID:

```sh
simslim list
simslim profiles
simslim on <udid>
simslim status <udid>
simslim measure <udid>
```

`on` boots the device if needed, applies the managed service state, reboots,
and verifies the state. It leaves the simulator booted unless
`--preserve-boot-state` is used for a simulator that began shut down. `off`
re-enables every managed label and performs the same verified reboot.

`status` and `measure` answer different questions:

- `status` counts allowlisted `launchd` labels recorded as disabled. It is not
  a live process count.
- `measure` finds the simulator's `launchd_sim` process tree and sums process
  `phys_footprint`.

# Profiles

The default profile disables every slimmable label. Keep a complete category
with `--except`, or keep one managed label with `--keep`:

```sh
simslim on <udid> --except search,store
simslim on <udid> --keep com.apple.apsd
```

For a repeatable setup, commit a profile file with the code it supports:

```json
{
  "name": "ci",
  "description": "Capabilities required by UI tests",
  "except": ["search"],
  "keep": ["com.apple.apsd"]
}
```

```sh
simslim on <udid> --profile ci.json
simslim verify <udid> --profile ci.json
```

`--profile` cannot be combined with `--except` or `--keep`. Unknown JSON
fields, category IDs, and unmanaged labels are rejected. Run `simslim profile`
in a terminal to build a profile interactively without overwriting an existing
file.

Use `doctor` as a capability-oriented preflight:

```sh
simslim doctor --list
simslim doctor <udid> --requires push,storekit,universal-links
```

`verify` asks whether the exact configured label state still holds. `doctor`
asks whether the named workflow capabilities still have their supporting
labels enabled. Both exit nonzero on a failed check.

# Other commands

```sh
simslim top                          # live fleet monitor in a terminal
simslim top <udid>                   # per-process view
simslim size <udid>                  # allocated device-directory size
simslim disk-categories              # cleanup choices and protected rows
simslim disk-plan <udid>             # read-only cleanup/storage analysis
simslim disk-clean --categories caches,logs --confirm <udid>
simslim clone <source-udid> <name>
simslim repair-clone <source-udid> <clone-udid>
simslim rename <udid> <name>
simslim boot <udid>
simslim shutdown <udid>
simslim erase <udid>
simslim delete <udid>
```

Read-only and simulator-management commands accept `--json` where applicable.
JSON is sorted and pretty-printed for stable inspection. Consult
`simslim <command> --help` before scripting a mutating operation.

# Timeouts and device sets

The default total boot/reconfiguration timeout is 10 minutes. Each spawned
`launchctl` operation is bounded by 2 minutes. Slow CI hosts can override them:

```sh
simslim on <udid> --boot-timeout 15m --spawn-timeout 5m

export SIMSLIM_BOOT_TIMEOUT=15m
export SIMSLIM_SPAWN_TIMEOUT=5m
```

Explicit flags override the environment. Duration syntax accepts Go-style
components such as `500ms`, `2m30s`, and `1h`. Global options may appear before
or after the subcommand.

The default and `testing` CoreSimulator device sets are scanned. Register
additional set names or paths with the global `--set` option:

```sh
simslim --set /path/to/device-set list
```

# Concurrent agent workflows

SimSlim changes the selected device and reboots it; it does not provide device
ownership. Use SimLease as the outer lifecycle boundary whenever another agent
could use Simulator concurrently:

```sh
simlease run --label "<task>" -- zsh -lc '
  set -euo pipefail
  simslim on "$SIMULATOR_ID" --profile ci.json
  simslim verify "$SIMULATOR_ID" --profile ci.json
  # Continue the complete build/install/test workflow here.
'
```

Only pass the lease's exact `SIMULATOR_ID`. Apply SimSlim before installing the
app or fixtures because `on` performs a reboot. A disposable leased simulator
does not need `simslim off` when SimLease will delete it on exit.

# Related concepts

- [Architecture and launchd mechanism](architecture.md)
- [Safety, cloning, and disk cleanup](safety.md)
- [Port baseline and parity](parity.md)
