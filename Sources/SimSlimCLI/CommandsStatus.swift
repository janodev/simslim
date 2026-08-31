import ArgumentParser
import SimSlimCore

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report how slim a booted simulator is."
    )

    @ParentCommand var parent: SimSlimCommand
    @Flag(name: .long, help: "Print machine-readable JSON.") var json = false
    @Flag(name: .long, help: "List disabled labels grouped by category.") var dropped = false
    @Argument(help: "Simulator UDID.") var udid: String

    mutating func run() async throws {
        let services = try await CLIServices.make(options: parent.globals)
        let (status, disabled) = try await services.slimming.readStatus(udid: udid)
        let verdict: String
        if status.managedDisabled == status.managedTotal {
            verdict = "slim"
        } else if status.managedDisabled > 0 {
            verdict = "partially slim"
        } else {
            verdict = "stock"
        }
        let droppedCategories = dropped ? droppedCategories(disabled: disabled) : []

        if json {
            try writeJSON(
                StatusOutput(
                    status: status,
                    verdict: verdict,
                    dropped: droppedCategories
                )
            )
            return
        }

        print("\(udid): \(status.managedDisabled)/\(status.managedTotal) managed launchd labels disabled (\(verdict))")
        if dropped {
            if droppedCategories.isEmpty {
                print("  Nothing dropped; every managed launchd label is enabled.")
            }
            for category in droppedCategories {
                print("  " + padded(category.id, width: 14) + " " + category.name + " — " + category.downside)
                for label in category.labels {
                    print("    \(label)")
                }
            }
        }
    }
}

struct VerifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Check that a simulator exactly matches a service profile."
    )

    @ParentCommand var parent: SimSlimCommand
    @OptionGroup var profileOptions: ProfileOptions
    @Flag(name: .long, help: "Print machine-readable JSON.") var json = false
    @Argument(help: "Simulator UDID.") var udid: String

    mutating func run() async throws {
        let profile = try profileOptions.build()
        let services = try await CLIServices.make(options: parent.globals)
        let (_, disabled) = try await services.slimming.readStatus(udid: udid)
        var result = compareDisabled(
            disabled: disabled,
            desired: profile.desired(),
            managed: managedSet()
        )
        result.udid = udid

        if json {
            try writeJSON(result)
        } else if result.ok {
            print("\(udid) matches the profile: all \(profile.desired().count) expected daemons disabled.")
        } else {
            print("\(udid) does not match the profile (\(result.missing.count) missing, \(result.extra.count) extra):")
            for label in result.missing {
                print("  missing \(label) (should be disabled, is enabled)")
            }
            for label in result.extra {
                print("  extra   \(label) (disabled beyond the profile)")
            }
            print("Re-run `simslim on` with the same profile to repair.")
        }
        if !result.ok {
            throw ExitCode.failure
        }
    }
}

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check features required by a booted simulator workflow."
    )

    @ParentCommand var parent: SimSlimCommand
    @Flag(name: .long, help: "Print machine-readable JSON.") var json = false
    @Flag(name: .long, help: "List every checkable feature.") var list = false
    @Option(name: .long, help: "Comma-separated feature IDs the simulator must support.")
    var requires = ""
    @Argument(help: "Simulator UDID; omit with --list.") var udid: String?

    mutating func run() async throws {
        _ = try parent.globals.resolve()
        if list {
            guard udid == nil else {
                throw ValidationError("doctor --list takes no arguments")
            }
            if json {
                try writeJSON(features)
            } else {
                for feature in features {
                    print(
                        padded(feature.id, width: 16) + " "
                            + padded(feature.name, width: 38) + " "
                            + feature.labels.joined(separator: ", ")
                    )
                }
            }
            return
        }

        guard let udid else {
            throw ValidationError("expected exactly one simulator UDID (see `simslim list`)")
        }
        let requested = try resolveFeatures(splitList(requires))
        guard !requested.isEmpty else {
            throw ValidationError("doctor needs at least one feature via --requires (see `simslim doctor --list`)")
        }
        let services = try await CLIServices.make(options: parent.globals)
        let (_, disabled) = try await services.slimming.readStatus(udid: udid)
        var report = diagnoseFeatures(requested, disabled: disabled)
        report.udid = udid

        if json {
            try writeJSON(report)
        } else {
            let broken = report.features.count(where: { !$0.ok })
            print("\(udid): \(report.features.count - broken)/\(report.features.count) required features OK")
            for feature in report.features {
                if feature.ok {
                    print("  ok     \(feature.id)")
                } else {
                    print("  BROKEN \(feature.id) — \(feature.disabled.joined(separator: ", ")) disabled")
                }
            }
        }
        if !report.ok {
            throw ExitCode.failure
        }
    }
}

struct MeasureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "measure",
        abstract: "Report a booted simulator's memory footprint."
    )

    @ParentCommand var parent: SimSlimCommand
    @Flag(name: .long, help: "Print machine-readable JSON.") var json = false
    @Argument(help: "Simulator UDID.") var udid: String

    mutating func run() async throws {
        let services = try await CLIServices.make(options: parent.globals)
        let measurement = try await services.measurement.measure(udid: udid)
        if json {
            try writeJSON(measurement)
        } else {
            print("\(udid): \(measurement.processes) processes, \(humanBytes(measurement.bytes)) memory footprint (phys_footprint)")
        }
    }
}
