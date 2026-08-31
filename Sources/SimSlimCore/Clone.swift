import Darwin
import Foundation

public enum CloneServiceError: Error, Equatable, LocalizedError, Sendable {
    case operationTimedOut(Duration)

    public var errorDescription: String? {
        switch self {
        case .operationTimedOut(let timeout):
            "clone operation timed out after \(timeout)"
        }
    }
}

private enum CloneOperationEvent<Value: Sendable>: Sendable {
    case deadline
    case operation(Result<Value, any Error>)
    case timerCancelled
}

struct CloneFilesystem: Equatable, Sendable {
    let sourceUDID: String
    let cloneUDID: String
    let sourceDeviceDirectory: String
    let cloneDeviceDirectory: String
    let sourceDataDirectory: String
    let cloneDataDirectory: String
    let sourceLogDirectory: String
    let cloneLogDirectory: String
}

public struct CloneService: Sendable {
    public let simctl: SimCtl
    public let slimming: SlimmingService

    public init(simctl: SimCtl = SimCtl(), slimming: SlimmingService? = nil) {
        self.simctl = simctl
        self.slimming = slimming ?? SlimmingService(simctl: simctl)
    }

    public var operationTimeout: Duration {
        simctl.configuration.bootTimeout * 3 + simctl.configuration.shutdownTimeout * 2
    }

    public func clone(udid: String, name: String) async throws -> String {
        try await withOperationTimeout {
            try await cloneWithinBudget(udid: udid, name: name)
        }
    }

    private func cloneWithinBudget(udid: String, name: String) async throws -> String {
        let name = try SimCtl.normalizeSimulatorName(name)
        let (source, sourceDataDirectory) = try await validatedSimulatorDataDirectory(
            simctl: simctl,
            udid: udid
        )
        guard source.state == "Booted" || source.state == "Shutdown" else {
            throw filesystemError(
                "simulator must be booted or shutdown before cloning (it is \(source.state))"
            )
        }
        let sourceWasBooted = source.state == "Booted"
        var createdUDID: String?
        var cloneIsSafe = false
        var operationResult: Result<String, any Error>

        do {
            try await simctl.bootAndWait(set: source.set, udid: udid)
            let disabled = try await simctl.readDisabled(set: source.set, udid: udid)
            let desired = desiredCloneDisabled(disabled)
            try await simctl.shutdown(set: source.set, udid: udid)
            try await simctl.waitShutdown(
                set: source.set,
                udid: udid,
                timeout: simctl.configuration.shutdownTimeout
            )
            let knownUDIDs = Set(
                try await simctl.listDevices()
                    .filter { $0.set == source.set }
                    .map(\.udid)
            )
            let temporaryName = "SimSlim clone \(UUID().uuidString)"

            let arguments = await simctl.simctlArguments(
                set: source.set,
                subcommand: ["clone", udid, temporaryName]
            )
            let cloneResult: CommandResult
            do {
                cloneResult = try await simctl.xcrun(
                    arguments: arguments,
                    timeout: operationTimeout
                )
            } catch let cloneError {
                let discovery = await discoverClonedDevices(
                    knownUDIDs: knownUDIDs,
                    source: source,
                    temporaryName: temporaryName
                )
                switch discovery {
                case .success(let candidates) where candidates.count == 1:
                    createdUDID = candidates[0].udid
                    throw cloneError
                case .success(let candidates):
                    let identifiers = candidates.map(\.udid).sorted().joined(separator: ", ")
                    let detail = identifiers.isEmpty ? "none" : identifiers
                    throw filesystemError(
                        "simctl clone failed after using temporary name \"\(temporaryName)\"; matching new devices: \(detail); inspect the \(source.set) device set manually",
                        cloneError
                    )
                case .failure(let discoveryError):
                    throw filesystemError(
                        "simctl clone failed after using temporary name \"\(temporaryName)\"; additionally could not inspect the device set: \(discoveryError.localizedDescription)",
                        cloneError
                    )
                }
            }
            let discovery = await discoverClonedDevices(
                knownUDIDs: knownUDIDs,
                source: source,
                temporaryName: temporaryName
            )
            let candidates: [Device]
            switch discovery {
            case .success(let discoveredDevices):
                candidates = discoveredDevices
            case .failure(let error):
                throw filesystemError(
                    "simctl clone succeeded as \"\(temporaryName)\", but its new simulator could not be validated",
                    error
                )
            }
            let newUDID = try clonedUDID(
                from: cloneResult,
                candidates: candidates,
                temporaryName: temporaryName
            )
            createdUDID = newUDID
            try await simctl.rename(udid: newUDID, name: name)

            do {
                let paths = try await cloneFilesystemFor(
                    simctl: simctl,
                    source: source,
                    sourceDataDirectory: sourceDataDirectory,
                    cloneUDID: newUDID
                )
                try sanitizeClonedDeviceAt(paths)
                _ = try await slimming.ensure(set: source.set, udid: newUDID, desired: desired)
                try await verifyRunningCloneDoesNotOpenSource(runner: simctl.runner, paths: paths)
                try await simctl.shutdown(set: source.set, udid: newUDID)
                try await simctl.waitShutdown(
                    set: source.set,
                    udid: newUDID,
                    timeout: simctl.configuration.shutdownTimeout
                )
                try verifyCloneIndependence(paths)
                cloneIsSafe = true
                operationResult = .success(newUDID)
            } catch {
                operationResult = .failure(error)
            }
        } catch {
            operationResult = .failure(error)
        }

        // A created clone is not publishable until static path checks, service
        // state restoration, a live open-file audit, and a final offline check
        // all succeed. Delete any partially prepared clone on every failure.
        if let createdUDID, !cloneIsSafe {
            let cleanupResult = await runDetached(timeout: simctl.configuration.bootTimeout) {
                try await deleteUnsafeClone(simctl: simctl, set: source.set, udid: createdUDID)
            }
            switch cleanupResult {
            case .success:
                operationResult = .failure(
                    filesystemError(
                        "prepare cloned simulator \(createdUDID): \(operationResult.errorDescription); deleted the unsafe clone"
                    )
                )
            case .failure(let cleanupError):
                operationResult = .failure(
                    filesystemError(
                        "prepare cloned simulator \(createdUDID): \(operationResult.errorDescription); additionally could not delete the unsafe clone",
                        cleanupError
                    )
                )
            }
        }

        let restoreResult = await runDetached(timeout: simctl.configuration.bootTimeout) {
            try await restoreCloneSourceState(
                simctl: simctl,
                set: source.set,
                udid: udid,
                shouldBeBooted: sourceWasBooted
            )
        }
        switch (operationResult, restoreResult) {
        case (.success(let newUDID), .success):
            return newUDID
        case (.success(let newUDID), .failure(let restoreError)):
            throw filesystemError(
                "cloned simulator \(newUDID), but could not restore the source boot state",
                restoreError
            )
        case (.failure(let operationError), .success):
            throw operationError
        case (.failure(let operationError), .failure(let restoreError)):
            throw filesystemError(
                "\(operationError.localizedDescription); additionally could not restore the source boot state",
                restoreError
            )
        }
    }

