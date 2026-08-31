import Foundation

public struct Device: Codable, Equatable, Sendable {
    public let udid: String
    public let name: String
    public let state: String
    public let osVersion: String
    public let set: String
    public let dataPath: String

    public init(
        udid: String,
        name: String,
        state: String,
        osVersion: String,
        set: String,
        dataPath: String = ""
    ) {
        self.udid = udid
        self.name = name
        self.state = state
        self.osVersion = osVersion
        self.set = set
        self.dataPath = dataPath
    }

    private enum CodingKeys: String, CodingKey {
        case udid
        case name
        case state
        case osVersion
        case set
        case dataPath
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        udid = try container.decode(String.self, forKey: .udid)
        name = try container.decode(String.self, forKey: .name)
        state = try container.decode(String.self, forKey: .state)
        osVersion = try container.decode(String.self, forKey: .osVersion)
        set = try container.decode(String.self, forKey: .set)
        dataPath = try container.decodeIfPresent(String.self, forKey: .dataPath) ?? ""
    }

    /// `dataPath` is deliberately internal operational data in the Go JSON
    /// contract and is therefore omitted from public machine-readable output.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(udid, forKey: .udid)
        try container.encode(name, forKey: .name)
        try container.encode(state, forKey: .state)
        try container.encode(osVersion, forKey: .osVersion)
        try container.encode(set, forKey: .set)
    }
}

public struct DeviceSet: Equatable, Sendable {
    public let token: String
    public let name: String

    public init(token: String, name: String) {
        self.token = token
        self.name = name
    }
}

public actor DeviceSetRegistry {
    public static let shared = DeviceSetRegistry()

    private var extraSets: [DeviceSet] = []

    public init() {}

    public func register(_ value: String) {
        guard !knownSets().contains(where: { $0.token == value }) else { return }
        extraSets.append(DeviceSet(token: value, name: value))
    }

    public func reset() {
        extraSets.removeAll()
    }

    public func extraTokens() -> [String] {
        extraSets.map(\.token)
    }

    public func knownSets() -> [DeviceSet] {
        [
            DeviceSet(token: "", name: "default"),
            DeviceSet(token: "testing", name: "testing"),
        ] + extraSets
    }

    public func token(forName name: String) -> String {
        knownSets().first(where: { $0.name == name })?.token ?? ""
    }
}

public enum SimCtlError: Error, Equatable, LocalizedError, Sendable {
    case invalidSimulatorName(String)
    case invalidClonedUDID(String)
    case noSimulator(String)
    case parseDeviceList(String)
    case missingDataPath(String)
    case shutdownTimedOut(String)
    case launchctlTransitions(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSimulatorName(let message),
             .parseDeviceList(let message),
             .launchctlTransitions(let message):
            message
        case .invalidClonedUDID(let value):
            "simctl clone returned an invalid UDID \"\(value)\""
        case .noSimulator(let udid):
            "no simulator with udid \(udid)"
        case .missingDataPath(let udid):
            "simulator \(udid) has no data path"
        case .shutdownTimedOut(let udid):
            "timed out waiting for \(udid) to shut down"
        }
    }
}

public struct SimCtlConfiguration: Equatable, Sendable {
    public var shutdownTimeout: Duration
    public var bootTimeout: Duration
    public var spawnTimeout: Duration
    public var shutdownPollInterval: Duration
    public var applyPasses: Int
    public var batchSize: Int
    public var batchWave: Int

    public init(
        shutdownTimeout: Duration = .seconds(30),
        bootTimeout: Duration = .seconds(600),
        spawnTimeout: Duration = .seconds(120),
        shutdownPollInterval: Duration = .milliseconds(500),
        applyPasses: Int = 3,
        batchSize: Int = 40,
        batchWave: Int = 8
    ) {
        self.shutdownTimeout = shutdownTimeout
        self.bootTimeout = bootTimeout
        self.spawnTimeout = spawnTimeout
        self.shutdownPollInterval = shutdownPollInterval
        self.applyPasses = max(1, applyPasses)
        self.batchSize = max(1, batchSize)
        self.batchWave = max(1, batchWave)
    }
}

