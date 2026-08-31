import Foundation
@testable import SimSlimCore
import Testing

private let testSourceUDID = "11111111-1111-1111-1111-111111111111"
private let testCloneUDID = "22222222-2222-2222-2222-222222222222"

@Test func desiredCloneDisabledKeepsOnlySlimmableServices() throws {
    let category = try #require(categories.first(where: { $0.labels.count > 1 }))
    let required = try #require(categories.lazy.flatMap(\.alwaysEnabled).first?.label)
    let disabled = [
        category.labels[0]: true,
        category.labels[1]: false,
        required: true,
        "com.example.unmanaged-test": true,
    ]

    #expect(desiredCloneDisabled(disabled) == [category.labels[0]])
}

@Test func sanitizeClonedDeviceAtRebasesDirectLinks() throws {
    let paths = try newTestCloneFilesystem()
    defer { try? FileManager.default.removeItem(atPath: cloneTestRoot(paths)) }

    let trialSource = testPath(paths.sourceDataDirectory, "Library", "Trial", "shared-state")
    let trialClone = testPath(paths.cloneDataDirectory, "Library", "Trial", "shared-state")
    try writeCloneTestFile(trialSource, contents: "source trial state")
    try writeCloneTestFile(trialClone, contents: "cloned trial state")
    let absoluteLink = testPath(paths.cloneDataDirectory, "Library", "Trial", "current-state")
    try FileManager.default.createSymbolicLink(atPath: absoluteLink, withDestinationPath: trialSource)

    let shortcutSource = testPath(paths.sourceDataDirectory, "Library", "Shortcuts", "store")
    let shortcutClone = testPath(paths.cloneDataDirectory, "Library", "Shortcuts", "store")
    try writeCloneTestFile(shortcutSource, contents: "source shortcuts")
    try writeCloneTestFile(shortcutClone, contents: "cloned shortcuts")
    let relativeSourceLink = testPath(
        paths.cloneDataDirectory,
        "Library",
        "Shortcuts",
        "source-relative"
    )
    let relativeSourceTarget = relativePath(
        from: (relativeSourceLink as NSString).deletingLastPathComponent,
        to: shortcutSource
    )
    try FileManager.default.createSymbolicLink(
        atPath: relativeSourceLink,
        withDestinationPath: relativeSourceTarget
    )

    let localRelativeLink = testPath(paths.cloneDataDirectory, "Library", "Trial", "local-relative")
    try FileManager.default.createSymbolicLink(
        atPath: localRelativeLink,
        withDestinationPath: "shared-state"
    )
    let sharedRuntimeLink = testPath(paths.cloneDataDirectory, "Library", "shared-runtime")
    let sharedRuntimeTarget = "/Library/Developer/CoreSimulator/Volumes/iOS_23A123"
    try FileManager.default.createSymbolicLink(
        atPath: sharedRuntimeLink,
        withDestinationPath: sharedRuntimeTarget
    )
    let logsLink = testPath(paths.cloneDataDirectory, "Library", "Logs")
    try FileManager.default.createSymbolicLink(
        atPath: logsLink,
        withDestinationPath: paths.sourceLogDirectory
    )

    let lsdDirectory = testPath(paths.cloneDataDirectory, "var", "db", "lsd")
    try writeCloneTestFile(
        testPath(lsdDirectory, "com.apple.LaunchServices-1-v2.csstore"),
        contents: "stale paths"
    )
    try writeCloneTestFile(
        testPath(lsdDirectory, "SystemDataOnly-com.apple.LaunchServices-1-v2.csstore"),
        contents: "keep"
    )
    let frontBoardDirectory = testPath(paths.cloneDataDirectory, "Library", "FrontBoard")
    for name in ["applicationState.db", "applicationState.db-shm", "applicationState.db-wal"] {
        try writeCloneTestFile(testPath(frontBoardDirectory, name), contents: "stale paths")
    }

    let generatedStateDirectories = [
        testPath(paths.cloneDataDirectory, "Library", "AppleMediaServices", "Engagement", "internal", "database"),
        testPath(paths.cloneDataDirectory, "Library", "Spotlight"),
        testPath(paths.cloneDataDirectory, "Library", "chronod", "replicator"),
        testPath(paths.cloneDataDirectory, "Library", "com.apple.nsurlsessiond"),
        testPath(paths.cloneDataDirectory, "private", "var", "MobileAsset", "AssetsV2", "locks"),
        testPath(paths.cloneDataDirectory, "private", "var", "MobileAsset", "AssetsV2", "persisted"),
        testPath(paths.cloneDataDirectory, "private", "var", "db", "assetsubscriptiond", "history"),
        testPath(paths.cloneDataDirectory, "var", "db", "diagnostics", "Persist"),
        testPath(paths.cloneDataDirectory, "var", "db", "diagnostics", "Special"),
        testPath(paths.cloneDataDirectory, "Containers", "Shared", "AppGroup", "SYSTEM", "replicatord"),
    ]
    for directory in generatedStateDirectories {
        try writeCloneTestFile(
            testPath(directory, "copied-state.db"),
            contents: "file://\(trialSource)"
        )
    }
    let downloadedAsset = testPath(
        paths.cloneDataDirectory,
        "private",
        "var",
        "MobileAsset",
        "AssetsV2",
        "com_apple_MobileAsset_Test",
        "AssetData",
        "model.bin"
    )
    try writeCloneTestFile(downloadedAsset, contents: "downloaded payload")

    try writeCloneTestFile(
        testPath(paths.cloneDataDirectory, "Library", "Caches", "system.cache"),
        contents: "discard"
    )
    try writeCloneTestFile(testPath(paths.cloneDataDirectory, "tmp", "snapshot"), contents: "discard")
    let springBoardPreference = testPath(
        paths.cloneDataDirectory,
        "Library",
        "Preferences",
        "com.apple.springboard.plist"
    )
    try writeCloneTestFile(
        springBoardPreference,
        contents: "file://\(testPath(paths.sourceDataDirectory, "Library", "Poster", "snapshot.atx"))"
    )
    let appBundle = testPath(
        paths.cloneDataDirectory,
        "Containers",
        "Bundle",
        "Application",
        "APP",
        "FleetDog.app",
        "FleetDog"
    )
    let appDocument = testPath(
        paths.cloneDataDirectory,
        "Containers",
        "Data",
        "Application",
        "APP",
        "Documents",
        "fleetdog.db"
    )
    let appCache = testPath(
        paths.cloneDataDirectory,
        "Containers",
        "Data",
        "Application",
        "APP",
        "Library",
        "Caches",
        "offline.cache"
    )
    try writeCloneTestFile(appBundle, contents: "executable")
    try writeCloneTestFile(appDocument, contents: "user data")
    try writeCloneTestFile(appCache, contents: "app cache")

    try sanitizeClonedDeviceAt(paths)

    #expect(try symlinkTarget(absoluteLink) == trialClone)
    #expect(
        try symlinkTarget(relativeSourceLink)
            == relativePath(
                from: (relativeSourceLink as NSString).deletingLastPathComponent,
                to: shortcutClone
            )
    )
    #expect(try symlinkTarget(localRelativeLink) == "shared-state")
    #expect(try symlinkTarget(sharedRuntimeLink) == sharedRuntimeTarget)
    #expect(try symlinkTarget(logsLink) == paths.cloneLogDirectory)

    #expect(try fileStatus(at: testPath(lsdDirectory, "com.apple.LaunchServices-1-v2.csstore"))?.isRegularFile == nil)
    #expect(try fileStatus(at: testPath(lsdDirectory, "SystemDataOnly-com.apple.LaunchServices-1-v2.csstore"))?.isRegularFile == true)
    for name in ["applicationState.db", "applicationState.db-shm", "applicationState.db-wal"] {
        #expect(try fileStatus(at: testPath(frontBoardDirectory, name))?.isRegularFile == nil)
    }
    for directory in generatedStateDirectories {
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory).isEmpty)
    }
    #expect(try fileStatus(at: downloadedAsset)?.isRegularFile == true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: testPath(paths.cloneDataDirectory, "Library", "Caches")).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: testPath(paths.cloneDataDirectory, "tmp")).isEmpty)

    let preferenceContents = try String(contentsOfFile: springBoardPreference, encoding: .utf8)
    #expect(!preferenceContents.contains(testSourceUDID))
    #expect(preferenceContents.contains(testCloneUDID))
    for preserved in [appBundle, appDocument, appCache] {
        #expect(try fileStatus(at: preserved)?.isRegularFile == true)
    }

    try walkFilesystem(at: paths.cloneDeviceDirectory) { linkPath, status in
        if status.isSymbolicLink {
            let target = try symlinkTarget(linkPath)
            #expect(!target.contains(testSourceUDID))
            return .skipDescendants
        }
        return .descend
    }
}

