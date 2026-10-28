// BackupTests.swift — hermetic tests for BackupManager (ditto ZIP backup lane).
// Swift Testing ONLY — XCTest discovery is broken on this toolchain (Xcode 27 beta,
// see AGENTS.md gotcha ledger). Swift Testing does not re-export Foundation, so
// `import Foundation` is required.
//
// Test-space Process usage is ditto-only (restore round-trips); zip creation and
// listing verification inside BackupManager itself are also ditto / unzip -l (system
// verbs, no extra permissions).

import Testing
import Foundation
@testable import AppUpdaterCore

// MARK: - Hermetic fixtures (synthetic .app bundles + roots under the process temp dir)

private func makeWorkspace() throws -> URL {
    let workspace = FileManager.default.temporaryDirectory
        .appendingPathComponent("appupdater-backuptests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    return workspace
}

/// Canonical URL for a (already-created) subfolder of `root`, derived by performing the
/// same enumeration the code under test does. URL arithmetic — including
/// `resolvingSymlinksInPath` — does NOT reproduce FileManager's directory-symlink
/// resolving enumeration (/var → /private/var under the system temp dir; the
/// scanner-lane gotcha), so only enumeration output is path-truth here.
private func canonicalFolderPath(of projected: URL, under root: URL) throws -> URL {
    let entries = try FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil, options: [])
    let entry = try #require(entries.first { $0.lastPathComponent == projected.lastPathComponent })
    var path = entry.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") {
        path.removeLast()
    }
    return URL(fileURLWithPath: path, isDirectory: true)
}

private struct Fixture {
    var app: InstalledApp
    var appURL: URL
    var infoBytes: Data
    var stubBytes: Data
}

/// Builds a standard synthetic app: `Contents/Info.plist` (XML) + `Contents/MacOS/stub`.
private func writeFixtureApp(
    in root: URL,
    name: String = "Fixture.app",
    bundleIdentifier: String = "io.appupdater.fixture",
    shortVersion: String? = "1.2.3",
    bundleVersion: String? = "456"
) throws -> Fixture {
    let appURL = root.appendingPathComponent(name)
    let contentsURL = appURL.appendingPathComponent("Contents")
    let macosURL = contentsURL.appendingPathComponent("MacOS")
    try FileManager.default.createDirectory(at: macosURL, withIntermediateDirectories: true)

    var plist: [String: Any] = [
        "CFBundleIdentifier": bundleIdentifier,
        "CFBundleName": "Fixture",
    ]
    if let shortVersion { plist["CFBundleShortVersionString"] = shortVersion }
    if let bundleVersion { plist["CFBundleVersion"] = bundleVersion }
    let infoData = try PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0)
    let infoURL = contentsURL.appendingPathComponent("Info.plist")
    try infoData.write(to: infoURL)

    let stubData = Data("#!/bin/sh\necho fixture stub\n".utf8)
    try stubData.write(to: macosURL.appendingPathComponent("stub"))

    let app = InstalledApp(
        bundleIdentifier: bundleIdentifier,
        name: "Fixture",
        path: appURL.path(percentEncoded: false))
    let infoBytesOnDisk = try Data(contentsOf: infoURL)
    return Fixture(app: app, appURL: appURL, infoBytes: infoBytesOnDisk, stubBytes: stubData)
}

/// Test-side ditto extraction (round-trip proof). Nothing but ditto is spawned here.
private func extractZip(_ zipURL: URL, into destination: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = [
        "-x", "-k",
        zipURL.path(percentEncoded: false),
        destination.path(percentEncoded: false),
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(
            .fileReadUnknown,
            userInfo: [NSLocalizedDescriptionKey: "ditto -x -k failed for \(zipURL.path)"])
    }
}

private func fileSize(at url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    return (attributes[.size] as? NSNumber)?.int64Value ?? 0
}

/// Reads a named extended attribute, or nil when absent (size-0 probe then full read via
/// Darwin getxattr — the same attribute the TM exclusion writes).
private func readXattr(_ name: String, at url: URL) throws -> Data? {
    let path = url.path(percentEncoded: false)
    return try path.withCString { cPath in
        try name.withCString { cName in
            let size = getxattr(cPath, cName, nil, 0, 0, 0)
            guard size > 0 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                getxattr(cPath, cName, raw.baseAddress, size, 0, 0)
            }
            guard read >= 0 else {
                throw CocoaError(.fileReadUnknown, userInfo: [
                    NSLocalizedDescriptionKey: "getxattr failed for \(name) on \(path)",
                ])
            }
            return data
        }
    }
}

