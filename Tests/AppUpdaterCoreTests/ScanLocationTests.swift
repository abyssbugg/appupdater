// ScanLocationTests.swift — gap #18 lane (custom scan locations): hermetic
// Swift Testing coverage of Scan/ScanLocations.swift's documented contract —
// persistence round-trips, the add-refusal ladder (incl. the /Applications
// guard verbatim), remove semantics, resolvedRoots honesty (vanished dirs
// stay listed with url nil), the tolerated-nil-bookmark warning cycle, the
// clean never-auto-delete throw on corrupt JSON, and a scan plug-in smoke.
// Unique temp root per test; one read-only stat in the guard test is the only
// /Applications contact, never the real Application Support tree, no network
// volumes. XCTest collects 0 tests here (gotcha ledger); Swift Testing does
// not re-export Foundation, hence the explicit import.

import Foundation
import Testing
@testable import AppUpdaterCore

// MARK: - Hermetic fixtures

/// Unique temp root per TEST call, UUID-scoped so concurrent runners never share it.
private func makeRoot(_ leaf: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("appupdater-scanlocations-\(leaf)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Canonical POSIX spelling that must byte-match the store's dedupe identity
/// (resolvingSymlinksInPath + trailing-slash strip) — mirrored rather than
/// shared (RuleStoreTests pattern): the test asserts the PERSISTED contract.
private func canonical(_ url: URL) -> String {
    var path = url.resolvingSymlinksInPath().path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") {
        path.removeLast()
    }
    return path
}

/// Writes one minimal real `.app` bundle (Contents/Info.plist) and returns its URL.
@discardableResult
private func writeAppBundle(in root: URL, baseName: String, bundleID: String) throws -> URL {
    let appURL = root.appendingPathComponent(baseName + ".app")
    let contents = appURL.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plistData = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleName": baseName, "CFBundleIdentifier": bundleID],
        format: .xml, options: 0)
    try plistData.write(to: contents.appendingPathComponent("Info.plist"))
    return appURL
}

/// Bookmark double: refuses the FIRST request, then defers to the system
/// producer — the only deterministic way to drive the tolerated-nil branch.
private final class FailingOnceBookmarkProducer: @unchecked Sendable {
    private var outstanding = 1

    func data(for url: URL) throws -> Data? {
        if outstanding > 0 {
            outstanding -= 1
            throw ScanLocationError(
                reason: "test bookmark producer failing-once: bookmark creation refused by the double")
        }
        return try ScanLocationStore.systemBookmarkData(for: url)
    }
}

// MARK: - Tests

@Suite struct ScanLocationTests {

    // MARK: (1) Persistence — round-trip across store instances

