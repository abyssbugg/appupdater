// Source tier: GitHub Releases — the Updatest "/releases/latest" recipe
// (docs/reverse/UPDATEST-FINDINGS.md §3.6 + §4.2; GAP-ANALYSIS.md item #3).
//
// Endpoint + request shape (brief-locked for this lane):
//   GET https://api.github.com/repos/<owner>/<repo>/releases/latest
//   Accept: application/vnd.github.v3+json
//   User-Agent: AppUpdater/0.1 (macOS)
//   If-None-Match: <raw etag> — sent ONLY when the persisted ETag cache has one
//
// Honesty framing: Updatest ships the in-product label "Best-effort update
// detection. May be rate limited." and the install model is MANUAL ("Updates
// must be downloaded directly from the GitHub release page", "GitHub release
// data may be inaccurate"). This source claims ONLY what the release JSON
// states; the install side already refuses updates without verifyable bytes,
// so an info-only claim (downloadURL nil) is a valid return, never an error.
// No version is ever synthesized: a release without `tag_name` is skipped
// (honest miss), and tags travel verbatim (whatever their shape).
//
// Candidate policy (max 2 per check, deduped, order preserved):
//   - Pinned init: the pinned owner/repo is the ONLY candidate — user
//     attestation, validated by nothing else (Updatest's manual-pinning
//     model). Invalid slug → explicit empty candidate list (never the
//     default harvest) → honest nil with zero requests.
//   - nil repoProvider → default provider harvests from the app's OWN
//     `sparkleFeedURL` ONLY (zero extra network): https + host github.com
//     → first two path segments = owner/repo (trailing ".git" stripped);
//     hosts "githubusercontent.com" / "raw.githubusercontent.com" → first
//     two segments. This keeps .github claims quiet for every app EXCEPT
//     those whose own Sparkle feed lives on GitHub — honest and bounded.
//   - A custom provider returning [] says "no candidates" actively (wins
//     over the default harvest); returning nil means "decide yourself"
//     (default harvest runs); >2 refs get capped to the first 2 UNIQUE.
//
// Status map (per candidate):
//   200            → persist etag+body into the cache, then parse
//   304            → reuse the cached verbatim body (no etag → honest miss;
//                    we never send If-None-Match without a cache entry anyway)
//   404            → continue to the next candidate; none left → nil (honest miss)
//   403 with       → THROW with the verbatim honest message
//   X-RateLimit-     "GitHub API rate limit exhausted (403) — releases/latest
//   Remaining "0"    for '<owner>/<repo>'" so UpdateCheckEngine.failures
//                    surfaces it. Thrown immediately: the limit is account/IP
//                    wide, so trying the next candidate would just 403 again
//                    and demote a diagnosable failure to a silent nil.
//   other status / → honest miss (continue to next candidate / nil); network
//   network error    errors surface through next-candidate-continue or nil.
//
// Parse rules: `tag_name` REQUIRED (verbatim into newestShortVersion);
// `published_at` ISO8601 → Date (fractional-seconds variant tolerated,
// missing → nil); `body` → releaseNotes; assets[].name + assets[]
// .browser_download_url → the macOS asset pick.
//
// Asset pick for downloadURL (documented tie-break order):
//   1. extension tier: `.dmg` beats `.zip` — other extensions are never picked
//      (.pkg/.exe/.deb/.rpm/.apk/.AppImage stay ignored by construction)
//   2. within the winning tier: the first asset whose name contains "arm64"
//      or "aarch64" (case-insensitive) beats everything else in the tier —
//      including an earlier x86_64/x64-labeled asset; x64-labeled and
//      unlabeled names rank equally and fall to first-match in array order
//   3. no eligible asset → downloadURL nil (info-only claim)
//   HTTPS-ONLY FLOOR: an asset whose browser_download_url is not https is
//   skipped from the pick (derived-URL honesty; the request URL itself is
//   constructed https by definition).
//
// SHA-256 sidecar: when an asset is named EXACTLY "<chosenName>.sha256",
// it is fetched (one extra request, https only), its FIRST whitespace token
// must be exactly 64 hex chars → sha256Hex (lowercased) + confidence .high;
// anything else → sha256Hex nil + confidence .medium, with sourceDetail
// saying the claim is self-attested upstream source. The sidecar is
// deliberately NOT ETag-cached (cache keys are owner/repo granularity); it
// costs at most one extra request per check.
//
// ETag cache (Updatest-schema, <directory>/github_etag_cache.json):
//   {"etags":     {"<owner>/<repo>": "<raw etag>",       …},
//    "responses": {"<owner>/<repo>": <last release JSON verbatim>, …}}
// "Verbatim" is implemented as the release BODY stored as a JSON string
// value: GitHub release JSON is valid UTF-8, so Data→String→Data round-trips
// byte-exactly, while embedding a re-serialized object would reorder keys
// (NOT verbatim). Write is atomic (staged file + same-volume swap); a failed
// write never corrupts the previous good file, and persistence is best-effort
// (a write failure degrades to a plain re-fetch next time — it never blocks
// the claim). Cache state is loaded fresh per fetch and reloaded-merged
// before persisting, so multi-candidate and concurrent-app writes stay
// correct; the worst race loses an entry (benign), never the byte integrity.