    private func discoverClonedDevices(
        knownUDIDs: Set<String>,
        source: Device,
        temporaryName: String
    ) async -> Result<[Device], any Error> {
        await runDetached(timeout: simctl.configuration.bootTimeout) {
            var candidates: [Device] = []
            for attempt in 0 ..< 20 {
                let devices = try await simctl.listDevices()
                candidates = devices.filter {
                    $0.set == source.set
                        && $0.osVersion == source.osVersion
                        && $0.name == temporaryName
                        && !knownUDIDs.contains($0.udid)
                }
                if !candidates.isEmpty || attempt == 19 {
                    return candidates
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            return candidates
        }
    }

    private func clonedUDID(
        from result: CommandResult,
        candidates: [Device],
        temporaryName: String
    ) throws -> String {
        let parsedResult: Result<String, any Error>
        do {
            parsedResult = .success(
                try SimCtl.parseClonedUDID(
                    standardOutput: result.standardOutput,
                    standardError: result.standardError
                )
            )
        } catch {
            parsedResult = .failure(error)
        }

        if case .success(let parsedUDID) = parsedResult,
           candidates.contains(where: { $0.udid == parsedUDID })
        {
            return parsedUDID
        }
        if candidates.count == 1, let candidate = candidates.first {
            return candidate.udid
        }

        let identifiers = candidates.map(\.udid).sorted().joined(separator: ", ")
        let detail = identifiers.isEmpty ? "none" : identifiers
        let identificationError: any Error
        switch parsedResult {
        case .success(let parsedUDID):
            identificationError = SimCtlError.invalidClonedUDID(parsedUDID)
        case .failure(let error):
            identificationError = error
        }
        throw filesystemError(
            "simctl clone succeeded as \"\(temporaryName)\", but its new simulator could not be identified safely; matching new devices: \(detail); inspect the device set manually",
            identificationError
        )
    }

    public func repair(sourceUDID: String, cloneUDID: String) async throws {
        try await withOperationTimeout {
            try await repairWithinBudget(sourceUDID: sourceUDID, cloneUDID: cloneUDID)
        }
    }

    private func repairWithinBudget(sourceUDID: String, cloneUDID: String) async throws {
        guard sourceUDID != cloneUDID else {
            throw filesystemError("clone source and destination UDIDs must be distinct")
        }
        let (source, sourceDataDirectory) = try await validatedSimulatorDataDirectory(
            simctl: simctl,
            udid: sourceUDID
        )
        let (clone, _) = try await validatedSimulatorDataDirectory(simctl: simctl, udid: cloneUDID)
        guard source.set == clone.set else {
            throw filesystemError("source and clone must belong to the same simulator set")
        }
        guard source.osVersion == clone.osVersion else {
            throw filesystemError(
                "source and clone runtimes differ (iOS \(source.osVersion) and iOS \(clone.osVersion))"
            )
        }
        for device in [source, clone] where device.state != "Booted" && device.state != "Shutdown" {
            throw filesystemError(
                "simulator \(device.udid) must be booted or shutdown before repair (it is \(device.state))"
            )
        }
        let paths = try await cloneFilesystemFor(
            simctl: simctl,
            source: source,
            sourceDataDirectory: sourceDataDirectory,
            cloneUDID: cloneUDID
        )
        let sourceWasBooted = source.state == "Booted"
        let cloneWasBooted = clone.state == "Booted"
        var repairIsSafe = false
        var operationError: (any Error)?

        do {
            try await restoreCloneSourceState(
                simctl: simctl,
                set: clone.set,
                udid: cloneUDID,
                shouldBeBooted: false
            )
            try await restoreCloneSourceState(
                simctl: simctl,
                set: source.set,
                udid: sourceUDID,
                shouldBeBooted: false
            )
            try sanitizeClonedDeviceAt(paths)
            try await simctl.bootAndWait(set: clone.set, udid: cloneUDID)
            let disabled = try await simctl.readDisabled(set: clone.set, udid: cloneUDID)
            let desired = desiredCloneDisabled(disabled)
            _ = try await slimming.ensure(set: clone.set, udid: cloneUDID, desired: desired)
            try await verifyRunningCloneDoesNotOpenSource(runner: simctl.runner, paths: paths)
            try await restoreCloneSourceState(
                simctl: simctl,
                set: clone.set,
                udid: cloneUDID,
                shouldBeBooted: false
            )
            try verifyCloneIndependence(paths)
            if cloneWasBooted {
                try await simctl.bootAndWait(set: clone.set, udid: cloneUDID)
                try await verifyRunningCloneDoesNotOpenSource(
                    runner: simctl.runner,
                    paths: paths
                )
            }
            repairIsSafe = true
        } catch {
            operationError = error
        }

        // An unsuccessful legacy-clone repair may have modified generated
        // stores. Its safe terminal state is shutdown, never a restarted clone
        // that could continue writing through a source-bound path.
        if !repairIsSafe {
            let shutdownResult = await runDetached(timeout: simctl.configuration.bootTimeout) {
                try await restoreCloneSourceState(
                    simctl: simctl,
                    set: clone.set,
                    udid: cloneUDID,
                    shouldBeBooted: false
                )
            }
            if case .failure(let shutdownError) = shutdownResult {
                if let currentError = operationError {
                    operationError = filesystemError(
                        "\(currentError.localizedDescription); additionally could not leave the clone safely shutdown",
                        shutdownError
                    )
                } else {
                    operationError = filesystemError(
                        "could not leave the clone safely shutdown",
                        shutdownError
                    )
                }
            }
        }

        let sourceRestoreResult = await runDetached(timeout: simctl.configuration.bootTimeout) {
            try await restoreCloneSourceState(
                simctl: simctl,
                set: source.set,
                udid: sourceUDID,
                shouldBeBooted: sourceWasBooted
            )
        }
        if case .failure(let restoreError) = sourceRestoreResult {
            if let currentError = operationError {
                operationError = filesystemError(
                    "\(currentError.localizedDescription); additionally could not restore the source boot state",
                    restoreError
                )
            } else {
                operationError = filesystemError(
                    "clone repaired, but could not restore the source boot state",
                    restoreError
                )
            }
        }
        if let operationError {
            throw operationError
        }
    }

    private func withOperationTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeout = operationTimeout
        return try await withThrowingTaskGroup(of: CloneOperationEvent<T>.self) { group in
            group.addTask {
                do {
                    return .operation(.success(try await operation()))
                } catch {
                    return .operation(.failure(error))
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .deadline
                } catch {
                    return .timerCancelled
                }
            }

            guard let first = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            switch first {
            case .operation(let result):
                try await group.waitForAll()
                return try result.get()

            case .deadline:
                var operationResult: Result<T, any Error>?
                while let event = try await group.next() {
                    if case .operation(let result) = event {
                        operationResult = result
                    }
                }
                guard let operationResult else {
                    throw CloneServiceError.operationTimedOut(timeout)
                }
                switch operationResult {
                case .success(let value):
                    return value
                case .failure(is CancellationError):
                    throw CloneServiceError.operationTimedOut(timeout)
                case .failure(let error):
                    throw filesystemError(
                        "clone operation timed out after \(timeout); cancellation handling reported",
                        error
                    )
                }

            case .timerCancelled:
                while let event = try await group.next() {
                    if case .operation(let result) = event {
                        return try result.get()
                    }
                }
                throw CancellationError()
            }
        }
    }
}

extension Result where Success == String, Failure == any Error {
    var errorDescription: String {
        switch self {
        case .success(let value):
            return value
        case .failure(let error):
            return error.localizedDescription
        }
    }
}

func desiredCloneDisabled(_ disabled: Set<String>) -> Set<String> {
    // Never propagate unrelated or obsolete launchd overrides from a source.
    disabled.intersection(slimmableSet())
}

func cloneFilesystemFor(
    simctl: SimCtl,
    source: Device,
    sourceDataDirectory: String,
    cloneUDID: String
) async throws -> CloneFilesystem {
    let (clone, cloneDataDirectory) = try await validatedSimulatorDataDirectory(
        simctl: simctl,
        udid: cloneUDID
    )
    guard clone.set == source.set else {
        throw filesystemError(
            "CoreSimulator placed clone \(cloneUDID) in \(clone.set) instead of source set \(source.set)"
        )
    }
    let logsRoot = path(FileManager.default.homeDirectoryForCurrentUser.path, "Library", "Logs", "CoreSimulator")
    return CloneFilesystem(
        sourceUDID: source.udid,
        cloneUDID: cloneUDID,
        sourceDeviceDirectory: (sourceDataDirectory as NSString).deletingLastPathComponent,
        cloneDeviceDirectory: (cloneDataDirectory as NSString).deletingLastPathComponent,
        sourceDataDirectory: sourceDataDirectory,
        cloneDataDirectory: cloneDataDirectory,
        sourceLogDirectory: path(logsRoot, source.udid),
        cloneLogDirectory: path(logsRoot, cloneUDID)
    )
}

func restoreCloneSourceState(
    simctl: SimCtl,
    set: String,
    udid: String,
    shouldBeBooted: Bool
) async throws {
    let device = try await simctl.findDevice(udid: udid, set: set)
    if shouldBeBooted {
        if device.state != "Booted" {
            try await simctl.bootAndWait(set: set, udid: udid)
        }
        return
    }
    if device.state != "Shutdown" {
        try await simctl.shutdown(set: set, udid: udid)
        try await simctl.waitShutdown(
            set: set,
            udid: udid,
            timeout: simctl.configuration.shutdownTimeout
        )
    }
}

func deleteUnsafeClone(simctl: SimCtl, set: String, udid: String) async throws {
    var stopError: (any Error)?
    do {
        try await simctl.shutdown(set: set, udid: udid)
        try await simctl.waitShutdown(
            set: set,
            udid: udid,
            timeout: simctl.configuration.shutdownTimeout
        )
    } catch {
        stopError = error
    }
    let arguments = await simctl.simctlArguments(set: set, subcommand: ["delete", udid])
    do {
        _ = try await simctl.xcrun(arguments: arguments, timeout: simctl.configuration.bootTimeout)
    } catch {
        if let stopError {
            throw filesystemError("stop clone: \(stopError.localizedDescription); delete clone", error)
        }
        throw error
    }
}

func runDetached<T: Sendable>(
    timeout: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async -> Result<T, any Error> {
    await Task.detached {
        do {
            let value = try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask(operation: operation)
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw filesystemError("detached cleanup operation timed out after \(timeout)")
                }
                guard let first = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return first
            }
            return .success(value)
        } catch {
            return .failure(error)
        }
    }.value
}

