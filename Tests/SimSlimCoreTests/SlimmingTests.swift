import SimSlimCore
import Testing

private struct SuspendedCommandRunner: CommandRunning {
    func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        try await Task.sleep(for: .seconds(30))
        return CommandResult()
    }
}

private actor ShutdownCancellationRunner: CommandRunning {
    let label: String

    init(label: String) {
        self.label = label
    }

    func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        if invocation.arguments.contains("shutdown") {
            throw CancellationError()
        }
        if invocation.arguments.contains("simslim-batch") {
            return CommandResult(standardOutput: "simslim-ok \(label)")
        }
        if invocation.arguments.contains("print-disabled") {
            return CommandResult(standardOutput: "disabled services = {}")
        }
        return CommandResult()
    }
}

@Test func countLostScopesPersistenceCheckToManagedLabels() {
    let managed: Set<String> = ["a", "b", "c"]
    #expect(
        SlimmingService.countLost(
            after: ["a", "b"],
            desired: ["a", "b"],
            managed: managed
        ) == 0
    )
    #expect(
        SlimmingService.countLost(
            after: ["a"],
            desired: ["a", "b"],
            managed: managed
        ) == 1
    )
    #expect(
        SlimmingService.countLost(
            after: ["a", "com.example.unmanaged"],
            desired: ["a"],
            managed: managed
        ) == 0
    )
    #expect(
        SlimmingService.countLost(
            after: ["a", "c"],
            desired: ["a"],
            managed: managed
        ) == 1
    )
}

@Test func osMajorParsesKnownAndUnknownVersions() {
    #expect(SlimmingService.osMajor("17.2") == 17)
    #expect(SlimmingService.osMajor("27") == 27)
    #expect(SlimmingService.osMajor("") == 0)
    #expect(SlimmingService.osMajor("garbage") == 0)
}

@Test func ensureAppliesRebootsAndVerifiesPersistentState() async throws {
    let label = try #require(slimmableSet().sorted().first)
    let list = deviceListJSON(state: "Shutdown")
    let runner = MockCommandRunner(
        responses: [
            .result(CommandResult()), // boot
            .result(CommandResult()), // bootstatus
            .result(CommandResult(standardOutput: "disabled services = {}")),
            .result(CommandResult(standardOutput: "simslim-ok \(label)")),
            .result(CommandResult()), // shutdown
            .result(CommandResult(standardOutput: list)), // waitShutdown
            .result(CommandResult()), // boot
            .result(CommandResult()), // bootstatus
            .result(CommandResult(standardOutput: "\"\(label)\" => disabled")),
        ]
    )
    let simctl = SimCtl(
        runner: runner,
        registry: DeviceSetRegistry(),
        configuration: SimCtlConfiguration(
            shutdownTimeout: .seconds(1),
            bootTimeout: .seconds(1),
            spawnTimeout: .seconds(1),
            shutdownPollInterval: .milliseconds(1)
        )
    )
    let service = SlimmingService(simctl: simctl)

    let changed = try await service.ensure(
        set: "default",
        udid: testUDID,
        desired: [label]
    )

    #expect(changed)
    let invocations = await runner.invocations
    #expect(invocations.filter { $0.arguments.contains("bootstatus") }.count == 2)
    #expect(invocations.contains { $0.arguments.contains("shutdown") })
}

@Test func ensureDoesNotRebootWhenDesiredStateAlreadyMatches() async throws {
    let label = try #require(slimmableSet().sorted().first)
    let runner = MockCommandRunner(
        responses: [
            .result(CommandResult()),
            .result(CommandResult()),
            .result(CommandResult(standardOutput: "\"\(label)\" => true")),
        ]
    )
    let service = SlimmingService(
        simctl: SimCtl(
            runner: runner,
            registry: DeviceSetRegistry(),
            configuration: SimCtlConfiguration(bootTimeout: .seconds(1))
        )
    )

    let changed = try await service.ensure(
        set: "default",
        udid: testUDID,
        desired: [label]
    )

    #expect(!changed)
    let invocations = await runner.invocations
    #expect(!invocations.contains { $0.arguments.contains("shutdown") })
}

@Test func readStatusRejectsShutdownDeviceWithoutLaunchctl() async throws {
    let runner = MockCommandRunner(responses: [])
    let service = SlimmingService(
        simctl: SimCtl(runner: runner, registry: DeviceSetRegistry())
    )
    let device = Device(
        udid: testUDID,
        name: "Phone",
        state: "Shutdown",
        osVersion: "27.0",
        set: "default"
    )

    do {
        _ = try await service.readStatus(for: device)
        Issue.record("expected a boot-state error")
    } catch let error as SlimmingError {
        #expect(error == .simulatorMustBeBooted(state: "Shutdown"))
    }
    #expect(await runner.invocations.isEmpty)
}

@Test func ensureBoundsTheWholeReconfiguration() async throws {
    let simctl = SimCtl(
        runner: SuspendedCommandRunner(),
        registry: DeviceSetRegistry(),
        configuration: SimCtlConfiguration(bootTimeout: .milliseconds(20))
    )

    do {
        _ = try await SlimmingService(simctl: simctl).ensure(
            set: "default",
            udid: testUDID,
            desired: []
        )
        Issue.record("expected reconfiguration timeout")
    } catch let error as SlimmingError {
        #expect(error == .reconfigureTimedOut(.milliseconds(20)))
    }
}

@Test func ensurePreservesCancellationIdentityDuringShutdown() async throws {
    let label = try #require(slimmableSet().sorted().first)
    let runner = ShutdownCancellationRunner(label: label)
    let service = SlimmingService(
        simctl: SimCtl(
            runner: runner,
            registry: DeviceSetRegistry(),
            configuration: SimCtlConfiguration(
                shutdownTimeout: .seconds(1),
                bootTimeout: .seconds(1),
                spawnTimeout: .seconds(1)
            )
        )
    )

    await #expect(throws: CancellationError.self) {
        _ = try await service.ensure(set: "default", udid: testUDID, desired: [label])
    }
}