import Foundation

// MARK: - RepoRef

/// A validated GitHub repository reference (`owner`/`repo`).
///
/// Valid slug characters are alphanumerics plus `-`, `_`, `.` in BOTH parts,
/// and both parts must be non-empty. Construction is via the failable
/// `validated(owner:repo:)` helper — invalid input yields nil, never a
/// half-formed reference that would build a broken API URL later.
public struct RepoRef: Sendable, Hashable {
    public let owner: String
    public let repo: String

    /// Cache-key form used by the ETag store ("<owner>/<repo>" keys).
    public var slug: String { owner + "/" + repo }

    private init(owner: String, repo: String) {
        self.owner = owner
        self.repo = repo
    }

    /// The exact slug alphabet admitted by this lane (ASCII alphanumerics,
    /// `-`, `_`, `.` — Updatest's regex shape), as a scalar set.
    private static let slugScalars = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")

    /// Failable construction: both parts must be non-empty and contain only
    /// valid GitHub slug characters. Anything else → nil (honest rejection).
    public static func validated(owner: String, repo: String) -> RepoRef? {
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        let valid = owner.unicodeScalars.allSatisfy(slugScalars.contains)
            && repo.unicodeScalars.allSatisfy(slugScalars.contains)
        guard valid else { return nil }
        return RepoRef(owner: owner, repo: repo)
    }
}

// MARK: - Rate-limit error

/// Thrown ONLY for the 403 + `X-RateLimit-Remaining == "0"` honesty rule.
/// `String(describing:)` renders the verbatim brief message, which is exactly
/// how `UpdateCheckEngine.failures` surfaces it (`String(describing: error)`).
public struct GithubRateLimitError: Error, Sendable, CustomStringConvertible {
    /// "owner/repo" of the rate-limited releases/latest request.
    public let repoSlug: String

    public init(repoSlug: String) {
        self.repoSlug = repoSlug
    }

    /// Verbatim honest message (brief-locked, em dash included).
    public var description: String {
        "GitHub API rate limit exhausted (403) — releases/latest for '\(repoSlug)'"
    }
}

// MARK: - ETag cache

/// Persisted ETag cache content, Updatest-schema (see the file header).
/// `responses` stores each cached release body VERBATIM as a JSON string
/// value (byte-exact round-trip; see the header note for why not an object).
struct GithubEtagCache: Codable, Sendable, Equatable {
    var etags: [String: String] = [:]
    var responses: [String: String] = [:]
}