func desiredCloneDisabled(_ disabled: [String: Bool]) -> Set<String> {
    let slimmable = slimmableSet()
    return Set(disabled.compactMap { label, isDisabled in
        isDisabled && slimmable.contains(label) ? label : nil
    })
}

func sanitizeClonedDeviceAt(_ paths: CloneFilesystem) throws {
    try validateCloneFilesystem(paths)

    // These stores are regenerated from installed apps and current simulator
    // paths. App bundles, app data, settings, and app-owned caches are retained.
    try resetClonedLaunchServicesAt(dataDirectory: paths.cloneDataDirectory)
    try resetClonedFrontBoardAt(dataDirectory: paths.cloneDataDirectory)
    try resetClonedGeneratedPathStateAt(dataDirectory: paths.cloneDataDirectory)
    for directory in [
        path(paths.cloneDataDirectory, "Library", "Caches"),
        path(paths.cloneDataDirectory, "tmp"),
    ] {
        do {
            try clearDirectoryContents(dataDirectory: paths.cloneDataDirectory, target: directory)
        } catch {
            throw filesystemError("reset cloned transient state", error)
        }
    }
    try rebaseClonePropertyLists(paths)
    try rebaseCloneSymlinks(paths)
    try verifyCloneIndependence(paths)
}

func rebaseClonePropertyLists(_ paths: CloneFilesystem) throws {
    // UUIDs have equal byte lengths, so replacement preserves XML and binary
    // plist structure while redirecting simulator-local URLs into the clone.
    guard paths.sourceUDID.utf8.count == paths.cloneUDID.utf8.count else {
        throw filesystemError("source and clone UDIDs must have equal lengths")
    }
    let source = Data(paths.sourceUDID.utf8)
    let clone = Data(paths.cloneUDID.utf8)
    try walkFilesystem(at: paths.cloneDeviceDirectory) { filePath, status in
        guard status.isRegularFile,
              (filePath as NSString).pathExtension.caseInsensitiveCompare("plist") == .orderedSame
        else {
            return .descend
        }

        var contents: Data
        do {
            contents = try Data(contentsOf: URL(fileURLWithPath: filePath))
        } catch {
            throw filesystemError("read cloned property list \(filePath)", error)
        }
        guard contents.range(of: source) != nil else {
            return .descend
        }
        contents = replacingAll(in: contents, source: source, replacement: clone)
        do {
            try replaceRegularFile(at: filePath, contents: contents, permissions: status.permissions)
        } catch {
            throw filesystemError("rebase cloned property list \(filePath)", error)
        }
        return .descend
    }
}

