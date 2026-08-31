import SimSlimCore
import Testing

@Test func parseDUDiskUsageConvertsKiBToBytes() throws {
    #expect(
        try DiskSizeService.parseDUDiskUsage("4747728\t/simulator/path\n")
            == 4_861_673_472
    )
    #expect(throws: DiskSizeError.self) {
        try DiskSizeService.parseDUDiskUsage("")
    }
    #expect(throws: DiskSizeError.self) {
        try DiskSizeService.parseDUDiskUsage("nope /simulator/path")
    }
    #expect(throws: DiskSizeError.self) {
        try DiskSizeService.parseDUDiskUsage("-1 /simulator/path")
    }
}

@Test func diskUsageResolvesExactDeviceBeforeBuildingPath() async throws {
    let dataPath = "/tmp/CoreSimulator/Devices/\(testUDID)/data"
    let runner = MockCommandRunner { invocation in
        if invocation.executable == "xcrun" {
            if invocation.arguments.contains("--set") {
                return CommandResult(termination: .exited(1))
            }
            return CommandResult(
                standardOutput: deviceListJSON(dataPath: dataPath)
            )
        }
        if invocation.executable == "du" {
            return CommandResult(standardOutput: "10\t\(dataPath)\n")
        }
        throw MockCommandError.message("unexpected command")
    }
    let simctl = SimCtl(runner: runner, registry: DeviceSetRegistry())
    let service = DiskSizeService(simctl: simctl)

    let result = try await service.deviceDiskUsage(udid: testUDID)

    #expect(result.bytes == 10_240)
    let invocations = await runner.invocations
    let du = try #require(invocations.first { $0.executable == "du" })
    #expect(du.arguments == ["-sk", "/tmp/CoreSimulator/Devices/\(testUDID)"])
}
