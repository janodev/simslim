import Darwin
import Foundation

/// One tightly allowlisted class of per-device data. Shared runtime files are
/// deliberately outside this model and remain owned by Xcode/CoreSimulator.
public struct DiskCleanupCategory: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let downside: String
    public let recovery: String
    public let risk: String
    public let defaultSelected: Bool
    public let canClean: Bool

    public init(
        id: String,
        name: String,
        description: String,
        downside: String,
        recovery: String,
        risk: String,
        defaultSelected: Bool,
        canClean: Bool
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.downside = downside
        self.recovery = recovery
        self.risk = risk
        self.defaultSelected = defaultSelected
        self.canClean = canClean
    }
}

public let diskCleanupCategories: [DiskCleanupCategory] = [
    DiskCleanupCategory(
        id: "caches",
        name: "System & App Caches",
        description: "Generated cache files belonging to iOS and installed apps.",
        downside: "Next launches may be slower; downloaded or offline cache content can disappear.",
        recovery: "Old cache contents stay deleted; apps build new caches as needed.",
        risk: "Lower risk",
        defaultSelected: true,
        canClean: true
    ),
    DiskCleanupCategory(
        id: "logs",
        name: "Logs & Diagnostics",
        description: "Unified logs, signposts, symbol text, crash logs, and app log folders.",
        downside: "Existing diagnostic and crash history is deleted.",
        recovery: "Old history stays deleted; future runs create new logs.",
        risk: "Lower risk",
        defaultSelected: true,
        canClean: true
    ),
    DiskCleanupCategory(
        id: "temporary",
        name: "Temporary Files",
        description: "Files in simulator and app temporary directories.",
        downside: "Apps that misuse temporary storage may lose in-progress work.",
        recovery: "Old contents stay deleted; apps create new temporary files as needed.",
        risk: "Lower risk",
        defaultSelected: true,
        canClean: true
    ),
    DiskCleanupCategory(
        id: "linguistic-data",
        name: "Downloaded Language Data",
        description: "On-demand language models used by Siri, Search, and text analysis.",
        downside: "Language-aware features may be limited until iOS downloads the package again.",
        recovery: "iOS downloads the language package again when a feature needs it.",
        risk: "Restored on demand",
        defaultSelected: false,
        canClean: true
    ),
    DiskCleanupCategory(
        id: "required-siri-assets",
        name: "Required Siri Assets",
        description: "Siri understanding, speech, voice, and accessibility downloads restored by iOS.",
        downside: "Manual deletion is unsupported, and iOS promptly downloads required assets again.",
        recovery: "Required assets return automatically after boot.",
        risk: "System managed",
        defaultSelected: false,
        canClean: false
    ),
]

public struct DiskCleanupCategoryMeasurement: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let downside: String
    public let recovery: String
    public let risk: String
    public let defaultSelected: Bool
    public let canClean: Bool
    public var bytes: Int64
    public let targets: Int

    init(category: DiskCleanupCategory, bytes: Int64 = 0, targets: Int) {
        id = category.id
        name = category.name
        description = category.description
        downside = category.downside
        recovery = category.recovery
        risk = category.risk
        defaultSelected = category.defaultSelected
        canClean = category.canClean
        self.bytes = bytes
        self.targets = targets
    }
}

public struct DiskCleanupPlan: Codable, Equatable, Sendable {
    public let udid: String
    public var totalBytes: Int64
    public var cleanableBytes: Int64
    public var categories: [DiskCleanupCategoryMeasurement]
    public var storage: [DiskStorageMeasurement]

    init(
        udid: String,
        totalBytes: Int64 = 0,
        cleanableBytes: Int64 = 0,
        categories: [DiskCleanupCategoryMeasurement] = [],
        storage: [DiskStorageMeasurement] = []
    ) {
        self.udid = udid
        self.totalBytes = totalBytes
        self.cleanableBytes = cleanableBytes
        self.categories = categories
        self.storage = storage
    }
}

