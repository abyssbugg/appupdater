// ManualSourceStore.swift — per-app manual source pins (gap #2, Updatest §3.11):
// an owner-attested source override ("manual wins over auto-detected sinks")
// persisted honestly over one explicit directory and consumed by the engine
// through the coordinator-authored `ManualSourceResolver` seam
// (Engine/UpdateCheckEngine.swift — see ManualSourceResolver.swift for the
// service that plugs in there).
//
// Evidence frame (docs/reverse/GAP-ANALYSIS.md item #8 + UPDATEST-FINDINGS.md
// §3.11): Updatest ships AddManualSourceView with per-app source types —
// GitHub `owner/repo`, Homebrew cask token (tap-qualified optional), plus a
// Sparkle-appcast form — persisted in its manual_source_cache. THE MANUAL SOURCE
// IS AN OWNER ATTESTATION: it is consulted INSTEAD of every auto-detected sink
// for that app, never in addition (engine-side rule, already frozen in
// UpdateCheckEngine.check(app:) — "manual pin = the ONLY source consulted for
// pinned apps; built-ins never queried; claim still strictly-greater gated at
// resolve; pin throw recorded verbatim in failures"). No auto-detection exists
// for pinned apps — the pin replaces detection wholesale.
//
// Scope of THIS file: exactly two pin kinds (github repo pin, cask token pin —
// the two forms the Sprint brief locks). The Sparkle-appcast override form is
// deliberately NOT modeled here: adding a third kind without its own source
// lane would manufacture behavior nobody can resolve yet; extension is
// additive in the JSON (unknown kinds decode-error → see the corrupt-file
// contract below, which never auto-deletes).
//
// Persistence layout (the contract asserted by ManualSourceTests): the store
// directory is REQUIRED explicitly at init (no default convenience —
// production wires ~/Library/Application Support/AppUpdater, the coordinator
// owns that wiring, this file never hardcodes it); the file is
// manual_sources.json written as JSONEncoder [.prettyPrinted, .sortedKeys]
// with the default date strategy (identical to ScanLocationStore/RuleStore),
// shape {"schemaVersion": 1, "pins": […]} sorted by bundleID → kind →
// createdAt.
//
// Honest-behavior rules (mirrors Scan/ScanLocations.swift line for line where
// the semantics coincide):
//   - Disk is the single source of truth: every verb re-reads the file —
//     store instances hold NO pin state in memory, so two instances over the
//     same directory observe one serialized file state.
//   - Missing manual_sources.json → `pins()` returns `[]` and NOTHING is
//     created (reads are lazy; the file appears on the first mutation).
//   - Corrupt/unreadable/unsupported-schemaVersion file → THROW clean,
//     user-readable text; NEVER auto-delete, never fake-empty; the bytes are
//     never modified (tested byte-for-byte). The UI surfaces the verbatim
//     failure where it can.
//   - Refusals in `add(…)`: empty/whitespace bundleID → invalid GitHub slug
//     (RepoRef, SAME alphabet as the built-in GithubSource) → cask token
//     whitespace/empty → duplicate SAME bundleID + SAME kind. Every refusal
//     throws `ManualSourceError` with honest human text and never touches disk.
//   - Normalization: inputs are trimmed first; the trimmed form is what is
//     persisted ("org.foo " validates as "org.foo").
//   - ONE pin per (bundleID, kind) pair, but a bundle identifier MAY hold
//     one github pin AND one cask pin simultaneously — documented choice:
//     the owner may want to compare sources for one app, and the resolver's
//     "first pin in store sort order" rule stays deterministic (cask sorts
//     before github by the kind ordering below).
//   - A pin for a bundle identifier that is not (yet) any installed app IS
//     lawful — the store validates TEXT, never the scan set; the sheet
//     renders such pins under their raw bundle identifier (honesty in UI).
//   - Writes are atomic: staged bytes swapped in with replaceItemAt/moveItem
//     (same-volume rename), so a failed write never corrupts the previous
//     file. Log surface: os.Logger "io.appupdater.AppUpdater/manualsources",
//     used only before throwing.
//   - Pin IDENTITY for matcher/sheet/tests: pins match apps by
//     `bundleIdentifier` EXACTLY (string equality, no case folding, no
//     prefix matching) — see ManualSourceResolver.swift.