/// File-backed ETag store: `<directory>/github_etag_cache.json`.
///
/// Load tolerates a corrupt/unreadable file by returning nil (the cache then
/// self-heals on the next 200 persist); persist is atomic (unique staging
/// file in the target directory + same-volume `replaceItemAt`/`moveItem`
/// swap) so a failure anywhere before the swap leaves the previous good file
/// untouched. Store instances hold no state of their own — two instances on
/// the same directory read/write the same file, which is exactly the
/// "persisted across store instances" property.
struct GithubEtagStore {
    /// The Updatest cache file name, brief-locked.
    static let fileName = "github_etag_cache.json"

    let fileURL: URL

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent(Self.fileName)
    }

    func load() -> GithubEtagCache? {
        guard let data = try? Data(contentsOf: fileURL),
              let cache = try? JSONDecoder().decode(GithubEtagCache.self, from: data) else {
            return nil // unreadable/corrupt cache → treat as none; next 200 rebuilds it
        }
        return cache
    }

    func persist(_ cache: GithubEtagCache) throws {
        let data = try JSONEncoder().encode(cache)
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staging = dir.appendingPathComponent(Self.fileName + ".staging-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: staging.path, contents: data) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: staging.path])
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.replaceItemAt(fileURL, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: fileURL)
        }
    }
}

// MARK: - Release JSON models

/// The release fields this lane consumes (tolerant decode: unknown keys are
/// ignored by synthesized Codable behavior; a malformed `assets` array voids
/// that ONE candidate honestly rather than mispicking).
private struct GithubReleaseRecord: Decodable, Sendable {
    let tagName: String?
    let publishedAt: String?
    let body: String?
    let assets: [GithubAssetRecord]?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case publishedAt = "published_at"
        case body
        case assets
    }
}

/// One release asset; both fields may be absent (decoding stays tolerant —
/// untyped assets are simply never eligible for the pick). Internal so the
/// static pick helpers stay unit-testable in hermetic suites.
struct GithubAssetRecord: Decodable, Sendable {
    let name: String?
    let browserDownloadUrl: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}

// MARK: - GithubSource

/// GitHub Releases source. See the file header for the full documented
/// design; `fetchUpdateInfo(for:)` is the contract surface.
public struct GithubSource: UpdateSource, Sendable {
    public static var kind: SourceKind { .github }

    private static let userAgent = "AppUpdater/0.1 (macOS)"
    private static let accept = "application/vnd.github.v3+json"

    /// Nil (no provider wired) → the default sparkleFeedURL harvest runs.
    /// Returning [] actively suppresses candidates; returning nil also falls
    /// back to the default harvest. Provider refs (and the harvested list)
    /// are capped to the first 2 UNIQUE refs and keep their order.
    private let repoProvider: (@Sendable (InstalledApp) async -> [RepoRef]?)?
    private let directory: URL
    private let session: URLSession

    /// Per-fetch store view (stateless; directory is fixed at init).
    private var store: GithubEtagStore { GithubEtagStore(directory: directory) }

    /// Explicit repo pin (consumed later by the manual-sources lane via
    /// coordinator wiring): the pinned repo wins as the ONLY candidate.
    /// An invalid pin yields an explicit empty candidate list — pinned
    /// semantics must never silently fall back to the default harvest.
    public init(pinnedOwner: String, pinnedRepo: String, directory: URL, session: URLSession) {
        self.directory = directory
        self.session = session
        let pin = RepoRef.validated(owner: pinnedOwner, repo: pinnedRepo)
        self.repoProvider = { _ in pin.map { [$0] } ?? [] }
    }

    /// Provider-driven source. `repoProvider` nil → default harvest from the
    /// app's own `sparkleFeedURL` (bounded to GitHub-hosted feeds; see the
    /// header). `directory` is REQUIRED in both inits: tests pass unique
    /// temp dirs; production wires the real directory at integration.
    public init(repoProvider: (@Sendable (InstalledApp) async -> [RepoRef]?)? = nil, directory: URL, session: URLSession) {
        self.repoProvider = repoProvider
        self.directory = directory
        self.session = session
    }