public struct DiskCleanupResult: Codable, Equatable, Sendable {
    public let udid: String
    public let categoryIds: [String]
    public let beforeBytes: Int64
    public let afterBytes: Int64
    public let reclaimedBytes: Int64
    public var wasBooted: Bool
    public var bootStateRestored: Bool

    init(
        udid: String,
        categoryIds: [String],
        beforeBytes: Int64,
        afterBytes: Int64,
        reclaimedBytes: Int64,
        wasBooted: Bool = false,
        bootStateRestored: Bool = false
    ) {
        self.udid = udid
        self.categoryIds = categoryIds
        self.beforeBytes = beforeBytes
        self.afterBytes = afterBytes
        self.reclaimedBytes = reclaimedBytes
        self.wasBooted = wasBooted
        self.bootStateRestored = bootStateRestored
    }
}

public struct DiskCleanupService: Sendable {
    public let simctl: SimCtl

    public init(simctl: SimCtl = SimCtl()) {
        self.simctl = simctl
    }

    public func plan(udid: String) async throws -> DiskCleanupPlan {
        let (_, dataDirectory) = try await validatedSimulatorDataDirectory(simctl: simctl, udid: udid)
        return try diskCleanupPlanAt(udid: udid, dataDirectory: dataDirectory)
    }

    public func clean(
        udid: String,
        categoryIDs: [String],
        preserveBootState: Bool
    ) async throws -> DiskCleanupResult {
        let (device, dataDirectory) = try await validatedSimulatorDataDirectory(simctl: simctl, udid: udid)
        guard device.state == "Booted" || device.state == "Shutdown" else {
            throw filesystemError(
                "simulator must be booted or shutdown before disk cleanup (it is \(device.state))"
            )
        }
        let categoryIDs = try validateDiskCleanupSelection(categoryIDs)
        let wasBooted = device.state == "Booted"
        // No process may be writing through a path while its contents are
        // removed. Preserve the original boot state only when requested.
        if wasBooted {
            _ = try await simctl.shutdownIfBooted(udid: udid)
        }

        var result: DiskCleanupResult
        var cleanupError: (any Error)?
        do {
            result = try cleanDiskAt(
                udid: udid,
                dataDirectory: dataDirectory,
                categoryIDs: categoryIDs
            )
        } catch {
            cleanupError = error
            result = DiskCleanupResult(
                udid: udid,
                categoryIds: categoryIDs,
                beforeBytes: 0,
                afterBytes: 0,
                reclaimedBytes: 0
            )
        }
        result.wasBooted = wasBooted

        if wasBooted, preserveBootState {
            do {
                try await simctl.bootAndWait(set: device.set, udid: udid)
                result.bootStateRestored = true
            } catch {
                if let cleanupError {
                    throw filesystemError(
                        "\(cleanupError.localizedDescription); additionally could not restore boot state",
                        error
                    )
                }
                throw filesystemError("disk cleanup finished, but could not restore boot state", error)
            }
        }
        if let cleanupError {
            throw cleanupError
        }
        return result
    }
}

func validatedSimulatorDataDirectory(
    simctl: SimCtl,
    udid: String
) async throws -> (device: Device, dataDirectory: String) {
    let resolved = try await simctl.simulatorDataDirectory(udid: udid)
    let status: FileStatus
    do {
        status = try requiredFileStatus(at: resolved.dataDirectory)
    } catch {
        throw filesystemError("locate simulator data", error)
    }
    guard status.isDirectory, !status.isSymbolicLink else {
        throw filesystemError(
            "simulator data path is not a real directory: \(resolved.dataDirectory)"
        )
    }
    return resolved
}

struct SimSlimFilesystemError: Error, LocalizedError, CustomStringConvertible {
    let message: String

    var description: String { message }
    var errorDescription: String? { message }
}

func filesystemError(_ message: String, _ underlying: (any Error)? = nil) -> SimSlimFilesystemError {
    guard let underlying else {
        return SimSlimFilesystemError(message: message)
    }
    return SimSlimFilesystemError(message: "\(message): \(underlying.localizedDescription)")
}