// MARK: - Tests

@Suite struct BackupTests {

    // (1) Happy backup: real zip on disk, receipt fields mirror the disk truth.
    @Test func backupProducesVerifiedZipAndReceipt() async throws {
        let workspace = try makeWorkspace()
        let backupsRoot = workspace.appendingPathComponent("Backups", isDirectory: true)
        let fixture = try writeFixtureApp(in: workspace.appendingPathComponent("Apps"))

        let receipt = try await BackupManager().backup(app: fixture.app, into: backupsRoot)

        // Zip lands at the documented position — derived naming from the receipt's own
        // creation time (same-Date comparison, so no clock race in the assertion).
        let expectedURL = BackupManager.zipPath(in: backupsRoot, app: fixture.app, for: receipt.createdAt)
        #expect(receipt.zipURL == expectedURL)
        #expect(FileManager.default.fileExists(atPath: receipt.zipURL.path(percentEncoded: false)))
        #expect(receipt.byteCount > 0)
        let onDiskSize = try fileSize(at: receipt.zipURL)
        #expect(receipt.byteCount == onDiskSize)

        // Receipt fields: original path as given, versions read fresh from Info.plist.
        #expect(receipt.originalPath == fixture.app.path)
        #expect(receipt.originalShortVersion == "1.2.3")
        #expect(receipt.originalBundleVersion == "456")
        #expect(abs(receipt.createdAt.timeIntervalSinceNow) < 5)
    }

    // (2) Restore round-trip: ditto -x -k reproduces the bundle byte-for-byte.
    @Test func zipRoundTripsBundleContents() async throws {
        let workspace = try makeWorkspace()
        let backupsRoot = workspace.appendingPathComponent("Backups", isDirectory: true)
        let fixture = try writeFixtureApp(in: workspace.appendingPathComponent("Apps"))

        let receipt = try await BackupManager().backup(app: fixture.app, into: backupsRoot)

        let restoreRoot = workspace.appendingPathComponent("Restored", isDirectory: true)
        try FileManager.default.createDirectory(at: restoreRoot, withIntermediateDirectories: true)
        try extractZip(receipt.zipURL, into: restoreRoot)

        let restoredBundle = restoreRoot.appendingPathComponent(fixture.appURL.lastPathComponent)
        let restoredInfo = try Data(contentsOf:
            restoredBundle.appendingPathComponent("Contents/Info.plist"))
        let restoredStub = try Data(contentsOf:
            restoredBundle.appendingPathComponent("Contents/MacOS/stub"))
        // REAL integrity proof: restored Info.plist bytes equal the original bytes.
        #expect(restoredInfo == fixture.infoBytes)
        #expect(restoredStub == fixture.stubBytes)
    }

