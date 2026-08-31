import Foundation

public struct Measurement: Codable, Equatable, Sendable {
    public let processes: Int
    public let bytes: Int64
    public let cpu: Double

    public init(processes: Int, bytes: Int64, cpu: Double) {
        self.processes = processes
        self.bytes = bytes
        self.cpu = cpu
    }
}

public struct Process: Codable, Equatable, Sendable {
    public let pid: Int
    public let command: String
    public let bytes: Int64
    public let cpu: Double

    public init(pid: Int, command: String, bytes: Int64, cpu: Double) {
        self.pid = pid
        self.command = command
        self.bytes = bytes
        self.cpu = cpu
    }
}

public enum MeasurementError: Error, Equatable, LocalizedError, Sendable {
    case simulatorNotBooted(String)
    case invalidLaunchdPID(String)

    public var errorDescription: String? {
        switch self {
        case .simulatorNotBooted(let udid):
            "simulator \(udid) does not appear to be booted"
        case .invalidLaunchdPID(let value):
            "invalid simulator launchd pid \"\(value)\""
        }
    }
}

public struct MeasurementService: Sendable {
    public let runner: any CommandRunning

    public init(runner: any CommandRunning = SubprocessCommandRunner()) {
        self.runner = runner
    }

    public func measure(udid: String) async throws -> Measurement {
        let root = try await simulatorLaunchdPID(udid: udid)
        let snapshot = try await processSnapshot()
        let footprint = try await footprintByPID()
        return Self.measureTree(root: root, snapshot: snapshot, footprint: footprint)
    }

    public func measureProcesses(udid: String) async throws -> [Process] {
        let root = try await simulatorLaunchdPID(udid: udid)
        let snapshot = try await processSnapshot()
        let footprint = try await footprintByPID()

        return Self.treePIDs(root: root, children: snapshot.children)
            .map { pid in
                Process(
                    pid: pid,
                    command: snapshot.commands[pid, default: ""],
                    bytes: footprint[pid, default: 0],
                    cpu: snapshot.cpu[pid, default: 0]
                )
            }
            .sorted {
                if $0.bytes != $1.bytes {
                    return $0.bytes > $1.bytes
                }
                return $0.pid < $1.pid
            }
    }

    /// Takes one shared `ps` and `top` snapshot for all booted simulators.
    public func measureMany(
        udids: [String]
    ) async throws -> (measurements: [String: Measurement], errors: [String: String]) {
        var measurements: [String: Measurement] = [:]
        var errors: [String: String] = [:]
        var roots: [String: Int] = [:]

        for udid in udids {
            try Task.checkCancellation()
            do {
                roots[udid] = try await simulatorLaunchdPID(udid: udid)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                errors[udid] = Self.describe(error)
            }
        }
        guard !roots.isEmpty else { return (measurements, errors) }

        let snapshot: ProcessSnapshot
        do {
            snapshot = try await processSnapshot()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            for udid in roots.keys {
                errors[udid] = Self.describe(error)
            }
            return (measurements, errors)
        }

        let footprint: [Int: Int64]
        do {
            footprint = try await footprintByPID()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            for udid in roots.keys {
                errors[udid] = Self.describe(error)
            }
            return (measurements, errors)
        }

        for (udid, root) in roots {
            measurements[udid] = Self.measureTree(
                root: root,
                snapshot: snapshot,
                footprint: footprint
            )
        }
        return (measurements, errors)
    }