func diskCleanupCategory(id: String) -> DiskCleanupCategory? {
    diskCleanupCategories.first { $0.id == id }
}

func diskCleanupPlanAt(udid: String, dataDirectory: String) throws -> DiskCleanupPlan {
    var plan = DiskCleanupPlan(udid: udid)
    for category in diskCleanupCategories {
        let targets: [String]
        do {
            targets = try diskCleanupTargets(dataDirectory: dataDirectory, categoryID: category.id)
        } catch {
            throw filesystemError("scan \(category.name)", error)
        }

        var measurement = DiskCleanupCategoryMeasurement(category: category, targets: targets.count)
        for target in targets {
            do {
                measurement.bytes += try allocatedSize(at: target)
            } catch {
                throw filesystemError("measure \(target)", error)
            }
        }
        plan.totalBytes += measurement.bytes
        if category.canClean {
            plan.cleanableBytes += measurement.bytes
        }
        plan.categories.append(measurement)
    }
    plan.storage = try diskStorageMeasurements(dataDirectory: dataDirectory)
    return plan
}

func cleanDiskAt(udid: String, dataDirectory: String, categoryIDs: [String]) throws -> DiskCleanupResult {
    let categoryIDs = try validateDiskCleanupSelection(categoryIDs)
    let beforePlan = try diskCleanupPlanAt(udid: udid, dataDirectory: dataDirectory)
    let beforeBytes = selectedCleanupBytes(plan: beforePlan, ids: categoryIDs)

    for id in categoryIDs {
        for target in try diskCleanupTargets(dataDirectory: dataDirectory, categoryID: id) {
            do {
                try clearDirectoryContents(dataDirectory: dataDirectory, target: target)
            } catch {
                throw filesystemError("clean \(target)", error)
            }
        }
    }

    let afterPlan = try diskCleanupPlanAt(udid: udid, dataDirectory: dataDirectory)
    let afterBytes = selectedCleanupBytes(plan: afterPlan, ids: categoryIDs)
    return DiskCleanupResult(
        udid: udid,
        categoryIds: categoryIDs,
        beforeBytes: beforeBytes,
        afterBytes: afterBytes,
        reclaimedBytes: max(0, beforeBytes - afterBytes)
    )
}

public func validateDiskCleanupSelection(_ ids: [String]) throws -> [String] {
    var seen = Set<String>()
    var validated: [String] = []
    for rawID in ids {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !seen.contains(id) else {
            continue
        }
        guard let category = diskCleanupCategory(id: id) else {
            throw filesystemError("unknown disk cleanup category \"\(id)\"")
        }
        guard category.canClean else {
            throw filesystemError("disk cleanup category \"\(id)\" is measured only and cannot be cleaned")
        }
        seen.insert(id)
        validated.append(id)
    }
    guard !validated.isEmpty else {
        throw filesystemError("select at least one cleanable disk category")
    }
    return validated.sorted()
}

func selectedCleanupBytes(plan: DiskCleanupPlan, ids: [String]) -> Int64 {
    let selected = Set(ids)
    return plan.categories.reduce(into: 0) { total, category in
        if selected.contains(category.id) {
            total += category.bytes
        }
    }
}

func diskCleanupTargets(dataDirectory: String, categoryID: String) throws -> [String] {
    let candidates: [String]
    switch categoryID {
    case "caches":
        candidates = try findNamedDirectories(root: dataDirectory, name: "Caches")
    case "temporary":
        candidates = try findNamedDirectories(
            root: dataDirectory,
            name: "tmp",
            excludedAncestors: ["Caches"]
        )
    case "logs":
        candidates = [
            path(dataDirectory, "Library", "Logs"),
            path(dataDirectory, "var", "log"),
            path(dataDirectory, "var", "db", "diagnostics"),
            path(dataDirectory, "var", "db", "uuidtext"),
        ] + (try findNamedDirectories(
            root: dataDirectory,
            name: "Logs",
            excludedAncestors: ["Caches", "tmp"]
        ))
    case "linguistic-data":
        candidates = try linguisticDataTargets(dataDirectory: dataDirectory)
    case "required-siri-assets":
        candidates = try requiredSiriAssetTargets(dataDirectory: dataDirectory)
    default:
        throw filesystemError("unknown disk cleanup category \"\(categoryID)\"")
    }
    return try compactExistingTargets(root: dataDirectory, candidates: candidates)
}

