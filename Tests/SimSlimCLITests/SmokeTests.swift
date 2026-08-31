import Darwin
import Foundation
@testable import SimSlimCLI
import SimSlimCore
import Testing

private enum InterruptCleanupError: Error, Equatable, Sendable {
    case failed
}

@Test func cliTargetLoads() {
    #expect(true)
}

@Test func truncatePreservesUnicode() {
    #expect(truncated("模拟器名称", to: 4) == "模拟器…")
    #expect(truncated("short", to: 10) == "short")
}

@Test func humanByteFormatting() {
    #expect(humanBytes(8 << 10) == "8 KB")
    #expect(compactBytes(0) == "0B")
    #expect(compactBytes(1_536) == "1.5K")
    #expect(compactBytes(3 * (1 << 30) + (1 << 29)) == "3.5G")
}

@Test func dottedVersionsCompareNumerically() {
    #expect(versionIsLess("9.0", "26.4"))
    #expect(versionIsLess("26.4", "26.10"))
    #expect(versionIsLess("18", "18.3"))
    #expect(!versionIsLess("18.3", "18.3"))
}

@Test func parsesGoStyleDurations() {
    #expect(parseDuration("15m") == .seconds(900))
    #expect(parseDuration("1m30s") == .seconds(90))
    #expect(parseDuration("250ms") == .milliseconds(250))
    #expect(parseDuration("-.5s") == .milliseconds(-500))
    #expect(parseDuration("1m-30s") == nil)
    #expect(parseDuration("1m+30s") == nil)
    #expect(parseDuration("5μs") == .microseconds(5))
    #expect(parseDuration("0") == .zero)
    #expect(parseDuration("0.5ns") == .zero)
    #expect(parseDuration("9223372036.854775807s") == .nanoseconds(Int64.max))
    #expect(parseDuration("9223372036.854776s") == nil)
    #expect(parseDuration("forever") == nil)
}

@Test func writesStablePrettyJSON() throws {
    struct Value: Codable {
        let second: Int
        let first: Int
    }

    let output = String(decoding: try encodedJSON(Value(second: 2, first: 1)), as: UTF8.self)
    #expect(output == "{\n  \"first\" : 1,\n  \"second\" : 2\n}\n")
}

@Test func normalizesGlobalOptionsAroundSubcommands() {
    #expect(normalizedGlobalArguments(["-v"]) == ["version"])
    #expect(normalizedGlobalArguments(["--version"]) == ["version"])
    #expect(
        normalizedGlobalArguments(["profiles", "--set", "/tmp/testing"]) ==
            ["--set", "/tmp/testing", "profiles"]
    )
    #expect(
        normalizedGlobalArguments(["profiles", "--boot-timeout=15m", "siri", "--json"]) ==
            ["--boot-timeout=15m", "profiles", "siri", "--json"]
    )
    #expect(
        normalizedGlobalArguments(["--set", "/first", "profiles", "--set=/last"]) ==
            ["--set=/last", "profiles"]
    )
    #expect(
        normalizedGlobalArguments(["profiles", "--spawn-timeout", "-1m"]) ==
            ["--spawn-timeout", "-1m", "profiles"]
    )
    #expect(
        normalizedGlobalArguments(["profiles", "--", "--set"]) ==
            ["profiles", "--", "--set"]
    )
}

@Test func profileWizardKeepsCategoriesAndIndividualDaemons() throws {
    let arrowDown = "\u{001B}[B"
    let arrowRight = "\u{001B}[C"
    let arrowLeft = "\u{001B}[D"
    let input = Data(("ci\nUI tests\n" + arrowDown + " " + arrowRight + " " + arrowLeft + "\r").utf8)
    let profile = try runProfileWizard(input: input)

    #expect(profile.name == "ci")
    #expect(profile.description == "UI tests")
    #expect(profile.except == ["siri"])
    #expect(profile.keep.isEmpty)
}

@Test func profileWizardPreservesCatalogOrder() throws {
    let arrowDown = "\u{001B}[B"
    let profile = try runProfileWizard(input: Data(("\n\n" + arrowDown + " " + arrowDown + " " + "\r").utf8))
    #expect(profile.except == ["siri", "search"])
}

