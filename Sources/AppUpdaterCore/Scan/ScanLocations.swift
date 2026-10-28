// ScanLocations.swift — user-chosen scan roots beyond /Applications (gap #18):
// a bookmark-backed, honest persistence store for custom discovery locations
// (Updatest §3.1 evidence) whose output plugs directly into the FROZEN scan
// contract `AppScanner.scan(directoryURLs:)`. This file adds NO scanning
// behavior of its own — the scanner lane owns enumeration (Scanner.swift).
//
// Relationship to /Applications: the scan ENGINE scans /Applications on its
// own; this store must never contain it, so `add(_:)` refuses with the
// owner-approved guard text "the default /Applications root is always scanned
// and cannot also be a custom location" — the resolved root list stays a pure
// superset of user-added folders.
//
// Persistence layout (the contract asserted by ScanLocationTests): the store
// directory is REQUIRED explicitly at init (no default convenience —
// production wires ~/Library/Application Support/AppUpdater, the coordinator
// owns that wiring, this file never hardcodes it); the file is
// scan_locations.json written as JSONEncoder [.prettyPrinted, .sortedKeys]
// with the default date strategy (full-precision secondsSinceReferenceDate,
// identical to RuleStore), shape {"schemaVersion": 1, "locations": […]}.
// Honest-behavior rules:
//   - Canonicalization: `URL.resolvingSymlinksInPath()` + a required
//     trailing-slash strip is the DEDUPE identity (see canonicalPath(for:)) —
//     one real folder is exactly one string; a symlink aliases its target.
//   - REFUSAL ladder in `add(_:)`, in documented order: nonexistent path →
//     not a directory → already present (canonical) → canonical is
//     /Applications; every refusal throws `ScanLocationError` with honest
//     human text and never touches disk state.
//   - Security-scoped bookmarks: bookmarkData is created for the CHOSEN url;
//     creation failure does NOT block adding (network volumes keep working
//     THROUGH bookmarks, while any existing local folder is reachable by
//     canonical path); it is recorded on `lastBookmarkWarning` instead.
//   - Missing scan_locations.json → `locations()` returns []; unreadable or
//     unsupported file → THROW clean text; never auto-delete, never
//     fake-empty — the UI shows the verbatim failure.
//   - Vanished custom folders keep their LIST entry (`resolvedRoots()`
//     answers `url == nil` so the UI renders them missing honestly); they
//     only ever leave the list through `remove(id:)`.
//   - Writes are atomic: staged bytes swapped in with replaceItemAt/moveItem
//     (same-volume rename), so a failed write never corrupts the previous
//     file. Log surface: os.Logger "io.appupdater.AppUpdater/scanlocations",
//     used only before throwing/for bookmark tolerance.

import Foundation
import os

/// One user-chosen scan root, persisted in scan_locations.json. `canonicalPath`
/// is the dedupe identity AND the stable `id` (Identifiable) — one real folder
/// equals exactly one row. `bookmarkData` is a security-scoped bookmark taken
/// for the folder when it was added; nil is legal and documented on
/// `ScanLocationStore.add(_:)`. `addedAt` is display metadata, not identity.
public struct ScanLocation: Codable, Hashable, Sendable, Identifiable {
    public let canonicalPath: String
    /// Security-scoped bookmark, or nil when creating one failed
    /// (recorded honestly on `ScanLocationStore.lastBookmarkWarning`).
    public let bookmarkData: Data?
    public let addedAt: Date

    public var id: String { canonicalPath }

    public init(canonicalPath: String, bookmarkData: Data? = nil, addedAt: Date) {
        self.canonicalPath = canonicalPath
        self.bookmarkData = bookmarkData
        self.addedAt = addedAt
    }
}

/// One persisted location paired with whether it still resolves to a folder on
/// disk. `url == nil` means "vanished — still listed, owner can remove it";
/// the UI renders that as its missing-state row.
public struct ResolvedRoot: Sendable {
    public let location: ScanLocation
    public let url: URL?

    public init(location: ScanLocation, url: URL?) {
        self.location = location
        self.url = url
    }
}

/// Honest refusal/persistence failure with verbatim human `reason` text the
/// UI surfaces unchanged (the /Applications guard sentence is user-approved).
public struct ScanLocationError: LocalizedError, Sendable {
    public let reason: String
    public var errorDescription: String? { reason }
    public init(reason: String) { self.reason = reason }
}