public struct SimCtl: Sendable {
    public let runner: any CommandRunning
    public let registry: DeviceSetRegistry
    public let configuration: SimCtlConfiguration

    public init(
        runner: any CommandRunning = SubprocessCommandRunner(),
        registry: DeviceSetRegistry = .shared,
        configuration: SimCtlConfiguration = SimCtlConfiguration()
    ) {
        self.runner = runner
        self.registry = registry
        self.configuration = configuration
    }

    public static func simctlArguments(setToken: String, subcommand: [String]) -> [String] {
        if setToken.isEmpty {
            return ["simctl"] + subcommand
        }
        return ["simctl", "--set", setToken] + subcommand
    }

    public func simctlArguments(set: String, subcommand: [String]) async -> [String] {
        let token = await registry.token(forName: set)
        return Self.simctlArguments(setToken: token, subcommand: subcommand)
    }

    @discardableResult
    public func xcrun(
        arguments: [String],
        timeout: Duration? = nil
    ) async throws -> CommandResult {
        let invocation = CommandInvocation(
            executable: "xcrun",
            arguments: arguments,
            timeout: timeout
        )
        let result = try await runner.run(invocation)
        try result.requireSuccess(context: "xcrun", invocation: invocation)
        return result
    }

    public func listDevices() async throws -> [Device] {
        var devices: [Device] = []
        for set in await registry.knownSets() {
            do {
                devices += try await listDevices(in: set)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if set.token.isEmpty {
                    throw error
                }
                // Secondary sets are optional and may not exist on a host.
            }
        }
        return devices
    }

    public func listDevices(in set: DeviceSet) async throws -> [Device] {
        let arguments = Self.simctlArguments(
            setToken: set.token,
            subcommand: ["list", "devices", "-j"]
        )
        let invocation = CommandInvocation(executable: "xcrun", arguments: arguments)
        let result = try await runner.run(invocation)
        try result.requireSuccess(context: "simctl list", invocation: invocation)

        let payload: SimctlDeviceList
        do {
            payload = try JSONDecoder().decode(
                SimctlDeviceList.self,
                from: Data(result.standardOutput.utf8)
            )
        } catch {
            throw SimCtlError.parseDeviceList("parse simctl list: \(error)")
        }

        var devices: [Device] = []
        for (runtime, runtimeDevices) in payload.devices where runtime.contains("iOS") {
            for device in runtimeDevices where device.isAvailable {
                devices.append(
                    Device(
                        udid: device.udid,
                        name: device.name,
                        state: device.state,
                        osVersion: Self.osVersion(runtime: runtime),
                        set: set.name,
                        dataPath: device.dataPath ?? ""
                    )
                )
            }
        }
        return devices
    }

    public func findDevice(udid: String, set: String? = nil) async throws -> Device {
        for knownSet in await registry.knownSets() {
            if let set, knownSet.name != set {
                continue
            }
            do {
                let devices = try await listDevices(in: knownSet)
                if let device = devices.first(where: { $0.udid == udid }) {
                    return device
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if knownSet.token.isEmpty {
                    throw error
                }
            }
        }
        throw SimCtlError.noSimulator(udid)
    }

    public func simulatorDataDirectory(
        udid: String
    ) async throws -> (device: Device, dataDirectory: String) {
        let device = try await findDevice(udid: udid)
        guard !device.dataPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SimCtlError.missingDataPath(udid)
        }
        return (device, device.dataPath)
    }

    public func shutdownIfBooted(
        udid: String
    ) async throws -> (set: String, wasBooted: Bool) {
        let device = try await findDevice(udid: udid)
        guard device.state == "Booted" else {
            return (device.set, false)
        }
        try await shutdown(set: device.set, udid: udid)
        try await waitShutdown(
            set: device.set,
            udid: udid,
            timeout: configuration.shutdownTimeout
        )
        return (device.set, true)
    }

