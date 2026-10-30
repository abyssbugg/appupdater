// Source tier: Homebrew's public cask JSON API (single-cask document).
//
// Endpoint (brief-locked for this phase):
//   https://formulae.brew.sh/api/cask/<token>.json
//
// FULL-INDEX DECISION (documented per brief): the whole-index matcher
// (`https://formulae.brew.sh/api/cask.json`, tens of MB per scan) is a
// later phase (docs/MACUPDATER-BREAKDOWN.md §3.1.2). It is NOT fetched here:
// the single-cask document already carries everything the primary policy
// needs, and a token miss under the slug policy has no honest alternative
// candidate to try, so the outcome is nil rather than a weaker guess.

import Foundation
import os

/// Fetches newest-version info for an installed app from the public Homebrew
/// cask JSON API.
///
/// Matching policy (honest boundary — no guessing):
/// 1. Candidate token = app name lowercased with non-alphanumeric runs dashed
///    (`CaskMatching.candidateToken`).
/// 2. Fetch `https://formulae.brew.sh/api/cask/<token>.json` once
///    (`User-Agent: AppUpdater/0.1 (macOS)`).
/// 3. Validate the returned cask by its `app` artifacts: at least one must match
///    the installed app's name or `/path/Basename.app` (case-insensitive,
///    ".app" ignored). A mismatch is a DIFFERENT app — return nil, never a
///    misattributed update.
///
/// Alias fallback (locked coordinator decision, 2026-10-26): if step 2's
/// endpoint answers HTTP 404 for the derived token AND `CaskAliases.table`
/// carries that token, the aliased token is fetched and validated ONCE — the
/// identical pipeline (same decode, same version check, same artifact match)
/// as the primary attempt, so an alias can surface nothing the primary path
/// couldn't. The fallback is deliberately failure-driven, never a pre-emptive
/// rewrite of the token: a correctly derived token wins without a second
/// fetch, and the substitution is logged when it happens
/// (os.Logger, category "cask"). HTTP 404 is the only trigger — network
/// errors, other statuses, and validation failures get no alias retry (their
/// honest-nil is final), which keeps "the token does not exist" distinct from
/// "the endpoint is unhappy" and bounds the worst case to one extra request.
/// A token that is unknown to the table stays an honest miss with no retry.
///
/// Failure semantics (documented design): network failure, non-200 status,
/// malformed/undecodable JSON, and a document without a usable `version` all
/// yield `nil` = "no verifiable update info from this source". The declared
/// `throws` is the frozen `UpdateSource` contract; this implementation never
/// rethrows through it. No version is ever synthesized.
public struct CaskSource: UpdateSource, Sendable {
    public static var kind: SourceKind { .cask }

    /// Log surface: os.Logger subsystem "io.appupdater.AppUpdater", category
    /// "cask". Documented line: "cask token '<derived>' 404 — aliased to
    /// '<target>'" (emitted when an alias substitution actually fires).
    private static let log = Logger(subsystem: "io.appupdater.AppUpdater", category: "cask")

    private let session: URLSession

    /// Default networking: URLSession default configuration + identifying
    /// User-Agent on every request.
    public init() {
        self.init(session: URLSession(configuration: CaskSource.defaultConfiguration()))
    }

    /// Injectable for testing (hermetic URLSessionConfiguration + URLProtocol stubs).
    public init(session: URLSession) {
        self.session = session
    }

