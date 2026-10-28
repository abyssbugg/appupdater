// TerminalEmulator.swift — GAP #25, opt-in Terminal typing: which emulator the
// owner's terminal-typing flow targets, plus persistence for the owner's
// default choice. PURE DATA + FILE IO ONLY — nothing in this module (or its
// sibling TerminalScriptBuilder.swift) executes AppleScript, spawns a process
// or touches the network; the coordinator's app layer is what runs the built
// script (NSAppleScript) after an explicit click.
//
// Evidence frame (docs/reverse/UPDATEST-FINDINGS.md §3.13 "Terminal automation
// (the privileged path)"): Updatest runs Homebrew/CLI updates in the user's
// real Terminal via AppleScript so the sudo password stays with the user, with
// two confirmed dialects (Terminal.app: `tell application id "<bundleid>" …
// do script "…"` with `activate`; iTerm2: `create window with default profile`
// / `input text "…" to term` fragments) and a "Default Terminal" setting
// (`_defaultTerminalBundleID`) plus an always-available copy/paste fallback.
//
// The CopyPaste fallback is AppUpdater's DEFAULT and stays the default:
// terminal typing is strictly OPT-IN. Every typing script therefore requires
// an explicit `userApprovedTyping: true` at build time (see
// TerminalScriptBuilder) — mirroring the click-driven consent boundary of
// LOCKED decision 14 (nothing privileged happens without the owner's explicit
// click/keystroke; PKG/privileged paths stay staged owner commands).
//
// Provenance split (marked honestly, per the sprint brief):
//   - THEIRS (confirmed fragments): Terminal.app bundle id `com.apple.Terminal`
//     literal; `tell application id "<bundleid>"` + `do script "…"` +
//     `activate` shape.
//   - OURS (teardown silent, standard dialect chosen): the iTerm2 bundle id
//     `com.googlecode.iterm2` literal (the teardown infers iTerm2 by app-id
//     but never prints the literal), the `displayName` labels, and the
//     persistence store below (Updatest's `_defaultTerminalBundleID` proves
//     the SETTING exists; its on-disk shape does not survive in the teardown,
//     so ours is our own JSON contract).
//
// Persistence layout (the contract asserted by TerminalScriptTests): the
// store directory is REQUIRED explicitly at init (no default convenience —
// production wires Application Support, the coordinator owns that wiring,
// this file never hardcodes it); the file is terminal_emulator.json written
// as JSONEncoder [.prettyPrinted, .sortedKeys] with the default date
// strategy, shape {"schemaVersion": 1, "defaultEmulator": "terminal"|"iterm2"}.
// ABSENCE of the file (or a cleared choice) means "no typing preference" —
// the copy/paste fallback remains the app's default, honestly.
//
// Honest-behavior rules (mirrors Manual/ManualSourceStore.swift line for line
// where the semantics coincide):
//   - Disk is the single source of truth: every verb re-reads the file —
//     store instances hold NO choice state in memory.
//   - Missing terminal_emulator.json → `loadDefault()` returns `nil` and
//     NOTHING is created (reads are lazy; the file appears on the first save).
//   - Corrupt/unreadable/unsupported-schemaVersion file → THROW clean,
//     user-readable text; NEVER auto-delete, never fake-empty; the bytes are
//     never modified (tested byte-for-byte).
//   - Writes are atomic: staged bytes swapped in with replaceItemAt/moveItem
//     (same-volume rename), so a failed write never corrupts the previous
//     file. Log surface: os.Logger "io.appupdater.AppUpdater/terminal",
//     used only before throwing.

import Foundation
import os

// MARK: - Emulator model

/// The emulators the typing flow can target. The raw value is the persisted
/// tag in terminal_emulator.json — renames would be migrations; treat as
/// frozen. CopyPaste is deliberately NOT a case: it is the app's built-in
/// fallback and the state this store models the ABSENCE of (nil choice).
public enum TerminalEmulator: String, CaseIterable, Codable, Sendable {
    /// macOS Terminal.app — the confirmed `com.apple.Terminal` literal.
    case terminal
    /// iTerm2 — bundle id OUR choice (`com.googlecode.iterm2`, the well-known
    /// literal; teardown silent on it, marked in the file header).
    case iterm2

    /// The bundle identifier the AppleScript targets via
    /// `tell application id "<bundleID>"`. `com.apple.Terminal` is a CONFIRMED
    /// literal in Updatest's binary; `com.googlecode.iterm2` is our standard
    /// choice for the same reason (stable across renames of the .app).
    public var bundleID: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm2: return "com.googlecode.iterm2"
        }
    }

    /// Human label for settings/sheet surfaces — one wording, one voice.
    public var displayName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm2: return "iTerm2"
        }
    }
}

// MARK: - Error type

/// Honest persistence failure with verbatim human `reason` text the settings
/// surface can show unchanged (mirrors ManualSourceError / ScanLocationError).
public struct TerminalEmulatorStoreError: LocalizedError, Sendable {
    public let reason: String
    public var errorDescription: String? { reason }
    public init(reason: String) { self.reason = reason }
}

// MARK: - Store