import Foundation
import os

// MARK: - Pin model

/// One owner-attested manual source pin, persisted in manual_sources.json.
/// `id` is the stable row identity (a UUID string minted at add time, used by
/// `remove(id:)` and the sheet); `bundleID` is the TARGET app's bundle
/// identifier — the matcher key (`ManualSourceResolverService` matches it
/// against `InstalledApp.bundleIdentifier` exactly). `createdAt` is display
/// metadata, not identity.
public struct ManualSource: Codable, Hashable, Sendable, Identifiable {
    /// Stable row identity, minted at add time (`UUID().uuidString`).
    public var id: String
    /// The bundle identifier this pin targets (matched EXACTLY, no folding).
    public var bundleID: String
    /// Which source kind the pin attests.
    public var kind: Kind
    /// GitHub pin fields (kind .github only; nil otherwise).
    public var owner: String?
    public var repo: String?
    /// Homebrew cask token (kind .cask only; nil otherwise).
    public var token: String?
    /// When the pin was added (display metadata, not identity).
    public var createdAt: Date

    /// The two pin kinds this build models. The raw value is the persisted
    /// tag AND the sort key between kinds (alphabetical: cask < github), so
    /// renames would be migrations — treat as frozen.
    public enum Kind: String, Codable, Sendable {
        /// Attested GitHub repository ("owner/repo", releases/latest lookup).
        case github
        /// Attested Homebrew cask token (single-token cask document lookup).
        case cask

        /// Human label used by the sheet and by refusal texts — one wording,
        /// one voice, everywhere.
        public var label: String {
            switch self {
            case .github: return "GitHub release"
            case .cask: return "Homebrew cask"
            }
        }
    }

    /// "owner/repo" for GitHub pins, the bare token for cask pins. Missing
    /// fields render the honest "—" placeholder (never invented).
    public var targetDescription: String {
        switch kind {
        case .github: return "\(owner ?? "—")/\(repo ?? "—")"
        case .cask: return token ?? "—"
        }
    }

    /// Full-fidelity initializer (defaults where honest: a fresh pin mints
    /// its own id and createdAt; explicit values exist for decode-side
    /// helpers and tests — the public API strangers is the store's add).
    public init(
        id: String = UUID().uuidString,
        bundleID: String,
        kind: Kind,
        owner: String? = nil,
        repo: String? = nil,
        token: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.bundleID = bundleID
        self.kind = kind
        self.owner = owner
        self.repo = repo
        self.token = token
        self.createdAt = createdAt
    }
}

// MARK: - Error type

/// Honest refusal/persistence failure with verbatim human `reason` text the
/// sheet surfaces unchanged (mirrors ScanLocationError).
public struct ManualSourceError: LocalizedError, Sendable {
    public let reason: String
    public var errorDescription: String? { reason }
    public init(reason: String) { self.reason = reason }
}

// MARK: - Store

/// Persistent store of manual source pins over one explicit directory.
///
/// Sendability judgment (documented, per the `@unchecked` opt-in and copied
/// from ScanLocationStore): the class holds NO mutable stored properties at
/// all — the JSON file on disk is the single source of truth and every public
/// verb re-derives from it UNDER THE SERIAL `NSLock`, so concurrent callers
/// (main-thread sheet, engine resolver) see one consistent serialized file
/// state and `@unchecked Sendable` hides no real race. The lock also
/// serializes each read-modify-write mutation sequence against the file.
public final class ManualSourceStore: @unchecked Sendable {

    /// File name inside the persistence directory (fixed schema contract).
    private static let fileName = "manual_sources.json"
    /// The only schema version this build reads/writes. Anything else is an
    /// honest, clean-text throw — never decode-guessing, never auto-migrating.
    private static let schemaVersion = 1

    private static let log = Logger(subsystem: "io.appupdater.AppUpdater", category: "manualsources")

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    /// Store directory — REQUIRED explicitly at init (tests use unique temp
    /// directories; production wiring belongs to the coordinator).
    public let directory: URL

    /// Serial lock serializing reads AND read-modify-write mutation
    /// sequences against the file (see the class Sendability doc).
    private let lock = NSLock()

