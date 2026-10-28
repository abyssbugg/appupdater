// SettingsMigration.swift — GAP #26, the settings-schema envelope service.
// Lane polish · exclusive core files of this lane (Sources/AppUpdaterCore/Migration/).
//
// WHAT THIS IS
//   A tiny launch-time service that gives every app-support settings file a
//   recorded schema version. The envelope file (settings_migration_state.json)
//   persists which settings shape the files on disk correspond to; a future
//   build that changes a settings shape registers a migration STEP (from → to
//   + transform) and the service applies the chained steps before any store
//   reads, then re-stamps the envelope. Version 1 is the IDENTITY migration:
//   the current shapes ARE version 1, so the service records them and
//   transforms nothing — the mechanism is proven now, before any transformation
//   ever needs it.
//
// REGISTRY (the settings files this envelope covers, all in ONE shared
// directory — the app-support home the coordinator wires):
//   rules.json · schedule.json · proxy_settings.json ·
//   auto_apply_settings.json · terminal_emulator.json ·
//   scan_locations.json · manual_sources.json ·
//   display_settings.json · welcome_state.json
// The last two are app-target-owned (GAP #26 stores, same directory, same
// envelope family); the rest are core stores. Filenames only — the service
// never decodes the settings files themselves, so there is no type coupling.
//
// CONTRACT (mirrors the house stores line for line — TerminalEmulatorStore's
// sync surface + AutoApplySettingsStore's atomic write):
//   - The envelope file is the single source of truth; instances hold no
//     version state in memory. Reads create nothing; the envelope appears on
//     the first stamp.
//   - Missing envelope → `freshEnvelope`: the CURRENT build stamps its own
//     shapes (no steps run — a fresh install never needs old→new transforms).
//   - Envelope at the current version → `alreadyCurrent`, and the file is NOT
//     rewritten (bytes preserved, migratedAt preserved).
//   - Envelope BELOW the current version → every registered step chained from
//     that version runs, ascending, then the envelope re-stamps. v1 registers
//     NO steps, so this path stamps without transformation (the honest
//     meaning of "identity migration"). A future registry MUST add steps
//     covering its increments; a missing step means the stamp proceeds
//     WITHOUT transformation — recorded in the returned outcome, never hidden.
//   - Envelope NEWER than this build → clean THROW, file untouched: the disk
//     describes shapes this build does not understand, and stamping backwards
//     would lie about them.
//   - Unparseable envelope → clean THROW, file untouched (never auto-delete,
//     never fake-empty — TerminalEmulatorStore's honesty rule).
//   - A failing step throws with the step label; the envelope is NOT stamped,
//     so the next launch re-runs the chain — steps must be safe to re-run.
//   - Writes are atomic: staging file in the target directory, swapped with
//     replaceItemAt/moveItem — a failed write never corrupts the envelope.
//   - Log surface: os.Logger "io.appupdater.AppUpdater/settings-migration",
//     used only before throwing.
//
// WIRING (the single call): the app coordinator runs `runIfNeeded()` at the
// very top of AppState.init, BEFORE any store is constructed or read — a
// synchronous call, so the ordering guarantee is structural, not a race to
// lose. A failure is recorded verbatim in the app's settings surface and
// never blocks launch; the stores then load under their own contracts.

import Foundation
import os

// MARK: - Envelope (persisted state)

/// The persisted schemaVersion envelope for the app-support settings files.
public struct SettingsMigrationState: Codable, Hashable, Sendable {

    /// The settings-shape generation the recorded files correspond to.
    public var settingsSchemaVersion: Int

    /// Per-file recorded shape version (`rules.json` → 1, …). Absence of a
    /// key means the recording build did not know the file.
    public var recordedFiles: [String: Int]

    /// When the envelope was last stamped (default date strategy, house
    /// stores' convention).
    public var migratedAt: Date?

