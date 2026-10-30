import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("CheckCacheStore — last verdicts survive relaunch, never stale")
struct CheckCacheStoreTests {

    private static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("appupdater-checkcache-\(UUID().uuidString)")

    private func freshDirectory() -> URL {
        Self.root.appendingPathComponent(UUID().uuidString)
    }

    private func app(_ id: String, version: String, checkedAt: Date? = nil) -> InstalledApp {
        InstalledApp(bundleIdentifier: id, name: id, path: "/Applications/\(id).app",
                     shortVersion: version, bundleVersion: version, checkedAt: checkedAt)
    }

    @Test func missingFileLoadsNil() {
        #expect(CheckCacheStore(directory: freshDirectory()).load() == nil)
    }

    @Test func roundTripPreservesChecksAndCheckedAt() throws {
        let store = CheckCacheStore(directory: freshDirectory())
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let apps = [app("a", version: "1.0", checkedAt: stamp), app("b", version: "2.0", checkedAt: stamp)]
        let checks = apps.map { UpdateCheck(app: $0, candidates: [], resolved: nil) }
        try store.save(apps: apps, checks: checks, now: stamp)
        let loaded = try #require(store.load())
        #expect(loaded.apps == apps)
        #expect(loaded.checks == checks)
        #expect(loaded.savedAt == stamp)
        #expect(loaded.checks.first?.app.checkedAt == stamp)
    }

    @Test func garbageAndOtherSchemaLoadNil() throws {
        let directory = freshDirectory()
        let store = CheckCacheStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.fileURL)
        #expect(store.load() == nil)
        let other = #"{"schemaVersion":99,"savedAt":"2026-10-30T00:00:00Z","apps":[],"checks":[]}"#
        try Data(other.utf8).write(to: store.fileURL)
        #expect(store.load() == nil)
    }

    @Test func misalignedPairIsRefusedAndPreviousFileKept() throws {
        let store = CheckCacheStore(directory: freshDirectory())
        let apps = [app("a", version: "1.0")]
        try store.save(apps: apps, checks: apps.map { UpdateCheck(app: $0, candidates: [], resolved: nil) })
        #expect(throws: CheckCacheStore.CacheError.misaligned(apps: 1, checks: 0)) {
            try store.save(apps: apps, checks: [])
        }
        #expect(store.load()?.apps == apps)
    }

    /// The restore contract: cached verdicts pass through CheckCarryOver
    /// against a fresh scan, so a self-updated app loses its stale verdict.
    @Test func restoredChecksDropForChangedApps() throws {
        let store = CheckCacheStore(directory: freshDirectory())
        let apps = [app("kept", version: "1.0"), app("updated", version: "1.0")]
        try store.save(apps: apps, checks: apps.map { UpdateCheck(app: $0, candidates: [], resolved: nil) })
        let loaded = try #require(store.load())
        let fresh = [app("kept", version: "1.0"), app("updated", version: "1.1")]
        let carried = CheckCarryOver.carry(previousChecks: loaded.checks, previousApps: loaded.apps, newApps: fresh)
        #expect(carried[0] != nil)
        #expect(carried[1] == nil)
    }
}
