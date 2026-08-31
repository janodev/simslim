import Foundation
@testable import SimSlimCore
import Testing

@Test func diskStorageMeasurementsSeparateDurableDataFromCleanup() throws {
    let root = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }

    let dataDirectory = testPath(root, "data")
    let installedApp = testPath(
        dataDirectory,
        "Containers",
        "Bundle",
        "Application",
        "APP-CONTAINER",
        "Example.app",
        "Example"
    )
    let documents = testPath(
        dataDirectory,
        "Containers",
        "Data",
        "Application",
        "DATA-CONTAINER",
        "Documents"
    )
    let appSupport = testPath(
        dataDirectory,
        "Containers",
        "Data",
        "Application",
        "DATA-CONTAINER",
        "Library",
        "Application Support"
    )
    let cacheDirectory = testPath(
        dataDirectory,
        "Containers",
        "Data",
        "Application",
        "DATA-CONTAINER",
        "Library",
        "Caches"
    )
    let logDirectory = testPath(
        dataDirectory,
        "Containers",
        "Data",
        "Application",
        "DATA-CONTAINER",
        "Library",
        "Logs"
    )
    let tempDirectory = testPath(
        dataDirectory,
        "Containers",
        "Data",
        "Application",
        "DATA-CONTAINER",
        "tmp"
    )
    let mediaDirectory = testPath(dataDirectory, "Media", "DCIM", "100APPLE")

    try writeTestFile(installedApp, size: 32 * 1_024)
    try writeTestFile(testPath(documents, "project.data"), size: 24 * 1_024)
    try writeTestFile(testPath(appSupport, "database.sqlite"), size: 20 * 1_024)
    try writeTestFile(testPath(cacheDirectory, "response.cache"), size: 64 * 1_024)
    try writeTestFile(testPath(logDirectory, "app.log"), size: 64 * 1_024)
    try writeTestFile(testPath(tempDirectory, "work.tmp"), size: 64 * 1_024)
    try writeTestFile(testPath(mediaDirectory, "photo.heic"), size: 28 * 1_024)

    var measurements = try diskStorageMeasurements(dataDirectory: dataDirectory)
    var byID = Dictionary(uniqueKeysWithValues: measurements.map { ($0.id, $0) })
    for id in ["installed-apps", "documents", "app-data", "user-media"] {
        #expect(byID[id]?.bytes ?? 0 > 0)
    }

    let appDataBefore = try #require(byID["app-data"]?.bytes)
    try writeTestFile(testPath(cacheDirectory, "larger.cache"), size: 512 * 1_024)
    measurements = try diskStorageMeasurements(dataDirectory: dataDirectory)
    byID = Dictionary(uniqueKeysWithValues: measurements.map { ($0.id, $0) })
    #expect(byID["app-data"]?.bytes == appDataBefore)
}

@Test func diskCleanupPlanIncludesReadOnlyStorageBreakdown() throws {
    let root = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }

    let dataDirectory = testPath(root, "data")
    try writeTestFile(
        testPath(dataDirectory, "Containers", "Bundle", "Application", "APP", "Example.app", "Example"),
        size: 4_096
    )
    try writeTestFile(
        testPath(dataDirectory, "Containers", "Data", "Application", "DATA", "Documents", "keep.txt"),
        size: 4_096
    )

    let plan = try diskCleanupPlanAt(udid: "TEST-UDID", dataDirectory: dataDirectory)
    #expect(plan.storage.count == diskStorageCategories.count)
    #expect(plan.cleanableBytes == 0)
}

@Test func appDataRejectsContainerRootEscapingThroughSymlink() throws {
    let root = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }

    let dataDirectory = testPath(root, "data")
    let containerParent = testPath(dataDirectory, "Containers", "Data")
    let outside = testPath(root, "outside")
    try FileManager.default.createDirectory(atPath: containerParent, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        atPath: testPath(containerParent, "Application"),
        withDestinationPath: outside
    )

    // Go intentionally skips a symlink used as the app-container root instead
    // of traversing it or charging unrelated data to the simulator.
    #expect(try appDataSize(dataDirectory: dataDirectory) == 0)
}
