import Foundation
import SimSlimCore
import Testing

let testUDID = "00000000-0000-0000-0000-000000000001"

func deviceListJSON(
    udid: String = testUDID,
    state: String = "Booted",
    runtime: String = "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
    dataPath: String = "/tmp/CoreSimulator/Devices/\(testUDID)/data"
) -> String {
    """
    {
      "devices": {
        "\(runtime)": [
          {
            "udid": "\(udid)",
            "name": "iPhone 17 Pro",
            "state": "\(state)",
            "isAvailable": true,
            "dataPath": "\(dataPath)"
          }
        ],
        "com.apple.CoreSimulator.SimRuntime.tvOS-27-0": [
          {
            "udid": "11111111-1111-1111-1111-111111111111",
            "name": "Apple TV",
            "state": "Shutdown",
            "isAvailable": true
          }
        ]
      }
    }
    """
}

@Test func simctlArgumentsRouteDeviceSets() async {
    #expect(
        SimCtl.simctlArguments(setToken: "", subcommand: ["boot", "U"])
            == ["simctl", "boot", "U"]
    )
    #expect(
        SimCtl.simctlArguments(setToken: "testing", subcommand: ["boot", "U"])
            == ["simctl", "--set", "testing", "boot", "U"]
    )

    let registry = DeviceSetRegistry()
    await registry.register("/custom/set")
    let simctl = SimCtl(runner: MockCommandRunner(responses: []), registry: registry)
    #expect(
        await simctl.simctlArguments(set: "/custom/set", subcommand: ["list"])
            == ["simctl", "--set", "/custom/set", "list"]
    )
    #expect(await registry.extraTokens() == ["/custom/set"])
}

@Test func listDevicesKeepsIOSAvailableDevicesAndSkipsMissingSecondarySet() async throws {
    let runner = MockCommandRunner { invocation in
        if invocation.arguments.contains("--set") {
            return CommandResult(standardError: "set does not exist", termination: .exited(1))
        }
        return CommandResult(standardOutput: deviceListJSON())
    }
    let simctl = SimCtl(runner: runner, registry: DeviceSetRegistry())

    let devices = try await simctl.listDevices()

    #expect(devices.count == 1)
    #expect(devices[0].udid == testUDID)
    #expect(devices[0].osVersion == "27.0")
    #expect(devices[0].set == "default")
    #expect(devices[0].dataPath.hasSuffix("/data"))
}

@Test func destructiveCommandsResolveAnExactDeviceBeforeActing() async throws {
    let runner = MockCommandRunner { invocation in
        if invocation.arguments.contains("list") {
            return CommandResult(standardOutput: deviceListJSON(state: "Shutdown"))
        }
        return CommandResult()
    }
    let simctl = SimCtl(runner: runner, registry: DeviceSetRegistry())

    try await simctl.delete(udid: testUDID)
    let invocations = await runner.invocations
    #expect(invocations.last?.arguments == ["simctl", "delete", testUDID])

    do {
        try await simctl.erase(udid: "all")
        Issue.record("simctl alias should not enter a destructive path")
    } catch let error as SimCtlError {
        #expect(error == .noSimulator("all"))
    }
    let afterRejectedAlias = await runner.invocations
    #expect(!afterRejectedAlias.contains { $0.arguments.contains("erase") })
}

@Test func simulatorNameAndCloneUDIDValidationMatchesGoBehavior() throws {
    #expect(try SimCtl.normalizeSimulatorName("  Démo 📱  ") == "Démo 📱")
    #expect(throws: SimCtlError.self) {
        try SimCtl.normalizeSimulatorName("QA\nPhone")
    }
    #expect(throws: SimCtlError.self) {
        try SimCtl.normalizeSimulatorName(String(repeating: "a", count: 129))
    }

    #expect(try SimCtl.parseClonedUDID("\n\(testUDID)\n") == testUDID)
    #expect(
        try SimCtl.parseClonedUDID(
            standardOutput: "warning: clone output moved\n",
            standardError: "created simulator (\(testUDID))\n"
        ) == testUDID
    )
    #expect(throws: SimCtlError.self) {
        try SimCtl.parseClonedUDID("00000000-0000-0000-0000-00000000000Z")
    }
    #expect(throws: SimCtlError.self) {
        try SimCtl.parseClonedUDID(
            standardOutput: "\(testUDID)\n",
            standardError: "33333333-3333-3333-3333-333333333333\n"
        )
    }
}

@Test func launchctlOutputParsersHandleCurrentAndLegacyForms() {
    let disabled = SimCtl.parseDisabled(
        """
        disabled services = {
          "com.apple.current" => disabled
          "com.apple.legacy" => true
          "com.apple.enabled" => false
        }
        """
    )
    #expect(disabled == ["com.apple.current", "com.apple.legacy"])

    let confirmed = SimCtl.parseBatchOK(
        """
        warning
        simslim-ok com.apple.one
          simslim-ok com.apple.two
        simslim-fail com.apple.three
        simslim-ok\(" ")
        """
    )
    #expect(confirmed == ["com.apple.one", "com.apple.two"])
}

@Test func applyDeltaFallsBackToBoundedConcurrentRetries() async throws {
    let runner = MockCommandRunner { invocation in
        if invocation.arguments.contains("/bin/sh") {
            return CommandResult(standardOutput: "batch produced no markers")
        }
        return CommandResult()
    }
    let configuration = SimCtlConfiguration(
        spawnTimeout: .seconds(1),
        applyPasses: 3,
        batchSize: 40,
        batchWave: 2
    )
    let simctl = SimCtl(
        runner: runner,
        registry: DeviceSetRegistry(),
        configuration: configuration
    )

    try await simctl.applyDelta(
        set: "default",
        udid: testUDID,
        toDisable: ["a", "b", "c"],
        toEnable: ["d"]
    )

    let invocations = await runner.invocations
    let direct = invocations.filter {
        $0.arguments.contains("launchctl") && !$0.arguments.contains("/bin/sh")
    }
    #expect(direct.count == 4)
    #expect(direct.contains { $0.arguments.suffix(3) == ["launchctl", "disable", "system/a"] })
    #expect(direct.contains { $0.arguments.suffix(3) == ["launchctl", "enable", "system/d"] })
}

@Test func deviceEncodingOmitsOperationalDataPath() throws {
    let device = Device(
        udid: testUDID,
        name: "Phone",
        state: "Booted",
        osVersion: "27.0",
        set: "default",
        dataPath: "/private/sensitive/path"
    )
    let encoded = String(decoding: try JSONEncoder().encode(device), as: UTF8.self)
    #expect(!encoded.contains("dataPath"))
    #expect(!encoded.contains("sensitive"))
}