/// Persistent store of custom scan locations over one explicit directory.
///
/// Sendability judgment (documented, per the `@unchecked` opt-in): every
/// stored property is immutable EXCEPT `lastBookmarkWarning` (+ its private
/// path companion), and every access to those is INSIDE the serial `NSLock`.
/// Location data is never cached in memory — the JSON file on disk is the
/// single source of truth and every public verb re-derives from it UNDER THAT
/// LOCK, so concurrent callers (main-thread UI, engine) see one consistent
/// serialized file state and `@unchecked Sendable` hides no real race.
/// `lastBookmarkWarning` is an instance-local observation of the most recent
/// bookmark attempt — deliberately NOT persisted (a fresh store starts
/// warning-free) — and should be read on the thread that performed the latest
/// mutation (the SwiftUI pane below is @MainActor-only).
public final class ScanLocationStore: @unchecked Sendable {

    /// File name inside the persistence directory (fixed schema contract).
    private static let fileName = "scan_locations.json"
    /// The only schema version this build reads/writes. Anything else is an
    /// honest, clean-text throw — never decode-guessing, never auto-migrating.
    private static let schemaVersion = 1

    private static let log = Logger(subsystem: "io.appupdater.AppUpdater", category: "scanlocations")

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    /// Store directory — passed REQUIRED explicitly at init (tests use temp
    /// directories; production wiring belongs to the coordinator).
    public let directory: URL

    /// Serial lock guarding `lastBookmarkWarning` (+ companion path) and
    /// serializing read-modify-write mutation sequences against the file.
    private let lock = NSLock()

    /// Why bookmark creation failed on the most recent tolerated `add(_:)`,
    /// or nil after a successful bookmark. Failure never blocks adding: the
    /// location persists with `bookmarkData == nil` and this line says why.
    public private(set) var lastBookmarkWarning: String?

    /// Canonical path the current warning describes, so `remove(id:)` can
    /// clear a warning about a location that is now gone.
    private var lastBookmarkWarningPath: String?

    /// The bookmark producer (internal seam: hermetic tests swap in a failing
    /// double — the tolerated-failure branch is otherwise unreachable since
    /// bookmarkData succeeds for any existing local directory).
    private let bookmarkDataForURL: @Sendable (URL) throws -> Data?

    /// Builds a store rooted at `directory`, touching NOTHING on disk (reads
    /// create nothing; directory + file appear lazily on first mutation).
    public convenience init(directory: URL) {
        self.init(directory: directory, bookmarkDataForURL: Self.systemBookmarkData(for:))
    }

    /// Test seam overload — not exported, never used in production.
    init(directory: URL, bookmarkDataForURL: @escaping @Sendable (URL) throws -> Data?) {
        self.directory = directory
        self.bookmarkDataForURL = bookmarkDataForURL
    }

    /// The system bookmark producer frozen by design:
    /// `url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)`.
    /// Static + internal: the public init names it in its BODY (public default
    /// arguments may not reference internals).
    internal static func systemBookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// File URL of the persistence file (`directory` + scan_locations.json).
    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    // MARK: Reading

    /// Reads the persisted locations, sorted by canonicalPath (plain `<`).
    /// Missing file → `[]` (honest absence; reads create nothing). Unreadable
    /// bytes / unsupported schemaVersion → THROW clean text — never fake-empty,
    /// never auto-delete.
    public func locations() throws -> [ScanLocation] {
        lock.lock(); defer { lock.unlock() }
        return try loadLocationsLocked()
    }

    /// Reads each location AND its on-disk truth: bookmark resolution first
    /// (`URL(resolvingBookmarkData:options:[]:relativeTo:nil)`), then the
    /// canonical path as fallback (a bookmark can go stale while the path
    /// still exists). Gone both ways → `url == nil`, still listed — vanish is
    /// displayed, only `remove(id:)` unlists. Never throws per-location: an
    /// unresolvable bookmark is an honest nil, not an error.
    public func resolvedRoots() throws -> [ResolvedRoot] {
        lock.lock(); defer { lock.unlock() }
        return try loadLocationsLocked().map { location in
            ResolvedRoot(location: location, url: Self.resolvedURL(from: location))
        }
    }