    // (3) Same-second collision: a second backup appends ` -2` and never overwrites.
    @Test func sameSecondCollisionAppendsSuffixInsteadOfOverwriting() async throws {
        let workspace = try makeWorkspace()
        let backupsRoot = workspace.appendingPathComponent("Backups", isDirectory: true)
        let fixture = try writeFixtureApp(in: workspace.appendingPathComponent("Apps"))
        let forced = Date(timeIntervalSince1970: 1761478200)

        // Pre-occupy the name the backup would take (same-second "prior run").
        let occupied = BackupManager.zipPath(in: backupsRoot, app: fixture.app, for: forced)
        try FileManager.default.createDirectory(
            at: occupied.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("preexisting sentinel".utf8).write(to: occupied)

        let receipt = try await BackupManager().backup(app: fixture.app, into: backupsRoot, at: forced)

        // New zip got the determinstic ` -2` name beside the occupied one.
        let expectedName = String(occupied.lastPathComponent.dropLast(".zip".count)) + " -2.zip"
        #expect(receipt.zipURL.lastPathComponent == expectedName)
        #expect(FileManager.default.fileExists(atPath: receipt.zipURL.path(percentEncoded: false)))
        // The original zip was not overwritten.
        #expect(try Data(contentsOf: occupied) == Data("preexisting sentinel".utf8))
    }

    // (4) Retention: oldest-by-filename-token beyond n are deleted, newest kept —
    //     across folders, with foreign files untouched. mtime is never consulted:
    //     Drop1 carries the NEWEST mtime yet is still deleted.
    @Test func keepLatestDeletesOldestByFilenameTimestamp() async throws {
        let workspace = try makeWorkspace()
        let backupsRoot = workspace.appendingPathComponent("Backups", isDirectory: true)
        let folderAProjected = backupsRoot.appendingPathComponent("com.a_test", isDirectory: true)
        let folderBProjected = backupsRoot.appendingPathComponent("com.b_test", isDirectory: true)
        try FileManager.default.createDirectory(at: folderAProjected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderBProjected, withIntermediateDirectories: true)
        // Expectations are built on enumeration-canonical paths (see helper doc above),
        // because keepLatest returns paths derived from enumeration entries.
        let folderA = try canonicalFolderPath(of: folderAProjected, under: backupsRoot)
        let folderB = try canonicalFolderPath(of: folderBProjected, under: backupsRoot)

        let bytes = Data("zip placeholder — retention orders by name, not content".utf8)
        let keep1 = folderA.appendingPathComponent("2026-10-25T120000Z-Keep1.app.zip")
        let keep2 = folderA.appendingPathComponent("2026-10-24T110000Z-Keep2.app.zip")
        let drop1 = folderA.appendingPathComponent("2026-10-22T100000Z-Drop1.app.zip")
        let drop2 = folderB.appendingPathComponent("2026-10-23T090000Z-Drop2.app.zip")
        let foreign = folderA.appendingPathComponent("stale-not-a-managed-name.zip")
        for url in [keep1, keep2, drop1, drop2, foreign] { try bytes.write(to: url) }

        // Adversarial mtime: newest-on-disk, yet oldest by the token in its name.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1795000000)],
            ofItemAtPath: drop1.path(percentEncoded: false))

        // Root-level managed-looking file: outside any per-app folder, never touched.
        let rootLevel = backupsRoot.appendingPathComponent("2026-10-21T120000Z-RootLevel.app.zip")
        try bytes.write(to: rootLevel)

        let deleted = try await BackupManager().keepLatest(2, in: backupsRoot)

        // Combined pool (newest first by token): Keep1, Keep2 | excess tail: Drop2, Drop1.
        #expect(deleted == [
            drop2.path(percentEncoded: false),
            drop1.path(percentEncoded: false),
        ])
        #expect(!FileManager.default.fileExists(atPath: drop1.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: drop2.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: keep1.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: keep2.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: foreign.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: rootLevel.path(percentEncoded: false)))
    }

    // (5) Failure honesty: nonexistent app bundle → backupFailed with tool detail.
    @Test func missingAppBundleFailsWithDittoDetail() async throws {
        let workspace = try makeWorkspace()
        let backupsRoot = workspace.appendingPathComponent("Backups", isDirectory: true)
        let ghostPath = workspace.appendingPathComponent("Ghost.app").path(percentEncoded: false)
        let ghost = InstalledApp(
            bundleIdentifier: "io.appupdater.ghost", name: "Ghost", path: ghostPath)

        do {
            _ = try await BackupManager().backup(app: ghost, into: backupsRoot)
            Issue.record("backup() should fail for a nonexistent app bundle")
        } catch {
            guard case let InstallerError.backupFailed(reason) = error else {
                Issue.record("expected InstallerError.backupFailed, got: \(error)")
                return
            }
            // The reason must carry the tool's own diagnostic (and the offending path).
            #expect(reason.contains("ditto"))
            #expect(reason.contains(ghostPath))
            // Nothing fake was left behind: no zip, no folder for this bundle id.
            #expect(!FileManager.default.fileExists(
                atPath: backupsRoot
                    .appendingPathComponent("io.appupdater.ghost")
                    .path(percentEncoded: false)))
        }
    }

    // (6) Bundle-id escaping: `/` and `:` are escaped, one flat folder per app.
    @Test func sanitizedBundleIdDrivesPerAppFolders() async throws {
        let workspace = try makeWorkspace()
        let backupsRoot = workspace.appendingPathComponent("Backups", isDirectory: true)
        let fancy = try writeFixtureApp(
            in: workspace.appendingPathComponent("AppsA"),
            bundleIdentifier: "io.appupdater.fancy/one:two")
        let plain = try writeFixtureApp(
            in: workspace.appendingPathComponent("AppsB"),
            name: "Plain.app",
            bundleIdentifier: "io.appupdater.plain")
        let date1 = Date(timeIntervalSince1970: 1761478200) // distinct fixed instants
        let date2 = Date(timeIntervalSince1970: 1761481800)

        let receiptFancy = try await BackupManager().backup(app: fancy.app, into: backupsRoot, at: date1)
        let receiptPlain = try await BackupManager().backup(app: plain.app, into: backupsRoot, at: date2)

        let fancyFolder = backupsRoot.appendingPathComponent("io.appupdater.fancy_one_two")
        let plainFolder = backupsRoot.appendingPathComponent("io.appupdater.plain")
        #expect(receiptFancy.zipURL.deletingLastPathComponent() == fancyFolder)
        #expect(receiptPlain.zipURL.deletingLastPathComponent() == plainFolder)
        #expect(FileManager.default.fileExists(atPath: fancyFolder.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: plainFolder.path(percentEncoded: false)))
        // Each per-app folder holds exactly one managed zip.
        for folder in [fancyFolder, plainFolder] {
            let zips = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "zip" }
            #expect(zips.count == 1)
        }
    }

    // (7) Restore hint: documentation-level string with quit-first + the ditto command.
    @Test func restoreHintMentionsQuitAndExtractionCommand() throws {
        let hint = BackupManager().restoreHint(for: BackupReceipt(
            zipURL: URL(fileURLWithPath: "/Users/me/OldAppBackups/FooApp/2026-10-26T103000Z-Foo.app.zip"),
            originalPath: "/Applications/Foo.app",
            originalShortVersion: "1.0",
            originalBundleVersion: "1",
            createdAt: Date(timeIntervalSince1970: 1761478200),
            byteCount: 123))
        #expect(hint.contains("quit \"Foo.app\""))
        #expect(hint.contains("ditto -x -k"))
        #expect(hint.contains("2026-10-26T103000Z-Foo.app.zip"))
        #expect(hint.contains("/Applications"))
    }

    // MARK: - Time Machine awareness (lane delta-backup)

    // (8) TM destination: backup is NEVER skipped — zip verifies as usual, the exclusion
    //     attribute is really applied to the zip, and the note states both honestly.
    @Test func timeMachineDestinationAdjustsZipAndRecordsNote() async throws {
        let workspace = try makeWorkspace()
        let backupsRoot = workspace.appendingPathComponent("Backups", isDirectory: true)
        let fixture = try writeFixtureApp(in: workspace.appendingPathComponent("Apps"))
        let manager = BackupManager(timeMachineProbe: { _ in .timeMachineDestination })

        let outcome = try await manager.backupWithNote(app: fixture.app, into: backupsRoot)

        // The pre-swap artifact exists and is verified — TM awareness never skips it.
        #expect(FileManager.default.fileExists(atPath: outcome.receipt.zipURL.path(percentEncoded: false)))
        #expect(outcome.receipt.byteCount > 0)
        #expect(try fileSize(at: outcome.receipt.zipURL) == outcome.receipt.byteCount)

        // The adjustment is REAL on disk: the documented TM exclusion attribute is on the zip.
        let xattr = try readXattr(BackupManager.timeMachineExclusionXattr, at: outcome.receipt.zipURL)
        #expect(xattr == Data(BackupManager.timeMachineExclusionValue.utf8))

        // The note reports what was detected and what was done — no invented certainty.
        let note = try #require(outcome.timeMachineNote)
        #expect(note.contains("Time Machine backup volume"))
        #expect(note.contains("marked excluded from Time Machine"))
        #expect(note.contains(BackupManager.timeMachineExclusionXattr))
    }

    // (9) Destination inside a TM store: still backs up (never fails), stronger relocation
    //     advice in the note, exclusion attribute applied best-effort.
    @Test func insideTimeMachineStoreStillBacksUpWithRelocationAdvice() async throws {
        let workspace = try makeWorkspace()
        let backupsRoot = workspace.appendingPathComponent("Backups", isDirectory: true)
        let fixture = try writeFixtureApp(in: workspace.appendingPathComponent("Apps"))
        let manager = BackupManager(timeMachineProbe: { _ in .insideTimeMachineStore })

        let outcome = try await manager.backupWithNote(app: fixture.app, into: backupsRoot)

        #expect(FileManager.default.fileExists(atPath: outcome.receipt.zipURL.path(percentEncoded: false)))
        let note = try #require(outcome.timeMachineNote)
        #expect(note.contains("sits inside a Time Machine backup store"))
        #expect(note.contains("relocating the backups root"))
        let xattr = try readXattr(BackupManager.timeMachineExclusionXattr, at: outcome.receipt.zipURL)
        #expect(xattr != nil)
    }

    // (10) Non-TM destination via the DEFAULT probe: no note, no exclusion attribute —
    //      pre-TM-aware behavior is byte-identical (no side effects at all).
    @Test func nonTimeMachineDestinationKeepsOldBehavior() async throws {
        let workspace = try makeWorkspace()
        let backupsRoot = workspace.appendingPathComponent("Backups", isDirectory: true)
        let fixture = try writeFixtureApp(in: workspace.appendingPathComponent("Apps"))

        // The default probe on a boot-volume temp path decides without any TM markers.
        #expect(BackupManager.defaultTimeMachineProbe(for: backupsRoot) == .notTimeMachine)

        let outcome = try await BackupManager().backupWithNote(app: fixture.app, into: backupsRoot)

        #expect(outcome.timeMachineNote == nil)
        let xattr = try readXattr(BackupManager.timeMachineExclusionXattr, at: outcome.receipt.zipURL)
        #expect(xattr == nil)
        // The plain backup(app:into:) surface still works and returns just the receipt.
        let receipt = try await BackupManager().backup(app: fixture.app, into: backupsRoot, at: Date(timeIntervalSince1970: 1761478300))
        #expect(receipt.byteCount > 0)
    }

    // (11) Indeterminate probe (.unknown): claims nothing, records nothing, never fails.
    @Test func unknownProbeRecordsNothingAndNeverFails() async throws {
        let workspace = try makeWorkspace()
        let backupsRoot = workspace.appendingPathComponent("Backups", isDirectory: true)
        let fixture = try writeFixtureApp(in: workspace.appendingPathComponent("Apps"))
        let manager = BackupManager(timeMachineProbe: { _ in .unknown })

        let outcome = try await manager.backupWithNote(app: fixture.app, into: backupsRoot)

        #expect(outcome.timeMachineNote == nil)  // no guess masquerading as honesty
        #expect(FileManager.default.fileExists(atPath: outcome.receipt.zipURL.path(percentEncoded: false)))
        let xattr = try readXattr(BackupManager.timeMachineExclusionXattr, at: outcome.receipt.zipURL)
        #expect(xattr == nil)
    }

    // (12) Default probe semantics: store-component detection is pure path analysis (no
    //      filesystem access needed); a nonexistent /Volumes root honestly reports unknown.
    @Test func defaultProbeFlagsStoreComponentsAndUnknownRoots() {
        // TM1 store directory in the path — decided by components alone.
        #expect(BackupManager.defaultTimeMachineProbe(
            for: URL(fileURLWithPath: "/Volumes/Store/Backups.backupdb/mac/2026-01-01"))
            == .insideTimeMachineStore)
        // Modern per-machine APFS TM store wrapper (.backupbundle component).
        #expect(BackupManager.defaultTimeMachineProbe(
            for: URL(fileURLWithPath: "/Volumes/Store/A1B2C3.backupbundle/backups"))
            == .insideTimeMachineStore)
        // Boot-volume path (no Volumes prefix, no markers) — cannot be a TM destination.
        #expect(BackupManager.defaultTimeMachineProbe(
            for: URL(fileURLWithPath: "/tmp/appupdater-normal/Backups")) == .notTimeMachine)
        // /Volumes root that does not exist: enumeration fails ⇒ honest .unknown, no guess.
        #expect(BackupManager.defaultTimeMachineProbe(
            for: URL(fileURLWithPath: "/Volumes/DefinitelyNotAVolume/backups")) == .unknown)
    }
}