func replacingAll(in input: Data, source: Data, replacement: Data) -> Data {
    guard !source.isEmpty else {
        return input
    }
    var result = input
    var searchStart = result.startIndex
    while searchStart < result.endIndex,
          let match = result.range(of: source, in: searchStart ..< result.endIndex)
    {
        result.replaceSubrange(match, with: replacement)
        searchStart = match.lowerBound + replacement.count
    }
    return result
}

func replaceRegularFile(at filePath: String, contents: Data, permissions: mode_t) throws {
    let directory = (filePath as NSString).deletingLastPathComponent
    let temporaryPath = path(directory, ".simslim-rebase-\(UUID().uuidString)")
    let descriptor = temporaryPath.withCString {
        Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, permissions)
    }
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    var needsClose = true
    defer {
        if needsClose {
            _ = Darwin.close(descriptor)
        }
        _ = temporaryPath.withCString(Darwin.unlink)
    }
    guard Darwin.fchmod(descriptor, permissions) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try contents.withUnsafeBytes { rawBuffer in
        guard var address = rawBuffer.baseAddress else {
            return
        }
        var remaining = rawBuffer.count
        while remaining > 0 {
            let written = Darwin.write(descriptor, address, remaining)
            guard written >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            remaining -= written
            address = address.advanced(by: written)
        }
    }
    guard Darwin.fsync(descriptor) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    guard Darwin.close(descriptor) == 0 else {
        needsClose = false
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    needsClose = false
    guard temporaryPath.withCString({ temporary in
        filePath.withCString { destination in
            Darwin.rename(temporary, destination)
        }
    }) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

func validateCloneFilesystem(_ paths: CloneFilesystem) throws {
    guard !paths.sourceUDID.isEmpty,
          !paths.cloneUDID.isEmpty,
          paths.sourceUDID != paths.cloneUDID
    else {
        throw filesystemError("clone source and destination UDIDs must be distinct")
    }

    for (label, directory) in [
        ("source device", paths.sourceDeviceDirectory),
        ("clone device", paths.cloneDeviceDirectory),
        ("source data", paths.sourceDataDirectory),
        ("clone data", paths.cloneDataDirectory),
    ] {
        let status: FileStatus
        do {
            status = try requiredFileStatus(at: directory)
        } catch {
            throw filesystemError("locate \(label) directory", error)
        }
        guard status.isDirectory, !status.isSymbolicLink else {
            throw filesystemError("\(label) path is not a real directory: \(directory)")
        }
    }

    for (deviceDirectory, dataDirectory) in [
        (paths.sourceDeviceDirectory, paths.sourceDataDirectory),
        (paths.cloneDeviceDirectory, paths.cloneDataDirectory),
    ] {
        try requireDescendant(root: deviceDirectory, target: dataDirectory)
        try requireResolvedDescendant(root: deviceDirectory, target: dataDirectory)
    }
}

func resetClonedLaunchServicesAt(dataDirectory: String) throws {
    let directory = path(dataDirectory, "var", "db", "lsd")
    try requireDescendant(root: dataDirectory, target: directory)
    guard let directoryStatus = try fileStatus(at: directory) else {
        return
    }
    guard directoryStatus.isDirectory, !directoryStatus.isSymbolicLink else {
        throw filesystemError("cloned LaunchServices path is not a real directory: \(directory)")
    }
    try requireResolvedDescendant(root: dataDirectory, target: directory)

    let names: [String]
    do {
        names = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
    } catch {
        throw filesystemError("read cloned LaunchServices data", error)
    }
    for name in names where name.hasPrefix("com.apple.LaunchServices-") && name.contains(".csstore") {
        let target = path(directory, name)
        try requireDescendant(root: directory, target: target)
        let status: FileStatus
        do {
            status = try requiredFileStatus(at: target)
        } catch {
            throw filesystemError("inspect cloned LaunchServices store", error)
        }
        guard status.isRegularFile, !status.isSymbolicLink else {
            throw filesystemError("cloned LaunchServices store is not a regular file: \(target)")
        }
        do {
            try FileManager.default.removeItem(atPath: target)
        } catch {
            throw filesystemError("reset cloned LaunchServices store", error)
        }
    }
}

func resetClonedFrontBoardAt(dataDirectory: String) throws {
    let directory = path(dataDirectory, "Library", "FrontBoard")
    try requireDescendant(root: dataDirectory, target: directory)
    guard let directoryStatus = try fileStatus(at: directory) else {
        return
    }
    guard directoryStatus.isDirectory, !directoryStatus.isSymbolicLink else {
        throw filesystemError("cloned FrontBoard path is not a real directory: \(directory)")
    }
    try requireResolvedDescendant(root: dataDirectory, target: directory)

    for name in ["applicationState.db", "applicationState.db-shm", "applicationState.db-wal"] {
        let target = path(directory, name)
        guard let status = try fileStatus(at: target) else {
            continue
        }
        guard status.isRegularFile, !status.isSymbolicLink else {
            throw filesystemError("cloned FrontBoard store is not a regular file: \(target)")
        }
        do {
            try FileManager.default.removeItem(atPath: target)
        } catch {
            throw filesystemError("reset cloned FrontBoard store", error)
        }
    }
}

func resetClonedGeneratedPathStateAt(dataDirectory: String) throws {
    // Only generated indexes, task databases, and registries known to contain
    // absolute simulator paths belong here. Downloaded asset payloads do not.
    var directories = [
        path(dataDirectory, "Library", "AppleMediaServices", "Engagement", "internal", "database"),
        path(dataDirectory, "Library", "Spotlight"),
        path(dataDirectory, "Library", "chronod", "replicator"),
        path(dataDirectory, "Library", "com.apple.nsurlsessiond"),
        path(dataDirectory, "private", "var", "MobileAsset", "AssetsV2", "locks"),
        path(dataDirectory, "private", "var", "MobileAsset", "AssetsV2", "persisted"),
        path(dataDirectory, "private", "var", "db", "assetsubscriptiond", "history"),
        path(dataDirectory, "var", "db", "diagnostics", "Persist"),
        path(dataDirectory, "var", "db", "diagnostics", "Special"),
    ]
    let appGroups = path(dataDirectory, "Containers", "Shared", "AppGroup")
    if let names = try? FileManager.default.contentsOfDirectory(atPath: appGroups).sorted() {
        directories.append(contentsOf: names.map { path(appGroups, $0, "replicatord") })
    }

    for directory in directories {
        do {
            try clearDirectoryContents(dataDirectory: dataDirectory, target: directory)
        } catch {
            throw filesystemError("reset cloned generated path state \(directory)", error)
        }
    }
}

func rebaseCloneSymlinks(_ paths: CloneFilesystem) throws {
    try walkFilesystem(at: paths.cloneDeviceDirectory) { linkPath, status in
        guard status.isSymbolicLink else {
            return .descend
        }
        let target: String
        do {
            target = try FileManager.default.destinationOfSymbolicLink(atPath: linkPath)
        } catch {
            throw filesystemError("read cloned symlink \(linkPath)", error)
        }

        let unresolvedTarget = (target as NSString).isAbsolutePath
            ? target
            : path((linkPath as NSString).deletingLastPathComponent, target)
        let resolution = try resolveFilesystemAliases(unresolvedTarget)
        let mappedTarget = try rebaseAliasResolution(resolution, paths: paths)
        guard let mappedTarget else {
            return .skipDescendants
        }

        let newTarget = (target as NSString).isAbsolutePath
            ? mappedTarget
            : relativePath(
                from: (linkPath as NSString).deletingLastPathComponent,
                to: mappedTarget
            )
        do {
            try replaceSymlink(at: linkPath, target: newTarget)
        } catch {
            throw filesystemError("rebase cloned symlink \(linkPath)", error)
        }
        return .skipDescendants
    }
}

struct FilesystemAliasResolution: Equatable {
    let finalPath: String
    let traversedPaths: [String]
}

func resolveFilesystemAliases(_ candidate: String) throws -> FilesystemAliasResolution {
    var components = (candidate as NSString).pathComponents
    guard components.first == "/" else {
        throw filesystemError("symbolic-link target is not absolute: \(candidate)")
    }
    components.removeFirst()
    var remaining = components
    var resolved = "/"
    var expandedStates = Set<String>()
    var followedLinks = 0
    var traversedPaths: [String] = []

    while !remaining.isEmpty {
        let component = remaining.removeFirst()
        if component == "." || component.isEmpty {
            continue
        }
        if component == ".." {
            resolved = (resolved as NSString).deletingLastPathComponent
            if resolved.isEmpty {
                resolved = "/"
            }
            traversedPaths.append(resolved)
            continue
        }
        let next = path(resolved, component)
        traversedPaths.append(next)
        guard let status = try fileStatus(at: next) else {
            var unresolved = next
            for pending in remaining {
                if pending == "." || pending.isEmpty {
                    continue
                }
                if pending == ".." {
                    unresolved = (unresolved as NSString).deletingLastPathComponent
                } else {
                    unresolved = path(unresolved, pending)
                }
            }
            let finalPath = unresolved.isEmpty ? "/" : unresolved
            if traversedPaths.last != finalPath {
                traversedPaths.append(finalPath)
            }
            return FilesystemAliasResolution(
                finalPath: finalPath,
                traversedPaths: traversedPaths
            )
        }
        guard status.isSymbolicLink else {
            resolved = next
            continue
        }

        followedLinks += 1
        guard followedLinks <= 64 else {
            throw filesystemError("cyclic symbolic-link chain while resolving \(candidate)")
        }
        let target: String
        do {
            target = try FileManager.default.destinationOfSymbolicLink(atPath: next)
        } catch {
            throw filesystemError("resolve symbolic-link chain at \(next)", error)
        }
        var targetComponents = (target as NSString).pathComponents
        if targetComponents.first == "/" {
            targetComponents.removeFirst()
            resolved = "/"
        }
        remaining = targetComponents + remaining
        let state = resolved + "\u{0}" + remaining.joined(separator: "/")
        guard expandedStates.insert(state).inserted else {
            throw filesystemError(
                "cyclic symbolic-link chain while resolving \(candidate)"
            )
        }
    }
    return FilesystemAliasResolution(finalPath: resolved, traversedPaths: traversedPaths)
}

func rebaseAliasResolution(
    _ resolution: FilesystemAliasResolution,
    paths: CloneFilesystem
) throws -> String? {
    if let mapped = try rebaseResolvedPath(
        resolution.finalPath,
        sourceRoot: paths.sourceDeviceDirectory,
        cloneRoot: paths.cloneDeviceDirectory
    ) ?? rebaseResolvedPath(
        resolution.finalPath,
        sourceRoot: paths.sourceLogDirectory,
        cloneRoot: paths.cloneLogDirectory
    ) {
        return mapped
    }

    for traversedPath in resolution.traversedPaths {
        if try rebaseResolvedPath(
            traversedPath,
            sourceRoot: paths.sourceDeviceDirectory,
            cloneRoot: paths.cloneDeviceDirectory
        ) != nil || rebaseResolvedPath(
            traversedPath,
            sourceRoot: paths.sourceLogDirectory,
            cloneRoot: paths.cloneLogDirectory
        ) != nil {
            // The final destination is shared or external, but reaching it
            // currently depends on walking through the source. Link directly
            // to that destination so deleting the source cannot break it.
            return resolution.finalPath
        }
    }
    return nil
}

func rebaseResolvedPath(
    _ candidate: String,
    sourceRoot: String,
    cloneRoot: String
) throws -> String? {
    let resolvedSourceRoot = try resolveFilesystemAliases(sourceRoot).finalPath
    if let mapped = rebasePath(
        candidate,
        sourceRoot: resolvedSourceRoot,
        cloneRoot: cloneRoot
    ) {
        return mapped
    }
    guard let sourceStatus = try fileStatus(at: sourceRoot) else {
        return nil
    }

    var current = normalizedPath(candidate)
    var suffix: [String] = []
    while current != "/" {
        if let status = try fileStatus(at: current),
           status.device == sourceStatus.device,
           status.inode == sourceStatus.inode
        {
            return suffix.reduce(normalizedPath(cloneRoot)) { path($0, $1) }
        }
        suffix.insert((current as NSString).lastPathComponent, at: 0)
        let parent = (current as NSString).deletingLastPathComponent
        guard parent != current else {
            break
        }
        current = parent
    }
    return nil
}

func rebasePath(_ candidate: String, sourceRoot: String, cloneRoot: String) -> String? {
    let candidate = normalizedPath(candidate)
    let sourceRoot = normalizedPath(sourceRoot)
    if candidate == sourceRoot {
        return normalizedPath(cloneRoot)
    }
    guard isStrictDescendant(root: sourceRoot, target: candidate) else {
        return nil
    }
    let relative = relativePath(from: sourceRoot, to: candidate)
    return path(cloneRoot, relative)
}

func replaceSymlink(at linkPath: String, target: String) throws {
    let temporaryPath = path(
        (linkPath as NSString).deletingLastPathComponent,
        ".simslim-relink-\(UUID().uuidString)"
    )
    do {
        try FileManager.default.createSymbolicLink(atPath: temporaryPath, withDestinationPath: target)
        guard temporaryPath.withCString({ temporary in
            linkPath.withCString { destination in
                Darwin.rename(temporary, destination)
            }
        }) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    } catch {
        _ = temporaryPath.withCString(Darwin.unlink)
        throw error
    }
}

private struct CloneFileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t
}