    /// Resolution ladder for one persisted location (pure, static — the honest
    /// nil contract needs no store state, so no lock).
    private static func resolvedURL(from location: ScanLocation) -> URL? {
        if let bookmarkData = location.bookmarkData {
            // Staleness is an `inout Bool` on this SDK; no live target → fall
            // through to the path fallback below.
            var stale = false
            let resolved = try? URL(
                resolvingBookmarkData: bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            if let resolved, isExistingDirectory(resolved) {
                return resolved
            }
        }
        let canonical = URL(fileURLWithPath: location.canonicalPath)
        return isExistingDirectory(canonical) ? canonical : nil
    }

    /// True when `url` exists on disk as a directory (symlinks followed —
    /// mirrors how the scanner weights its entries).
    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// The canonical identity string for a scan-location URL —
    /// `URL.resolvingSymlinksInPath()` plus a REQUIRED trailing-slash strip:
    /// on this SDK the API keeps a directory slash, so one real folder would
    /// present as "/Applications/" vs "/Applications" (guard comparison) or
    /// "…/X/" vs "…/X" (same folder re-derived after its deletion), breaking
    /// identity and dedupe. Stripping also mirrors the scanner's own
    /// `posixPath(of:)` policy. Remaining spelling is exactly what the
    /// filesystem hands back (no /private/var rewriting on this toolchain):
    /// identity is a stable STRING, never a pretified path.
    private static func canonicalPath(for url: URL) -> String {
        var path = url.resolvingSymlinksInPath().path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    // MARK: Mutations (save-through: persist on success, refuse = untouched disk)

    /// Adds `url` and persists the canonical sorted set. Refusal ladder, each
    /// an honest `ScanLocationError` never touching disk: nonexistent → not a
    /// directory → already present (symlink aliases included) → /Applications
    /// guard (verbatim copy). Bookmark creation failure is TOLERATED: the
    /// location persists with `bookmarkData == nil` and `lastBookmarkWarning`
    /// records why, cleared by the next success — applied only AFTER a
    /// successful persist.
    public func add(_ url: URL) throws {
        lock.lock(); defer { lock.unlock() }

        var isDirectory: ObjCBool = false
        let posixPath = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: posixPath, isDirectory: &isDirectory) else {
            throw ScanLocationError(reason:
                "could not add “\(posixPath)” as a scan location: the folder could not be found on this Mac (it may have been moved, renamed, or is not mounted)")
        }
        guard isDirectory.boolValue else {
            throw ScanLocationError(reason:
                "could not add “\(posixPath)” as a scan location: it is not a folder — scan locations are folders that contain apps, not files")
        }
        let canonicalPath = Self.canonicalPath(for: url)

        var locations = try loadLocationsLocked()
        if let clash = locations.first(where: { $0.canonicalPath == canonicalPath }) {
            throw ScanLocationError(reason:
                "could not add “\(posixPath)” as a scan location: it is already added (canonical path “\(clash.canonicalPath)” — the same real folder under a different spelling, e.g. a symlink)")
        }
        if canonicalPath.caseInsensitiveCompare("/Applications") == .orderedSame {
            throw ScanLocationError(reason:
                "could not add “\(posixPath)” as a scan location: the default /Applications root is always scanned and cannot also be a custom location")
        }

        var bookmark: Data?
        var bookmarkFailure: Error?
        do {
            bookmark = try bookmarkDataForURL(url)
        } catch {
            // Tolerated: recorded AFTER the persist below so a failed add
            // never leaves a warning about a location that is not there.
            bookmarkFailure = error
        }

        locations.append(ScanLocation(canonicalPath: canonicalPath, bookmarkData: bookmark, addedAt: Date()))
        try persistLocationsLocked(locations)

        // Persist succeeded — this mutation is real; refresh the warning now.
        switch bookmarkFailure {
        case .none:
            clearBookmarkWarningLocked()
        case .some(let failure):
            setBookmarkWarningLocked(chosenPath: posixPath, canonicalPath: canonicalPath, error: failure)
        }
    }

    /// Removes the location whose id (= canonical path) matches `id` and
    /// persists. Unknown ids throw honestly (the id is named in the error).
    /// When the removed row was the one the bookmark warning described, the
    /// warning clears with it; an unrelated removal leaves it untouched.
    public func remove(id: String) throws {
        lock.lock(); defer { lock.unlock() }

        var locations = try loadLocationsLocked()
        guard locations.contains(where: { $0.canonicalPath == id }) else {
            throw ScanLocationError(reason:
                "could not remove scan location “\(id)”: no custom location with that id is present (ids are the canonical paths shown in the pane; the file may have changed meanwhile)")
        }
        locations.removeAll { $0.canonicalPath == id }
        try persistLocationsLocked(locations)
        if lastBookmarkWarningPath == id { clearBookmarkWarningLocked() }
    }

    // MARK: Persistence internals (all called with `lock` held)

    /// JSON disk record — {"schemaVersion": 1, "locations": […]} — with
    /// warnings deliberately NOT persisted (see the class Sendability doc).
    private struct PersistedScanLocations: Codable {
        let schemaVersion: Int
        let locations: [ScanLocation]
    }

    private func loadLocationsLocked() throws -> [ScanLocation] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return [] }
        do {
            return try Self.decodePersisted(Data(contentsOf: fileURL)).locations
                .sorted { $0.canonicalPath < $1.canonicalPath }
        } catch {
            throw Self.unreadableFileError(directory: directory, underlying: error)
        }
    }

    /// Decode + schema gate split out so `loadLocationsLocked` stays one line:
    /// decode failures and wrong-schema failures share one clean-text contract.
    private static func decodePersisted(_ data: Data) throws -> PersistedScanLocations {
        let decoded = try Self.decoder.decode(PersistedScanLocations.self, from: data)
        guard decoded.schemaVersion == schemaVersion else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [], debugDescription:
                    "unsupported schemaVersion \(decoded.schemaVersion) (this build writes and reads 1 only)"))
        }
        return decoded
    }

    /// The CLEAN, user-readable error contract for an unreadable store file:
    /// what, where, and the promise that nothing was touched. Never auto-delete.
    private static func unreadableFileError(directory: URL, underlying: Error) -> ScanLocationError {
        log.error("scan_locations.json unreadable (\(String(describing: underlying), privacy: .public)) — throwing honestly, file untouched")
        return ScanLocationError(
            reason: "scan_locations.json could not be read from "
                + "“\(directory.path(percentEncoded: false))”: \(String(describing: underlying)). "
                + "The file has not been modified or deleted — fix or remove it manually, then retry.")
    }

    /// Persists the set (canonical order = sorted by canonicalPath) atomically:
    /// full bytes staged by a single createFile call OUTSIDE the target name,
    /// then swapped in with replaceItemAt/moveItem — a failed write anywhere
    /// before the swap leaves the previous file untouched.
    private func persistLocationsLocked(_ locations: [ScanLocation]) throws {
        let payload = PersistedScanLocations(
            schemaVersion: Self.schemaVersion,
            locations: locations.sorted { $0.canonicalPath < $1.canonicalPath })
        let data = try Self.encoder.encode(payload)

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(
            ".\(Self.fileName)-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staging) }

        guard FileManager.default.createFile(
            atPath: staging.path(percentEncoded: false), contents: data) else {
            throw ScanLocationError(
                reason: "could not stage scan_locations.json write in "
                    + "“\(directory.path(percentEncoded: false))” — nothing was changed")
        }

        do {
            if FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: fileURL)
            }
        } catch {
            throw ScanLocationError(
                reason: "could not swap scan_locations.json into place in "
                    + "“\(directory.path(percentEncoded: false))”: \(String(describing: error)) "
                    + "— the previous good file survives the atomic-write contract")
        }
    }

    // MARK: Bookmark-warning bookkeeping (lock held at every call site)

    private func clearBookmarkWarningLocked() {
        lastBookmarkWarning = nil
        lastBookmarkWarningPath = nil
    }

    /// Bookmark failure is TOLERATED at add time: the location still persists
    /// (by canonical path), and the warning says so, verbatim.
    private func setBookmarkWarningLocked(chosenPath: String, canonicalPath: String, error: Error) {
        let reason = "a security-scoped bookmark could not be created for “\(chosenPath)”: "
            + "\(error.localizedDescription) — the location was still added and is remembered by its "
            + "canonical path (“\(canonicalPath)”); scanning works while that path exists on this Mac."
        Self.log.notice("bookmark creation failed for \(canonicalPath, privacy: .public), tolerated")
        lastBookmarkWarning = reason
        lastBookmarkWarningPath = canonicalPath
    }
}