    @Test func persistenceRoundTripsAcrossStoreInstancesSorted() throws {
        let root = try makeRoot("roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let dirA = root.appendingPathComponent("AAA", isDirectory: true)
        let dirB = root.appendingPathComponent("BBB", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)

        let storeDir = root.appendingPathComponent("Store", isDirectory: true)
        let store = ScanLocationStore(directory: storeDir)

        // Lazy-create honesty: reading a virgin store creates nothing on disk.
        #expect(try store.locations().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: storeDir.path(percentEncoded: false)))

        // Added OUT of canonical order — the file must store the sorted set.
        try store.add(dirB)
        try store.add(dirA)

        let persistedURLs = try store.locations().map(\.canonicalPath)
        #expect(persistedURLs == [canonical(dirA), canonical(dirB)])

        // A fresh store instance over the SAME directory reads the same records.
        let reopened = ScanLocationStore(directory: storeDir)
        #expect(try reopened.locations().count == 2)
        let first = try reopened.locations().first
        #expect(first?.canonicalPath == canonical(dirA))
        #expect(first?.bookmarkData != nil)   // the system producer succeeds for local dirs
        let locallySeen = try store.locations().first
        #expect(locallySeen == first)
        #expect(locallySeen?.addedAt == first?.addedAt)
    }

    // MARK: (2) add refusals

    @Test func addRefusesMissingPath() throws {
        let root = try makeRoot("missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScanLocationStore(
            directory: root.appendingPathComponent("Store", isDirectory: true))
        let ghost = root.appendingPathComponent("gone-\(UUID().uuidString)", isDirectory: true)

        do {
            try store.add(ghost)
            Issue.record("adding a nonexistent root must be refused")
        } catch let thrown as ScanLocationError {
            #expect(thrown.reason.contains("could not be found on this Mac"))
            #expect(thrown.reason.contains(ghost.path(percentEncoded: false)))
        }
        #expect(!FileManager.default.fileExists(atPath: storeDirPath(store)))
    }

    @Test func addRefusesPlainFileNotDirectory() throws {
        let root = try makeRoot("plainfile")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScanLocationStore(
            directory: root.appendingPathComponent("Store", isDirectory: true))
        let file = root.appendingPathComponent("Notes.txt")
        try Data("notes".utf8).write(to: file)

        do {
            try store.add(file)
            Issue.record("adding a plain file must be refused")
        } catch let thrown as ScanLocationError {
            #expect(thrown.reason.contains("is not a folder"))
            #expect(thrown.reason.contains(file.path(percentEncoded: false)))
        }
    }

    @Test func addRefusesDuplicateExactPath() throws {
        let root = try makeRoot("duplicate")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScanLocationStore(
            directory: root.appendingPathComponent("Store", isDirectory: true))
        let dir = root.appendingPathComponent("Apps", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try store.add(dir)
        do {
            try store.add(dir)
            Issue.record("adding the same canonical root twice must be refused")
        } catch let thrown as ScanLocationError {
            #expect(thrown.reason.contains("already added"))
            #expect(thrown.reason.contains(canonical(dir)))
        }
        #expect(try store.locations().count == 1)   // refusal left disk state untouched
    }

    @Test func addRefusesSymlinkedDuplicateFromBothDirections() throws {
        let root = try makeRoot("symlinkdup")
        defer { try? FileManager.default.removeItem(at: root) }
        let realDir = root.appendingPathComponent("Real", isDirectory: true)
        let aliasDir = root.appendingPathComponent("Alias", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: aliasDir, withDestinationURL: realDir)

        // Direction 1: alias added first, real second → same canonical folder.
        let storeAliasFirst = ScanLocationStore(
            directory: root.appendingPathComponent("StoreA", isDirectory: true))
        try storeAliasFirst.add(aliasDir)
        #expect(try storeAliasFirst.locations().map(\.canonicalPath) == [canonical(realDir)])
        do {
            try storeAliasFirst.add(realDir)
            Issue.record("adding the target of an added symlink must be refused")
        } catch let thrown as ScanLocationError {
            #expect(thrown.reason.contains("already added"))
        }

        // Direction 2 (fresh dir): real first, alias second → same refusal.
        let storeRealFirst = ScanLocationStore(
            directory: root.appendingPathComponent("StoreB", isDirectory: true))
        try storeRealFirst.add(realDir)
        do {
            try storeRealFirst.add(aliasDir)
            Issue.record("adding a symlink onto an added folder must be refused")
        } catch let thrown as ScanLocationError {
            #expect(thrown.reason.contains("already added"))
        }
        #expect(try storeRealFirst.locations().map(\.canonicalPath) == [canonical(realDir)])
    }

    @Test func addRefusesApplicationsWithVerbatimGuard() throws {
        let root = try makeRoot("appsguard")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScanLocationStore(
            directory: root.appendingPathComponent("Store", isDirectory: true))

        do {
            try store.add(URL(fileURLWithPath: "/Applications"))
            Issue.record("adding /Applications must be refused")
        } catch let thrown as ScanLocationError {
            #expect(thrown.reason.contains(
                "the default /Applications root is always scanned and cannot also be a custom location"))
        }
        #expect(try store.locations().isEmpty)   // guard refused → nothing persisted
    }