    public func simulatorLaunchdPID(udid: String) async throws -> Int {
        let invocation = CommandInvocation(
            executable: "pgrep",
            arguments: ["-f", "\(udid)/data/var/run/launchd_bootstrap"]
        )
        let result: CommandResult
        do {
            result = try await runner.run(invocation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MeasurementError.simulatorNotBooted(udid)
        }
        guard result.succeeded else {
            throw MeasurementError.simulatorNotBooted(udid)
        }
        guard let value = result.standardOutput.split(whereSeparator: \.isWhitespace).first else {
            throw MeasurementError.simulatorNotBooted(udid)
        }
        guard let pid = Int(value) else {
            throw MeasurementError.invalidLaunchdPID(String(value))
        }
        return pid
    }

    public func processSnapshot() async throws -> ProcessSnapshot {
        let invocation = CommandInvocation(
            executable: "ps",
            arguments: ["-axo", "pid,ppid,%cpu,comm"]
        )
        let result = try await runner.run(invocation)
        try result.requireSuccess(context: "ps process snapshot", invocation: invocation)
        return Self.parsePS(result.standardOutput)
    }

    public func footprintByPID() async throws -> [Int: Int64] {
        let invocation = CommandInvocation(
            executable: "top",
            arguments: ["-l", "1", "-stats", "pid,mem"]
        )
        let result = try await runner.run(invocation)
        try result.requireSuccess(context: "top memory snapshot", invocation: invocation)

        var footprint: [Int: Int64] = [:]
        for line in result.standardOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, let pid = Int(fields[0]) else { continue }
            let memory = String(fields[1])
            guard Self.looksLikeTopMemory(memory) else { continue }
            footprint[pid] = Self.parseBytes(memory)
        }
        return footprint
    }

    public static func treePIDs(root: Int, children: [Int: [Int]]) -> Set<Int> {
        var seen: Set<Int> = []
        var stack = [root]
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted else { continue }
            stack.append(contentsOf: children[pid, default: []])
        }
        return seen
    }

    public static func measureTree(
        root: Int,
        snapshot: ProcessSnapshot,
        footprint: [Int: Int64]
    ) -> Measurement {
        var processes = 0
        var bytes: Int64 = 0
        var cpu = 0.0
        for pid in treePIDs(root: root, children: snapshot.children) {
            processes += 1
            bytes += footprint[pid, default: 0]
            cpu += snapshot.cpu[pid, default: 0]
        }
        return Measurement(processes: processes, bytes: bytes, cpu: cpu)
    }

    public static func parsePS(_ output: String) -> ProcessSnapshot {
        var children: [Int: [Int]] = [:]
        var cpu: [Int: Double] = [:]
        var commands: [Int: String] = [:]

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 4,
                  let pid = Int(fields[0]),
                  let parentPID = Int(fields[1]) else {
                continue
            }
            children[parentPID, default: []].append(pid)
            if let value = Double(fields[2]) {
                cpu[pid] = value
            }
            commands[pid] = commandName(
                fields.dropFirst(3).map(String.init).joined(separator: " ")
            )
        }
        return ProcessSnapshot(children: children, cpu: cpu, commands: commands)
    }

    public static func commandName(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
    }

    public static func parseBytes(_ input: String) -> Int64 {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("+") {
            value.removeLast()
        }
        guard !value.isEmpty else { return 0 }

        var multiplier = 1.0
        switch value.last {
        case "K":
            multiplier = 1_024
            value.removeLast()
        case "M":
            multiplier = 1_024 * 1_024
            value.removeLast()
        case "G":
            multiplier = 1_024 * 1_024 * 1_024
            value.removeLast()
        case "B":
            value.removeLast()
        default:
            break
        }
        guard let number = Double(value), number.isFinite else { return 0 }
        return Int64(number * multiplier)
    }

    private static func looksLikeTopMemory(_ value: String) -> Bool {
        var candidate = value
        if candidate.last == "+" {
            candidate.removeLast()
        }
        if let suffix = candidate.last, "KMGB".contains(suffix) {
            candidate.removeLast()
        }
        return !candidate.isEmpty
            && candidate.allSatisfy { $0.isNumber || $0 == "." }
    }

    private static func describe(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

public struct ProcessSnapshot: Equatable, Sendable {
    public let children: [Int: [Int]]
    public let cpu: [Int: Double]
    public let commands: [Int: String]

    public init(
        children: [Int: [Int]],
        cpu: [Int: Double],
        commands: [Int: String]
    ) {
        self.children = children
        self.cpu = cpu
        self.commands = commands
    }
}
