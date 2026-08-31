import Foundation

public struct DiskSizeService: Sendable {
    public let simctl: SimCtl
    public let runner: any CommandRunning

    public init(
        simctl: SimCtl = SimCtl(),
        runner: (any CommandRunning)? = nil
    ) {
        self.simctl = simctl
        self.runner = runner ?? simctl.runner
    }

    /// Reports allocated blocks for one exact simulator device directory.
    public func deviceDiskUsage(udid: String) async throws -> DiskMeasurement {
        let location = try await simctl.simulatorDataDirectory(udid: udid)
        let devicePath = URL(fileURLWithPath: location.dataDirectory)
            .deletingLastPathComponent()
            .path
        let invocation = CommandInvocation(
            executable: "du",
            arguments: ["-sk", devicePath],
            timeout: simctl.configuration.bootTimeout
        )
        let result = try await runner.run(invocation)
        try result.requireSuccess(
            context: "measure simulator disk usage",
            invocation: invocation
        )
        return DiskMeasurement(
            bytes: try Self.parseDUDiskUsage(
                result.standardOutput + "\n" + result.standardError
            )
        )
    }

    public static func parseDUDiskUsage(_ output: String) throws -> Int64 {
        guard let field = output.split(whereSeparator: \.isWhitespace).first else {
            throw DiskSizeError.invalidOutput("du returned no disk usage")
        }
        guard let kibibytes = Int64(field), kibibytes >= 0 else {
            throw DiskSizeError.invalidOutput("parse du disk usage \"\(field)\"")
        }
        let (bytes, overflow) = kibibytes.multipliedReportingOverflow(by: 1_024)
        guard !overflow else {
            throw DiskSizeError.invalidOutput("parse du disk usage \"\(field)\"")
        }
        return bytes
    }
}

public enum DiskSizeError: Error, Equatable, LocalizedError, Sendable {
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .invalidOutput(let message):
            message
        }
    }
}