    /// The frozen UpdateSource contract. Throws ONLY on the rate-limit rule;
    /// every other failure is an honest nil (or next-candidate continuation).
    public func fetchUpdateInfo(for app: InstalledApp) async throws -> UpdateInfo? {
        let candidates = await Self.candidates(for: app, provider: repoProvider)
        for candidate in candidates {
            switch try await claim(for: candidate) {
            case .info(let info): return info
            case .miss: continue // honest miss on this candidate → try the next
            }
        }
        return nil // every candidate missed, or there were none
    }

    // MARK: Candidate building

    private enum LookupOutcome {
        case info(UpdateInfo)
        /// 404, unparseable, missing tag, network failure, non-HTTP
        /// response, other statuses — this candidate has nothing usable.
        case miss
    }

    /// Candidate list for one check: provider-or-harvest → dedupe → cap 2.
    /// Order is preserved end to end so request logs stay deterministic.
    static func candidates(for app: InstalledApp, provider: (@Sendable (InstalledApp) async -> [RepoRef]?)?) async -> [RepoRef] {
        let provided = await provider?(app) ?? repoRefs(fromSparkleFeed: app.sparkleFeedURL)
        var seen = Set<RepoRef>()
        var unique: [RepoRef] = []
        for ref in provided where seen.insert(ref).inserted {
            unique.append(ref)
            if unique.count == 2 { break } // max 2 candidates per check (brief)
        }
        return unique
    }

    /// Default provider harvest: derive candidates from the app's own
    /// Sparkle feed ONLY (zero extra network). Bounded to https feeds whose
    /// host is exactly "github.com", "githubusercontent.com" or
    /// "raw.githubusercontent.com"; other githubusercontent subdomains and
    /// every other host stay unmatched (v1 honesty: narrower beats wilder).
    /// One feed string carries at most one repo today; the per-check cap of
    /// 2 candidates still bounds the loop independently.
    static func repoRefs(fromSparkleFeed raw: String?) -> [RepoRef] {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "github.com" || host == "githubusercontent.com" || host == "raw.githubusercontent.com"
        else { return [] }

        let components = url.pathComponents // ["/", owner, repo, …]
        guard components.count >= 3 else { return [] }
        var repo = components[2]
        if repo.lowercased().hasSuffix(".git") { repo.removeLast(4) } // strip ".git"
        guard let ref = RepoRef.validated(owner: components[1], repo: repo) else { return [] }
        return [ref]
    }

    // MARK: Per-candidate claim