/// Persistent store of the owner's default terminal-emulator choice over one
/// explicit directory.
///
/// Sendability judgment (documented, per the `@unchecked` opt-in and copied
/// from ManualSourceStore): the class holds NO mutable stored properties —
/// the JSON file on disk is the single source of truth and every public verb
/// re-derives from it UNDER THE SERIAL `NSLock`, so concurrent callers see one
/// consistent serialized file state and `@unchecked Sendable` hides no real
/// race.
public final class TerminalEmulatorStore: @unchecked Sendable {

    /// File name inside the persistence directory (fixed schema contract).
    private static let fileName = "terminal_emulator.json"
    /// The only schema version this build reads/writes. Anything else is an
    /// honest, clean-text throw — never decode-guessing, never auto-migrating.
    private static let schemaVersion = 1

    private static let log = Logger(subsystem: "io.appupdater.AppUpdater", category: "terminal")

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    /// Store directory — REQUIRED explicitly at init (tests use unique temp
    /// directories; production wiring belongs to the coordinator).
    public let directory: URL

    /// Serial lock serializing reads AND the read-persist mutation sequence
    /// against the file (see the class Sendability doc).
    private let lock = NSLock()

    /// File URL of the persistence file (`directory` + terminal_emulator.json).
    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// Builds a store rooted at `directory`, touching NOTHING on disk (reads
    /// create nothing; directory + file appear lazily on the first save).
    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: Reading

    /// The persisted default emulator choice, or `nil` when the owner has
    /// made NO typing choice — which is the copy/paste fallback default the
    /// app ships with (typing is opt-in; nothing here enables it).
    /// Missing file → `nil` (honest absence; reads create nothing). Unreadable
    /// bytes / unsupported schemaVersion / unknown emulator tag → THROW clean
    /// text — never fake-empty, never auto-delete.
    public func loadDefault() throws -> TerminalEmulator? {
        lock.lock(); defer { lock.unlock() }
        return try loadDefaultLocked()
    }

    // MARK: Mutations (save-through: persist on success, refusal = untouched disk)

    /// Persists `emulator` as the owner's default choice (atomic write; a
    /// failed write anywhere before the swap leaves the previous file
    /// untouched).
    public func saveDefault(_ emulator: TerminalEmulator) throws {
        lock.lock(); defer { lock.unlock() }
        try persistDefaultLocked(emulator)
    }

    /// Clears the persisted choice — back to the copy/paste fallback default.
    /// Missing file → no-op (the cleared state already holds). Removal
    /// failures throw honestly; nothing partial survives.
    public func clearDefault() throws {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            throw TerminalEmulatorStoreError(
                reason: "could not clear terminal_emulator.json in "
                    + "“\(directory.path(percentEncoded: false))”: \(String(describing: error)) "
                    + "— the stored choice survives the removal failure")
        }
    }

    // MARK: Internals (all file access happens UNDER `lock`)

    /// JSON disk record — {"schemaVersion": 1, "defaultEmulator": <tag>}.
    private struct PersistedDefault: Codable {
        let schemaVersion: Int
        let defaultEmulator: TerminalEmulator
    }

    private func loadDefaultLocked() throws -> TerminalEmulator? {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return nil }
        do {
            let persisted = try Self.decoder.decode(PersistedDefault.self, from: Data(contentsOf: fileURL))
            guard persisted.schemaVersion == Self.schemaVersion else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [], debugDescription:
                        "unsupported schemaVersion \(persisted.schemaVersion) (this build writes and reads 1 only)"))
            }
            return persisted.defaultEmulator
        } catch {
            throw Self.unreadableFileError(directory: directory, underlying: error)
        }
    }

    /// The CLEAN, user-readable error contract for an unreadable store file:
    /// what, where, and the promise that nothing was touched. Never auto-delete.
    private static func unreadableFileError(directory: URL, underlying: Error) -> TerminalEmulatorStoreError {
        log.error("terminal_emulator.json unreadable (\(String(describing: underlying), privacy: .public)) — throwing honestly, file untouched")
        return TerminalEmulatorStoreError(
            reason: "terminal_emulator.json could not be read from "
                + "“\(directory.path(percentEncoded: false))”: \(String(describing: underlying)). "
                + "The file has not been modified or deleted — fix or remove it manually, then retry.")
    }

    /// Persists the choice atomically: full bytes staged by a single
    /// createFile call OUTSIDE the target name, then swapped in with
    /// replaceItemAt/moveItem — a failed write anywhere before the swap
    /// leaves the previous file untouched.
    private func persistDefaultLocked(_ emulator: TerminalEmulator) throws {
        let payload = PersistedDefault(schemaVersion: Self.schemaVersion, defaultEmulator: emulator)
        let data = try Self.encoder.encode(payload)

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(
            ".\(Self.fileName)-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staging) }

        guard FileManager.default.createFile(
            atPath: staging.path(percentEncoded: false), contents: data) else {
            throw TerminalEmulatorStoreError(
                reason: "could not stage terminal_emulator.json write in "
                    + "“\(directory.path(percentEncoded: false))” — nothing was changed")
        }

        do {
            if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: fileURL)
            }
        } catch {
            throw TerminalEmulatorStoreError(
                reason: "could not swap terminal_emulator.json into place in "
                    + "“\(directory.path(percentEncoded: false))”: \(String(describing: error)) "
                    + "— the previous good file survives the atomic-write contract")
        }
    }
}
