// Source tier: Homebrew's public cask JSON API — WHOLE-INDEX variant (one file, one fetch).
//
// Gap closed here (GAP-ANALYSIS item #1, 2026-10-27 gap-closure sprint): Updatest
// keeps the ENTIRE cask catalog on disk — `brew_api_cache.json` (~19 MB live) with a
// companion `brew_api_etag.txt` — and revalidates it with a conditional GET
// (UPDATEST-FINDINGS §3.2: "cached in brew_api_cache.json with an ETag … 'Brew API
// revalidated (304): '"). The single-token source (CaskSource) fetches one cask per
// app and leans on a 14-entry hand-maintained alias table; a whole index makes the
// alias table maintenance RETIRED BY DESIGN: the correct token is found by scanning
// the loaded index's `app` artifacts, not by a lookup table that must be grown by
// hand (see bestMatch below).
//
// FILE LAYOUT in the explicitly-passed persistence directory (REQUIRED parameter —
// production passes the real Application Support dir, tests pass unique temp dirs;
// this store deliberately has NO implicit/default directory so a test can never
// silently touch the real one):
//   cask.json        — the RAW response body of the last 200 (never re-encoded),
//                      consumed verbatim for the next conditional GET
//   cask.json.etag   — the raw ETag header string, sent verbatim as If-None-Match
//
// LOAD SEMANTICS (each ensureLoaded call runs one full cycle; concurrent calls
// dedupe onto a single inflight task — sequential calls re-run the cycle by design,
// and AppState wiring calls ensure exactly once per scan pass):
//   1. If the in-memory index already holds records, it is authoritative and the
//      disk decode is skipped (every write path keeps memory and disk in sync).
//      Otherwise a present cache file is decoded from disk.
//   2. Conditional GET https://formulae.brew.sh/api/cask.json
//      (User-Agent "AppUpdater/0.1 (macOS)", timeouts 15s connect / 300s resource).
//      If-None-Match is sent ONLY when the store actually holds usable decoded
//      records AND the persisted ETag string is present: a poisoned cache never
//      claims the ETag's bytes else it could deadlock on a 304 for bytes it cannot
//      decode.
//   3. Status handling:
//      200 → decode the body FIRST, then persist raw bytes + ETag (atomic staging
//            swap, ScheduleFileStore pattern), then hand out the decoded records.
//            Decode happens before persist deliberately: an undecodable body must
//            NEVER clobber a good cache, and no ETag is ever recorded for bytes
//            this store failed to decode (that ETag would pin dead bytes forever).
//      304 → revalidated: the in-memory/disk-decoded records stand, no refetch.
//      304 with NO usable cached records → protocol absurdity, recorded honestly.
//            Self-heal: the persisted ETag is dropped so the next cycle becomes an
//            unconditional GET.
//      anything else / network throw / decode throw → lastError records the
//            verbatim status ("HTTP 500") or the verbatim error (`String
//            (describing:)`), returns false, logs once (os.Logger, subsystem
//            "io.appupdater.AppUpdater", category "cask-index").
//
// FAILURE SEMANTICS BEYOND THE BOOL: when a cycle fails but usable records were
// still loaded (disk cache decoded, network revalidation failed), the records STAY
// available for matching — stale-but-verifiable data beats an empty verdict, and
// `lastError` carries the honest revalidation failure. The returned Bool means
// "this cycle revalidated/refreshed cleanly", NOT "records are usable"; callers
// that must distinguish read `isLoaded`/`cachedRecordCount` (≡ records > 0) and
// `lastError` together. Disk-persist failures are logged but do NOT fail the cycle
// (the session's in-memory index is complete); `lastError` tracks only the
// status/network/decode pipeline per the brief.
//
// MATCHING (honest boundary — a record is returned only if ITS OWN `app`
// artifacts validate the installed app via the shared `CaskMatching` validators,
// or — strictly weaker and gated — through the pkg-only evidence class in (c);
// a record failing both validations is never returned, token path or scan path):
//   a. token hit: `CaskMatching.candidateToken(from: app.name)` looked up in the
//      loaded index and accepted only if `CaskMatching.caskMatchesInstalledApp`
//      agrees (artifact evidence).
//   b. artifact scan (THE ALIAS-KILLER): a linear scan over ALL loaded records
//      validated the same way. This is how app "Chrome" resolves to cask
//      `google-chrome` (artifact "Google Chrome.app") with zero alias-table
//      maintenance and zero extra fetches. Ties: prefer a record whose
//      `displayName` equals app.name case-insensitively; if several still match,
//      the FIRST record in index order is kept and the ambiguity is recorded in
//      the log (os.Logger, category "cask-index").
//   c. pkg-only fallback (2026-10-28, staged owner-command flow): reached ONLY
//      when zero app-artifact matches exist anywhere (a) and (b) both empty.
//      Pkg-only casks (tailscale-app shape: artifacts carry `pkg`, NO `app`)
//      can never satisfy (a)/(b), so they previously never drove the staged
//      sudo-installer flow at all. Now ONE pkg-claiming record may match iff
//      `CaskMatching.pkgArtifactsMatchInstalledApp` accepts (derived pkg-name
//      equality + sha256-hex floor + `url` really is the .pkg). Weaker evidence
//      demands UNIQUENESS: 2+ distinct claiming records return nil, and the
//      ambiguity is recorded in the log like (b)'s note.
//
// VISIBILITY NOTE (compile-forced, flagged to the coordinator): `CaskRecord` is
// internal to this module (defined in CaskResponse.swift, a shared file outside
// this lane's ownership), so `bestMatch(for:)`, `record(withToken:)` and
// `resolvedMatch(for:)` are compiled internal rather than public — Swift rejects a
// public API exposing an internal type. Tests reach them through @testable import;
// a later lane may revisit by opening up CaskRecord (shared-file decision).
// `ensureLoaded`, `dropCache`, `isLoaded`, `cachedRecordCount` and `lastError`
// carry no internal types and are public as briefed.

