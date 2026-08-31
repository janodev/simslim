import ArgumentParser
import SimSlimCore

struct SizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "size",
        abstract: "Report a simulator's allocated disk footprint."
    )

    @ParentCommand var parent: SimSlimCommand
    @Flag(name: .long, help: "Print machine-readable JSON.") var json = false
    @Argument(help: "Simulator UDID.") var udid: String

    mutating func run() async throws {
        let services = try await CLIServices.make(options: parent.globals)
        let measurement = try await services.diskSize.deviceDiskUsage(udid: udid)
        if json {
            try writeJSON(measurement)
        } else {
            print("\(udid): \(humanBytes(measurement.bytes)) on disk")
        }
    }
}

struct DiskCategoriesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disk-categories",
        abstract: "Show cleanup and protected system-asset categories."
    )

    @ParentCommand var parent: SimSlimCommand
    @Flag(name: .long, help: "Print machine-readable JSON.") var json = false

    func run() throws {
        _ = try parent.globals.resolve()
        if json {
            try writeJSON(diskCleanupCategories)
            return
        }
        for category in diskCleanupCategories {
            let availability = category.canClean ? "cleanable" : "measured only"
            print(
                padded(category.id, width: 22) + " "
                    + padded(category.name, width: 28) + " "
                    + "\(category.risk) · \(availability)"
            )
            print("                       \(category.downside)")
        }
    }
}

struct DiskPlanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disk-plan",
        abstract: "Measure reclaimable and stored data without deleting it."
    )

    @ParentCommand var parent: SimSlimCommand
    @Flag(name: .long, help: "Print machine-readable JSON.") var json = false
    @Argument(help: "Simulator UDID.") var udid: String

    mutating func run() async throws {
        let services = try await CLIServices.make(options: parent.globals)
        let plan = try await services.diskCleanup.plan(udid: udid)
        if json {
            try writeJSON(plan)
            return
        }

        print("\(udid): \(humanBytes(plan.cleanableBytes)) currently cleanable")
        for category in plan.categories {
            let availability = category.canClean ? "" : " (iOS-managed; measured only)"
            print("  " + padded(category.id, width: 22) + " " + leftPadded(humanBytes(category.bytes), width: 8) + availability)
        }
        if !plan.storage.isEmpty {
            print("  Stored data (read only)")
            for storage in plan.storage {
                print("    " + padded(storage.id, width: 20) + " " + leftPadded(humanBytes(storage.bytes), width: 8))
            }
        }
    }
}

struct DiskCleanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disk-clean",
        abstract: "Permanently delete selected per-device data."
    )

    @ParentCommand var parent: SimSlimCommand
    @Flag(name: .long, help: "Print machine-readable JSON.") var json = false
    @Option(name: .long, help: "Comma-separated cleanable disk category IDs.") var categories = ""
    @Flag(name: .long, help: "Acknowledge permanent deletion.") var confirm = false
    @Flag(name: .long, help: "Reboot a simulator that was booted before cleanup.")
    var preserveBootState = false
    @Argument(help: "Simulator UDID.") var udid: String

    mutating func run() async throws {
        guard confirm else {
            throw ValidationError(
                "disk-clean permanently deletes data; pass --confirm after reviewing `simslim disk-plan \(udid)`"
            )
        }
        let categoryIDs = try validateDiskCleanupSelection(splitList(categories))
        let services = try await CLIServices.make(options: parent.globals)
        let result = try await services.diskCleanup.clean(
            udid: udid,
            categoryIDs: categoryIDs,
            preserveBootState: preserveBootState
        )
        if json {
            try writeJSON(result)
        } else {
            print(
                "Cleaned \(udid) and reclaimed \(humanBytes(result.reclaimedBytes)). "
                    + "Generated contents stay deleted; on-demand assets may download again when needed."
            )
        }
    }
}

func leftPadded(_ value: String, width: Int) -> String {
    guard value.count < width else { return value }
    return String(repeating: " ", count: width - value.count) + value
}