    /// File URL of the persistence file (`directory` + manual_sources.json).
    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// Builds a store rooted at `directory`, touching NOTHING on disk (reads
    /// create nothing; directory + file appear lazily on first mutation).
    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: Reading

    /// Reads the persisted pins, sorted by bundleID, then kind (raw value —
    /// cask precedes github), then createdAt. This sort order is also the
    /// resolver's pick order for a bundle id that holds both kinds.
    /// Missing file → `[]` (honest absence; reads create nothing). Unreadable
    /// bytes / unsupported schemaVersion → THROW clean text — never
    /// fake-empty, never auto-delete.
    public func pins() throws -> [ManualSource] {
        lock.lock(); defer { lock.unlock() }
        return try loadPinsLocked()
    }

    // MARK: Mutations (save-through: persist on success, refuse = untouched disk)

    /// Adds a GitHub release pin (`owner`/`repo` attested for the app with
    /// bundle identifier `bundleID`) and persists. Validation, each step an
    /// honest `ManualSourceError` never touching disk: bundleID non-empty →
    /// owner/repo slug valid through `RepoRef.validated` (the SAME alphabet
    /// GithubSource itself admits — an invalid pin would build a broken API
    /// URL, so it is refused up front, never stored half-formed) → same
    /// bundleID+kind duplicate refusal. bundleIDs not present in any scan
    /// remain lawful (the store validates text, not the scan set).
    public func add(githubPin owner: String, repo: String, bundleID: String) throws {
        let trimmedBundleID = Self.normalize(bundleID)
        let trimmedOwner = Self.normalize(owner)
        let trimmedRepo = Self.normalize(repo)

        guard !trimmedBundleID.isEmpty else {
            throw ManualSourceError(reason:
                "could not add the manual source: the app's bundle identifier is empty — "
                + "a pin is keyed by the app's bundle identifier, so it must name one")
        }
        guard let ref = RepoRef.validated(owner: trimmedOwner, repo: trimmedRepo) else {
            throw ManualSourceError(reason:
                "could not add the manual source: \"\(trimmedOwner)/\(trimmedRepo)\" is not a valid "
                + "GitHub repository — owner and repo may contain only letters, numbers, '-', '_' "
                + "and '.', and neither part may be empty")
        }

        try mutatePinsLocked(kind: .github, bundleID: trimmedBundleID) { pins in
            pins.append(ManualSource(
                bundleID: trimmedBundleID,
                kind: .github,
                owner: ref.owner,
                repo: ref.repo
            ))
        }
    }

    /// Adds a Homebrew cask token pin and persists. Validation: bundleID
    /// non-empty → token non-empty after trimming and containing NO
    /// whitespace (a cask token is one path word — "google-chrome" is a
    /// token, "google chrome" is not) → same bundleID+kind duplicate
    /// refusal.
    public func add(caskPin token: String, bundleID: String) throws {
        let trimmedBundleID = Self.normalize(bundleID)
        let trimmedToken = Self.normalize(token)

        guard !trimmedBundleID.isEmpty else {
            throw ManualSourceError(reason:
                "could not add the manual source: the app's bundle identifier is empty — "
                + "a pin is keyed by the app's bundle identifier, so it must name one")
        }
        guard !trimmedToken.isEmpty, !trimmedToken.contains(where: \.isWhitespace) else {
            throw ManualSourceError(reason:
                "could not add the manual source: cask tokens are single words without whitespace "
                + "(\"google-chrome\", not \"google chrome\"), and \"\(trimmedToken)\" is not one")
        }

        try mutatePinsLocked(kind: .cask, bundleID: trimmedBundleID) { pins in
            pins.append(ManualSource(
                bundleID: trimmedBundleID,
                kind: .cask,
                token: trimmedToken
            ))
        }
    }

    /// Removes the pin whose id matches `id` and persists. Unknown ids throw
    /// honestly with the id named (the sheet only ever passes listed ids, so
    /// the catch path there covers honest store-read races instead).
    public func remove(id: String) throws {
        lock.lock(); defer { lock.unlock() }

        var pins = try loadPinsLocked()
        guard pins.contains(where: { $0.id == id }) else {
            throw ManualSourceError(reason:
                "could not remove the manual source: no pin with id \"\(id)\" is present "
                + "(it may have been removed already, or manual_sources.json changed meanwhile)")
        }
        pins.removeAll { $0.id == id }
        try persistPinsLocked(pins)
    }