import Foundation
import os

public actor CaskIndexStore {

    /// Last failure of the LATEST ensure cycle, VERBATIM: an HTTP status failure is
    /// recorded as "HTTP <code>"; a thrown network/decode error as
    /// `String(describing:)`. nil after a successful cycle (each cycle starts by
    /// clearing the previous verdict) and after dropCache.
    public private(set) var lastError: String?

    /// The loaded index is available for matching (≡ cachedRecordCount > 0).
    public var isLoaded: Bool { !records.isEmpty }

    /// Number of cask records held in memory after the last successful decode.
    public var cachedRecordCount: Int { records.count }

    private var records: [CaskRecord] = []
    private var tokenIndex: [String: CaskRecord] = [:]
    private var inflight: Task<Bool, Never>?

    private let directory: URL
    private let session: URLSession

    private static let cacheFileName = "cask.json"
    private static let etagFileName = "cask.json.etag"
    private static let indexURLString = "https://formulae.brew.sh/api/cask.json"
    private static let userAgent = "AppUpdater/0.1 (macOS)"

    /// Log surface: os.Logger subsystem "io.appupdater.AppUpdater", category
    /// "cask-index". Error lines carry the verbatim failure exactly once per
    /// failed cycle; stale-attention notes (poisoned cache, ambiguity, dropped
    /// ETag) are notices.
    private nonisolated static let log = Logger(
        subsystem: "io.appupdater.AppUpdater", category: "cask-index")

    /// Required explicit persistence directory (see header). touch nothing on init.
    public init(directory: URL, session: URLSession) {
        self.directory = directory
        self.session = session
    }

    /// Production convenience: builds the tightened-default session internally
    /// (identical double-init pattern to CaskSource — the injected init above is
    /// the hermetic test seam).
    ///
    /// NOTE: actors cannot declare `convenience` initializers (unlike structs and
    /// classes); this delegating init still has the convenience role.
    public init(directory: URL) {
        self.init(directory: directory, session: URLSession(configuration: Self.defaultConfiguration()))
    }

    /// URLSession default configuration with tightened timeouts (15s request /
    /// 300s resource — the 19 MB index is a large resource, so the resource window
    /// is generous where the single-cask source stays at 60s).
    nonisolated static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 300
        return configuration
    }

    // MARK: - Load pipeline

    /// Loads the index: disk decode + one conditional GET per the header contract.
    /// Concurrent callers share the single inflight task (all receive the same
    /// verdict); sequential callers start a fresh cycle.
    public func ensureLoaded() async -> Bool {
        if let existing = inflight { return await existing.value }
        let task = Task { await self.runLoadCycle() }
        inflight = task
        defer { inflight = nil }
        return await task.value
    }

    /// Wipes the persisted cache files and the in-memory index (best-effort file
    /// removal — a failed removal leaves the file for the next cycle to overwrite;
    /// also clears `lastError`, making the store semantically "never loaded").
    public func dropCache() async {
        records = []
        tokenIndex = [:]
        lastError = nil
        try? FileManager.default.removeItem(at: cacheFileURL)
        try? FileManager.default.removeItem(at: etagFileURL)
    }

    // MARK: - Matching (internal: CaskRecord is module-internal, see header note)

    /// Exact-token hit: the loaded record whose `token` field equals `token`.
    /// No validation here — callers accept only through the artifact validators.
    func record(withToken token: String) async -> CaskRecord? {
        tokenIndex[token]
    }

    /// The matching record for `app`, or nil. Never returns a record that fails
    /// validation (app-artifact evidence, or the strictly-gated pkg-only class —
    /// see header "MATCHING").
    func bestMatch(for app: InstalledApp) async -> CaskRecord? {
        await resolvedMatch(for: app)?.record
    }

    /// bestMatch plus HOW it matched — the basis fragment feeds CaskIndexSource's
    /// honest sourceDetail text ("matched by token 'x'" / "matched by
    /// artifact-name 'Y.app'" / "matched by pkg-artifact 'F.pkg' (derived 'n')").
    func resolvedMatch(for app: InstalledApp) async -> CaskIndexMatch? {
        // (a) derived token, accepted only with artifact evidence.
        if let token = CaskMatching.candidateToken(from: app.name),
           let record = tokenIndex[token],
           CaskMatching.caskMatchesInstalledApp(record, for: app) {
            return .token(token: token, record: record)
        }

        // (b) the alias-killer scan — validation-identical sweep over every loaded
        // record; a token hit whose artifacts do NOT match falls through to here.
        let matches = records.filter { CaskMatching.caskMatchesInstalledApp($0, for: app) }
        guard let chosen = matches.first(where: {
            $0.displayName?.caseInsensitiveCompare(app.name) == .orderedSame
        }) ?? matches.first else {
            // (c) zero app-artifact matches anywhere — the strictly-gated
            // pkg-only evidence class may still fire (never the other way
            // around: (a)/(b) ALWAYS win when they fire).
            return pkgDerivedMatch(for: app)
        }
        if matches.count > 1 {
            // The "note it" directive: ambiguity is recorded whenever it is broken
            // (string built outside the logger macro — OSLogMessage is not combinable).
            let kept = chosen.token ?? "?"
            let note = "cask bestMatch for '\(app.name)' ambiguous (\(matches.count) artifact matches) — kept '\(kept)'"
            Self.log.notice("\(note, privacy: .public)")
        }
        let artifact = Self.matchingArtifact(of: chosen, for: app)
        return .artifactName(
            record: chosen,
            artifact: artifact ?? "artifact-name match (artifact list inconsistent with validator)")
    }

    /// (c) The weaker evidence class: pkg-only casks whose pkg filename derives
    /// the installed app's name. Gated by `CaskMatching.pkgArtifactsMatchInstalledApp`
    /// (derived-name equality + sha256 floor + url-is-the-pkg) AND by uniqueness —
    /// 2+ distinct claiming records return nil, because a wrong derivation here
    /// would stage the WRONG pkg for a sudo install.
    private func pkgDerivedMatch(for app: InstalledApp) -> CaskIndexMatch? {
        let pkgMatches = records.filter { CaskMatching.pkgArtifactsMatchInstalledApp(record: $0, for: app) }
        // "Distinct" = distinct cask tokens: the index can hold duplicate entries
        // under one token (installDecodedRecords last-wins), and one cask claiming
        // twice is still ONE cask. Tokenless records each stand alone.
        var seenTokens = Set<String>()
        let distinct = pkgMatches.filter { record in
            guard let token = record.token else { return true }
            return seenTokens.insert(token).inserted
        }
        guard distinct.count == 1, let chosen = distinct.first else {
            if distinct.count > 1 {
                // Same "note it" directive as the artifact ambiguity above.
                let note = "cask pkg match for '\(app.name)' ambiguous (\(distinct.count) distinct pkg-only records) — weaker evidence requires uniqueness, refusing"
                Self.log.notice("\(note, privacy: .public)")
            }
            return nil
        }
        guard let evidence = Self.matchingPkgArtifact(of: chosen, for: app) else {
            // pkgArtifactsMatchInstalledApp accepted but the name-only mirror
            // finds nothing — the validator's policy moved; never fabricate a
            // basis (same honesty contract as matchingArtifact's fallback).
            return nil
        }
        return .pkgArtifact(record: chosen, artifact: evidence.artifact, derived: evidence.derived)
    }

    /// Derive-only mirror of `CaskMatching.caskMatchesInstalledApp` internals,
    /// used solely to NAME the matched artifact for the sourceDetail string. The
    /// accept/reject decision itself always delegates to the canonical validator;
    /// these two could only disagree if CaskMatching's policy changed, in which
    /// case resolvedMatch names the honest fallback above.
    private nonisolated static func matchingArtifact(of record: CaskRecord, for app: InstalledApp) -> String? {
        let pathBasename = (app.path as NSString).lastPathComponent
        let installed = Set([
            CaskMatching.normalizeBundleName(app.name),
            CaskMatching.normalizeBundleName(pathBasename),
        ])
        return record.artifactAppNames.first { installed.contains(CaskMatching.normalizeBundleName($0)) }
    }

    /// Derive-only mirror of `CaskMatching.pkgArtifactsMatchInstalledApp`'
    /// name comparison, used solely to NAME the matched pkg artifact + its
    /// derived name for the sourceDetail string. The accept/reject decision
    /// itself always delegates to the canonical validator (sha256/url floors
    /// included); these two could only disagree if CaskMatching's policy
    /// changed, in which case pkgDerivedMatch honestly returns nil.
    private nonisolated static func matchingPkgArtifact(
        of record: CaskRecord, for app: InstalledApp
    ) -> (artifact: String, derived: String)? {
        let pathBasename = (app.path as NSString).lastPathComponent
        let installed = Set([
            CaskMatching.normalizeBundleName(app.name),
            CaskMatching.normalizeBundleName(pathBasename),
        ])
        for artifact in record.pkgArtifactNames {
            if let derived = CaskMatching.pkgDerivedMatchName(fromPkgFilename: artifact),
               installed.contains(derived) {
                return (artifact, derived)
            }
        }
        return nil
    }

    // MARK: - Cycle internals

    private func runLoadCycle() async -> Bool {
        lastError = nil

        let usableCache = provideUsableCacheIfNeeded()
        // The ETag is read FRESH from the persisted file every cycle — persisted
        // bytes are the single source of truth (a failed etag persist therefore
        // costs one unconditional GET next cycle, never a hidden mismatch).
        let persistedETag = readPersistedETag()

        guard let endpoint = Self.indexURL else {
            return failCycle("invalid whole-index endpoint URL \(Self.indexURLString)")
        }
        var request = URLRequest(url: endpoint)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // Conditional GET only when usable records exist — a cache this store
        // cannot decode never claims its ETag's bytes (see header §LOAD 2).
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
                    "cask index 304 without usable cached records — dropping persisted ETag for a fresh GET next cycle"
                )
                try? FileManager.default.removeItem(at: etagFileURL)
                return failCycle("HTTP 304 without a usable cached cask.json")
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

    /// Fake-load stage: returns whether usable records are held after this point
    /// (memory first, then a disk decode; an existing-but-undecodable file is
    /// noticed and never fatal — the cycle's network leg recovers it).
    private func provideUsableCacheIfNeeded() -> Bool {
        if !records.isEmpty { return true }
        guard FileManager.default.fileExists(atPath: cacheFileURL.path) else { return false }
        let bytes: Data
        do {
            bytes = try Data(contentsOf: cacheFileURL)
        } catch {
            Self.log.notice(
                "cached cask.json unreadable (\(String(describing: error), privacy: .public)) — falling back to an unconditional GET"
            )
            return false
        }
        do {
            try installDecodedRecords(from: bytes)
            return true
        } catch {
            Self.log.notice(
                "cached cask.json undecodable (\(String(describing: error), privacy: .public)) — falling back to an unconditional GET"
            )
            return false
        }
    }

    /// Installs decoded records + the token index into memory. Decode failure
    /// leaves nothing half-installed (records/tokenIndex only change on success).
    private func installDecodedRecords(from bytes: Data) throws {
        let decoded = try JSONDecoder().decode([CaskRecord].self, from: bytes)
        var index: [String: CaskRecord] = [:]
        for record in decoded {
            if let token = record.token { index[token] = record } // last-wins; tokens are unique in the index
        }
        records = decoded
        tokenIndex = index
    }

    private func readPersistedETag() -> String? {
        let raw = try? String(contentsOf: etagFileURL, encoding: .utf8)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// The whole-index endpoint (nil is unreachable for the frozen constant, but
    /// the guard keeps the Sources target free of force unwraps).
    private nonisolated static var indexURL: URL? { URL(string: indexURLString) }

    /// Persists the RAW response body + ETag after a successful decode.
    /// Write-through but never blocking the verdict: failures are logged once and
    /// the (already-decoded) memory index stands; `lastError` stays clear because
    /// the load pipeline itself succeeded (see header "FAILURE SEMANTICS").
    private func persistCache(bytes: Data, responseETag: String?) {
        let etag = responseETag?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try writeBytesAtomically(bytes, to: cacheFileURL)
            if let etag, !etag.isEmpty {
                guard FileManager.default.createFile(
                    atPath: etagFileURL.path, contents: Data(etag.utf8)) else {
                    Self.log.error(
                        "cask index etag persist failed — next cycle refetches the full cask.json unconditionally"
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
                "cask index cache persist failed (\(String(describing: error), privacy: .public))"
            )
        }
    }

    /// Staging file + atomic swap (ScheduleFileStore pattern; staging lives in the
    /// target directory so the final rename is same-volume).
    private func writeBytesAtomically(_ data: Data, to target: URL) throws {
        let dir = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staging = dir.appendingPathComponent(
            ".\(target.lastPathComponent)-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staging) }

        guard FileManager.default.createFile(atPath: staging.path, contents: data) else {
            throw CaskIndexWriteFailure(reason: "could not stage cask.json write in \(dir.path)")
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
            "cask index load failed: \(reason, privacy: .public)"
        )
        return false
    }

    private var cacheFileURL: URL { directory.appendingPathComponent(Self.cacheFileName) }
    private var etagFileURL: URL { directory.appendingPathComponent(Self.etagFileName) }
}

/// Honest persistence failure (log-surface only in this store; the in-memory index
/// still stands, so persistence defects never fail a load cycle).
struct CaskIndexWriteFailure: Error, Sendable {
    let reason: String
}

/// Match result carrying HOW the record was found — the basis that
/// `CaskIndexSource` cites in its honest sourceDetail text. Internal: exposes the
/// module-internal CaskRecord (see store header VISIBILITY NOTE).
enum CaskIndexMatch: Sendable {
    /// Matched through the derived-token path (exact token + artifact validation).
    case token(token: String, record: CaskRecord)
    /// Matched through the whole-index artifact scan (the alias-killer path).
    case artifactName(record: CaskRecord, artifact: String)
    /// Matched through the strictly-gated pkg-only evidence class (weaker:
    /// filename derivation, uniqueness required) behind the staged
    /// owner-command flow. Reached only when zero app-artifact matches exist.
    case pkgArtifact(record: CaskRecord, artifact: String, derived: String)

    var record: CaskRecord {
        switch self {
        case .token(_, let record): return record
        case .artifactName(let record, _): return record
        case .pkgArtifact(let record, _, _): return record
        }
    }

    /// Fragment inside CaskIndexSource's sourceDetail:
    /// "token 'google-chrome'" / "artifact-name 'Google Chrome.app'" /
    /// "pkg-artifact 'Tailscale-1.104.4-macos.pkg' (derived 'tailscale')" —
    /// the pkg fragment names the weaker evidence class honestly.
    var basisFragment: String {
        switch self {
        case .token(let token, _): return "token '\(token)'"
        case .artifactName(_, let artifact): return "artifact-name '\(artifact)'"
        case .pkgArtifact(_, let artifact, let derived):
            return "pkg-artifact '\(artifact)' (derived '\(derived)')"
        }
    }
}