    public func rename(udid: String, name: String) async throws {
        let device = try await findDevice(udid: udid)
        let normalized = try Self.normalizeSimulatorName(name)
        let arguments = await simctlArguments(
            set: device.set,
            subcommand: ["rename", udid, normalized]
        )
        _ = try await xcrun(arguments: arguments, timeout: configuration.shutdownTimeout)
    }

    public func erase(udid: String) async throws {
        let state = try await shutdownIfBooted(udid: udid)
        let arguments = await simctlArguments(
            set: state.set,
            subcommand: ["erase", udid]
        )
        _ = try await xcrun(arguments: arguments, timeout: configuration.bootTimeout)
    }

    public func delete(udid: String) async throws {
        let state = try await shutdownIfBooted(udid: udid)
        let arguments = await simctlArguments(
            set: state.set,
            subcommand: ["delete", udid]
        )
        _ = try await xcrun(arguments: arguments, timeout: configuration.bootTimeout)
    }

    public func bootAndWait(set: String, udid: String) async throws {
        let bootArguments = await simctlArguments(set: set, subcommand: ["boot", udid])
        let bootInvocation = CommandInvocation(
            executable: "xcrun",
            arguments: bootArguments,
            timeout: configuration.bootTimeout
        )
        let bootResult = try await runner.run(bootInvocation)
        if !bootResult.succeeded {
            let message = bootResult.diagnosticOutput
            if !message.contains("already booted") && !message.contains("current state: Booted") {
                throw CommandExecutionError(
                    context: "simctl boot",
                    invocation: bootInvocation,
                    result: bootResult
                )
            }
        }

        let statusArguments = await simctlArguments(
            set: set,
            subcommand: ["bootstatus", udid, "-b"]
        )
        _ = try await xcrun(arguments: statusArguments, timeout: configuration.bootTimeout)
    }

    public func shutdown(set: String, udid: String) async throws {
        let arguments = await simctlArguments(set: set, subcommand: ["shutdown", udid])
        let invocation = CommandInvocation(
            executable: "xcrun",
            arguments: arguments,
            timeout: configuration.shutdownTimeout
        )
        let result = try await runner.run(invocation)
        if !result.succeeded && !result.diagnosticOutput.contains("current state: Shutdown") {
            throw CommandExecutionError(
                context: "simctl shutdown",
                invocation: invocation,
                result: result
            )
        }
    }

