import SimSlimCore
import Testing

@Test func measureTreeHandlesCyclesWithoutDoubleCounting() {
    let snapshot = ProcessSnapshot(
        children: [
            10: [11, 12],
            11: [13],
            13: [10],
        ],
        cpu: [10: 1.5, 11: 0.5, 12: 2, 13: 0],
        commands: [:]
    )
    let footprint: [Int: Int64] = [10: 100, 11: 20, 12: 30, 13: 4]

    let result = MeasurementService.measureTree(
        root: 10,
        snapshot: snapshot,
        footprint: footprint
    )

    #expect(result == Measurement(processes: 4, bytes: 154, cpu: 4))
}

@Test func parsePSBuildsTreeAndUsesExecutableBasenames() {
    let snapshot = MeasurementService.parsePS(
        """
          PID  PPID %CPU COMM
           10     1  1.5 launchd_sim
           11    10 12.0 /usr/libexec/assistantd
           12    10  0.0 /System/Library/CoreServices/SpringBoard.app/SpringBoard
          bad line that should be skipped
        """
    )

    #expect(snapshot.children[10] == [11, 12])
    #expect(snapshot.commands[11] == "assistantd")
    #expect(snapshot.commands[12] == "SpringBoard")
    #expect(snapshot.cpu[11] == 12)
    #expect(snapshot.commands[1] == nil)
}

@Test(arguments: [
    ("512B", Int64(512)),
    ("8K", Int64(8 << 10)),
    ("823M", Int64(823 << 20)),
    ("1.5G+", Int64(3 << 29)),
])
func parseTopMemoryUnits(input: String, expected: Int64) {
    #expect(MeasurementService.parseBytes(input) == expected)
}

@Test func measureManyUsesOneSharedPSAndTopSnapshot() async throws {
    let first = "00000000-0000-0000-0000-000000000001"
    let second = "00000000-0000-0000-0000-000000000002"
    let runner = MockCommandRunner { invocation in
        switch invocation.executable {
        case "pgrep":
            return CommandResult(
                standardOutput: invocation.arguments.last?.contains(first) == true ? "10\n" : "20\n"
            )
        case "ps":
            return CommandResult(
                standardOutput: """
                  PID PPID %CPU COMM
                  10 1 1.0 launchd_sim
                  11 10 2.0 child-one
                  20 1 3.0 launchd_sim
                  21 20 4.0 child-two
                """
            )
        case "top":
            return CommandResult(
                standardOutput: """
                  PID MEM
                  10 100B
                  11 20B
                  20 200B
                  21 30B
                """
            )
        default:
            throw MockCommandError.message("unexpected command \(invocation.executable)")
        }
    }
    let service = MeasurementService(runner: runner)

    let result = try await service.measureMany(udids: [first, second])

    #expect(result.errors.isEmpty)
    #expect(result.measurements[first] == Measurement(processes: 2, bytes: 120, cpu: 3))
    #expect(result.measurements[second] == Measurement(processes: 2, bytes: 230, cpu: 7))
    let invocations = await runner.invocations
    #expect(invocations.filter { $0.executable == "ps" }.count == 1)
    #expect(invocations.filter { $0.executable == "top" }.count == 1)
}

@Test func measureManyStopsImmediatelyOnCancellation() async {
    let runner = SleepingMeasurementRunner()
    let service = MeasurementService(runner: runner)
    let task = Task {
        try await service.measureMany(udids: ["one", "two", "three"])
    }
    while await runner.invocationCount == 0 {
        await Task.yield()
    }

    task.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await task.value
    }
    #expect(await runner.invocationCount == 1)
}

@Test func measuredProcessesSortByMemoryThenPID() async throws {
    let runner = MockCommandRunner { invocation in
        switch invocation.executable {
        case "pgrep":
            return CommandResult(standardOutput: "10\n")
        case "ps":
            return CommandResult(
                standardOutput: "10 1 0 root\n11 10 0 eleven\n12 10 0 twelve\n"
            )
        case "top":
            return CommandResult(standardOutput: "10 1B\n11 20B\n12 20B\n")
        default:
            throw MockCommandError.message("unexpected command")
        }
    }

    let processes = try await MeasurementService(runner: runner)
        .measureProcesses(udid: testUDID)

    #expect(processes.map(\.pid) == [11, 12, 10])
}

private actor SleepingMeasurementRunner: CommandRunning {
    private(set) var invocationCount = 0

    func run(_: CommandInvocation) async throws -> CommandResult {
        invocationCount += 1
        try await Task.sleep(for: .seconds(30))
        return CommandResult()
    }
}