@Test func profileWizardCanBeCancelled() {
    #expect(throws: ProfileWizardError.cancelled) {
        try runProfileWizard(input: Data("\n\nq".utf8))
    }
}

@Test func commandTreeAcceptsEveryPortedCommand() throws {
    let commands: [[String]] = [
        ["list"],
        ["profiles"],
        ["profile"],
        ["status", "UDID"],
        ["verify", "UDID"],
        ["doctor", "--list"],
        ["measure", "UDID"],
        ["top"],
        ["size", "UDID"],
        ["disk-categories"],
        ["disk-plan", "UDID"],
        ["disk-clean", "--categories", "caches", "--confirm", "UDID"],
        ["clone", "UDID", "Clone"],
        ["repair-clone", "SOURCE", "CLONE"],
        ["rename", "UDID", "Name"],
        ["boot", "UDID"],
        ["shutdown", "UDID"],
        ["erase", "UDID"],
        ["delete", "UDID"],
        ["on", "UDID"],
        ["off", "UDID"],
        ["version"],
    ]

    for arguments in commands {
        _ = try SimSlimCommand.parseAsRoot(arguments)
    }
}

@Test func parserAcceptsGlobalOptionsAfterSubcommand() throws {
    let arguments = normalizedGlobalArguments([
        "profiles",
        "siri",
        "--json",
        "--boot-timeout",
        "15m",
        "--spawn-timeout=5m",
        "--set",
        "/tmp/testing",
    ])
    let parsed = try SimSlimCommand.parseAsRoot(arguments)
    #expect(parsed is ProfilesCommand)
}

@Test func duplicateJSONFlagIsRejectedLikeTheGoCLI() {
    let arguments = normalizedGlobalArguments(["profiles", "--json", "--json"])
    #expect(throws: (any Error).self) {
        try SimSlimCommand.parseAsRoot(arguments)
    }
}

@Test func versionValidatesGlobalOptions() throws {
    let parsed = try SimSlimCommand.parseAsRoot(
        normalizedGlobalArguments(["--boot-timeout", "invalid", "version"])
    )
    guard let command = parsed as? VersionCommand else {
        Issue.record("expected the version command")
        return
    }
    #expect(throws: (any Error).self) {
        try command.run()
    }
}

@Test func interruptCancelsTheCommandTask() async {
    actor Observation {
        var wasCancelled = false

        func recordCancellation() {
            wasCancelled = true
        }
    }

    let observation = Observation()
    let (interrupts, interruptContinuation) = AsyncStream<Void>.makeStream()
    let (starts, startContinuation) = AsyncStream<Void>.makeStream()
    let task = Task {
        await runUntilInterrupted(signals: interrupts) {
            startContinuation.yield(())
            do {
                try await Task.sleep(for: .seconds(30))
                return nil
            } catch is CancellationError {
                await observation.recordCancellation()
                return InterruptCleanupError.failed
            } catch {
                return error
            }
        }
    }

    var startIterator = starts.makeAsyncIterator()
    _ = await startIterator.next()
    interruptContinuation.yield(())
    let completion = await task.value
    #expect(await observation.wasCancelled)
    guard case .interrupted(let error) = completion else {
        Issue.record("expected an interrupted completion")
        return
    }
    #expect(error as? InterruptCleanupError == .failed)
    interruptContinuation.finish()
    startContinuation.finish()
}

@Test func topInputReaderPreservesBatchedKeysAndEscapeSequences() throws {
    var descriptors = [Int32](repeating: 0, count: 2)
    try #require(Darwin.pipe(&descriptors) == 0)
    defer {
        Darwin.close(descriptors[0])
        Darwin.close(descriptors[1])
    }
    var reader = TopInputReader(fileDescriptor: descriptors[0])
    let input = Array("jjq".utf8) + [0x1B, 0x5B, 0x41] + [0x1B, 0x6A]
    _ = input.withUnsafeBytes { buffer in
        Darwin.write(descriptors[1], buffer.baseAddress, buffer.count)
    }

    #expect(reader.readKey(timeoutMilliseconds: 0) == .down)
    #expect(reader.readKey(timeoutMilliseconds: 0) == .down)
    #expect(reader.readKey(timeoutMilliseconds: 0) == .quit)
    #expect(reader.readKey(timeoutMilliseconds: 0) == .up)
    #expect(reader.readKey(timeoutMilliseconds: 0) == .back)
    #expect(reader.readKey(timeoutMilliseconds: 0) == .down)
}

