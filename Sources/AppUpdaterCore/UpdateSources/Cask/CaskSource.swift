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
/// Failure semantics (documented design): network failure, non-200 status,
/// malformed/undecodable JSON, and a document without a usable `version` all
/// yield `nil` = "no verifiable update info from this source". The declared
/// `throws` is the frozen `UpdateSource` contract; this implementation never
/// rethrows through it. No version is ever synthesized.
public struct CaskSource: UpdateSource, Sendable {
    public static var kind: SourceKind { .cask }

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
        guard let endpoint = endpointURL(token: token) else { return nil }

        var request = URLRequest(url: endpoint)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let payload: (data: Data, response: URLResponse)
        do {
            payload = try await session.data(for: request)
        } catch {
            return nil // network failure → honest nil
        }

        guard let http = payload.response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil // 404 / other status → this source has nothing to say
        }

        let record: CaskRecord
        do {
            record = try JSONDecoder().decode(CaskRecord.self, from: payload.data)
        } catch {
            return nil // malformed/undecodable JSON → honest nil (design note above)
        }

        guard let version = record.version?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else {
            return nil // missing/blank version → never synthesize one
        }
        guard CaskMatching.caskMatchesInstalledApp(record, for: app) else {
            return nil // artifact mismatch: the cask is for a different app
        }

        return UpdateInfo(
            source: .cask,
            newestShortVersion: version,
            // Cask JSON carries `bundle_version` (cask-computed CFBundleVersion), but
            // this phase pins newestBundleVersion = nil per the frozen brief; revisit
            // at install time if the oracle needs a bundle-version comparison.
            newestBundleVersion: nil,
            downloadURL: Self.downloadURL(from: record.url),
            sha256Hex: record.sha256?.hex?.trimmingCharacters(in: .whitespacesAndNewlines),
            // `depends_on.macos` is an operator map, not a plain floor version;
            // parsing it is deliberately deferred rather than approximated.
            minimumSystemVersion: nil,
            releaseNotes: record.homepage ?? record.desc,
            confidence: .medium,
            sourceDetail: Self.sourceDetail
        )
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