    /// URLSession default configuration with tightened timeouts.
    static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        return configuration
    }

    private static let userAgent = "AppUpdater/0.1 (macOS)"

    public func fetchUpdateInfo(for app: InstalledApp) async throws -> UpdateInfo? {
        guard let token = CaskMatching.candidateToken(from: app.name) else { return nil }

        // Attempt 1 — the primary derived-token behavior, unchanged.
        let primary = try await lookup(token: token, for: app)
        if case .info(let info) = primary { return info }

        // Attempt 2 — ONCE, and only when the primary token PROVABLY missed
        // (HTTP 404) and the alias table carries it. Anything else honest
        // (network failure, non-404 status, malformed JSON, missing version,
        // artifact mismatch) concludes nil right here: those outcomes say the
        // TOKEN EXISTS but has nothing usable for this app, and an alias must
        // not second-guess a validation verdict.
        guard case .notFound = primary else { return nil }
        guard let aliased = CaskAliases.table[token], aliased != token else {
            return nil // not in the table → no retry, honest nil stands
        }
        Self.log.notice(
            "cask token '\(token, privacy: .public)' 404 — aliased to '\(aliased, privacy: .public)'"
        )
        let secondary = try await lookup(token: aliased, for: app)
        if case .info(let info) = secondary { return info }
        return nil // aliased doc also has nothing usable → honest nil
    }

    /// One token-document lookup: fetch, decode, version-check, artifact
    /// validation — the exact pipeline shared by the primary attempt and the
    /// alias retry.
    private enum LookupOutcome {
        case info(UpdateInfo)
        /// The endpoint answered HTTP 404: the token does not exist.
        case notFound
        /// Every other honest nil: network failure, non-404 status,
        /// malformed/undecodable JSON, missing/blank version, artifact
        /// mismatch — this token has nothing to say about this app.
        case noResult
    }

    private func lookup(token: String, for app: InstalledApp) async throws -> LookupOutcome {
        guard let endpoint = endpointURL(token: token) else { return .noResult }

        var request = URLRequest(url: endpoint)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let payload: (data: Data, response: URLResponse)
        do {
            payload = try await session.data(for: request)
        } catch {
            return .noResult // network failure → honest nil
        }

        guard let response = payload.response as? HTTPURLResponse else {
            return .noResult // non-HTTP response → this source has nothing to say
        }
        if response.statusCode == 404 { return .notFound }
        guard response.statusCode == 200 else {
            return .noResult // 404 handled above; other statuses stay an honest nil
        }

        let record: CaskRecord
        do {
            record = try JSONDecoder().decode(CaskRecord.self, from: payload.data)
        } catch {
            return .noResult // malformed/undecodable JSON → honest nil (design note above)
        }

        guard let version = record.version?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else {
            return .noResult // missing/blank version → never synthesize one
        }
        guard CaskMatching.caskMatchesInstalledApp(record, for: app) else {
            return .noResult // artifact mismatch: the cask is for a different app
        }

        let (marketingVersion, buildSuffix) = CaskVersion.split(version) // compare marketing only

        return .info(UpdateInfo(
            source: .cask,
            newestShortVersion: marketingVersion,
            // Cask JSON carries `bundle_version` (cask-computed CFBundleVersion), but
            // this phase pins newestBundleVersion = nil per the frozen brief; revisit
            // at install time if the oracle needs a bundle-version comparison.
            newestBundleVersion: nil,
            newestBuild: buildSuffix,
            downloadURL: Self.downloadURL(from: record.url),
            sha256Hex: record.sha256?.hex?.trimmingCharacters(in: .whitespacesAndNewlines),
            // `depends_on.macos` is an operator map, not a plain floor version;
            // parsing it is deliberately deferred rather than approximated.
            minimumSystemVersion: nil,
            releaseNotes: record.homepage ?? record.desc,
            confidence: .medium,
            sourceDetail: Self.sourceDetail
        ))
    }

    private static let sourceDetail = "Homebrew cask metadata is public but self-attested (sha256 lives in the same unsigned JSON)."

    private func endpointURL(token: String) -> URL? {
        URL(string: "https://formulae.brew.sh/api/cask/\(token).json")
    }

    private static func downloadURL(from string: String?) -> URL? {
        guard let string = string, !string.isEmpty else { return nil }
        if let url = URL(string: string) { return url }
        // Some cask urls contain literal spaces; percent-encode as a fallback.
        guard let encoded = string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: encoded)
    }
}
