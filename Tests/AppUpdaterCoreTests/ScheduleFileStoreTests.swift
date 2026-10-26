// ScheduleFileStoreTests — coordinator (Phase-4 merge): schedule.json
// persistence honesty. Swift Testing only (XCTest discovery broken here).
// Hermetic: directory-injected store over a per-PROCESS unique temp root
// (the Phase-4 cross-process flake fix — see AGENTS.md gotcha ledger; no
// fixed shared names, ever).

import Foundation
import Testing
@testable import AppUpdaterCore

@Suite(.serialized)
struct ScheduleFileStoreTests {

    private static let processRoot: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "appupdater-schedulestore-\(UUID().uuidString)", isDirectory: true)

    private var root: URL

    init() {
        // Each test gets its own fresh subdirectory — no wipes, no shared
        // fixed names (the flake rule).
        root = Self.processRoot.appendingPathComponent(
            "test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func store() -> ScheduleFileStore { ScheduleFileStore(directory: root) }

    @Test func loadMissingGivesDefaultsAndCreatesNothing() async throws {
        // A subdirectory path that does NOT exist yet: load must not create it.
        let untouched = root.appendingPathComponent("never-made-\(UUID().uuidString)")
        let store = ScheduleFileStore(directory: untouched)
        let loaded = try await store.load()
        #expect(loaded.policy.intervalMinutes == SchedulePolicy().intervalMinutes)
        #expect(loaded.policy.skipOnBattery == true)
        #expect(loaded.policy.onWakeCatchUp == true)
        #expect(loaded.state.lastFireAt == nil)
        #expect(loaded.state.lastFireAppsChecked == nil)
        #expect(loaded.state.lastFireWasCatchUp == nil)
        #expect(loaded.state.lastFireError == nil)
        #expect(!FileManager.default.fileExists(atPath: untouched.path))
    }

    @Test func saveLoadRoundTripIdentical() async throws {
        let fireAt = Date(timeIntervalSince1970: 1_761_400_000)
        let snapshot = ScheduleSnapshot(
            policy: SchedulePolicy(intervalMinutes: 90, skipOnBattery: false, onWakeCatchUp: false),
            state: ScheduleState(
                lastFireAt: fireAt,
                lastFireAppsChecked: 42,
                lastFireWasCatchUp: true,
                lastFireError: "hdiutil attach failed (exit 1)"))
        try await store().save(snapshot)
        let loaded = try await store().load()
        #expect(loaded == snapshot)
    }

    @Test func unparseableFallsBackAndNextSaveReplacesGarbage() async throws {
        try Data("{not a snapshot".utf8).write(to: root.appendingPathComponent("schedule.json"))
        let loaded = try await store().load()
        #expect(loaded == ScheduleSnapshot(policy: SchedulePolicy(), state: ScheduleState()))

        // The next save honestly replaces the garbage bytes.
        let snapshot = ScheduleSnapshot(
            policy: SchedulePolicy(intervalMinutes: 240),
            state: ScheduleState(lastFireAt: Date(timeIntervalSince1970: 1_761_400_000)))
        try await store().save(snapshot)
        let reread = try await store().load()
        #expect(reread == snapshot)
        #expect(reread.state.lastFireError == nil)
    }

    @Test func loadClampsPolicyThroughRuleStoreClamped() async throws {
        let underFloor = ScheduleSnapshot(
            policy: SchedulePolicy(intervalMinutes: 5),
            state: ScheduleState())
        try await store().save(underFloor)
        #expect(try await store().load().policy.intervalMinutes == 15)

        try await store().save(ScheduleSnapshot(
            policy: SchedulePolicy(intervalMinutes: -3), state: ScheduleState()))
        #expect(try await store().load().policy.intervalMinutes == 0)

        try await store().save(ScheduleSnapshot(
            policy: SchedulePolicy(intervalMinutes: 60), state: ScheduleState()))
        #expect(try await store().load().policy.intervalMinutes == 60)
    }

    @Test func stateFieldsSurviveRoundTripExactly() async throws {
        let fireAt = Date(timeIntervalSince1970: 1_761_500_000)
        var state = ScheduleState(lastFireAt: fireAt, lastFireWasCatchUp: false)
        state.lastFireAppsChecked = 7
        state.lastFireError = "network down"
        try await store().save(ScheduleSnapshot(
            policy: SchedulePolicy(intervalMinutes: 15), state: state))
        let loaded = try await store().load()
        #expect(loaded.state.lastFireAt == fireAt)
        #expect(loaded.state.lastFireAppsChecked == 7)
        #expect(loaded.state.lastFireWasCatchUp == false)
        #expect(loaded.state.lastFireError == "network down")
    }

    @Test func saveIntoImpossiblePathThrowsHonestError() async throws {
        // A FILE where the store directory's PARENT would be: the store's
        // mkdir fails deterministically — the write throws, nothing is
        // corrupted (no temp-dir permission tricks, no flaky POSIX edits).
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data("#file".utf8).write(to: blocker)
        let store = ScheduleFileStore(
            directory: blocker.appendingPathComponent("impossible"))
        do {
            try await store.save(ScheduleSnapshot(
                policy: SchedulePolicy(), state: ScheduleState()))
            Issue.record("save into an impossible path must throw")
        } catch {
            // Honest throw is the contract; nothing inspects the exact type.
        }
        #expect(!FileManager.default.fileExists(
            atPath: blocker.appendingPathComponent("impossible").path))
    }
}
