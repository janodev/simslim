import Darwin
import Foundation
import Subprocess

/// Everything needed to launch one external command.
public struct CommandInvocation: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String?]
    public let workingDirectory: String?
    public let timeout: Duration?

    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String?] = [:],
        workingDirectory: String? = nil,
        timeout: Duration? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }

    public var rendered: String {
        ([executable] + arguments).map(Self.shellQuote).joined(separator: " ")
    }

    private static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-._/:".unicodeScalars.contains($0)
        }
        guard !safe else { return value }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

/// A platform-independent representation of how a command terminated.
public enum CommandTermination: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)

    public var isSuccess: Bool {
        self == .exited(0)
    }
}

/// Captured output and status for a process that was successfully launched.
public struct CommandResult: Equatable, Sendable {
    public let standardOutput: String
    public let standardError: String
    public let termination: CommandTermination

    public init(
        standardOutput: String = "",
        standardError: String = "",
        termination: CommandTermination = .exited(0)
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.termination = termination
    }

    public var succeeded: Bool {
        termination.isSuccess
    }

    /// Similar to Go's `CombinedOutput` for diagnostics. Ordering between the
    /// two streams is intentionally not promised by the command abstraction.
    public var diagnosticOutput: String {
        [standardOutput, standardError]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

public protocol CommandRunning: Sendable {
    func run(_ invocation: CommandInvocation) async throws -> CommandResult
}

public enum CommandRunnerError: Error, Equatable, LocalizedError, Sendable {
    case launchFailed(command: String, reason: String)
    case timedOut(command: String, timeout: Duration)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let command, let reason):
            "launch \(command): \(reason)"
        case .timedOut(let command, let timeout):
            "command timed out after \(timeout): \(command)"
        }
    }
}

public struct CommandExecutionError: Error, Equatable, LocalizedError, Sendable {
    public let context: String
    public let command: String
    public let termination: CommandTermination
    public let output: String

    public init(
        context: String,
        invocation: CommandInvocation,
        result: CommandResult
    ) {
        self.context = context
        command = invocation.rendered
        termination = result.termination
        output = result.diagnosticOutput
    }

    public var errorDescription: String? {
        let suffix = output.isEmpty ? "" : ": \(output)"
        return "\(context): \(command): \(termination)\(suffix)"
    }
}

extension CommandTermination: CustomStringConvertible {
    public var description: String {
        switch self {
        case .exited(let code):
            "exit status \(code)"
        case .signaled(let signal):
            "terminated by signal \(signal)"
        }
    }
}

extension CommandResult {
    public func requireSuccess(
        context: String,
        invocation: CommandInvocation
    ) throws {
        guard succeeded else {
            throw CommandExecutionError(context: context, invocation: invocation, result: self)
        }
    }
}

/// Production command runner backed by swiftlang/swift-subprocess.
///
/// Each command gets its own session. Cancellation therefore tears down the
/// command and descendants such as `xcrun` -> `simctl` -> a spawned shell,
/// without risking signals to SimSlim's own process group.
public struct SubprocessCommandRunner: CommandRunning {
    public static let defaultOutputLimit = 64 * 1_024 * 1_024

    private let outputLimit: Int

    public init(outputLimit: Int = Self.defaultOutputLimit) {
        self.outputLimit = outputLimit
    }

    public func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        guard let timeout = invocation.timeout else {
            return try await execute(invocation)
        }

        return try await withThrowingTaskGroup(of: CommandResult.self) { group in
            group.addTask {
                try await execute(invocation)
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    throw error
                }
                throw CommandRunnerError.timedOut(
                    command: invocation.rendered,
                    timeout: timeout
                )
            }

            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }

    private func execute(_ invocation: CommandInvocation) async throws -> CommandResult {
        var environment = Subprocess.Environment.inherit
        if !invocation.environment.isEmpty {
            var overrides: [Subprocess.Environment.Key: String?] = [:]
            for (key, value) in invocation.environment {
                guard let environmentKey = Subprocess.Environment.Key(rawValue: key) else {
                    throw CommandRunnerError.launchFailed(
                        command: invocation.rendered,
                        reason: "invalid environment variable name \(key)"
                    )
                }
                overrides[environmentKey] = value
            }
            environment = environment.updating(overrides)
        }

        var platformOptions = PlatformOptions()
        platformOptions.createSession = true
        platformOptions.teardownSequence = [
            // swift-subprocess 1.0 stops a graceful teardown as soon as the
            // group leader exits, which can leave a TERM-ignoring descendant
            // alive. Kill the isolated session atomically on cancellation.
            .send(
                signal: .kill,
                toProcessGroup: true,
                allowedDurationToNextStep: .zero
            ),
        ]

        do {
            let executable: Executable = if invocation.executable.contains("/") {
                .path(.init(invocation.executable))
            } else {
                .name(invocation.executable)
            }
            let result = try await Subprocess.run(
                executable,
                arguments: Arguments(invocation.arguments),
                environment: environment,
                workingDirectory: invocation.workingDirectory.map { .init($0) },
                platformOptions: platformOptions,
                output: .string(limit: outputLimit),
                error: .string(limit: outputLimit)
            )
            let termination: CommandTermination = switch result.terminationStatus {
            case .exited(let code):
                .exited(code)
            case .signaled(let signal):
                .signaled(signal)
            }
            return CommandResult(
                standardOutput: result.standardOutput,
                standardError: result.standardError,
                termination: termination
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CommandRunnerError {
            throw error
        } catch {
            throw CommandRunnerError.launchFailed(
                command: invocation.rendered,
                reason: String(describing: error)
            )
        }
    }
}
