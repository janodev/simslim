import Foundation

/// A read-only durable-storage row. These values stay separate from cleanup
/// categories so bundles, documents, and user data can never become selected.
public struct DiskStorageMeasurement: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public var bytes: Int64

    public init(id: String, name: String, description: String, bytes: Int64 = 0) {
        self.id = id
        self.name = name
        self.description = description
        self.bytes = bytes
    }
}

let diskStorageCategories: [DiskStorageMeasurement] = [
    DiskStorageMeasurement(
        id: "installed-apps",
        name: "Installed Apps",
        description: "Developer-installed app and test-runner bundles. Built-in apps live in the shared runtime."
    ),
    DiskStorageMeasurement(
        id: "documents",
        name: "Documents",
        description: "Files in app and app-group Documents directories."
    ),
    DiskStorageMeasurement(
        id: "app-data",
        name: "App Data",
        description: "Preferences, databases, and support files outside Documents and cleanup categories."
    ),
    DiskStorageMeasurement(
        id: "user-media",
        name: "User Media",
        description: "Photos, videos, downloads, and other files in the simulator media library."
    ),
]

func diskStorageMeasurements(dataDirectory: String) throws -> [DiskStorageMeasurement] {
    try diskStorageCategories.map { category in
        var measurement = category
        do {
            switch category.id {
            case "installed-apps":
                measurement.bytes = try allocatedSizeOfExistingDirectories(
                    root: dataDirectory,
                    candidates: [path(dataDirectory, "Containers", "Bundle", "Application")]
                )
            case "documents":
                measurement.bytes = try allocatedSizeOfExistingDirectories(
                    root: dataDirectory,
                    candidates: appDocumentTargets(dataDirectory: dataDirectory)
                )
            case "app-data":
                measurement.bytes = try appDataSize(dataDirectory: dataDirectory)
            case "user-media":
                measurement.bytes = try allocatedSizeOfExistingDirectories(
                    root: dataDirectory,
                    candidates: [path(dataDirectory, "Media")]
                )
            default:
                throw filesystemError("unknown disk storage category \"\(category.id)\"")
            }
        } catch {
            throw filesystemError("measure \(category.name)", error)
        }
        return measurement
    }
}

func appDocumentTargets(dataDirectory: String) throws -> [String] {
    var candidates: [String] = []
    for root in [
        path(dataDirectory, "Containers", "Data", "Application"),
        path(dataDirectory, "Containers", "Shared", "AppGroup"),
    ] {
        guard try fileStatus(at: root) != nil else {
            continue
        }
        for name in try FileManager.default.contentsOfDirectory(atPath: root).sorted() {
            let child = path(root, name)
            let childStatus = try requiredFileStatus(at: child)
            if childStatus.isDirectory {
                candidates.append(path(child, "Documents"))
            }
        }
    }
    return try compactExistingTargets(root: dataDirectory, candidates: candidates)
}

func appDataSize(dataDirectory: String) throws -> Int64 {
    let excluded: Set<String> = ["Caches", "Documents", "Logs", "tmp"]
    var total: Int64 = 0
    for root in [
        path(dataDirectory, "Containers", "Data", "Application"),
        path(dataDirectory, "Containers", "Shared", "AppGroup"),
    ] {
        guard let rootStatus = try fileStatus(at: root) else {
            continue
        }
        guard rootStatus.isDirectory, !rootStatus.isSymbolicLink else {
            continue
        }
        try requireResolvedDescendant(root: dataDirectory, target: root)
        total += try allocatedSizeExcludingNames(root: root, excluded: excluded)
    }
    return total
}

func allocatedSizeOfExistingDirectories(root: String, candidates: [String]) throws -> Int64 {
    let targets = try compactExistingTargets(root: root, candidates: candidates)
    return try targets.reduce(into: Int64(0)) { total, target in
        total += try allocatedSize(at: target)
    }
}

func allocatedSizeExcludingNames(root: String, excluded: Set<String>) throws -> Int64 {
    var total: Int64 = 0
    try walkFilesystem(at: root) { current, status in
        if current != root,
           status.isDirectory,
           excluded.contains((current as NSString).lastPathComponent)
        {
            return .skipDescendants
        }
        total += Int64(status.blocks) * 512
        return .descend
    }
    return total
}