func verifyCloneIndependence(_ paths: CloneFilesystem) throws {
    var sourceHardLinkIdentities = Set<CloneFileIdentity>()
    try walkFilesystem(at: paths.sourceDeviceDirectory) { _, sourceStatus in
        if sourceStatus.isRegularFile, sourceStatus.linkCount > 1 {
            sourceHardLinkIdentities.insert(
                CloneFileIdentity(device: sourceStatus.device, inode: sourceStatus.inode)
            )
        }
        return .descend
    }

    try walkFilesystem(at: paths.cloneDeviceDirectory) { clonePath, cloneStatus in
        if cloneStatus.isSymbolicLink {
            let target: String
            do {
                target = try FileManager.default.destinationOfSymbolicLink(atPath: clonePath)
            } catch {
                throw filesystemError("read cloned symlink \(clonePath)", error)
            }
            let unresolvedTarget = (target as NSString).isAbsolutePath
                ? target
                : path((clonePath as NSString).deletingLastPathComponent, target)
            let resolution = try resolveFilesystemAliases(unresolvedTarget)
            let pointsIntoSource = try rebaseAliasResolution(resolution, paths: paths) != nil
                || pathContainsComponent(
                resolution.finalPath,
                component: paths.sourceUDID
            ) || pathContainsComponent(target, component: paths.sourceUDID)
            if pointsIntoSource {
                throw filesystemError(
                    "cloned symlink \(clonePath) still resolves into the source simulator: \(target)"
                )
            }
            return .skipDescendants
        }
        guard cloneStatus.isRegularFile else {
            return .descend
        }
        let identity = CloneFileIdentity(device: cloneStatus.device, inode: cloneStatus.inode)
        if sourceHardLinkIdentities.contains(identity) {
            throw filesystemError("cloned file \(clonePath) is hard-linked to the source simulator")
        }
        return .descend
    }
}

