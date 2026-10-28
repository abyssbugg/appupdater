// Brew tier: Homebrew FORMULA whole-index store — ETag-cached, decode-lite
// (GAP-ANALYSIS #2 remainder; the cask half of this pattern shipped as
// CaskIndexStore, whose conventions this file mirrors INTENTIONALLY and
// VERBATIM — the two stores stay separate files/types because the cask lane's
// file ownership is closed).
//
// EVIDENCE (docs/reverse/UPDATEST-FINDINGS.md §3.2): Updatest keeps the ENTIRE
// brew API catalog on disk with a companion ETag file and revalidates with a
// conditional GET ("Brew API revalidated (304)"). The formulae side of that
// catalog is https://formulae.brew.sh/api/formula.json (the formula analog of
// the cask.json whole index the cask lane already ships).
//
// DECODE-LITE CONTRACT: only `name`, the version (the `versions.stable` map
// entry — the modern shape — falling back to the legacy top-level `version`
// string), `homepage` and `desc` are decoded; everything else in each record
// is ignored on the floor. A record with NO decodable version carries
// `version == nil` — never synthesized (the CaskRecord rule). The raw response
// body is persisted VERBATIM (never re-encoded) so the next conditional GET
// presents the exact bytes the ETag was issued for.
//
// FILE LAYOUT in the explicitly-passed persistence directory (REQUIRED
// parameter — production passes the real Application Support dir, tests pass
// unique temp dirs; NO implicit/default directory, so a test can never
// silently touch the real one — the CaskIndexStore design, copied):
//   formula.json        — the RAW response body of the last 200
//   formula.json.etag   — the raw ETag header string, sent verbatim as If-None-Match
//
// LOAD SEMANTICS (identical to CaskIndexStore — read its header for the full
// contract): in-memory records authoritative → disk decode → one conditional
// GET (User-Agent "AppUpdater/0.1 (macOS)", timeouts 15s connect / 300s
// resource; If-None-Match sent ONLY with usable decoded records AND a present
// persisted ETag); 200 → decode FIRST, then persist bytes + ETag (atomic
// staging swap); 304 → revalidated, records stand; 304 without usable records
// → recorded absurdity + persisted-ETag drop (self-heal to unconditional);
// anything else / network throw / decode throw → verbatim `lastError`, honest
// false, one log line (os.Logger, subsystem "io.appupdater.AppUpdater",
// category "brew-formula-index").
//
// FAILURE SEMANTICS BEYOND THE BOOL (copied): a failed cycle leaves
// already-loaded records USABLE — stale-but-verifiable beats an empty verdict;
// `isLoaded`/`cachedRecordCount` + `lastError` distinguish the states. Disk
// persist failures are logged and do NOT fail the cycle.
//
// LOOKUP: `record(named:)` — exact name hit against the loaded index (formula
// names are the brew index identifier; no artifact validation exists on this
// side — a formula is CLI software, not a scanned .app). Internal like the
// cask store's matchers; tests reach it via @testable import.
//
// CONSENT BOUNDARY: this store only ever GETs a public JSON index. It never
// runs brew, never installs, never mutates anything — read-only data plane,
// same as every Brew/ file.

import Foundation
import os

/// One decoded formula record — the lite projection (see header).
public struct BrewFormulaRecord: Codable, Hashable, Sendable {
    /// The formula name (brew index identifier), verbatim.
    public let name: String
    /// The self-attested stable version, or the legacy top-level version;
    /// nil when the record declares none (never synthesized).
    public let version: String?
    public let homepage: String?
    public let desc: String?

    private enum Keys: String, CodingKey {
        case name, versions, version, homepage, desc
    }
    private enum VersionKeys: String, CodingKey {
        case stable
    }

    public init(name: String, version: String?, homepage: String?, desc: String?) {
        self.name = name
        self.version = version
        self.homepage = homepage
        self.desc = desc
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        name = try container.decode(String.self, forKey: .name)
        // Modern shape: `versions` object carrying `stable`. Legacy shape:
        // top-level `version` string. Absent/blank → nil (never synthesized).
        if let versions = try? container.nestedContainer(keyedBy: VersionKeys.self, forKey: .versions) {
            let stable = try? versions.decodeIfPresent(String.self, forKey: .stable)
            version = Self.blankToNil(stable)
        } else {
            let legacy = try? container.decodeIfPresent(String.self, forKey: .version)
            version = Self.blankToNil(legacy)
        }
        homepage = Self.blankToNil(try? container.decodeIfPresent(String.self, forKey: .homepage))
        desc = Self.blankToNil(try? container.decodeIfPresent(String.self, forKey: .desc))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encodeIfPresent(homepage, forKey: .homepage)
        try container.encodeIfPresent(desc, forKey: .desc)
    }