@Test func cliSIGINTCancelsItsSubprocessSessionAndExits130() async throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let executable = repository.appending(path: ".build/debug/simslim")
    try #require(FileManager.default.isExecutableFile(atPath: executable.path))

    let directory = FileManager.default.temporaryDirectory
        .appending(path: "swift-simslim-sigint-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fakeXcrun = directory.appending(path: "xcrun")
    let pidFile = directory.appending(path: "children.pid")
    let script = """
    #!/bin/sh
    trap 'exit 0' TERM
    /usr/bin/perl -e '$SIG{TERM} = sub {}; sleep 30' &
    echo "$$ $!" > "$SIMSLIM_SIGNAL_TEST_PID_FILE"
    wait
    """
    try Data(script.utf8).write(to: fakeXcrun)
    try #require(Darwin.chmod(fakeXcrun.path, 0o755) == 0)

    let process = Foundation.Process()
    process.executableURL = executable
    process.arguments = ["list"]
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = directory.path + ":" + (environment["PATH"] ?? "")
    environment["SIMSLIM_SIGNAL_TEST_PID_FILE"] = pidFile.path
    process.environment = environment
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    defer {
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    for _ in 0 ..< 200 where !FileManager.default.fileExists(atPath: pidFile.path) {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(FileManager.default.fileExists(atPath: pidFile.path))
    let childPIDs = try String(contentsOf: pidFile, encoding: .utf8)
        .split(whereSeparator: \.isWhitespace)
        .compactMap { Int32($0) }
    try #require(childPIDs.count == 2)

    try #require(Darwin.kill(process.processIdentifier, SIGINT) == 0)
    for _ in 0 ..< 500 where process.isRunning {
        try await Task.sleep(for: .milliseconds(10))
    }
    let stillRunning = process.isRunning
    if stillRunning {
        Darwin.kill(process.processIdentifier, SIGKILL)
    }
    process.waitUntilExit()
    #expect(!stillRunning)
    #expect(process.terminationReason == .exit)
    #expect(process.terminationStatus == 130)

    for pid in childPIDs {
        for _ in 0 ..< 100 where processExists(pid) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let survived = processExists(pid)
        if survived {
            Darwin.kill(pid, SIGKILL)
        }
        #expect(!survived)
    }
}

private func processExists(_ pid: Int32) -> Bool {
    if Darwin.kill(pid, 0) == 0 {
        return true
    }
    return errno == EPERM
}

@Test func staticTopRenderersExposeGoCompatibleColumns() {
    let device = Device(
        udid: "ABCD1234-5678",
        name: "iPhone 17 Pro",
        state: "Booted",
        osVersion: "27.0",
        set: "default"
    )
    let measurement = Measurement(processes: 70, bytes: 900 << 20, cpu: 12)
    let fleet = staticFleet(
        TopOutput(
            sims: [
                TopSim(
                    device: device,
                    managedDisabled: 170,
                    managedTotal: 170,
                    memory: measurement
                ),
            ],
            totalBytes: measurement.bytes
        )
    )
    #expect(fleet.contains("iPhone 17 Pro · ABCD1234"))
    #expect(fleet.contains("slim"))
    #expect(fleet.contains("900.0M"))

    let processes = staticProcesses(
        TopProcesses(
            udid: device.udid,
            name: device.name,
            processes: [Process(pid: 42, command: "launchd_sim", bytes: 1 << 20, cpu: 2.5)],
            totalBytes: 1 << 20
        )
    )
    #expect(processes.contains("daemons by RAM"))
    #expect(processes.contains("launchd_sim"))
    #expect(processes.contains("2.5%"))
}