struct SourceReference: Equatable, Sendable {
    let pid: Int32
    let path: String
}

let cloneOpenFileAuditAttempts = 3
let cloneOpenFileAuditDelay: Duration = .milliseconds(100)

func verifyRunningCloneDoesNotOpenSource(
    runner: any CommandRunning,
    paths: CloneFilesystem
) async throws {
    // Static checks cannot see an absolute path persisted in an opaque store.
    // Audit live clone processes after boot and retry only process-churn cases.
    var lastError: (any Error)?
    for attempt in 0 ..< cloneOpenFileAuditAttempts {
        let audit = try await auditRunningCloneOpenFilesOnce(runner: runner, paths: paths)
        if audit.complete {
            if let error = audit.error {
                throw error
            }
            return
        }
        lastError = audit.error
        if attempt + 1 < cloneOpenFileAuditAttempts {
            do {
                try await Task.sleep(for: cloneOpenFileAuditDelay)
            } catch {
                throw filesystemError("audit cloned simulator open files", error)
            }
        }
    }
    throw lastError ?? filesystemError("audit cloned simulator open files did not complete")
}

func auditRunningCloneOpenFilesOnce(
    runner: any CommandRunning,
    paths: CloneFilesystem
) async throws -> (complete: Bool, error: (any Error)?) {
    let psInvocation = CommandInvocation(
        executable: "/bin/ps",
        arguments: ["eww", "-axo", "pid=,command="]
    )
    let psResult = try await runner.run(psInvocation)
    guard psResult.succeeded else {
        throw CommandExecutionError(context: "enumerate cloned simulator processes", invocation: psInvocation, result: psResult)
    }
    let pids = simulatorProcessIDsFromPS(psResult.standardOutput, udid: paths.cloneUDID)
    guard !pids.isEmpty else {
        return (
            false,
            filesystemError("could not identify any running processes for cloned simulator \(paths.cloneUDID)")
        )
    }

    let lsofInvocation = CommandInvocation(
        executable: "/usr/sbin/lsof",
        arguments: ["-n", "-P", "-Fpn", "-p", pids.map(String.init).joined(separator: ",")]
    )
    let lsofResult: CommandResult
    do {
        lsofResult = try await runner.run(lsofInvocation)
    } catch {
        return evaluateCloneLsofAudit(output: "", commandError: error, paths: paths)
    }
    let output = [lsofResult.standardOutput, lsofResult.standardError]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    let commandError: (any Error)? = lsofResult.succeeded
        ? nil
        : CommandExecutionError(context: "run lsof", invocation: lsofInvocation, result: lsofResult)
    return evaluateCloneLsofAudit(output: output, commandError: commandError, paths: paths)
}