    private static func blankToNil(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public actor BrewFormulaIndexStore {

    /// Last failure of the LATEST ensure cycle, VERBATIM (CaskIndexStore rule:
    /// "HTTP <code>" for status failures, `String(describing:)` for thrown
    /// errors; nil after a successful cycle and after dropCache).
    public private(set) var lastError: String?

    /// The loaded index is available for lookup (≡ cachedRecordCount > 0).
    public var isLoaded: Bool { !records.isEmpty }

    /// Number of formula records held in memory after the last successful decode.
    public var cachedRecordCount: Int { records.count }

    private var records: [BrewFormulaRecord] = []
    private var nameIndex: [String: BrewFormulaRecord] = [:]
    private var inflight: Task<Bool, Never>?

    private let directory: URL
    private let session: URLSession

    private static let cacheFileName = "formula.json"
    private static let etagFileName = "formula.json.etag"
    private static let indexURLString = "https://formulae.brew.sh/api/formula.json"
    private static let userAgent = "AppUpdater/0.1 (macOS)"

    /// Log surface: os.Logger subsystem "io.appupdater.AppUpdater", category
    /// "brew-formula-index" (the cask store's pattern, own category).
    private nonisolated static let log = Logger(
        subsystem: "io.appupdater.AppUpdater", category: "brew-formula-index")

    /// Required explicit persistence directory (see header). Touches nothing on init.
    public init(directory: URL, session: URLSession) {
        self.directory = directory
        self.session = session
    }

    /// Production convenience (actors cannot declare `convenience`; the
    /// injected init above is the hermetic test seam — CaskIndexStore pattern).
    public init(directory: URL) {
        self.init(directory: directory, session: URLSession(configuration: Self.defaultConfiguration()))
    }

    /// Tightened timeouts (15s request / 300s resource — the formula index is a
    /// multi-megabyte resource; same generous window as the cask whole index).
    nonisolated static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 300
        return configuration
    }

    // MARK: - Load pipeline

    /// Loads the index: disk decode + one conditional GET per the header
    /// contract. Concurrent callers share the single inflight task; sequential
    /// callers start a fresh cycle.
    public func ensureLoaded() async -> Bool {
        if let existing = inflight { return await existing.value }
        let task = Task { await self.runLoadCycle() }
        inflight = task
        defer { inflight = nil }
        return await task.value
    }

    /// Wipes the persisted cache files and the in-memory index (best-effort
    /// removal; also clears `lastError` — semantically "never loaded" again).
    public func dropCache() async {
        records = []
        nameIndex = [:]
        lastError = nil
        try? FileManager.default.removeItem(at: cacheFileURL)
        try? FileManager.default.removeItem(at: etagFileURL)
    }

    // MARK: - Lookup (internal; tests via @testable import)

    /// Exact-name hit: the loaded record whose `name` equals `name`; nil on a
    /// miss. No further validation exists on the formula side (see header).
    func record(named name: String) async -> BrewFormulaRecord? {
        nameIndex[name]
    }

    // MARK: - Cycle internals (CaskIndexStore conventions, mirrored)

    private func runLoadCycle() async -> Bool {
        lastError = nil

        let usableCache = provideUsableCacheIfNeeded()
        // The ETag is read FRESH from the persisted file every cycle —
        // persisted bytes are the single source of truth.
        let persistedETag = readPersistedETag()

        guard let endpoint = Self.indexURL else {
            return failCycle("invalid whole-index endpoint URL \(Self.indexURLString)")
        }
        var request = URLRequest(url: endpoint)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // Conditional GET only when usable records exist — a cache this store
        // cannot decode never claims its ETag's bytes.
        if usableCache, let persistedETag {
            request.setValue(persistedETag, forHTTPHeaderField: "If-None-Match")
        }

        let payload: (data: Data, response: URLResponse)
        do {
            payload = try await session.data(for: request)
        } catch {
            return failCycle(String(describing: error))
        }

        guard let http = payload.response as? HTTPURLResponse else {
            return failCycle("non-HTTP response from \(Self.indexURLString)")
        }
        if http.statusCode == 304 {
            guard usableCache else {
                // Protocol absurdity (304 for bytes we cannot hold). Self-heal:
                // let the next cycle go unconditional.
                Self.log.notice(
                    "formula index 304 without usable cached records — dropping persisted ETag for a fresh GET next cycle"
                )
                try? FileManager.default.removeItem(at: etagFileURL)
                return failCycle("HTTP 304 without a usable cached formula.json")
            }
            return true // revalidated; the decoded records stand, no refetch
        }
        guard http.statusCode == 200 else {
            return failCycle("HTTP \(http.statusCode)")
        }

        do {
            try installDecodedRecords(from: payload.data)
        } catch {
            // Undecodable body: the previous records/disk cache stand untouched.
            return failCycle(String(describing: error))
        }
        persistCache(bytes: payload.data, responseETag: http.value(forHTTPHeaderField: "ETag"))
        return true
    }

    /// Memory first, then a disk decode; an existing-but-undecodable file is
    /// noticed and never fatal — the cycle's network leg recovers it.
    private func provideUsableCacheIfNeeded() -> Bool {
        if !records.isEmpty { return true }
        guard FileManager.default.fileExists(atPath: cacheFileURL.path) else { return false }
        let bytes: Data
        do {
            bytes = try Data(contentsOf: cacheFileURL)
        } catch {
            Self.log.notice(
                "cached formula.json unreadable (\(String(describing: error), privacy: .public)) — falling back to an unconditional GET"
            )
            return false
        }
        do {
            try installDecodedRecords(from: bytes)
            return true
        } catch {
            Self.log.notice(
                "cached formula.json undecodable (\(String(describing: error), privacy: .public)) — falling back to an unconditional GET"
            )
            return false
        }
    }

    /// Installs decoded records + the name index into memory. Decode failure
    /// leaves nothing half-installed (decode-before-persist discipline).
    private func installDecodedRecords(from bytes: Data) throws {
        let decoded = try JSONDecoder().decode([BrewFormulaRecord].self, from: bytes)
        var index: [String: BrewFormulaRecord] = [:]
        for record in decoded {
            index[record.name] = record // last-wins; names are unique in the index
        }
        records = decoded
        nameIndex = index
    }

    private func readPersistedETag() -> String? {
        let raw = try? String(contentsOf: etagFileURL, encoding: .utf8)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// The whole-index endpoint (nil is unreachable for the frozen constant,
    /// but the guard keeps the target free of force unwraps).
    private nonisolated static var indexURL: URL? { URL(string: indexURLString) }

    /// Persists the RAW response body + ETag after a successful decode.
    /// Write-through but never blocking the verdict: failures are logged once
    /// and the (already-decoded) memory index stands; `lastError` stays clear
    /// because the load pipeline itself succeeded.
    private func persistCache(bytes: Data, responseETag: String?) {
        let etag = responseETag?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try writeBytesAtomically(bytes, to: cacheFileURL)
            if let etag, !etag.isEmpty {
                guard FileManager.default.createFile(
                    atPath: etagFileURL.path, contents: Data(etag.utf8)) else {
                    Self.log.error(
                        "formula index etag persist failed — next cycle refetches the full formula.json unconditionally"
                    )
                    return
                }
            } else {
                // No ETag on the wire: the persisted etag would no longer
                // correspond to these bytes — drop it (next cycle: full GET).
                try? FileManager.default.removeItem(at: etagFileURL)
            }
        } catch {
            Self.log.error(
                "formula index cache persist failed (\(String(describing: error), privacy: .public))"
            )
        }
    }

    /// Staging file + atomic swap (ScheduleFileStore pattern; staging lives in
    /// the target directory so the final rename is same-volume).
    private func writeBytesAtomically(_ data: Data, to target: URL) throws {
        let dir = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staging = dir.appendingPathComponent(
            ".\(target.lastPathComponent)-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staging) }

        guard FileManager.default.createFile(atPath: staging.path, contents: data) else {
            throw BrewFormulaIndexWriteFailure(reason: "could not stage formula.json write in \(dir.path)")
        }
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: target)
        }
    }

    /// The ONE error exit of a cycle: verbatim reason in `lastError`, one log
    /// line, honest false.
    private func failCycle(_ reason: String) -> Bool {
        lastError = reason
        Self.log.error(
            "formula index load failed: \(reason, privacy: .public)"
        )
        return false
    }

    private var cacheFileURL: URL { directory.appendingPathComponent(Self.cacheFileName) }
    private var etagFileURL: URL { directory.appendingPathComponent(Self.etagFileName) }
}

/// Honest persistence failure (log-surface only; the in-memory index still
/// stands, so persistence defects never fail a load cycle — CaskIndexStore).
struct BrewFormulaIndexWriteFailure: Error, Sendable {
    let reason: String
}