func findNamedDirectories(
    root: String,
    name: String,
    excludedAncestors: Set<String> = []
) throws -> [String] {
    var targets: [String] = []

    func walk(_ directory: String, isRoot: Bool) throws {
        let status = try requiredFileStatus(at: directory)
        guard status.isDirectory, !status.isSymbolicLink else {
            return
        }
        if !isRoot {
            let component = (directory as NSString).lastPathComponent
            if isProtectedCleanupSubtree(component) || excludedAncestors.contains(component) {
                return
            }
            if component == name {
                targets.append(directory)
                return
            }
        }

        for childName in try FileManager.default.contentsOfDirectory(atPath: directory).sorted() {
            let child = path(directory, childName)
            let childStatus = try requiredFileStatus(at: child)
            if childStatus.isDirectory, !childStatus.isSymbolicLink {
                try walk(child, isRoot: false)
            }
        }
    }

    try walk(normalizedPath(root), isRoot: true)
    return targets
}

func isProtectedCleanupSubtree(_ name: String) -> Bool {
    // An app may legitimately put directories named Caches, Logs, or tmp
    // below durable content. The name alone never makes that content eligible.
    ["Documents", "Mobile Documents", "Media", "MobileAsset"].contains(name)
}

func linguisticDataTargets(dataDirectory: String) throws -> [String] {
    try compactExistingTargets(
        root: dataDirectory,
        candidates: [
            path(
                dataDirectory,
                "private",
                "var",
                "MobileAsset",
                "AssetsV2",
                "com_apple_MobileAsset_LinguisticData"
            ),
        ]
    )
}

func requiredSiriAssetTargets(dataDirectory: String) throws -> [String] {
    let assetsRoot = path(dataDirectory, "private", "var", "MobileAsset", "AssetsV2")
    guard try fileStatus(at: assetsRoot) != nil else {
        return []
    }
    let prefixes = [
        "com_apple_MobileAsset_UAF_Siri_",
        "com_apple_MobileAsset_TTS",
        "com_apple_MobileAsset_VoiceServices_",
        "com_apple_MobileAsset_VoiceTrigger",
    ]
    var targets: [String] = []
    for name in try FileManager.default.contentsOfDirectory(atPath: assetsRoot).sorted() {
        let target = path(assetsRoot, name)
        let targetStatus = try requiredFileStatus(at: target)
        if targetStatus.isDirectory, prefixes.contains(where: name.hasPrefix)
        {
            targets.append(target)
        }
    }
    return targets
}

func compactExistingTargets(root: String, candidates: [String]) throws -> [String] {
    var unique = Set<String>()
    var targets: [String] = []
    for rawCandidate in candidates {
        let candidate = normalizedPath(rawCandidate)
        try requireDescendant(root: root, target: candidate)
        guard let status = try fileStatus(at: candidate) else {
            continue
        }
        guard status.isDirectory, !status.isSymbolicLink, !unique.contains(candidate) else {
            continue
        }
        try requireResolvedDescendant(root: root, target: candidate)
        unique.insert(candidate)
        targets.append(candidate)
    }

    targets.sort {
        if $0.utf8.count != $1.utf8.count {
            return $0.utf8.count < $1.utf8.count
        }
        return $0 < $1
    }
    var compacted: [String] = []
    for target in targets where !compacted.contains(where: { isStrictDescendant(root: $0, target: target) }) {
        compacted.append(target)
    }
    return compacted
}