    private func claim(for ref: RepoRef) async throws -> LookupOutcome {
        guard let endpoint = URL(string: "https://api.github.com/repos/\(ref.owner)/\(ref.repo)/releases/latest") else {
            return .miss // unreachable in practice (validated slug) — honest belt
        }
        var request = URLRequest(url: endpoint)
        // House posture like SparkleSource: never consult a shared cache.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(Self.accept, forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let cache = store.load() ?? GithubEtagCache()
        if let etag = cache.etags[ref.slug] {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let payload: (data: Data, response: URLResponse)
        do {
            payload = try await session.data(for: request)
        } catch {
            return .miss // network failure → honest miss (next candidate / nil)
        }
        guard let http = payload.response as? HTTPURLResponse else { return .miss }

        switch http.statusCode {
        case 200:
            // Persist BEFORE parsing (brief-locked order): an etag-less 200
            // is not persisted — without one no future conditional request
            // is possible, so caching the body alone is unusable ballast.
            if let etag = http.value(forHTTPHeaderField: "ETag") {
                persist(etag: etag, body: payload.data, ref: ref)
            }
            return await parseRelease(payload.data, ref: ref)
        case 304:
            guard let cachedBody = cache.responses[ref.slug] else { return .miss }
            return await parseRelease(Data(cachedBody.utf8), ref: ref) // cached verbatim body
        case 404:
            return .miss // honest miss → next candidate, or nil if none left
        case 403 where Self.isRateLimitExhausted(http):
            // Rate limit is account/IP wide → throw immediately rather than
            // burn a second doomed request; the engine's failures list keeps
            // this diagnosable instead of a silent nil.
            throw GithubRateLimitError(repoSlug: ref.slug)
        default:
            return .miss
        }
    }

    /// The rate-limit honesty rule: HTTP 403 with `X-RateLimit-Remaining`
    /// exactly "0" (whitespace-trimmed, absent header → not the rule).
    private static func isRateLimitExhausted(_ http: HTTPURLResponse) -> Bool {
        http.value(forHTTPHeaderField: "X-RateLimit-Remaining")
            .map { $0.trimmingCharacters(in: .whitespaces) } == "0"
    }

    private func persist(etag: String, body: Data, ref: RepoRef) {
        // Best-effort by design: a persist failure degrades to a re-fetch
        // next time and must never block or corrupt the claim. Reload-merge
        // minimizes racing writes between candidates/apps (worst benign case:
        // one entry lost; file bytes stay valid — staged atomic swap).
        var latest = store.load() ?? GithubEtagCache()
        latest.etags[ref.slug] = etag
        latest.responses[ref.slug] = String(decoding: body, as: UTF8.self)
        do { try store.persist(latest) } catch { /* best-effort, documented above */ }
    }

    private func parseRelease(_ data: Data, ref: RepoRef) async -> LookupOutcome {
        guard let record = try? JSONDecoder().decode(GithubReleaseRecord.self, from: data) else {
            return .miss // malformed JSON → honest nil for this candidate
        }
        guard let tag = record.tagName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tag.isEmpty else {
            return .miss // tag_name missing/blank → skip; NEVER synthesize a version
        }

        let assets = record.assets ?? []
        let chosen = Self.pickAsset(assets)
        let assetName = chosen?.name?.trimmingCharacters(in: .whitespacesAndNewlines)

        var detail = "github: \(ref.slug)"
        var downloadURL: URL?
        var sha256Hex: String?
        var verified = false

        if let chosen, let assetName, !assetName.isEmpty,
           let raw = chosen.browserDownloadUrl,
           let url = URL(string: raw),
           url.scheme?.lowercased() == "https" {
            // pickAsset already proved these; the re-guard only keeps the
            // builder crash-free and honest if the pick artist changed.
            downloadURL = url
            detail += "; release asset '\(assetName)'"
            if let sidecar = Self.sidecarAsset(named: assetName + ".sha256", in: assets),
               let sidecarRaw = sidecar.browserDownloadUrl,
               let sidecarURL = URL(string: sidecarRaw),
               sidecarURL.scheme?.lowercased() == "https" {
                if let hex = await fetchSidecarHex(url: sidecarURL) {
                    sha256Hex = hex
                    verified = true
                    detail += "; sha256 verified via sidecar '\(assetName).sha256'"
                }
            }
        } else {
            detail += "; no matching macOS release asset — info-only claim"
        }
        if !verified {
            detail += "; sha256 self-attested upstream source (not verified)"
        }

        return .info(UpdateInfo(
            source: .github,
            newestShortVersion: tag, // verbatim, never normalized or synthesized
            // Release JSON carries no separate numeric bundle version.
            newestBundleVersion: nil,
            downloadURL: downloadURL, // nil → info-only claim (install refuses unverifyable bytes)
            sha256Hex: sha256Hex,
            // /releases/latest exposes no macOS floor; claiming one would be a guess.
            minimumSystemVersion: nil,
            releaseDate: Self.releaseDate(from: record.publishedAt),
            releaseNotes: record.body,
            confidence: verified ? .high : .medium,
            sourceDetail: detail
        ))
    }

    // MARK: Sidecar

    /// The release asset named EXACTLY `name` (case-sensitive exact match,
    /// both ends trimmed defensively).
    static func sidecarAsset(named name: String, in assets: [GithubAssetRecord]) -> GithubAssetRecord? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return assets.first { ($0.name?.trimmingCharacters(in: .whitespacesAndNewlines)) == wanted }
    }

