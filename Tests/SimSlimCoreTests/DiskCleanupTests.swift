import Foundation
@testable import SimSlimCore
import Testing

@Test func diskCleanupCategoriesAreUniqueAndSafeByDefault() throws {
    var seen = Set<String>()
    for category in diskCleanupCategories {
        #expect(!category.id.isEmpty)
        #expect(seen.insert(category.id).inserted)
        #expect(!(category.defaultSelected && !category.canClean))
    }

    let requiredSiri = try #require(diskCleanupCategory(id: "required-siri-assets"))
    #expect(!requiredSiri.canClean)
    let linguisticData = try #require(diskCleanupCategory(id: "linguistic-data"))
    #expect(linguisticData.canClean)
    #expect(!linguisticData.defaultSelected)
}

@Test func diskCleanupRecoveryModelsStayDistinct() throws {
    for id in ["caches", "logs", "temporary"] {
        let category = try #require(diskCleanupCategory(id: id))
        #expect(category.recovery.contains("deleted"))
    }

    let assets = try #require(diskCleanupCategory(id: "required-siri-assets"))
    #expect(assets.recovery.contains("return automatically"))
    let language = try #require(diskCleanupCategory(id: "linguistic-data"))
    #expect(language.recovery.contains("downloads"))
    #expect(language.risk == "Restored on demand")
}

@Test func diskCleanupPlanAndCleanStayInsideAllowlist() throws {
    let root = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }

    let dataDirectory = testPath(root, "data")
    let cacheDirectory = testPath(dataDirectory, "Library", "Caches")
    let tempDirectory = testPath(dataDirectory, "Containers", "Data", "Application", "A", "tmp")
    let diagnosticsDirectory = testPath(dataDirectory, "var", "db", "diagnostics")
    let uuidTextDirectory = testPath(dataDirectory, "var", "db", "uuidtext")
    let requiredSiriDirectory = testPath(
        dataDirectory,
        "private",
        "var",
        "MobileAsset",
        "AssetsV2",
        "com_apple_MobileAsset_UAF_Siri_Understanding"
    )
    let linguisticDirectory = testPath(
        dataDirectory,
        "private",
        "var",
        "MobileAsset",
        "AssetsV2",
        "com_apple_MobileAsset_LinguisticData"
    )
    let unrelatedAssetDirectory = testPath(
        dataDirectory,
        "private",
        "var",
        "MobileAsset",
        "AssetsV2",
        "com_apple_MobileAsset_PKITrustStore"
    )
    let appDocumentDirectory = testPath(dataDirectory, "Containers", "Data", "Application", "A", "Documents")
    let userNamedCache = testPath(appDocumentDirectory, "Caches", "keep-cache.bin")
    let userNamedLogs = testPath(appDocumentDirectory, "Logs", "keep-log.txt")
    let userNamedTemp = testPath(appDocumentDirectory, "tmp", "keep-temp.bin")
    let assetNamedCache = testPath(requiredSiriDirectory, "Caches", "keep-asset-cache.bin")

    try writeTestFile(testPath(cacheDirectory, "cache.bin"), size: 32 * 1_024)
    try writeTestFile(testPath(tempDirectory, "temp.bin"), size: 16 * 1_024)
    try writeTestFile(testPath(diagnosticsDirectory, "log.tracev3"), size: 24 * 1_024)
    try writeTestFile(testPath(uuidTextDirectory, "symbols"), size: 24 * 1_024)
    try writeTestFile(testPath(requiredSiriDirectory, "model.bin"), size: 64 * 1_024)
    try writeTestFile(testPath(linguisticDirectory, "language-model.bin"), size: 48 * 1_024)
    try writeTestFile(testPath(unrelatedAssetDirectory, "trust.bin"), size: 64 * 1_024)
    try writeTestFile(testPath(appDocumentDirectory, "user.db"), size: 64 * 1_024)
    try writeTestFile(userNamedCache, size: 32 * 1_024)
    try writeTestFile(userNamedLogs, size: 32 * 1_024)
    try writeTestFile(userNamedTemp, size: 32 * 1_024)
    try writeTestFile(assetNamedCache, size: 32 * 1_024)

    let plan = try diskCleanupPlanAt(udid: "TEST-UDID", dataDirectory: dataDirectory)
    let measurements = Dictionary(uniqueKeysWithValues: plan.categories.map { ($0.id, $0) })
    for id in ["caches", "logs", "temporary", "linguistic-data", "required-siri-assets"] {
        #expect(measurements[id]?.bytes ?? 0 > 0)
    }
    #expect(plan.cleanableBytes > 0)
    #expect(plan.totalBytes > plan.cleanableBytes)

    let result = try cleanDiskAt(
        udid: "TEST-UDID",
        dataDirectory: dataDirectory,
        categoryIDs: ["temporary", "logs", "caches", "linguistic-data"]
    )
    #expect(result.reclaimedBytes > 0)

    for removed in [
        testPath(cacheDirectory, "cache.bin"),
        testPath(tempDirectory, "temp.bin"),
        testPath(diagnosticsDirectory, "log.tracev3"),
        testPath(uuidTextDirectory, "symbols"),
        testPath(linguisticDirectory, "language-model.bin"),
    ] {
        #expect(try fileStatus(at: removed) == nil)
    }
    for preservedDirectory in [
        cacheDirectory,
        tempDirectory,
        diagnosticsDirectory,
        uuidTextDirectory,
        linguisticDirectory,
    ] {
        #expect(try fileStatus(at: preservedDirectory)?.isDirectory == true)
    }
    for preserved in [
        testPath(requiredSiriDirectory, "model.bin"),
        testPath(unrelatedAssetDirectory, "trust.bin"),
        testPath(appDocumentDirectory, "user.db"),
        userNamedCache,
        userNamedLogs,
        userNamedTemp,
        assetNamedCache,
    ] {
        #expect(try fileStatus(at: preserved) != nil)
    }
}