func evaluateCloneLsofAudit(
    output: String,
    commandError: (any Error)?,
    paths: CloneFilesystem
) -> (complete: Bool, error: (any Error)?) {
    let parsed = parseCloneLsofOutput(output, paths: paths)
    if let reference = parsed.references.first {
        return (
            true,
            filesystemError(
                "clone process \(reference.pid) still has a source simulator path open: \(reference.path)"
            )
        )
    }
    if parsed.hasRecords {
        return (true, nil)
    }
    if let commandError {
        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            false,
            filesystemError(
                message.isEmpty
                    ? "audit cloned simulator open files"
                    : "audit cloned simulator open files: \(message)",
                commandError
            )
        )
    }
    return (false, filesystemError("audit cloned simulator open files returned no process or path records"))
}

func simulatorProcessIDsFromPS(_ output: String, udid: String) -> [Int32] {
    let marker = "SIMULATOR_UDID=\(udid)"
    var seen = Set<Int32>()
    var pids: [Int32] = []
    for line in output.split(separator: "\n", omittingEmptySubsequences: false) where line.contains(marker) {
        guard let first = line.split(whereSeparator: \Character.isWhitespace).first,
              let pid = Int32(first),
              pid > 0,
              seen.insert(pid).inserted
        else {
            continue
        }
        pids.append(pid)
    }
    return pids.sorted()
}

