import ArgumentParser
import SimSlimCore

struct CloneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clone",
        abstract: "Clone apps, data, settings, and the service profile."
    )

    @ParentCommand var parent: SimSlimCommand
    @Flag(name: .long, help: "Print machine-readable JSON.") var json = false
    @Argument(help: "Source simulator UDID.") var udid: String
    @Argument(help: "Name for the cloned simulator.") var name: String

    mutating func run() async throws {
        let normalizedName = try SimCtl.normalizeSimulatorName(name)
        let services = try await CLIServices.make(options: parent.globals)
        let newUDID = try await services.clone.clone(udid: udid, name: normalizedName)
        let result = SimulatorMutationOutput(
            action: "clone",
            udid: newUDID,
            name: normalizedName,
            sourceUdid: udid
        )
        if json {
            try writeJSON(result)
        } else {
            print("Cloned \(udid) as \(normalizedName.debugDescription) (\(newUDID)).")
        }
    }
}

struct RepairCloneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repair-clone",
        abstract: "Repair source-bound state in an existing clone."
    )

    @ParentCommand var parent: SimSlimCommand
    @Flag(name: .long, help: "Print machine-readable JSON.") var json = false
    @Argument(help: "Source simulator UDID.") var sourceUDID: String
    @Argument(help: "Cloned simulator UDID.") var cloneUDID: String

    mutating func run() async throws {
        let services = try await CLIServices.make(options: parent.globals)
        try await services.clone.repair(sourceUDID: sourceUDID, cloneUDID: cloneUDID)
        let result = SimulatorMutationOutput(
            action: "repair-clone",
            udid: cloneUDID,
            sourceUdid: sourceUDID
        )
        if json {
            try writeJSON(result)
        } else {
            print("Repaired clone \(cloneUDID) and verified no links or open files into specified source \(sourceUDID).")
        }
    }
}

struct RenameCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a simulator."
    )

    @ParentCommand var parent: SimSlimCommand
    @Flag(name: .long, help: "Print machine-readable JSON.") var json = false
    @Argument(help: "Simulator UDID.") var udid: String
    @Argument(help: "New simulator name.") var name: String

    mutating func run() async throws {
        let normalizedName = try SimCtl.normalizeSimulatorName(name)
        let services = try await CLIServices.make(options: parent.globals)
        try await services.simctl.rename(udid: udid, name: normalizedName)
        let result = SimulatorMutationOutput(action: "rename", udid: udid, name: normalizedName)
        if json {
            try writeJSON(result)
        } else {
            print("Renamed \(udid) to \(normalizedName.debugDescription).")
        }
    }
}

struct BootCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boot",
        abstract: "Boot a simulator and wait for its services."
    )

    @ParentCommand var parent: SimSlimCommand
    @Flag(name: .long, help: "Print machine-readable JSON.") var json = false
    @Argument(help: "Simulator UDID.") var udid: String

    mutating func run() async throws {
        let services = try await CLIServices.make(options: parent.globals)
        let device = try await services.simctl.findDevice(udid: udid)
        let result = SimulatorMutationOutput(action: "boot", udid: udid)
        if device.state == "Booted" {
            if json {
                try writeJSON(result)
            } else {
                print("Simulator \(udid) is already booted.")
            }
            return
        }

        if !json {
            writeStandardError("Booting \(udid)...\n")
        }
        try await services.simctl.bootAndWait(set: device.set, udid: udid)
        if json {
            try writeJSON(result)
        } else {
            print("Booted \(udid).")
        }
    }
}

struct ShutdownCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shutdown",
        abstract: "Shut down a booted simulator."
    )

    @ParentCommand var parent: SimSlimCommand
    @Flag(name: .long, help: "Print machine-readable JSON.") var json = false
    @Argument(help: "Simulator UDID.") var udid: String

    mutating func run() async throws {
        let services = try await CLIServices.make(options: parent.globals)
        let device = try await services.simctl.findDevice(udid: udid)
        let result = SimulatorMutationOutput(action: "shutdown", udid: udid)
        if device.state != "Booted" {
            if json {
                try writeJSON(result)
            } else {
                print("Simulator \(udid) is already shut down.")
            }
            return
        }

        try await services.simctl.shutdown(set: device.set, udid: udid)
        try await services.simctl.waitShutdown(
            set: device.set,
            udid: udid,
            timeout: services.simctl.configuration.shutdownTimeout
        )
        if json {
            try writeJSON(result)
        } else {
            print("Shut down \(udid).")
        }
    }
}