    public func waitShutdown(
        set: String,
        udid: String,
        timeout: Duration
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            let device = try await findDevice(udid: udid, set: set)
            if device.state == "Shutdown" {
                return
            }
            try await Task.sleep(for: configuration.shutdownPollInterval)
        }
        throw SimCtlError.shutdownTimedOut(udid)
    }

    public func readDisabled(set: String, udid: String) async throws -> Set<String> {
        let arguments = await simctlArguments(
            set: set,
            subcommand: ["spawn", udid, "launchctl", "print-disabled", "system"]
        )
        let invocation = CommandInvocation(
            executable: "xcrun",
            arguments: arguments
        )
        let result = try await runner.run(invocation)
        try result.requireSuccess(
            context: "launchctl print-disabled",
            invocation: invocation
        )
        return Self.parseDisabled(result.standardOutput + "\n" + result.standardError)
    }

    public func applyDelta(
        set: String,
        udid: String,
        toDisable: [String],
        toEnable: [String],
        reporter: Reporter? = nil
    ) async throws {
        var pending = toDisable.map { Transition(action: "disable", label: $0) }
        pending += toEnable.map { Transition(action: "enable", label: $0) }
        let total = pending.count
        guard total > 0 else { return }
        var done = 0

        var remaining: [Transition] = []
        for action in ["disable", "enable"] {
            let labels = pending.filter { $0.action == action }.map(\.label)
            for chunk in labels.chunks(ofCount: configuration.batchSize) {
                try Task.checkCancellation()
                let confirmed = try await runBatch(
                    set: set,
                    udid: udid,
                    action: action,
                    labels: chunk
                )
                for label in chunk {
                    if confirmed.contains(label) {
                        done += 1
                    } else {
                        remaining.append(Transition(action: action, label: label))
                    }
                }
                if done > 0 {
                    reporter?("  \(done)/\(total) services updated")
                }
            }
        }
        pending = remaining

        var failureMessages: [String] = []
        if configuration.applyPasses >= 2 {
            for pass in 2...configuration.applyPasses where !pending.isEmpty {
                try Task.checkCancellation()
                reporter?(
                    "  retrying \(pending.count) failed services "
                        + "(pass \(pass)/\(configuration.applyPasses))..."
                )
                let outcomes = try await runTransitions(
                    pending,
                    set: set,
                    udid: udid
                )
                var failed: [Transition] = []
                failureMessages.removeAll(keepingCapacity: true)
                for outcome in outcomes {
                    if let message = outcome.failure {
                        failed.append(outcome.transition)
                        failureMessages.append(message)
                    } else {
                        done += 1
                        if done == total || done.isMultiple(of: 20) {
                            reporter?("  \(done)/\(total) services updated")
                        }
                    }
                }
                pending = failed
            }
        }

        if !pending.isEmpty {
            throw SimCtlError.launchctlTransitions(
                "\(pending.count)/\(total) launchctl transitions failed after "
                    + "\(configuration.applyPasses) passes: "
                    + failureMessages.joined(separator: "; ")
            )
        }
    }

    public static func osVersion(runtime: String) -> String {
        guard let range = runtime.range(of: "iOS-", options: .backwards) else {
            return "?"
        }
        return runtime[range.upperBound...].replacingOccurrences(of: "-", with: ".")
    }

    public static func normalizeSimulatorName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw SimCtlError.invalidSimulatorName("simulator name cannot be empty")
        }
        guard name.unicodeScalars.count <= 128 else {
            throw SimCtlError.invalidSimulatorName(
                "simulator name cannot exceed 128 characters"
            )
        }
        guard !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SimCtlError.invalidSimulatorName(
                "simulator name cannot contain control characters"
            )
        }
        return name
    }

    public static func parseClonedUDID(_ output: String) throws -> String {
        let udid = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = Array(udid.unicodeScalars)
        guard scalars.count == 36 else {
            throw SimCtlError.invalidClonedUDID(udid)
        }
        let hyphens = Set([8, 13, 18, 23])
        for (index, scalar) in scalars.enumerated() {
            if hyphens.contains(index) {
                guard scalar == "-" else {
                    throw SimCtlError.invalidClonedUDID(udid)
                }
            } else {
                guard CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains(scalar) else {
                    throw SimCtlError.invalidClonedUDID(udid)
                }
            }
        }
        return udid
    }

    public static func parseClonedUDID(
        standardOutput: String,
        standardError: String
    ) throws -> String {
        let output = [standardOutput, standardError].joined(separator: "\n")
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        let candidates = Set(
            output.unicodeScalars
                .split(whereSeparator: { !allowed.contains($0) })
                .compactMap { try? parseClonedUDID(String($0)) }
        )
        guard candidates.count == 1, let udid = candidates.first else {
            throw SimCtlError.invalidClonedUDID(
                output.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return udid
    }

    public static func parseDisabled(_ output: String) -> Set<String> {
        var disabled: Set<String> = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let openingQuote = line.firstIndex(of: "\"") else { continue }
            let afterOpening = line.index(after: openingQuote)
            guard let closingQuote = line[afterOpening...].firstIndex(of: "\"") else { continue }
            let label = String(line[afterOpening..<closingQuote])
            guard let arrow = line[closingQuote...].range(of: "=>") else { continue }
            let value = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("disabled") || value.hasPrefix("true") {
                disabled.insert(label)
            }
        }
        return disabled
    }

    public static func parseBatchOK(_ output: String) -> Set<String> {
        Set(
            output.split(separator: "\n").compactMap { line in
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let marker = "simslim-ok "
                guard value.hasPrefix(marker) else { return nil }
                let label = String(value.dropFirst(marker.count))
                return label.isEmpty ? nil : label
            }
        )
    }

    private func runBatch(
        set: String,
        udid: String,
        action: String,
        labels: [String]
    ) async throws -> Set<String> {
        let arguments = await simctlArguments(
            set: set,
            subcommand: [
                "spawn", udid, "/bin/sh", "-c", Self.batchScript,
                "simslim-batch", action, String(configuration.batchWave),
            ] + labels
        )
        let invocation = CommandInvocation(
            executable: "xcrun",
            arguments: arguments,
            timeout: configuration.spawnTimeout
        )
        do {
            let result = try await runner.run(invocation)
            return Self.parseBatchOK(result.standardOutput + "\n" + result.standardError)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return []
        }
    }

    private func runTransition(
        _ transition: Transition,
        set: String,
        udid: String
    ) async throws {
        let arguments = await simctlArguments(
            set: set,
            subcommand: [
                "spawn", udid, "launchctl", transition.action,
                "system/\(transition.label)",
            ]
        )
        let invocation = CommandInvocation(
            executable: "xcrun",
            arguments: arguments,
            timeout: configuration.spawnTimeout
        )
        let result = try await runner.run(invocation)
        try result.requireSuccess(
            context: "\(transition.action) \(transition.label)",
            invocation: invocation
        )
    }

    /// Runs retry transitions with a bounded task group. Ordering of the
    /// returned outcomes matches the input so diagnostics stay deterministic.
    private func runTransitions(
        _ transitions: [Transition],
        set: String,
        udid: String
    ) async throws -> [TransitionOutcome] {
        try await withThrowingTaskGroup(of: IndexedTransitionOutcome.self) { group in
            var nextIndex = 0
            let initialCount = min(configuration.batchWave, transitions.count)
            for _ in 0..<initialCount {
                addTransitionTask(
                    to: &group,
                    index: nextIndex,
                    transition: transitions[nextIndex],
                    set: set,
                    udid: udid
                )
                nextIndex += 1
            }

            var indexedOutcomes: [IndexedTransitionOutcome] = []
            indexedOutcomes.reserveCapacity(transitions.count)
            while let outcome = try await group.next() {
                indexedOutcomes.append(outcome)
                if nextIndex < transitions.count {
                    addTransitionTask(
                        to: &group,
                        index: nextIndex,
                        transition: transitions[nextIndex],
                        set: set,
                        udid: udid
                    )
                    nextIndex += 1
                }
            }
            return indexedOutcomes.sorted { $0.index < $1.index }.map(\.outcome)
        }
    }

    private func addTransitionTask(
        to group: inout ThrowingTaskGroup<IndexedTransitionOutcome, any Error>,
        index: Int,
        transition: Transition,
        set: String,
        udid: String
    ) {
        group.addTask {
            do {
                try await runTransition(transition, set: set, udid: udid)
                return IndexedTransitionOutcome(
                    index: index,
                    outcome: TransitionOutcome(transition: transition, failure: nil)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return IndexedTransitionOutcome(
                    index: index,
                    outcome: TransitionOutcome(
                        transition: transition,
                        failure: Self.describe(error)
                    )
                )
            }
        }
    }

    private static func describe(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    private static let batchScript = #"""
    [ -n "$SIMULATOR_ROOT" ] && export DYLD_ROOT_PATH="$SIMULATOR_ROOT"
    action=$1; wave=$2; shift 2
    n=0
    for l in "$@"; do
      { launchctl "$action" "system/$l" && echo "simslim-ok $l" || echo "simslim-fail $l"; } &
      n=$((n + 1))
      [ $((n % wave)) -eq 0 ] && wait
    done
    wait
    exit 0
    """#
}

private struct SimctlDeviceList: Decodable {
    let devices: [String: [SimctlListedDevice]]
}

private struct SimctlListedDevice: Decodable {
    let udid: String
    let name: String
    let state: String
    let isAvailable: Bool
    let dataPath: String?
}

private struct Transition: Sendable {
    let action: String
    let label: String
}

private struct TransitionOutcome: Sendable {
    let transition: Transition
    let failure: String?
}

private struct IndexedTransitionOutcome: Sendable {
    let index: Int
    let outcome: TransitionOutcome
}

private extension Array {
    func chunks(ofCount size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}