    // MARK: (3) remove

    @Test func removeUnknownIdThrowsNamingTheId() throws {
        let root = try makeRoot("removeunknown")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScanLocationStore(
            directory: root.appendingPathComponent("Store", isDirectory: true))
        let unknownID = "/definitely/not/a/known/location/\(UUID().uuidString)"

        do {
            try store.remove(id: unknownID)
            Issue.record("removing an unknown id must be refused")
        } catch let thrown as ScanLocationError {
            #expect(thrown.reason.contains("no custom location with that id"))
            #expect(thrown.reason.contains(unknownID))
        }
    }

    @Test func removeExistingWorksAndPersistsAcrossInstances() throws {
        let root = try makeRoot("removeexisting")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeDir = root.appendingPathComponent("Store", isDirectory: true)
        let store = ScanLocationStore(directory: storeDir)
        let dir = root.appendingPathComponent("Apps", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try store.add(dir)
        try store.remove(id: canonical(dir))

        #expect(try store.locations().isEmpty)
        let reopened = ScanLocationStore(directory: storeDir)
        #expect(try reopened.locations().isEmpty)   // removal persisted, not memory-only
    }

    // MARK: (4) resolvedRoots honesty

    @Test func resolvedRootsResolvesExistingDir() throws {
        let root = try makeRoot("resolveexisting")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScanLocationStore(
            directory: root.appendingPathComponent("Store", isDirectory: true))
        let dir = root.appendingPathComponent("Apps", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try store.add(dir)
        let roots = try store.resolvedRoots()
        #expect(roots.count == 1)
        let resolved = roots.first?.url
        #expect(resolved != nil)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(
            atPath: resolved?.path(percentEncoded: false) ?? "/", isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(roots.first?.location.canonicalPath == canonical(dir))
    }

    @Test func resolvedRootsKeepsVanishedDirListedWithNilURL() throws {
        let root = try makeRoot("vanished")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeDir = root.appendingPathComponent("Store", isDirectory: true)
        let store = ScanLocationStore(directory: storeDir)
        let dir = root.appendingPathComponent("Ephemeral", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try store.add(dir)
        try FileManager.default.removeItem(at: dir)   // the folder vanishes behind the store

        let roots = try store.resolvedRoots()
        #expect(roots.count == 1)                     // still listed — vanish is displayed
        #expect(roots.first?.url == nil)              // honest nil: UI renders the missing dot
        #expect(roots.first?.location.canonicalPath == canonical(dir))

        let reopened = ScanLocationStore(directory: storeDir)
        let reopenedRoots = try reopened.resolvedRoots()
        #expect(reopenedRoots.count == 1)             // disappearance persists as a listing
        #expect(reopenedRoots.first?.url == nil)
    }

    // MARK: (5) tolerated nil bookmark + corrupt file honesty

    @Test func bookmarkFailureToleratedThenWarningClearedOnNextSuccess() throws {
        let root = try makeRoot("bookmarknil")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeDir = root.appendingPathComponent("Store", isDirectory: true)
        let producer = FailingOnceBookmarkProducer()
        let store = ScanLocationStore(
            directory: storeDir,
            bookmarkDataForURL: { try producer.data(for: $0) })
        let dirA = root.appendingPathComponent("Alpha", isDirectory: true)
        let dirB = root.appendingPathComponent("Beta", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)

        // First add: bookmark creation fails → TOLERATED, location persists.
        try store.add(dirA)
        let locations = try store.locations()
        #expect(locations.count == 1)
        #expect(locations.first?.canonicalPath == canonical(dirA))
        #expect(locations.first?.bookmarkData == nil)
        let warning = store.lastBookmarkWarning
        #expect(warning?.contains("test bookmark producer failing-once") == true)
        #expect(warning?.contains("still added") == true)
        #expect(warning?.contains("canonical path") == true)

        // Even with a nil bookmark the folder still resolves (canonical-path fallback).
        #expect(try store.resolvedRoots().first?.url != nil)

        // Second add: bookmark succeeds → warning cleared, record carries it.
        try store.add(dirB)
        #expect(store.lastBookmarkWarning == nil)
        let both = try store.locations()
        #expect(both.count == 2)
        #expect(Set(both.compactMap(\.bookmarkData)).count == 1)   // only Beta got a bookmark

        // Warnings are instance-local: a fresh store starts warning-free.
        let reopened = ScanLocationStore(directory: storeDir)
        #expect(reopened.lastBookmarkWarning == nil)
        #expect(try reopened.locations() == both)
    }

    @Test func locationsThrowsCleanTextOnCorruptFileAndNeverTouchesIt() throws {
        let root = try makeRoot("corrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeDir = root.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let fileURL = storeDir.appendingPathComponent("scan_locations.json")
        let garbage = Data("not json {{{ \u{1}\u{2} refuse to parse".utf8)
        try garbage.write(to: fileURL)

        let store = ScanLocationStore(directory: storeDir)
        do {
            _ = try store.locations()
            Issue.record("a corrupt scan_locations.json must throw, not fake empty state")
        } catch let thrown as ScanLocationError {
            #expect(thrown.reason.contains("scan_locations.json could not be read"))
            #expect(thrown.reason.contains("has not been modified or deleted"))
        }

        // The never-auto-delete promise: the garbage bytes survive untouched.
        #expect((try? Data(contentsOf: fileURL)) == garbage)

        // Unsupported schema version is the same clean-text contract.
        let future = storeDir.appendingPathComponent("scan_locations.json")
        try Data(#"""
        {"schemaVersion": 99, "locations": []}
        """#.utf8).write(to: future)
        let futureStore = ScanLocationStore(directory: storeDir)
        do {
            _ = try futureStore.locations()
            Issue.record("an unsupported schemaVersion must be refused honestly")
        } catch let thrown as ScanLocationError {
            #expect(thrown.reason.contains("scan_locations.json could not be read"))
        }
    }

    // MARK: (6) scan integration — the store plugs into the frozen contract

    @Test func scannerInventoriesFixtureAndCustomStoreRoots() async throws {
        let root = try makeRoot("scanplug")
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtureRoot = root.appendingPathComponent("ApplicationsFixture", isDirectory: true)
        let customRoot = root.appendingPathComponent("Custom", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: customRoot, withIntermediateDirectories: true)
        try writeAppBundle(in: fixtureRoot, baseName: "Alpha", bundleID: "com.fixture.alpha")
        try writeAppBundle(in: fixtureRoot, baseName: "Beta", bundleID: "com.fixture.beta")
        try writeAppBundle(in: customRoot, baseName: "Gamma", bundleID: "com.custom.gamma")

        let store = ScanLocationStore(
            directory: root.appendingPathComponent("Store", isDirectory: true))
        try store.add(customRoot)

        let roots = try store.resolvedRoots()
        #expect(roots.count == 1)
        let customURL = roots.first?.url
        #expect(customURL != nil)

        // The exact production composition: default-list fixture + custom root.
        let apps = try await ProductionAppScanner().scan(
            directoryURLs: [fixtureRoot, customURL ?? root])
        #expect(apps.count == 3)
        #expect(apps.map(\.name) == ["Alpha", "Beta", "Gamma"])
        #expect(Set(apps.map(\.bundleIdentifier)) == Set(["com.fixture.alpha", "com.fixture.beta", "com.custom.gamma"]))
    }
}

/// Store persistence path via the public `directory` surface — used to assert
/// the laziness promise (nothing on disk until the first save).
private func storeDirPath(_ store: ScanLocationStore) -> String {
    store.directory.path(percentEncoded: false)
}