func requireDescendant(root: String, target: String) throws {
    guard isStrictDescendant(root: root, target: target) else {
        throw filesystemError("refusing cleanup path outside simulator data: \(normalizedPath(target))")
    }
}

func requireResolvedDescendant(root: String, target: String) throws {
    // Lexical containment cannot detect `data/var -> /outside`; resolve every
    // existing component before permitting a destructive operation.
    let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
    let resolvedTarget = URL(fileURLWithPath: target).resolvingSymlinksInPath().standardizedFileURL.path
    do {
        try requireDescendant(root: resolvedRoot, target: resolvedTarget)
    } catch {
        throw filesystemError("refusing symlinked cleanup path \(target)", error)
    }
}

func allocatedSize(at root: String) throws -> Int64 {
    var total: Int64 = 0
    try walkFilesystem(at: root) { _, status in
        total += Int64(status.blocks) * 512
        return .descend
    }
    return total
}

func clearDirectoryContents(dataDirectory: String, target: String) throws {
    try requireDescendant(root: dataDirectory, target: target)
    guard let status = try fileStatus(at: target) else {
        return
    }
    guard status.isDirectory, !status.isSymbolicLink else {
        throw filesystemError("refusing to clear non-directory target \(target)")
    }
    try requireResolvedDescendant(root: dataDirectory, target: target)
    // removeItem unlinks a child symlink itself rather than following it. The
    // target directory is retained so system and app container invariants hold.
    for name in try FileManager.default.contentsOfDirectory(atPath: target).sorted() {
        let child = path(target, name)
        try requireDescendant(root: dataDirectory, target: child)
        try FileManager.default.removeItem(atPath: child)
    }
}

struct FileStatus {
    let value: Darwin.stat

    var blocks: blkcnt_t { value.st_blocks }
    var device: dev_t { value.st_dev }
    var inode: ino_t { value.st_ino }
    var linkCount: nlink_t { value.st_nlink }
    var permissions: mode_t { value.st_mode & 0o777 }
    var isDirectory: Bool { value.st_mode & S_IFMT == S_IFDIR }
    var isRegularFile: Bool { value.st_mode & S_IFMT == S_IFREG }
    var isSymbolicLink: Bool { value.st_mode & S_IFMT == S_IFLNK }
}

func fileStatus(at path: String) throws -> FileStatus? {
    var value = Darwin.stat()
    let result = path.withCString { Darwin.lstat($0, &value) }
    if result == 0 {
        return FileStatus(value: value)
    }
    if errno == ENOENT {
        return nil
    }
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

func requiredFileStatus(at path: String) throws -> FileStatus {
    guard let status = try fileStatus(at: path) else {
        throw POSIXError(.ENOENT)
    }
    return status
}

enum FilesystemWalkAction {
    case descend
    case skipDescendants
}

func walkFilesystem(
    at root: String,
    _ visit: (String, FileStatus) throws -> FilesystemWalkAction
) throws {
    let status = try requiredFileStatus(at: root)
    let action = try visit(root, status)
    guard action == .descend, status.isDirectory, !status.isSymbolicLink else {
        return
    }
    for name in try FileManager.default.contentsOfDirectory(atPath: root).sorted() {
        try walkFilesystem(at: path(root, name), visit)
    }
}

func isStrictDescendant(root: String, target: String) -> Bool {
    let rootComponents = URL(fileURLWithPath: normalizedPath(root)).pathComponents
    let targetComponents = URL(fileURLWithPath: normalizedPath(target)).pathComponents
    guard targetComponents.count > rootComponents.count else {
        return false
    }
    return targetComponents.starts(with: rootComponents)
}

func normalizedPath(_ path: String) -> String {
    (path as NSString).standardizingPath
}

func path(_ components: String...) -> String {
    components.reduce("") { partial, component in
        if partial.isEmpty {
            return component
        }
        return (partial as NSString).appendingPathComponent(component)
    }
}