@Test func simulatorProcessIDsFromPSFindsCloneProcesses() {
    let output = [
        "100 launchd_sim SIMULATOR_UDID=\(testCloneUDID) HOME=/clone",
        "101 SpringBoard HOME=/clone SIMULATOR_UDID=\(testCloneUDID)",
        "102 source SIMULATOR_UDID=\(testSourceUDID)",
        "not-a-pid helper SIMULATOR_UDID=\(testCloneUDID)",
        "",
    ].joined(separator: "\n")
    #expect(simulatorProcessIDsFromPS(output, udid: testCloneUDID) == [100, 101])
}

@Test func sourceReferencesFromLsofFindsOnlySourcePaths() throws {
    let paths = try newTestCloneFilesystem()
    defer { try? FileManager.default.removeItem(atPath: cloneTestRoot(paths)) }
    let output = [
        "p100",
        "fcwd",
        "n\(paths.cloneDataDirectory)",
        "ftxt",
        "n\(testPath(paths.sourceDataDirectory, "Library", "Poster", "snapshot.atx"))",
        "p101",
        "ftxt",
        "n/Library/Developer/CoreSimulator/Volumes/iOS_Runtime",
        "",
    ].joined(separator: "\n")

    let references = sourceReferencesFromLsof(output, paths: paths)
    #expect(references.count == 1)
    #expect(references.first?.pid == 100)
    #expect(references.first?.path.contains(testSourceUDID) == true)
}