    // MARK: Internals (all file access happens UNDER `lock`)

    /// Normalization contract: trim whitespace/newlines both ends; keep the
    /// case the owner typed (bundle identifiers are case-sensitive POSIX-side
    /// and GitHub slugs are case-insensitive-but-preserving — never folding
    /// invented here beats any folding guess).
    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// JSON disk record — {"schemaVersion": 1, "pins": […]}.
    private struct PersistedManualSources: Codable {
        let schemaVersion: Int
        let pins: [ManualSource]
    }

    /// The persist sort order, shared by `pins()` reads and disk writes so
    /// the file is always canonical (resolver pick order = store order).
    private static func sorted(_ pins: [ManualSource]) -> [ManualSource] {
        pins.sorted { lhs, rhs in
            if lhs.bundleID != rhs.bundleID { return lhs.bundleID < rhs.bundleID }
            if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private func loadPinsLocked() throws -> [ManualSource] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return [] }
        do {
            let persisted = try Self.decoder.decode(PersistedManualSources.self, from: Data(contentsOf: fileURL))
            guard persisted.schemaVersion == Self.schemaVersion else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [], debugDescription:
                        "unsupported schemaVersion \(persisted.schemaVersion) (this build writes and reads 1 only)"))
            }
            return Self.sorted(persisted.pins)
        } catch {
            throw Self.unreadableFileError(directory: directory, underlying: error)
        }
    }

    /// The CLEAN, user-readable error contract for an unreadable store file:
    /// what, where, and the promise that nothing was touched. Never auto-delete.
    private static func unreadableFileError(directory: URL, underlying: Error) -> ManualSourceError {
        log.error("manual_sources.json unreadable (\(String(describing: underlying), privacy: .public)) — throwing honestly, file untouched")
        return ManualSourceError(
            reason: "manual_sources.json could not be read from "
                + "“\(directory.path(percentEncoded: false))”: \(String(describing: underlying)). "
                + "The file has not been modified or deleted — fix or remove it manually, then retry.")
    }

    /// Read-load-mutation-persist under one lock acquisition: the shared SKELETON
    /// of both add verbs. Refusals (duplicate same-bundleID+kind, or any store
    /// read failure) throw and persist nothing — the disk stays byte-identical.
    private func mutatePinsLocked(kind: ManualSource.Kind, bundleID: String, _ mutate: (inout [ManualSource]) -> Void) throws {
        var pins = try loadPinsLocked()
        if let clash = pins.first(where: { $0.bundleID == bundleID && $0.kind == kind }) {
            throw ManualSourceError(reason:
                "could not add the manual source: “\(bundleID)” already has a \(kind.label) pin "
                + "(its attested source: “\(clash.targetDescription)”) — one pin per kind per app; "
                + "remove the existing \(kind.label) pin first if you want to replace it")
        }
        mutate(&pins)
        try persistPinsLocked(pins)
    }

    /// Persists the pin set (canonical order = bundleID → kind → createdAt)
    /// atomically: full bytes staged by a single createFile call OUTSIDE the
    /// target name, then swapped in with replaceItemAt/moveItem — a failed
    /// write anywhere before the swap leaves the previous file untouched.
    private func persistPinsLocked(_ pins: [ManualSource]) throws {
        let payload = PersistedManualSources(schemaVersion: Self.schemaVersion, pins: Self.sorted(pins))
        let data = try Self.encoder.encode(payload)

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(
            ".\(Self.fileName)-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staging) }

        guard FileManager.default.createFile(
            atPath: staging.path(percentEncoded: false), contents: data) else {
            throw ManualSourceError(
                reason: "could not stage manual_sources.json write in "
                    + "“\(directory.path(percentEncoded: false))” — nothing was changed")
        }

        do {
            if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: fileURL)
            }
        } catch {
            throw ManualSourceError(
                reason: "could not swap manual_sources.json into place in "
                    + "“\(directory.path(percentEncoded: false))”: \(String(describing: error)) "
                    + "— the previous good file survives the atomic-write contract")
        }
    }
}