@Test func diskCleanupRejectsIntermediateSymlink() throws {
    let root = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }

    let dataDirectory = testPath(root, "data")
    let outsideLogDirectory = testPath(root, "outside", "log")
    let outsideFile = testPath(outsideLogDirectory, "keep.log")
    try writeTestFile(outsideFile, size: 4_096)
    try FileManager.default.createDirectory(atPath: dataDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        atPath: testPath(dataDirectory, "var"),
        withDestinationPath: (outsideLogDirectory as NSString).deletingLastPathComponent
    )

    #expect(throws: (any Error).self) {
        _ = try cleanDiskAt(udid: "TEST-UDID", dataDirectory: dataDirectory, categoryIDs: ["logs"])
    }
    #expect(try fileStatus(at: outsideFile) != nil)
}

@Test func diskCleanupDoesNotFollowSymlinks() throws {
    let root = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }

    let dataDirectory = testPath(root, "data")
    let cacheDirectory = testPath(dataDirectory, "Library", "Caches")
    let outsideDirectory = testPath(root, "outside")
    let outsideFile = testPath(outsideDirectory, "keep.txt")
    try writeTestFile(outsideFile, size: 4_096)
    try FileManager.default.createDirectory(atPath: cacheDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        atPath: testPath(cacheDirectory, "outside-link"),
        withDestinationPath: outsideDirectory
    )

    _ = try cleanDiskAt(udid: "TEST-UDID", dataDirectory: dataDirectory, categoryIDs: ["caches"])
    #expect(try fileStatus(at: outsideFile) != nil)
}

@Test func diskCleanupRejectsUnsafeTargetsAndMeasuredOnlyCategory() throws {
    let root = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }

    let dataDirectory = testPath(root, "data")
    try FileManager.default.createDirectory(atPath: dataDirectory, withIntermediateDirectories: true)
    #expect(throws: (any Error).self) {
        try requireDescendant(root: dataDirectory, target: dataDirectory)
    }
    #expect(throws: (any Error).self) {
        try requireDescendant(root: dataDirectory, target: root)
    }
    #expect(throws: (any Error).self) {
        _ = try validateDiskCleanupSelection(["required-siri-assets"])
    }
}

@Test func diskCleanupSelectionIsTrimmedDeduplicatedAndSorted() throws {
    let selection = try validateDiskCleanupSelection([" temporary ", "logs", "", "logs", "caches"])
    #expect(selection == ["caches", "logs", "temporary"])
}

@Test func cleanDeviceDiskRestoresABootedSimulatorAfterCleanup() async throws {
    let root = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let dataDirectory = testPath(root, "Device", "data")
    try writeTestFile(testPath(dataDirectory, "Library", "Caches", "cache.bin"), size: 16 * 1_024)
    let runner = DiskCleanupCommandRunner(
        udid: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
        dataDirectory: dataDirectory,
        initialState: "Booted"
    )
    let service = DiskCleanupService(simctl: testSimCtl(runner: runner))

    let result = try await service.clean(
        udid: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
        categoryIDs: ["caches"],
        preserveBootState: true
    )
    let finalState = await runner.currentState()
    #expect(result.wasBooted)
    #expect(result.bootStateRestored)
    #expect(result.reclaimedBytes > 0)
    #expect(finalState == "Booted")
}

