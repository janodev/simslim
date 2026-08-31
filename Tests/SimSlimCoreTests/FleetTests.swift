import SimSlimCore
import Testing

@Test func fleetSnapshotFiltersSortsAndSharesMemorySnapshot() async throws {
    let first = "00000000-0000-0000-0000-000000000001"
    let second = "00000000-0000-0000-0000-000000000002"
    let shutdown = "00000000-0000-0000-0000-000000000003"
    let disabledLabel = try #require(slimmableSet().sorted().first)
    let list = """
    {
      "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
          {"udid":"\(first)","name":"First","state":"Booted","isAvailable":true,"dataPath":"/tmp/\(first)/data"},
          {"udid":"\(second)","name":"Second","state":"Booted","isAvailable":true,"dataPath":"/tmp/\(second)/data"},
          {"udid":"\(shutdown)","name":"Off","state":"Shutdown","isAvailable":true,"dataPath":"/tmp/\(shutdown)/data"}
        ]
      }
    }
    """
    let runner = MockCommandRunner { invocation in
        switch invocation.executable {
        case "xcrun":
            if invocation.arguments.contains("--set") {
                return CommandResult(termination: .exited(1))
            }
            if invocation.arguments.contains("list") {
                return CommandResult(standardOutput: list)
            }
            if invocation.arguments.contains("print-disabled") {
                return CommandResult(standardOutput: "\"\(disabledLabel)\" => disabled")
            }
        case "pgrep":
            return CommandResult(
                standardOutput: invocation.arguments.last?.contains(first) == true ? "10\n" : "20\n"
            )
        case "ps":
            return CommandResult(
                standardOutput: "10 1 1 root\n11 10 2 child\n20 1 3 root\n21 20 4 child\n"
            )
        case "top":
            return CommandResult(standardOutput: "10 100B\n11 20B\n20 200B\n21 30B\n")
        default:
            break
        }
        throw MockCommandError.message("unexpected command \(invocation.rendered)")
    }
    let simctl = SimCtl(runner: runner, registry: DeviceSetRegistry())

    let output = try await FleetService(simctl: simctl).snapshot(withDisk: false)

    #expect(output.sims.map(\.udid) == [second, first])
    #expect(output.sims.allSatisfy { $0.state == "Booted" })
    #expect(output.totalBytes == 350)
    #expect(output.sims.allSatisfy { $0.managedDisabled == 1 })
    #expect(output.sims.allSatisfy { $0.managedTotal == slimmableSet().count })
    let invocations = await runner.invocations
    #expect(invocations.filter { $0.executable == "ps" }.count == 1)
    #expect(invocations.filter { $0.executable == "top" }.count == 1)
    #expect(!invocations.contains { $0.executable == "du" })
}

@Test func topBytesSortsMissingMemoryLast() {
    let device = Device(
        udid: testUDID,
        name: "Phone",
        state: "Booted",
        osVersion: "27.0",
        set: "default"
    )
    let missing = TopSim(device: device, managedTotal: 0)
    let measured = TopSim(
        device: device,
        managedTotal: 0,
        memory: Measurement(processes: 1, bytes: 0, cpu: 0)
    )
    #expect(FleetService.topBytes(missing) == -1)
    #expect(FleetService.topBytes(measured) == 0)
}
