import ArgumentParser
import Foundation
import SimSlimCore

struct CLIServices: Sendable {
    let clone: CloneService
    let diskCleanup: DiskCleanupService
    let diskSize: DiskSizeService
    let fleet: FleetService
    let measurement: MeasurementService
    let simctl: SimCtl
    let slimming: SlimmingService

    static func make(options: GlobalOptions) async throws -> CLIServices {
        let resolved = try options.resolve()
        let registry = DeviceSetRegistry()
        for deviceSet in resolved.deviceSets {
            await registry.register(deviceSet)
        }

        let runner = SubprocessCommandRunner()
        let configuration = SimCtlConfiguration(
            bootTimeout: resolved.bootTimeout,
            spawnTimeout: resolved.spawnTimeout
        )
        let simctl = SimCtl(
            runner: runner,
            registry: registry,
            configuration: configuration
        )
        let slimming = SlimmingService(simctl: simctl)
        return CLIServices(
            clone: CloneService(simctl: simctl, slimming: slimming),
            diskCleanup: DiskCleanupService(simctl: simctl),
            diskSize: DiskSizeService(simctl: simctl, runner: runner),
            fleet: FleetService(
                simctl: simctl,
                measurement: MeasurementService(runner: runner),
                slimming: slimming,
                diskSize: DiskSizeService(simctl: simctl, runner: runner)
            ),
            measurement: MeasurementService(runner: runner),
            simctl: simctl,
            slimming: slimming
        )
    }
}

struct SimSlimCLIError: Error, LocalizedError, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

struct ProfileOptions: ParsableArguments, Sendable {
    @Option(name: .long, help: "Use a JSON profile file; mutually exclusive with --except and --keep.")
    var profile = ""

    @Option(name: .long, help: "Comma-separated category IDs to leave fully enabled.")
    var except = ""

    @Option(name: .long, help: "Comma-separated launchd labels to keep running.")
    var keep = ""

    func build() throws -> Profile {
        try buildProfile(profilePath: profile, except: except, keep: keep)
    }
}

func returnToShutdown(services: CLIServices, set: String, udid: String) async throws {
    do {
        try await services.simctl.shutdown(set: set, udid: udid)
        try await services.simctl.waitShutdown(
            set: set,
            udid: udid,
            timeout: services.simctl.configuration.shutdownTimeout
        )
    } catch {
        throw SimSlimCLIError("restore original shutdown state: \(error.localizedDescription)")
    }
}