    /// One extra https GET for the sidecar file. Any failure (network,
    /// non-200, malformed content) is an honest "unverified" — never an
    /// error, never a guess. The sidecar owns its fetch (not ETag-cached;
    /// see header).
    private func fetchSidecarHex(url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let payload: (data: Data, response: URLResponse)
        do {
            payload = try await session.data(for: request)
        } catch {
            return nil
        }
        guard let http = payload.response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return Self.sidecarHex(from: payload.data)
    }

    /// Sidecar content policy: take the FIRST whitespace token and require
    /// exactly 64 hex chars → lowercased hex. Malformed → nil (honest).
    static func sidecarHex(from data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let token = text.split(whereSeparator: \.isWhitespace).first else { return nil }
        let hex = String(token)
        guard hex.count == 64,
              hex.unicodeScalars.allSatisfy(Self.hexScalars.contains) else { return nil }
        return hex.lowercased()
    }

    private static let hexScalars = CharacterSet(charactersIn:
        "0123456789abcdefABCDEF")

    // MARK: Asset pick

    /// Extensions this lane never selects, no matter the tier logic
    /// (.dmg/.zip eligibility already excludes the others; the list documents
    /// intent AND guards shapes like a ".dmg.deb" pasted name gap… which the
    /// suffix filter below also rejects — belt and braces).
    private static let neverPickSuffixes = [".exe", ".deb", ".rpm", ".apk", ".appimage"]

    /// Archive tiers in tie-break order: .dmg first, .zip second.
    private static let archiveTiers = [".dmg", ".zip"]

    /// Documented tie-break (see file header): extension tier first
    /// (.dmg > .zip), then within the winning tier the first arm64/aarch64
    /// name beats everything else (x64-labeled and unlabeled rank equally,
    /// array order breaks them). Eligibility: non-empty name, .dmg/.zip
    /// suffix, NOT a never-pick suffix, https browser_download_url.
    static func pickAsset(_ assets: [GithubAssetRecord]) -> GithubAssetRecord? {
        let eligible = assets.filter { asset in
            guard let name = asset.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return false }
            let lower = name.lowercased()
            for suffix in neverPickSuffixes where lower.hasSuffix(suffix) { return false }
            guard lower.hasSuffix(".dmg") || lower.hasSuffix(".zip") else { return false }
            guard let raw = asset.browserDownloadUrl,
                  let url = URL(string: raw),
                  url.scheme?.lowercased() == "https" else { return false }
            return true
        }

        for tier in archiveTiers {
            var firstOfTier: GithubAssetRecord?
            var firstArmOfTier: GithubAssetRecord?
            for asset in eligible {
                let lower = (asset.name ?? "").lowercased()
                guard lower.hasSuffix(tier) else { continue }
                if firstOfTier == nil { firstOfTier = asset }
                if firstArmOfTier == nil, lower.contains("arm64") || lower.contains("aarch64") {
                    firstArmOfTier = asset
                }
            }
            if let pick = firstArmOfTier ?? firstOfTier { return pick }
        }
        return nil
    }

    // MARK: Release date

    /// ISO8601 → Date, tolerating both the plain and fractional-seconds
    /// variants GitHub emits; missing/unparseable → nil (never guessed).
    /// Formatters are built per call: `ISO8601DateFormatter` is not Sendable,
    /// so statics / shared mutable state are exactly what we must avoid here.
    static func releaseDate(from string: String?) -> Date? {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}