    public init(settingsSchemaVersion: Int, recordedFiles: [String: Int], migratedAt: Date?) {
        self.settingsSchemaVersion = settingsSchemaVersion
        self.recordedFiles = recordedFiles
        self.migratedAt = migratedAt
    }
}

// MARK: - Step (registry entry)

/// One registered migration: transform the settings directory from shape
/// `fromVersion` to shape `toVersion`. The transform receives the SHARED
/// settings directory and must be safe to re-run (the envelope is only
/// stamped after the whole chain succeeds, so a mid-chain failure re-runs
/// steps on the next launch).
public struct SettingsMigrationStep: Sendable {

    public let fromVersion: Int
    public let toVersion: Int
    /// Human-readable label for logs and failure text (e.g. "dock-badge split").
    public let label: String
    public let transform: @Sendable (URL) throws -> Void

    public init(
        fromVersion: Int, toVersion: Int, label: String,
        transform: @escaping @Sendable (URL) throws -> Void
    ) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.label = label
        self.transform = transform
    }
}

// MARK: - Outcome + error

/// What one `runIfNeeded()` pass did. `.migrated` names the actual from→to
/// pair so the app surface can state it verbatim.
public enum SettingsMigrationOutcome: Hashable, Sendable {
    /// No envelope existed: the current build's shapes were recorded.
    case freshEnvelope
    /// The envelope sat at an older version; the chain ran (possibly with
    /// zero steps — the v1 identity case) and the envelope was re-stamped.
    case migrated(from: Int, to: Int)
    /// The envelope already named the current version. Nothing written.
    case alreadyCurrent
}

/// Honest persistence/refusal failure with verbatim human `reason` text the
/// app surface can show unchanged (mirrors TerminalEmulatorStoreError).
public struct SettingsMigrationError: LocalizedError, Sendable {
    public let reason: String
    public var errorDescription: String? { reason }
    public init(reason: String) { self.reason = reason }
}

// MARK: - Service

/// The launch-time settings-schema service. `Sendable` by construction
/// (documented, per the `@unchecked` opt-in, copied from
/// TerminalEmulatorStore): the class holds NO mutable stored properties —
/// the envelope file on disk is the single source of truth, every public
/// verb re-derives from it UNDER the serial `NSLock`, so concurrent callers
/// see one consistent serialized file state and `@unchecked Sendable` hides
/// no real race.
public final class SettingsMigrationService: @unchecked Sendable {

    /// The settings-shape generation this build reads and writes.
    public static let currentSchemaVersion = 1

    /// The settings files this envelope covers (see the file header for the
    /// composition rationale). Order is presentation-only; the envelope
    /// stores a keyed map.
    public static let registeredFiles: [String] = [
        "rules.json",
        "schedule.json",
        "proxy_settings.json",
        "auto_apply_settings.json",
        "terminal_emulator.json",
        "scan_locations.json",
        "manual_sources.json",
        "display_settings.json",
        "welcome_state.json",
    ]

    /// The envelope file name inside the shared settings directory.
    static let stateFileName = "settings_migration_state.json"

    static let log = Logger(subsystem: "io.appupdater.AppUpdater", category: "settings-migration")

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    /// Settings directory — REQUIRED explicitly at init (production wires the
    /// app-support home; tests use unique temp directories).
    public let directory: URL

    /// The registered step chain, kept sorted ascending by `fromVersion`.
    private let steps: [SettingsMigrationStep]
    /// The version this build stamps (= `currentSchemaVersion` in production).
    private let targetVersion: Int

    private let lock = NSLock()

    private var stateURL: URL { directory.appendingPathComponent(Self.stateFileName) }

    /// Production wiring: the v1 identity registry (no steps — the current
    /// shapes ARE version 1; the envelope records them).
    public convenience init(directory: URL) {
        self.init(directory: directory, steps: [], targetVersion: Self.currentSchemaVersion)
    }

    /// Registry seam (tests + future registries): explicit step chain and
    /// target version.
    init(directory: URL, steps: [SettingsMigrationStep], targetVersion: Int) {
        self.directory = directory
        self.steps = steps.sorted { $0.fromVersion < $1.fromVersion }
        self.targetVersion = targetVersion
    }