@Test func cleanDeviceDiskRestoresBootStateEvenWhenCleanupFails() async throws {
    let root = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let dataDirectory = testPath(root, "Device", "data")
    let outside = testPath(root, "outside")
    try writeTestFile(testPath(outside, "log", "keep.log"), size: 4_096)
    try FileManager.default.createDirectory(atPath: dataDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        atPath: testPath(dataDirectory, "var"),
        withDestinationPath: outside
    )
    let runner = DiskCleanupCommandRunner(
        udid: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
        dataDirectory: dataDirectory,
        initialState: "Booted"
    )
    let service = DiskCleanupService(simctl: testSimCtl(runner: runner))

    await #expect(throws: (any Error).self) {
        _ = try await service.clean(
            udid: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
            categoryIDs: ["logs"],
            preserveBootState: true
        )
    }
    let finalState = await runner.currentState()
    #expect(finalState == "Booted")
    #expect(try fileStatus(at: testPath(outside, "log", "keep.log"))?.isRegularFile == true)
}

@Test func diskCleanupRejectsTransitionalSimulatorStatesBeforeDeleting() async throws {
    for (index, state) in ["Booting", "Shutting Down"].enumerated() {
        let root = try makeTestDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let dataDirectory = testPath(root, "Device", "data")
        let cacheFile = testPath(dataDirectory, "Library", "Caches", "cache.bin")
        try writeTestFile(cacheFile, size: 4_096)
        let udid = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCC\(index)"
        let runner = DiskCleanupCommandRunner(
            udid: udid,
            dataDirectory: dataDirectory,
            initialState: state
        )
        let service = DiskCleanupService(simctl: testSimCtl(runner: runner))

        await #expect(throws: (any Error).self) {
            _ = try await service.clean(
                udid: udid,
                categoryIDs: ["caches"],
                preserveBootState: false
            )
        }
        #expect(try fileStatus(at: cacheFile)?.isRegularFile == true)
    }
}

private func testSimCtl(runner: any CommandRunning) -> SimCtl {
    SimCtl(
        runner: runner,
        registry: DeviceSetRegistry(),
        configuration: SimCtlConfiguration(
            shutdownTimeout: .seconds(1),
            bootTimeout: .seconds(1),
            spawnTimeout: .seconds(1),
            shutdownPollInterval: .milliseconds(1)
        )
    )
}

private actor DiskCleanupCommandRunner: CommandRunning {
    private let dataDirectory: String
    private var state: String
    private let udid: String

    init(udid: String, dataDirectory: String, initialState: String) {
        self.udid = udid
        self.dataDirectory = dataDirectory
        state = initialState
    }

    func currentState() -> String {
        state
    }

    func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        guard invocation.executable == "xcrun" else {
            return CommandResult(standardError: "unexpected executable", termination: .exited(1))
        }
        let arguments = invocation.arguments
        if arguments.contains("list"), arguments.contains("devices") {
            let object: [String: Any] = [
                "devices": [
                    "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
                        [
                            "udid": udid,
                            "name": "Disk Test",
                            "state": state,
                            "isAvailable": true,
                            "dataPath": dataDirectory,
                        ] as [String: Any],
                    ],
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return CommandResult(standardOutput: String(decoding: data, as: UTF8.self))
        }
        if arguments.contains("shutdown") {
            state = "Shutdown"
            return CommandResult()
        }
        if arguments.contains("bootstatus") {
            return CommandResult()
        }
        if arguments.contains("boot") {
            state = "Booted"
            return CommandResult()
        }
        return CommandResult(standardError: "unexpected xcrun arguments", termination: .exited(1))
    }
}

func makeTestDirectory() throws -> String {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("swift-simslim-tests-\(UUID().uuidString)", isDirectory: true)
        .path
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    return directory
}

func testPath(_ components: String...) -> String {
    components.reduce("") { partial, component in
        partial.isEmpty ? component : (partial as NSString).appendingPathComponent(component)
    }
}

func writeTestFile(_ target: String, size: Int) throws {
    try FileManager.default.createDirectory(
        atPath: (target as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    try Data(repeating: 0x41, count: size).write(to: URL(fileURLWithPath: target))
}