@Test func evaluateCloneLsofAuditAcceptsLiveRecordsWhenAnotherPIDExited() throws {
    let paths = try newTestCloneFilesystem()
    defer { try? FileManager.default.removeItem(atPath: cloneTestRoot(paths)) }
    let output = ["p100", "fcwd", "n\(paths.cloneDataDirectory)", ""].joined(separator: "\n")
    let result = evaluateCloneLsofAudit(
        output: output,
        commandError: CloneTestError.failed,
        paths: paths
    )
    #expect(result.complete)
    #expect(result.error?.localizedDescription == nil)
}

@Test func evaluateCloneLsofAuditRetriesWhenAllSnapshottedPIDsExited() throws {
    let paths = try newTestCloneFilesystem()
    defer { try? FileManager.default.removeItem(atPath: cloneTestRoot(paths)) }
    let result = evaluateCloneLsofAudit(
        output: "",
        commandError: CloneTestError.failed,
        paths: paths
    )
    #expect(!result.complete)
    #expect(result.error?.localizedDescription != nil)
}

@Test func evaluateCloneLsofAuditRejectsSourceReferenceDespiteExitError() throws {
    let paths = try newTestCloneFilesystem()
    defer { try? FileManager.default.removeItem(atPath: cloneTestRoot(paths)) }
    let output = [
        "p100",
        "fcwd",
        "n\(testPath(paths.sourceDataDirectory, "Library", "linked.db"))",
        "",
    ].joined(separator: "\n")
    let result = evaluateCloneLsofAudit(
        output: output,
        commandError: CloneTestError.failed,
        paths: paths
    )
    #expect(result.complete)
    #expect(result.error?.localizedDescription.contains("source simulator path") == true)
}

@Test func sanitizeClonedDeviceAtRejectsUnknownSourceSymlink() throws {
    let paths = try newTestCloneFilesystem()
    defer { try? FileManager.default.removeItem(atPath: cloneTestRoot(paths)) }
    let outsideRoot = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: outsideRoot) }
    let link = testPath(paths.cloneDataDirectory, "Library", "unexpected-source-link")
    try FileManager.default.createSymbolicLink(
        atPath: link,
        withDestinationPath: testPath(outsideRoot, testSourceUDID, "state")
    )

    var message = ""
    do {
        try sanitizeClonedDeviceAt(paths)
        Issue.record("sanitizeClonedDeviceAt should reject an unknown source link")
    } catch {
        message = error.localizedDescription
    }
    #expect(message.contains("source simulator"))
}