struct EraseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "erase",
        abstract: "Erase a simulator's apps, data, and settings."
    )

    @ParentCommand var parent: SimSlimCommand
    @Flag(name: .long, help: "Print machine-readable JSON.") var json = false
    @Argument(help: "Simulator UDID.") var udid: String

    mutating func run() async throws {
        let services = try await CLIServices.make(options: parent.globals)
        try await services.simctl.erase(udid: udid)
        let result = SimulatorMutationOutput(action: "erase", udid: udid)
        if json {
            try writeJSON(result)
        } else {
            print("Erased simulator \(udid).")
        }
    }
}

struct DeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Permanently delete a simulator."
    )

    @ParentCommand var parent: SimSlimCommand
    @Flag(name: .long, help: "Print machine-readable JSON.") var json = false
    @Argument(help: "Simulator UDID.") var udid: String

    mutating func run() async throws {
        let services = try await CLIServices.make(options: parent.globals)
        try await services.simctl.delete(udid: udid)
        let result = SimulatorMutationOutput(action: "delete", udid: udid)
        if json {
            try writeJSON(result)
        } else {
            print("Deleted simulator \(udid).")
        }
    }
}

struct OnCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "on",
        abstract: "Slim a simulator and reboot it with persistent overrides."
    )

    @ParentCommand var parent: SimSlimCommand
    @OptionGroup var profileOptions: ProfileOptions
    @Flag(name: .long, help: "Return an initially shutdown simulator to shutdown.")
    var preserveBootState = false
    @Argument(help: "Simulator UDID.") var udid: String

    mutating func run() async throws {
        let profile = try profileOptions.build()
        let services = try await CLIServices.make(options: parent.globals)
        let device = try await services.simctl.findDevice(udid: udid)
        let restoreShutdown = preserveBootState && device.state == "Shutdown"
        writeStandardError(
            "Slimming \(udid): disabling \(profile.desired().count) background services. "
                + "The simulator will reboot to apply the changes.\n"
        )

        var changed = false
        var operationError: (any Error)?
        do {
            changed = try await services.slimming.enable(
                set: device.set,
                udid: udid,
                profile: profile,
                reporter: { writeStandardError("\($0)\n") }
            )
        } catch {
            operationError = error
        }
        let restoreError = await restoreIfNeeded(
            restoreShutdown,
            services: services,
            set: device.set,
            udid: udid
        )
        try throwCombined(operationError: operationError, restoreError: restoreError)

        switch (changed, restoreShutdown) {
        case (true, true):
            print("Done. Simulator reconfigured slim and returned to shutdown.")
        case (true, false):
            print("Done. Simulator reconfigured and rebooted slim.")
        case (false, true):
            print("Already slim. Original shutdown state restored.")
        case (false, false):
            print("Already slim. Nothing to change.")
        }
    }
}

struct OffCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "off",
        abstract: "Restore a simulator to stock service behavior."
    )

    @ParentCommand var parent: SimSlimCommand
    @Flag(name: .long, help: "Return an initially shutdown simulator to shutdown.")
    var preserveBootState = false
    @Argument(help: "Simulator UDID.") var udid: String

    mutating func run() async throws {
        let services = try await CLIServices.make(options: parent.globals)
        let device = try await services.simctl.findDevice(udid: udid)
        let restoreShutdown = preserveBootState && device.state == "Shutdown"
        writeStandardError(
            "Restoring \(udid) to stock. The simulator will reboot to apply the changes.\n"
        )

        var changed = false
        var operationError: (any Error)?
        do {
            changed = try await services.slimming.disable(
                set: device.set,
                udid: udid,
                reporter: { writeStandardError("\($0)\n") }
            )
        } catch {
            operationError = error
        }
        let restoreError = await restoreIfNeeded(
            restoreShutdown,
            services: services,
            set: device.set,
            udid: udid
        )
        try throwCombined(operationError: operationError, restoreError: restoreError)

        switch (changed, restoreShutdown) {
        case (true, true):
            print("Done. All daemons re-enabled and simulator returned to shutdown.")
        case (true, false):
            print("Done. All daemons re-enabled and simulator rebooted.")
        case (false, true):
            print("Already stock. Original shutdown state restored.")
        case (false, false):
            print("Already stock. Nothing to change.")
        }
    }
}

private func restoreIfNeeded(
    _ needed: Bool,
    services: CLIServices,
    set: String,
    udid: String
) async -> (any Error)? {
    guard needed else { return nil }
    do {
        try await returnToShutdown(services: services, set: set, udid: udid)
        return nil
    } catch {
        return error
    }
}

private func throwCombined(
    operationError: (any Error)?,
    restoreError: (any Error)?
) throws {
    if let operationError, let restoreError {
        throw SimSlimCLIError(
            "\(operationError.localizedDescription); additionally could not restore original shutdown state: "
                + restoreError.localizedDescription
        )
    }
    if let restoreError { throw restoreError }
    if let operationError { throw operationError }
}
