import Darwin
import Foundation
import SimSlimCore
import Testing

enum MockCommandError: Error, Equatable, Sendable {
    case message(String)
    case exhausted
}

enum MockCommandResponse: Sendable {
    case result(CommandResult)
    case failure(MockCommandError)
}

actor MockCommandRunner: CommandRunning {
    typealias Handler = @Sendable (CommandInvocation) throws -> CommandResult

    private var responses: [MockCommandResponse]
    private let handler: Handler?
    private(set) var invocations: [CommandInvocation] = []

    init(responses: [MockCommandResponse]) {
        self.responses = responses
        handler = nil
    }

    init(handler: @escaping Handler) {
        responses = []
        self.handler = handler
    }

    func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        invocations.append(invocation)
        if let handler {
            return try handler(invocation)
        }
        guard !responses.isEmpty else { throw MockCommandError.exhausted }
        switch responses.removeFirst() {
        case .result(let result):
            return result
        case .failure(let error):
            throw error
        }
    }
}

@Test func subprocessRunnerCapturesOutputAndExitStatus() async throws {
    let runner = SubprocessCommandRunner()
    let result = try await runner.run(
        CommandInvocation(
            executable: "/bin/sh",
            arguments: ["-c", "printf stdout; printf stderr >&2; exit 7"]
        )
    )

    #expect(result.standardOutput == "stdout")
    #expect(result.standardError == "stderr")
    #expect(result.termination == .exited(7))
    #expect(!result.succeeded)
}

@Test func subprocessRunnerTimesOutAndCancelsProcessGroup() async throws {
    let runner = SubprocessCommandRunner()
    let invocation = CommandInvocation(
        executable: "/bin/sh",
        arguments: ["-c", "sleep 30"],
        timeout: .milliseconds(20)
    )

    do {
        _ = try await runner.run(invocation)
        Issue.record("expected timeout")
    } catch let error as CommandRunnerError {
        guard case .timedOut(let command, let timeout) = error else {
            Issue.record("unexpected command runner error: \(error)")
            return
        }
        #expect(command.contains("sleep 30"))
        #expect(timeout == .milliseconds(20))
    }
}

@Test func subprocessTimeoutKillsTermIgnoringDescendants() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "swift-simslim-process-group-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appending(path: "descendant.pid")
    let script = """
    trap 'exit 0' TERM
    perl -e '$SIG{TERM} = sub {}; sleep 30' &
    echo $! > "$1"
    wait
    """
    let runner = SubprocessCommandRunner()

    do {
        _ = try await runner.run(
            CommandInvocation(
                executable: "/bin/sh",
                arguments: ["-c", script, "simslim-test", pidFile.path],
                timeout: .milliseconds(200)
            )
        )
        Issue.record("expected timeout")
    } catch let error as CommandRunnerError {
        guard case .timedOut = error else {
            Issue.record("unexpected command runner error: \(error)")
            return
        }
    }

    let text = try String(contentsOf: pidFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let pid = try #require(Int32(text))
    for _ in 0 ..< 100 where processExists(pid) {
        try await Task.sleep(for: .milliseconds(10))
    }
    let survived = processExists(pid)
    if survived {
        Darwin.kill(pid, SIGKILL)
    }
    #expect(!survived)
}

private func processExists(_ pid: Int32) -> Bool {
    if Darwin.kill(pid, 0) == 0 {
        return true
    }
    return errno == EPERM
}

@Test func commandFailureKeepsContextAndBothStreams() {
    let invocation = CommandInvocation(executable: "tool", arguments: ["an argument"])
    let result = CommandResult(
        standardOutput: "out",
        standardError: "err",
        termination: .exited(2)
    )
    let error = CommandExecutionError(
        context: "perform operation",
        invocation: invocation,
        result: result
    )

    #expect(error.errorDescription?.contains("perform operation") == true)
    #expect(error.errorDescription?.contains("'an argument'") == true)
    #expect(error.errorDescription?.contains("out\nerr") == true)
}