@Test func sanitizeClonedDeviceAtRejectsHardLinkedSourceFile() throws {
    let paths = try newTestCloneFilesystem()
    defer { try? FileManager.default.removeItem(atPath: cloneTestRoot(paths)) }
    let source = testPath(paths.sourceDataDirectory, "Library", "State", "shared.db")
    let clone = testPath(paths.cloneDataDirectory, "Library", "State", "shared.db")
    try writeCloneTestFile(source, contents: "shared inode")
    try FileManager.default.createDirectory(
        atPath: (clone as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    try FileManager.default.linkItem(atPath: source, toPath: clone)

    var message = ""
    do {
        try sanitizeClonedDeviceAt(paths)
        Issue.record("sanitizeClonedDeviceAt should reject a hard link")
    } catch {
        message = error.localizedDescription
    }
    #expect(message.contains("hard-linked"))
}

@Test func sanitizeClonedDeviceAtRejectsCrossPathHardLinkToSource() throws {
    let paths = try newTestCloneFilesystem()
    defer { try? FileManager.default.removeItem(atPath: cloneTestRoot(paths)) }
    let source = testPath(paths.sourceDataDirectory, "Library", "Original", "state.db")
    let clone = testPath(paths.cloneDataDirectory, "Library", "Relocated", "copy.db")
    try writeCloneTestFile(source, contents: "shared inode")
    try FileManager.default.createDirectory(
        atPath: (clone as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    try FileManager.default.linkItem(atPath: source, toPath: clone)

    var message = ""
    do {
        try sanitizeClonedDeviceAt(paths)
        Issue.record("sanitizeClonedDeviceAt should reject a relocated hard link")
    } catch {
        message = error.localizedDescription
    }
    #expect(message.contains("hard-linked"))
}

@Test func sanitizeClonedDeviceAtRebasesIndirectSourceSymlink() throws {
    let paths = try newTestCloneFilesystem()
    defer { try? FileManager.default.removeItem(atPath: cloneTestRoot(paths)) }
    let source = testPath(paths.sourceDataDirectory, "Library", "State", "source.db")
    let clone = testPath(paths.cloneDataDirectory, "Library", "State", "source.db")
    try writeCloneTestFile(source, contents: "source")
    try writeCloneTestFile(clone, contents: "clone")

    let aliasDirectory = testPath(cloneTestRoot(paths), "Aliases")
    try FileManager.default.createDirectory(
        atPath: aliasDirectory,
        withIntermediateDirectories: true
    )
    let sourceAlias = testPath(aliasDirectory, "source-device")
    try FileManager.default.createSymbolicLink(
        atPath: sourceAlias,
        withDestinationPath: paths.sourceDeviceDirectory
    )
    let cloneLink = testPath(paths.cloneDataDirectory, "Library", "State", "indirect")
    try FileManager.default.createSymbolicLink(
        atPath: cloneLink,
        withDestinationPath: testPath(sourceAlias, "data", "Library", "State", "source.db")
    )

    try sanitizeClonedDeviceAt(paths)

    #expect(try symlinkTarget(cloneLink) == clone)
}

@Test func sanitizeClonedDeviceAtResolvesParentTraversalAfterSymlink() throws {
    let paths = try newTestCloneFilesystem()
    defer { try? FileManager.default.removeItem(atPath: cloneTestRoot(paths)) }
    let sourceChild = testPath(paths.sourceDataDirectory, "Library", "Child")
    try FileManager.default.createDirectory(
        atPath: sourceChild,
        withIntermediateDirectories: true
    )
    let source = testPath(paths.sourceDataDirectory, "Library", "Secret", "state.db")
    let clone = testPath(paths.cloneDataDirectory, "Library", "Secret", "state.db")
    try writeCloneTestFile(source, contents: "source")
    try writeCloneTestFile(clone, contents: "clone")

    let aliasDirectory = testPath(cloneTestRoot(paths), "Aliases")
    try FileManager.default.createDirectory(
        atPath: aliasDirectory,
        withIntermediateDirectories: true
    )
    let childAlias = testPath(aliasDirectory, "child")
    try FileManager.default.createSymbolicLink(
        atPath: childAlias,
        withDestinationPath: sourceChild
    )
    let cloneLink = testPath(paths.cloneDataDirectory, "Library", "parent-traversal")
    try FileManager.default.createSymbolicLink(
        atPath: cloneLink,
        withDestinationPath: testPath(childAlias, "..", "Secret", "state.db")
    )

    try sanitizeClonedDeviceAt(paths)

    #expect(try symlinkTarget(cloneLink) == clone)
}

@Test func sanitizeClonedDeviceAtRemovesSourcePassThroughDependency() throws {
    let paths = try newTestCloneFilesystem()
    defer { try? FileManager.default.removeItem(atPath: cloneTestRoot(paths)) }
    let sharedTarget = testPath(cloneTestRoot(paths), "Shared", "runtime.dat")
    try writeCloneTestFile(sharedTarget, contents: "shared runtime")
    let sourceRuntimeLink = testPath(
        paths.sourceDataDirectory,
        "Library",
        "runtime-link"
    )
    try FileManager.default.createSymbolicLink(
        atPath: sourceRuntimeLink,
        withDestinationPath: sharedTarget
    )

    let aliasDirectory = testPath(cloneTestRoot(paths), "Aliases")
    try FileManager.default.createDirectory(
        atPath: aliasDirectory,
        withIntermediateDirectories: true
    )
    let sourceAlias = testPath(aliasDirectory, "source-runtime")
    try FileManager.default.createSymbolicLink(
        atPath: sourceAlias,
        withDestinationPath: sourceRuntimeLink
    )
    let cloneLink = testPath(paths.cloneDataDirectory, "Library", "shared-runtime")
    try FileManager.default.createSymbolicLink(
        atPath: cloneLink,
        withDestinationPath: sourceAlias
    )

    try sanitizeClonedDeviceAt(paths)

    let rewrittenTarget = try symlinkTarget(cloneLink)
    let resolvedSharedTarget = try resolveFilesystemAliases(sharedTarget).finalPath
    #expect(rewrittenTarget == resolvedSharedTarget)
    #expect(!rewrittenTarget.contains(testSourceUDID))
    try verifyCloneIndependence(paths)
}

@Test func sanitizeClonedDeviceAtRejectsCyclicSymlinkChain() throws {
    let paths = try newTestCloneFilesystem()
    defer { try? FileManager.default.removeItem(atPath: cloneTestRoot(paths)) }
    let aliasDirectory = testPath(cloneTestRoot(paths), "Aliases")
    try FileManager.default.createDirectory(
        atPath: aliasDirectory,
        withIntermediateDirectories: true
    )
    let first = testPath(aliasDirectory, "first")
    let second = testPath(aliasDirectory, "second")
    try FileManager.default.createSymbolicLink(atPath: first, withDestinationPath: second)
    try FileManager.default.createSymbolicLink(atPath: second, withDestinationPath: first)
    let cloneLink = testPath(paths.cloneDataDirectory, "Library", "cyclic")
    try FileManager.default.createSymbolicLink(atPath: cloneLink, withDestinationPath: first)

    var message = ""
    do {
        try sanitizeClonedDeviceAt(paths)
        Issue.record("sanitizeClonedDeviceAt should reject a cyclic link chain")
    } catch {
        message = error.localizedDescription
    }
    #expect(message.contains("cyclic symbolic-link chain"))
}

@Test func clonePathRebasingRequiresAComponentBoundary() {
    #expect(rebasePath("/devices/source/data", sourceRoot: "/devices/source", cloneRoot: "/devices/clone") == "/devices/clone/data")
    #expect(rebasePath("/devices/source-copy/data", sourceRoot: "/devices/source", cloneRoot: "/devices/clone") == nil)
}

@Test func cloneDeviceRestoresSourceAndReturnsAShutdownIndependentClone() async throws {
    let root = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let runner = try CloneCommandRunner(root: root, cloneMode: .safe)
    let simctl = cloneTestSimCtl(runner: runner)
    let service = CloneService(simctl: simctl)

    let clonedUDID = try await service.clone(udid: testSourceUDID, name: "Independent Clone")
    let sourceState = await runner.state(of: testSourceUDID)
    let cloneState = await runner.state(of: testCloneUDID)
    let deleted = await runner.deletedUnsafeClone
    #expect(clonedUDID == testCloneUDID)
    #expect(sourceState == "Booted")
    #expect(cloneState == "Shutdown")
    #expect(!deleted)
}

@Test func cloneFindsAUniqueUDIDInStandardError() async throws {
    let root = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let runner = try CloneCommandRunner(root: root, cloneMode: .uuidOnStandardError)
    let service = CloneService(simctl: cloneTestSimCtl(runner: runner))

    let clonedUDID = try await service.clone(udid: testSourceUDID, name: "Stderr Clone")

    #expect(clonedUDID == testCloneUDID)
    #expect(await runner.state(of: testSourceUDID) == "Booted")
    #expect(await runner.state(of: testCloneUDID) == "Shutdown")
}

@Test func cloneRecoversTheUDIDFromTheDeviceSetWhenOutputChanges() async throws {
    let root = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let runner = try CloneCommandRunner(root: root, cloneMode: .malformedCloneOutput)
    let service = CloneService(simctl: cloneTestSimCtl(runner: runner))

    let clonedUDID = try await service.clone(udid: testSourceUDID, name: "Discovered Clone")

    #expect(clonedUDID == testCloneUDID)
    #expect(await runner.state(of: testSourceUDID) == "Booted")
    #expect(await runner.state(of: testCloneUDID) == "Shutdown")
}

@Test func cloneDoesNotTrustAnUnrelatedUUIDInSuccessfulOutput() async throws {
    let root = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let runner = try CloneCommandRunner(root: root, cloneMode: .sourceUUIDOnly)
    let service = CloneService(simctl: cloneTestSimCtl(runner: runner))

    let clonedUDID = try await service.clone(udid: testSourceUDID, name: "Validated Clone")

    #expect(clonedUDID == testCloneUDID)
    #expect(await runner.state(of: testSourceUDID) == "Booted")
    #expect(await runner.state(of: testCloneUDID) == "Shutdown")
    #expect(!(await runner.deletedUnsafeClone))
}

@Test func cancellationAfterRawCloneCreationStillDeletesTheClone() async throws {
    let root = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let runner = try CloneCommandRunner(root: root, cloneMode: .blocksAfterCreatingClone)
    let service = CloneService(simctl: cloneTestSimCtl(runner: runner))
    let task = Task {
        try await service.clone(udid: testSourceUDID, name: "Cancelled Clone")
    }

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(1))
    while await runner.state(of: testCloneUDID) == nil, clock.now < deadline {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await runner.state(of: testCloneUDID) == "Shutdown")
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("cancelled clone should not succeed")
    } catch {
        // The cleanup assertions below are the behavior under test.
    }

    #expect(await runner.state(of: testSourceUDID) == "Booted")
    #expect(await runner.state(of: testCloneUDID) == nil)
    #expect(await runner.deletedUnsafeClone)
}

@Test func failedClonePreparationDeletesCloneAndRestoresSourceState() async throws {
    let root = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let runner = try CloneCommandRunner(root: root, cloneMode: .unsafeSourceSymlink)
    let service = CloneService(simctl: cloneTestSimCtl(runner: runner))

    var message = ""
    do {
        _ = try await service.clone(udid: testSourceUDID, name: "Unsafe Clone")
        Issue.record("clone should reject and delete an unsafe copy")
    } catch {
        message = error.localizedDescription
    }
    let sourceState = await runner.state(of: testSourceUDID)
    let cloneState = await runner.state(of: testCloneUDID)
    let deleted = await runner.deletedUnsafeClone
    #expect(message.contains("deleted the unsafe clone"))
    #expect(sourceState == "Booted")
    #expect(cloneState == nil)
    #expect(deleted)
}

@Test func cloneDeviceRestoresAnOriginallyShutdownSource() async throws {
    let root = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let runner = try CloneCommandRunner(
        root: root,
        cloneMode: .safe,
        sourceInitialState: "Shutdown"
    )
    let service = CloneService(simctl: cloneTestSimCtl(runner: runner))

    _ = try await service.clone(udid: testSourceUDID, name: "Shutdown Source Clone")
    let sourceState = await runner.state(of: testSourceUDID)
    #expect(sourceState == "Shutdown")
}

@Test func failedRepairLeavesCloneShutdownAndRestoresSourceState() async throws {
    let root = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let runner = try CloneCommandRunner(
        root: root,
        cloneMode: .unsafeSourceSymlink,
        includeExistingClone: true
    )
    let service = CloneService(simctl: cloneTestSimCtl(runner: runner))

    await #expect(throws: (any Error).self) {
        try await service.repair(sourceUDID: testSourceUDID, cloneUDID: testCloneUDID)
    }
    let sourceState = await runner.state(of: testSourceUDID)
    let cloneState = await runner.state(of: testCloneUDID)
    #expect(sourceState == "Booted")
    #expect(cloneState == "Shutdown")
}

@Test func successfulRepairRestoresABootedCloneAndSource() async throws {
    let root = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let runner = try CloneCommandRunner(
        root: root,
        cloneMode: .safe,
        includeExistingClone: true
    )
    let service = CloneService(simctl: cloneTestSimCtl(runner: runner))

    try await service.repair(sourceUDID: testSourceUDID, cloneUDID: testCloneUDID)

    #expect(await runner.state(of: testSourceUDID) == "Booted")
    #expect(await runner.state(of: testCloneUDID) == "Booted")
}

@Test func repairRejectsSourceLinkCreatedWhileTheCloneBoots() async throws {
    let root = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let runner = try CloneCommandRunner(
        root: root,
        cloneMode: .injectSourceSymlinkOnCloneBoot,
        includeExistingClone: true
    )
    let service = CloneService(simctl: cloneTestSimCtl(runner: runner))

    var message = ""
    do {
        try await service.repair(sourceUDID: testSourceUDID, cloneUDID: testCloneUDID)
        Issue.record("repair should reject source links generated during boot")
    } catch {
        message = error.localizedDescription
    }

    #expect(message.contains("source simulator"))
    #expect(await runner.state(of: testSourceUDID) == "Booted")
    #expect(await runner.state(of: testCloneUDID) == "Shutdown")
}

@Test func cloneOperationTimeoutDeletesPartialCloneAndRestoresSource() async throws {
    let root = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let baseRunner = try CloneCommandRunner(root: root, cloneMode: .safe)
    let runner = DelayedCloneCommandRunner(base: baseRunner, executable: "/usr/sbin/lsof")
    let configuration = SimCtlConfiguration(
        shutdownTimeout: .milliseconds(50),
        bootTimeout: .milliseconds(100),
        spawnTimeout: .milliseconds(100),
        shutdownPollInterval: .milliseconds(1)
    )
    let service = CloneService(
        simctl: SimCtl(
            runner: runner,
            registry: DeviceSetRegistry(),
            configuration: configuration
        )
    )

    var message = ""
    do {
        _ = try await service.clone(udid: testSourceUDID, name: "Timed Out Clone")
        Issue.record("expected the clone operation to time out")
    } catch {
        message = error.localizedDescription
    }
    #expect(message.contains("timed out"))
    #expect(message.contains("deleted the unsafe clone"))
    #expect(await baseRunner.state(of: testSourceUDID) == "Booted")
    #expect(await baseRunner.state(of: testCloneUDID) == nil)
    #expect(await baseRunner.deletedUnsafeClone)
}

@Test func cloneTimeoutReportsWhenUnsafeCloneDeletionFails() async throws {
    let root = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let baseRunner = try CloneCommandRunner(root: root, cloneMode: .safe)
    let runner = DelayedCloneCommandRunner(
        base: baseRunner,
        executable: "/usr/sbin/lsof",
        failureAfterCancellation: .delete
    )
    let configuration = shortCloneConfiguration()
    let service = CloneService(
        simctl: SimCtl(
            runner: runner,
            registry: DeviceSetRegistry(),
            configuration: configuration
        )
    )

    var message = ""
    do {
        _ = try await service.clone(udid: testSourceUDID, name: "Deletion Failure")
        Issue.record("expected the clone operation to time out")
    } catch {
        message = error.localizedDescription
    }
    #expect(message.contains("timed out"))
    #expect(message.contains("could not delete the unsafe clone"))
    #expect(await baseRunner.state(of: testSourceUDID) == "Booted")
    #expect(await baseRunner.state(of: testCloneUDID) == "Shutdown")
}

@Test func repairTimeoutReportsWhenCloneCannotBeLeftShutdown() async throws {
    let root = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let baseRunner = try CloneCommandRunner(
        root: root,
        cloneMode: .safe,
        includeExistingClone: true
    )
    let runner = DelayedCloneCommandRunner(
        base: baseRunner,
        executable: "/usr/sbin/lsof",
        failureAfterCancellation: .cloneShutdown
    )
    let service = CloneService(
        simctl: SimCtl(
            runner: runner,
            registry: DeviceSetRegistry(),
            configuration: shortCloneConfiguration()
        )
    )

    var message = ""
    do {
        try await service.repair(sourceUDID: testSourceUDID, cloneUDID: testCloneUDID)
        Issue.record("expected the repair operation to time out")
    } catch {
        message = error.localizedDescription
    }
    #expect(message.contains("timed out"))
    #expect(message.contains("could not leave the clone safely shutdown"))
    #expect(await baseRunner.state(of: testSourceUDID) == "Booted")
    #expect(await baseRunner.state(of: testCloneUDID) == "Booted")
}

private func shortCloneConfiguration() -> SimCtlConfiguration {
    SimCtlConfiguration(
        shutdownTimeout: .milliseconds(50),
        bootTimeout: .milliseconds(100),
        spawnTimeout: .milliseconds(100),
        shutdownPollInterval: .milliseconds(1)
    )
}

private func cloneTestSimCtl(runner: any CommandRunning) -> SimCtl {
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

private actor CloneCommandRunner: CommandRunning {
    enum CloneMode: Sendable {
        case blocksAfterCreatingClone
        case injectSourceSymlinkOnCloneBoot
        case malformedCloneOutput
        case safe
        case sourceUUIDOnly
        case unsafeSourceSymlink
        case uuidOnStandardError
    }

    struct Record: Sendable {
        let dataPath: String
        var name: String
        var state: String
    }

    private let cloneMode: CloneMode
    private let root: String
    private var devices: [String: Record]
    private(set) var deletedUnsafeClone = false

    init(
        root: String,
        cloneMode: CloneMode,
        includeExistingClone: Bool = false,
        sourceInitialState: String = "Booted"
    ) throws {
        self.cloneMode = cloneMode
        self.root = root
        let sourceData = testPath(root, "Devices", testSourceUDID, "data")
        try FileManager.default.createDirectory(
            atPath: testPath(sourceData, "Library"),
            withIntermediateDirectories: true
        )
        devices = [
            testSourceUDID: Record(dataPath: sourceData, name: "Source", state: sourceInitialState),
        ]
        if includeExistingClone {
            let cloneData = testPath(root, "Devices", testCloneUDID, "data")
            try Self.prepareCloneData(
                at: cloneData,
                mode: cloneMode,
                root: root
            )
            devices[testCloneUDID] = Record(
                dataPath: cloneData,
                name: "Existing Clone",
                state: "Booted"
            )
        }
    }

    func state(of udid: String) -> String? {
        devices[udid]?.state
    }

    func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        if invocation.executable == "/bin/ps" {
            guard devices[testCloneUDID]?.state == "Booted" else {
                return CommandResult()
            }
            return CommandResult(
                standardOutput: "100 launchd_sim SIMULATOR_UDID=\(testCloneUDID) HOME=/clone\n"
            )
        }
        if invocation.executable == "/usr/sbin/lsof" {
            guard let clone = devices[testCloneUDID] else {
                return CommandResult(termination: .exited(1))
            }
            return CommandResult(standardOutput: "p100\nfcwd\nn\(clone.dataPath)\n")
        }
        guard invocation.executable == "xcrun" else {
            return CommandResult(standardError: "unexpected executable", termination: .exited(1))
        }

        var arguments = invocation.arguments
        guard arguments.first == "simctl" else {
            return CommandResult(standardError: "expected simctl", termination: .exited(1))
        }
        arguments.removeFirst()
        if arguments.first == "--set", arguments.count >= 2 {
            arguments.removeFirst(2)
        }
        guard let command = arguments.first else {
            return CommandResult(standardError: "missing command", termination: .exited(1))
        }

        switch command {
        case "list":
            let rows: [[String: Any]] = devices.sorted(by: { $0.key < $1.key }).map { udid, record in
                [
                    "udid": udid,
                    "name": record.name,
                    "state": record.state,
                    "isAvailable": true,
                    "dataPath": record.dataPath,
                ]
            }
            let object: [String: Any] = [
                "devices": ["com.apple.CoreSimulator.SimRuntime.iOS-27-0": rows],
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return CommandResult(standardOutput: String(decoding: data, as: UTF8.self))

        case "boot":
            guard arguments.count >= 2, var device = devices[arguments[1]] else {
                return CommandResult(termination: .exited(1))
            }
            device.state = "Booted"
            devices[arguments[1]] = device
            if arguments[1] == testCloneUDID,
               cloneMode == .injectSourceSymlinkOnCloneBoot
            {
                let link = testPath(device.dataPath, "Library", "generated-source-link")
                if try fileStatus(at: link) == nil {
                    try FileManager.default.createSymbolicLink(
                        atPath: link,
                        withDestinationPath: testPath(
                            root,
                            "Devices",
                            testSourceUDID,
                            "data",
                            "Library"
                        )
                    )
                }
            }
            return CommandResult()

        case "bootstatus":
            return CommandResult()

        case "shutdown":
            guard arguments.count >= 2, var device = devices[arguments[1]] else {
                return CommandResult(termination: .exited(1))
            }
            device.state = "Shutdown"
            devices[arguments[1]] = device
            return CommandResult()

        case "spawn":
            return CommandResult(standardOutput: "disabled services = {\n}\n")

        case "clone":
            let cloneData = testPath(root, "Devices", testCloneUDID, "data")
            try Self.prepareCloneData(at: cloneData, mode: cloneMode, root: root)
            devices[testCloneUDID] = Record(
                dataPath: cloneData,
                name: arguments.count >= 3 ? arguments[2] : "Clone",
                state: "Shutdown"
            )
            switch cloneMode {
            case .blocksAfterCreatingClone:
                try await Task.sleep(for: .seconds(30))
                return CommandResult(standardOutput: "\(testCloneUDID)\n")
            case .malformedCloneOutput:
                return CommandResult(standardOutput: "clone created without a UDID\n")
            case .sourceUUIDOnly:
                return CommandResult(standardOutput: "warning for source \(testSourceUDID)\n")
            case .uuidOnStandardError:
                return CommandResult(
                    standardOutput: "warning: clone output moved\n",
                    standardError: "created simulator (\(testCloneUDID))\n"
                )
            case .injectSourceSymlinkOnCloneBoot, .safe, .unsafeSourceSymlink:
                return CommandResult(standardOutput: "\(testCloneUDID)\n")
            }

        case "rename":
            guard arguments.count >= 3, var device = devices[arguments[1]] else {
                return CommandResult(termination: .exited(1))
            }
            device.name = arguments[2]
            devices[arguments[1]] = device
            return CommandResult()

        case "delete":
            guard arguments.count >= 2 else {
                return CommandResult(termination: .exited(1))
            }
            if let record = devices.removeValue(forKey: arguments[1]) {
                try? FileManager.default.removeItem(
                    atPath: (record.dataPath as NSString).deletingLastPathComponent
                )
            }
            deletedUnsafeClone = true
            return CommandResult()

        default:
            return CommandResult(
                standardError: "unexpected simctl command \(command)",
                termination: .exited(1)
            )
        }
    }

    private static func prepareCloneData(
        at cloneData: String,
        mode: CloneMode,
        root: String
    ) throws {
        try FileManager.default.createDirectory(
            atPath: testPath(cloneData, "Library"),
            withIntermediateDirectories: true
        )
        if mode == .unsafeSourceSymlink {
            let link = testPath(cloneData, "Library", "unexpected-source-link")
            if try fileStatus(at: link) == nil {
                try FileManager.default.createSymbolicLink(
                    atPath: link,
                    withDestinationPath: testPath(root, "Detached", testSourceUDID, "state")
                )
            }
        }
    }
}

private actor DelayedCloneCommandRunner: CommandRunning {
    enum FailureAfterCancellation: Sendable {
        case cloneShutdown
        case delete
    }

    let base: any CommandRunning
    let executable: String
    let failureAfterCancellation: FailureAfterCancellation?
    private var cancellationObserved = false

    init(
        base: any CommandRunning,
        executable: String,
        failureAfterCancellation: FailureAfterCancellation? = nil
    ) {
        self.base = base
        self.executable = executable
        self.failureAfterCancellation = failureAfterCancellation
    }

    func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        if invocation.executable == executable {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancellationObserved = true
                throw error
            }
        }
        if cancellationObserved, let failureAfterCancellation {
            switch failureAfterCancellation {
            case .cloneShutdown
                where invocation.arguments.contains("shutdown")
                    && invocation.arguments.contains(testCloneUDID):
                return CommandResult(
                    standardError: "injected clone shutdown failure",
                    termination: .exited(1)
                )
            case .delete where invocation.arguments.contains("delete"):
                return CommandResult(
                    standardError: "injected clone deletion failure",
                    termination: .exited(1)
                )
            default:
                break
            }
        }
        return try await base.run(invocation)
    }
}

