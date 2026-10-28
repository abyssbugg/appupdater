// ScheduleFileStore.swift — schedule.json persistence (coordinator-owned,
// added at the Phase-4 merge).
//
// Lane-boundary note (recorded per protocol): the scheduler lane's header
// says "Lane 2 owns schedule.json" and the rules lane's contract fixed the
// file NAME — but Lane 2 deliberately delivered only `rules.json`
// (RuleStore). The coordinator picked the schedule.json half up here so the
// engine's rule ("whoever consumes the stream persists ScheduleSnapshot")
// has an owner. This file mirrors RuleStore's honesty contract exactly:
//
//   File: schedule.json — JSONEncoder [.prettyPrinted, .sortedKeys];
//         payload = the FROZEN `ScheduleSnapshot` (policy + state) verbatim.
//         No new interchange type is invented: the snapshot IS the file shape.
//   - Missing schedule.json     → defaults (SchedulePolicy(), ScheduleState()).
//   - Unparseable schedule.json → defaults + documented log line; the next
//     save honestly replaces the garbage file (never a crash, never a
//     partial parse).
//   - Load CLAMPS the policy through `RuleStore.clamped` (loader owns
//     sanitization, mirroring the rules lane; the engine clamps again —
//     double protection, so a hand-edited interval can never hot-loop the
//     scheduler). Since the sched-depth lane's deferral gates (2026-10-28),
//     `clamped` also normalizes invalid active windows to no-restriction, so
//     the policy the settings pane reads back always matches enforcement.
//   - Writes are atomic (staging file + replaceItemAt/moveItem, same-volume
//     rename): a failed write never corrupts the previous good file. The
//     write helper is deliberately file-local (~25 lines, a RuleStore
//     mirror) so the rules lane's file stays untouched at merge.
//   - Log surface: os.Logger subsystem "io.appupdater.AppUpdater", category
//     "schedule". Documented line:
//       "schedule.json unparseable (<reason>) — treating as defaults; next save replaces it"

import Foundation
import os

public struct ScheduleFileStore: Sendable {

    /// Filename inside the store directory (fixed by the frozen
    /// Model/ScheduleStore.swift persistence-layout comment).
    private static let fileName = "schedule.json"

    static let log = Logger(subsystem: "io.appupdater.AppUpdater", category: "schedule")

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    /// Store directory — same default as RuleStore's, so `rules.json` and
    /// `schedule.json` live together in one Application Support folder.
    public let directory: URL

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// Passing nil selects the shared user-visible default directory.
    /// Init and load touch nothing on disk — the directory is created
    /// lazily on first save only (read-only environments never grow state).
    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    /// Same default as RuleStore (`~/Library/Application Support/AppUpdater`).
    static var defaultDirectory: URL { RuleStore.defaultDirectory }

    /// Loads the persisted pair. Robust by contract:
    /// - missing/unreadable file → the default pair;
    /// - unparseable bytes → the same defaults + the documented log line;
    /// - the decoded policy is CLAMPED through `RuleStore.clamped`.
    public func load() async throws -> ScheduleSnapshot {
        guard let data = try? Data(contentsOf: fileURL) else {
            // Honest absence: no crash, no directory creation, no partial parse.
            return ScheduleSnapshot(policy: SchedulePolicy(), state: ScheduleState())
        }
        let decoded: ScheduleSnapshot
        do {
            decoded = try Self.decoder.decode(ScheduleSnapshot.self, from: data)
        } catch {
            Self.log.error(
                "schedule.json unparseable (\(String(describing: error), privacy: .public)) — treating as defaults; next save replaces it"
            )
            return ScheduleSnapshot(policy: SchedulePolicy(), state: ScheduleState())
        }
        return ScheduleSnapshot(
            policy: RuleStore.clamped(decoded.policy),
            state: decoded.state)
    }

    /// Persists `snapshot` atomically, verbatim (the caller works with
    /// clamped policies; load re-clamps regardless — the file may carry an
    /// unclamped value only if a caller deliberately saved one, and the
    /// loader still refuses to honor it).
    public func save(_ snapshot: ScheduleSnapshot) async throws {
        let data = try Self.encoder.encode(snapshot)
        try writeBytesAtomically(data, to: fileURL)
    }

    /// Staging + atomic swap (mirrors RuleStore's helper; the staging file
    /// lives in the target directory so the final rename is same-volume).
    private func writeBytesAtomically(_ data: Data, to target: URL) throws {
        let dir = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let staging = dir.appendingPathComponent(
            ".\(target.lastPathComponent)-\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: staging) }

        guard FileManager.default.createFile(atPath: staging.path, contents: Data()) else {
            throw ScheduleStoreWriteFailure(
                reason: "could not stage schedule.json write in \(dir.path)")
        }
        do {
            let handle = try FileHandle(forWritingTo: staging)
            defer { try? handle.close() }
            try handle.write(data)
        } catch {
            throw ScheduleStoreWriteFailure(
                reason: "staging schedule.json write failed: \(String(describing: error))"
            )
        }

        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: target)
        }
    }
}

/// Honest persistence failure (mirrors RuleStoreWriteFailure; never
/// swallowed — the UI surfaces the verbatim text, not "success" theater).
public struct ScheduleStoreWriteFailure: LocalizedError, Sendable {
    public let reason: String
    public var errorDescription: String? { "ScheduleFileStore write failed: \(reason)" }
    public init(reason: String) { self.reason = reason }
}