    // MARK: The single verb

    /// Runs the migration pass. See the file header's CONTRACT for every
    /// branch. Never throws for "nothing to do" — fresh + alreadyCurrent are
    /// outcomes, not errors.
    public func runIfNeeded() throws -> SettingsMigrationOutcome {
        lock.lock(); defer { lock.unlock() }

        let stored = try readStateLocked()
        if let stored {
            if stored.settingsSchemaVersion == targetVersion { return .alreadyCurrent }
            if stored.settingsSchemaVersion > targetVersion {
                throw SettingsMigrationError(reason:
                    "settings_migration_state.json describes settings schema version "
                        + "\(stored.settingsSchemaVersion), newer than this build's \(targetVersion). "
                        + "Refusing to guess or to stamp backwards — the file was not modified; "
                        + "update AppUpdater to a build that understands this schema.")
            }
        }

        // Fresh envelope (no file) = current build's shapes: NO steps run.
        // Older envelope: every step chained from that version runs ascending.
        if let prior = stored?.settingsSchemaVersion {
            for step in steps where step.fromVersion >= prior {
                do {
                    try step.transform(directory)
                } catch {
                    Self.log.error(
                        "migration step \"\(step.label, privacy: .public)\" failed — envelope not stamped"
                    )
                    throw SettingsMigrationError(reason:
                        "settings migration step \"\(step.label)\" "
                            + "(\(step.fromVersion) → \(step.toVersion)) failed: \(error). "
                            + "The envelope was NOT updated — the next launch re-runs the chain, "
                            + "so steps must be safe to re-run.")
                }
            }
        }

        let stamped = SettingsMigrationState(
            settingsSchemaVersion: targetVersion,
            recordedFiles: Dictionary(
                uniqueKeysWithValues: Self.registeredFiles.map { ($0, targetVersion) }),
            migratedAt: Date())
        try writeStateLocked(stamped)

        if let prior = stored?.settingsSchemaVersion {
            return .migrated(from: prior, to: targetVersion)
        }
        return .freshEnvelope
    }

    // MARK: Internals (all file access happens UNDER `lock`)

    /// nil = no envelope file (fresh). Corrupt bytes → clean throw, file
    /// untouched (never auto-delete, never fake-empty).
    private func readStateLocked() throws -> SettingsMigrationState? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        do {
            return try Self.decoder.decode(SettingsMigrationState.self, from: Data(contentsOf: stateURL))
        } catch {
            Self.log.error(
                "settings_migration_state.json unparseable (\(String(describing: error), privacy: .public)) — throwing honestly, file untouched"
            )
            throw SettingsMigrationError(reason:
                "settings_migration_state.json in “\(directory.path)” could not be read: "
                    + "\(String(describing: error)). The file has not been modified or deleted — "
                    + "fix or remove it manually, then retry.")
        }
    }

    /// Atomic stamp: staging bytes swapped in with replaceItemAt/moveItem
    /// (same-volume rename) — a failed write anywhere before the swap leaves
    /// the previous envelope untouched.
    private func writeStateLocked(_ state: SettingsMigrationState) throws {
        let data = try Self.encoder.encode(state)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(
            ".\(Self.stateFileName)-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staging) }

        guard FileManager.default.createFile(atPath: staging.path, contents: data) else {
            throw SettingsMigrationError(reason:
                "could not stage settings_migration_state.json write in “\(directory.path)” "
                    + "— nothing was changed")
        }
        do {
            if FileManager.default.fileExists(atPath: stateURL.path) {
                _ = try FileManager.default.replaceItemAt(stateURL, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: stateURL)
            }
        } catch {
            throw SettingsMigrationError(reason:
                "could not swap settings_migration_state.json into place in “\(directory.path)”: "
                    + "\(String(describing: error)) — the previous envelope survives the "
                    + "atomic-write contract")
        }
    }
}