func sourceReferencesFromLsof(_ output: String, paths: CloneFilesystem) -> [SourceReference] {
    parseCloneLsofOutput(output, paths: paths).references
}

func parseCloneLsofOutput(
    _ output: String,
    paths: CloneFilesystem
) -> (references: [SourceReference], hasRecords: Bool) {
    var currentPID: Int32 = 0
    var references: [SourceReference] = []
    var hasRecords = false
    for lineSlice in output.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(lineSlice)
        guard line.count >= 2, let field = line.first else {
            continue
        }
        let value = String(line.dropFirst())
        switch field {
        case "p":
            if let pid = Int32(value), pid > 0 {
                currentPID = pid
            } else {
                currentPID = 0
            }
        case "n":
            guard currentPID > 0 else {
                continue
            }
            hasRecords = true
            if rebasePath(
                value,
                sourceRoot: paths.sourceDeviceDirectory,
                cloneRoot: paths.cloneDeviceDirectory
            ) != nil || rebasePath(
                value,
                sourceRoot: paths.sourceLogDirectory,
                cloneRoot: paths.cloneLogDirectory
            ) != nil {
                references.append(SourceReference(pid: currentPID, path: value))
            }
        default:
            continue
        }
    }
    return (references, hasRecords)
}

func pathContainsComponent(_ candidate: String, component: String) -> Bool {
    guard !component.isEmpty else {
        return false
    }
    return URL(fileURLWithPath: normalizedPath(candidate)).pathComponents.contains(component)
}

func relativePath(from base: String, to target: String) -> String {
    let baseComponents = URL(fileURLWithPath: normalizedPath(base)).pathComponents
    let targetComponents = URL(fileURLWithPath: normalizedPath(target)).pathComponents
    var common = 0
    while common < baseComponents.count,
          common < targetComponents.count,
          baseComponents[common] == targetComponents[common]
    {
        common += 1
    }
    let parents = Array(repeating: "..", count: baseComponents.count - common)
    let descendants = Array(targetComponents.dropFirst(common))
    let components = parents + descendants
    return components.isEmpty ? "." : components.joined(separator: "/")
}