private enum CloneTestError: Error {
    case failed
}

private func newTestCloneFilesystem() throws -> CloneFilesystem {
    let root = try makeTestDirectory()
    let sourceDeviceDirectory = testPath(root, "Devices", testSourceUDID)
    let cloneDeviceDirectory = testPath(root, "Devices", testCloneUDID)
    let sourceDataDirectory = testPath(sourceDeviceDirectory, "data")
    let cloneDataDirectory = testPath(cloneDeviceDirectory, "data")
    try FileManager.default.createDirectory(
        atPath: testPath(sourceDataDirectory, "Library"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        atPath: testPath(cloneDataDirectory, "Library"),
        withIntermediateDirectories: true
    )
    return CloneFilesystem(
        sourceUDID: testSourceUDID,
        cloneUDID: testCloneUDID,
        sourceDeviceDirectory: sourceDeviceDirectory,
        cloneDeviceDirectory: cloneDeviceDirectory,
        sourceDataDirectory: sourceDataDirectory,
        cloneDataDirectory: cloneDataDirectory,
        sourceLogDirectory: testPath(root, "Logs", testSourceUDID),
        cloneLogDirectory: testPath(root, "Logs", testCloneUDID)
    )
}

private func cloneTestRoot(_ paths: CloneFilesystem) -> String {
    ((paths.sourceDeviceDirectory as NSString).deletingLastPathComponent as NSString)
        .deletingLastPathComponent
}

private func writeCloneTestFile(_ target: String, contents: String) throws {
    try FileManager.default.createDirectory(
        atPath: (target as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    try Data(contents.utf8).write(to: URL(fileURLWithPath: target))
}

private func symlinkTarget(_ link: String) throws -> String {
    try FileManager.default.destinationOfSymbolicLink(atPath: link)
}
