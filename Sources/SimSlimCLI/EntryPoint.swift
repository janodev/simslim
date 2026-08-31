import ArgumentParser
import Darwin
import Dispatch
import Foundation

@main
enum SimSlimEntryPoint {
    static func main() async {
        let rawArguments = Array(CommandLine.arguments.dropFirst())
        if rawArguments.isEmpty {
            FileHandle.standardOutput.write(Data(SimSlimCommand.helpMessage().utf8))
            Darwin.exit(2)
        }
        if let first = rawArguments.first, ["-v", "--version", "version"].contains(first) {
            print("simslim dev")
            return
        }
        let arguments = normalizedGlobalArguments(rawArguments)
        let interruptEvents = makeInterruptEvents()
        let completion = await runUntilInterrupted(signals: interruptEvents.signals) {
            await executeCommand(arguments: arguments)
        }
        interruptEvents.source.cancel()
        switch completion {
        case .completed(nil):
            return
        case .completed(let error?):
            SimSlimCommand.exit(withError: error)
        case .interrupted(let cleanupError):
            if let cleanupError, !(cleanupError is CancellationError) {
                writeStandardError("simslim: \(cleanupError.localizedDescription)\n")
            }
            Darwin.exit(128 + SIGINT)
        }
    }
}

struct SimSlimCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "simslim",
        abstract: "Reduce iOS Simulator background-service overhead.",
        discussion: """
        SimSlim writes persistent launchctl overrides inside one simulator and
        never modifies the host or the shared iOS runtime.
        """,
        subcommands: [
            ListCommand.self,
            ProfilesCommand.self,
            ProfileCommand.self,
            StatusCommand.self,
            VerifyCommand.self,
            DoctorCommand.self,
            MeasureCommand.self,
            TopCommand.self,
            SizeCommand.self,
            DiskCategoriesCommand.self,
            DiskPlanCommand.self,
            DiskCleanCommand.self,
            CloneCommand.self,
            RepairCloneCommand.self,
            RenameCommand.self,
            BootCommand.self,
            ShutdownCommand.self,
            EraseCommand.self,
            DeleteCommand.self,
            OnCommand.self,
            OffCommand.self,
            VersionCommand.self,
        ]
    )

    @OptionGroup var globals: GlobalOptions

    mutating func run() async throws {
        _ = try globals.resolve()
        FileHandle.standardOutput.write(Data(Self.helpMessage().utf8))
        throw ExitCode(2)
    }
}

struct VersionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Print the version."
    )

    @ParentCommand var parent: SimSlimCommand

    func run() throws {
        _ = try parent.globals.resolve()
        print("simslim dev")
    }
}

enum CommandCompletion: Sendable {
    case completed((any Error)?)
    case interrupted((any Error)?)
}

struct InterruptEvents {
    let signals: AsyncStream<Void>
    let source: any DispatchSourceSignal
}

func makeInterruptEvents() -> InterruptEvents {
    signal(SIGINT, SIG_IGN)
    let (signals, continuation) = AsyncStream<Void>.makeStream()
    let source = DispatchSource.makeSignalSource(signal: SIGINT)
    source.setEventHandler(
        handler: DispatchWorkItem { @Sendable in
            continuation.yield(())
        }
    )
    source.setCancelHandler(
        handler: DispatchWorkItem { @Sendable in
            continuation.finish()
        }
    )
    source.resume()
    return InterruptEvents(signals: signals, source: source)
}

func executeCommand(arguments: [String]) async -> (any Error)? {
    do {
        var command = try await SimSlimCommand.asyncParseAsRoot(arguments)
        if var asyncCommand = command as? AsyncParsableCommand {
            try await asyncCommand.run()
        } else {
            try command.run()
        }
        return nil
    } catch {
        return error
    }
}

func runUntilInterrupted(
    signals: AsyncStream<Void>,
    operation: @escaping @Sendable () async -> (any Error)?
) async -> CommandCompletion {
    await withTaskGroup(of: CommandCompletion.self) { group in
        group.addTask {
            .completed(await operation())
        }
        group.addTask {
            var iterator = signals.makeAsyncIterator()
            _ = await iterator.next()
            return .interrupted(nil)
        }
        guard let first = await group.next() else {
            return .completed(CancellationError())
        }
        group.cancelAll()
        switch first {
        case .completed:
            await group.waitForAll()
            return first
        case .interrupted:
            var operationError: (any Error)?
            while let completion = await group.next() {
                if case .completed(let error) = completion {
                    operationError = error
                }
            }
            return .interrupted(operationError)
        }
    }
}
