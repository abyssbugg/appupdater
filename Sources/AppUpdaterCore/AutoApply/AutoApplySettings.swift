// AutoApplySettings.swift — consent switches for per-app auto-apply (GAP #22).
// Gap-sprint wave · lane autoapply · exclusive file of this lane.
//
// CONSENT BOUNDARY (LOCKED DECISION 14, amended by the owner 2026-10-28):
//   The app's DEFAULT remains click-driven — nothing auto-applies unless the
//   owner opts in. Opt-in per-app auto-apply is authorized with MacUpdater's
//   safety gates, for USER-SPACE updates only (zip/dmg via the existing
//   verified install chain): a global master switch (default OFF) AND a
//   per-app opt-in (default OFF) must BOTH be on; PKG/privileged paths are
//   NEVER auto-applied (staged owner commands only, unchanged); every
//   auto-apply produces full verbatim receipts; all of MacUpdater's exclusion
//   gates apply (battery, offline, running-app — see AutoApplyGate.swift for
//   the full implemented matrix). This file is the PERSISTED consent state:
//   both switches default FALSE everywhere, and absence of a per-app entry is
//   "not opted in" — never inferred otherwise.
//
// PERSISTENCE (mirrors ProxySettingsStore / RuleStore conventions verbatim):
//   Directory:  default ~/Library/Application Support/AppUpdater (or init seam)
//   File:       auto_apply_settings.json — JSONEncoder [.prettyPrinted,
//               .sortedKeys], default date strategy (this model carries no
//               dates; the encoder config is kept identical to the sibling
//               stores on purpose)
//   - Init and load() touch nothing on disk; the directory is created lazily
//     on FIRST save only (read-only environments never grow state).
//   - Missing file     → defaults (AutoApplySettings()).
//   - Unparseable file → defaults + documented log line; the next save
//     honestly replaces the garbage bytes (never a crash, never a partial
//     parse).
//   - Writes are atomic: staging file in the target directory + FileHandle,
//     swapped with replaceItemAt (target exists) or moveItem (first write) —
//     a failed write never corrupts the previous good file.
//   - Log surface: os.Logger subsystem "io.appupdater.AppUpdater", category
//     "auto-apply-settings". Documented line (RuleStore phrasing, adapted):
//       "auto_apply_settings.json unparseable (<reason>) — treating as defaults; next save replaces it"
//
// READ-ONLY POSTURE (lane brief): this file never applies anything; it is the
// consent surface the coordinator reads before invoking the gate. The gate and
// the install chain are separate modules (gate-over-install separation).

import Foundation
import os

/// The persisted auto-apply consent state (decision 14).
///
/// Defaults are FAIL-CLOSED by contract: `autoApplyEnabled == false` and every
/// bundle identifier not present in `perAppOptIn` is NOT opted in. There is no
/// code path in this module that can turn consent on by default.
public struct AutoApplySettings: Codable, Hashable, Sendable {

    /// Global master switch. DEFAULT FALSE (decision 14). Wire-stable key.
    public var autoApplyEnabled: Bool

    /// Per-app opt-in map keyed by bundle identifier. ABSENT KEY = not opted
    /// in (DEFAULT OFF, decision 14) — an explicit `false` entry is stored
    /// only when a UI wants to record an explicit decline. Keys match the
    /// bundle identifier EXACTLY (case-sensitive), mirroring RuleStore's
    /// identity semantics.
    public var perAppOptIn: [String: Bool]

    public init(autoApplyEnabled: Bool = false, perAppOptIn: [String: Bool] = [:]) {
        self.autoApplyEnabled = autoApplyEnabled
        self.perAppOptIn = perAppOptIn
    }

    /// The per-app opt-in flag for one app. ABSENT = false — the consent
    /// default (decision 14), never inferred otherwise.
    public func isOptedIn(bundleIdentifier: String) -> Bool {
        perAppOptIn[bundleIdentifier] ?? false
    }

    /// Decode tolerance (additive-contract requirement, ProxySettings pattern):
    /// every key decodes with `decodeIfPresent` and falls back to the
    /// fail-closed default, so settings persisted by older builds (or
    /// hand-edited files missing keys) decode honestly instead of failing the
    /// whole file — and an old file can never decode into "consent granted".
    /// Encoding stays synthesized (every key always written).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoApplyEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoApplyEnabled) ?? false
        perAppOptIn = try container.decodeIfPresent([String: Bool].self, forKey: .perAppOptIn) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case autoApplyEnabled
        case perAppOptIn
    }
}

/// Persistence for ``AutoApplySettings`` (a ProxySettingsStore mirror; see the
/// file header for the full contract). `Sendable` by construction: all state
/// is immutable after init; every method re-derives from disk so concurrent
/// callers always see one truth.
public struct AutoApplySettingsStore: Sendable {

    /// Filename inside the store directory (sibling of rules.json,
    /// schedule.json and proxy_settings.json per the frozen store layout).
    private static let fileName = "auto_apply_settings.json"

    static let log = Logger(subsystem: "io.appupdater.AppUpdater", category: "auto-apply-settings")

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    /// Store directory — the ONLY test seam (real temp directories in tests,
    /// no protocol indirection; RuleStore convention).
    public let directory: URL

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// Builds a store rooted at `directory`. Passing nil selects the shared,
    /// user-visible default directory; nothing is touched on disk here.
    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    /// Same default as RuleStore (`~/Library/Application Support/AppUpdater`),
    /// so all settings files live together.
    static var defaultDirectory: URL { RuleStore.defaultDirectory }

    /// Loads the persisted consent state. Robust by contract:
    /// - missing/unreadable file → defaults (honest absence, nothing created);
    /// - unparseable bytes → defaults + the documented log line; the next
    ///   save honestly replaces the garbage file.
    /// A decode failure of an individual value is the same unparseable case —
    /// JSONDecoder is all-or-nothing. A partially-consented file can never
    /// load as "consented": both keys fall back to OFF.
    public func load() async throws -> AutoApplySettings {
        guard let data = try? Data(contentsOf: fileURL) else {
            return AutoApplySettings()
        }
        do {
            return try Self.decoder.decode(AutoApplySettings.self, from: data)
        } catch {
            Self.log.error(
                "auto_apply_settings.json unparseable (\(String(describing: error), privacy: .public)) — treating as defaults; next save replaces it"
            )
            return AutoApplySettings()
        }
    }

    /// Persists `settings` atomically as canonical JSON. Throws on failure —
    /// a consent change the user asked to set MUST surface its failure, never
    /// vanish into memory-only state (RuleStore convention).
    public func save(_ settings: AutoApplySettings) async throws {
        let data = try Self.encoder.encode(settings)
        try writeBytesAtomically(data, to: fileURL)
    }

    /// Staging + atomic swap (file-local ProxySettingsStore/RuleStore mirror:
    /// the staging file lives in the target directory so the final rename is
    /// same-volume, and a failure anywhere before the swap leaves the previous
    /// good file untouched).
    private func writeBytesAtomically(_ data: Data, to target: URL) throws {
        let dir = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staging = dir.appendingPathComponent(
            ".\(target.lastPathComponent)-\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: staging) }

        guard FileManager.default.createFile(atPath: staging.path, contents: Data()) else {
            throw AutoApplySettingsWriteFailure(
                reason: "could not stage auto_apply_settings.json write in \(dir.path)")
        }
        do {
            let handle = try FileHandle(forWritingTo: staging)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
        } catch {
            throw AutoApplySettingsWriteFailure(
                reason: "staging auto_apply_settings.json write failed: \(String(describing: error))")
        }

        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: target)
        }
    }
}

/// Honest persistence failure (mirrors RuleStoreWriteFailure; the UI surfaces
/// the verbatim text, not "success" theater).
public struct AutoApplySettingsWriteFailure: LocalizedError, Sendable {
    public let reason: String
    public var errorDescription: String? { "AutoApplySettingsStore write failed: \(reason)" }
    public init(reason: String) { self.reason = reason }
}
