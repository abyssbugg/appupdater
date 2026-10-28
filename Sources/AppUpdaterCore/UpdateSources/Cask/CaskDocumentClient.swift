// CaskDocumentClient — the single-token fetch/decode/validate pipeline extracted
// as a public reusable primitive.
//
// Why a separate client instead of widening CaskSource: CaskSource.swift is a
// shared file outside this lane's ownership, and the gap-sprint plan calls for a
// later integration that may swap the single-cask source's internals over to this
// client without touching that file. Everything here REPLICATES
// `CaskSource.lookup` behavior exactly (documented there, evidence
// docs/evidence/ff.json): same endpoint
// https://formulae.brew.sh/api/cask/<token>.json, same User-Agent
// "AppUpdater/0.1 (macOS)", same tightened timeouts (15s / 60s), same status
// branching (404 is special — `.notFound` — everything else honest-nil), same
// tolerant decode of drifting schema shapes (`name` string vs array; `sha256`
// string vs {"string": …}), same never-synthesize version contract, and the same
// artifact validation through CaskMatching (a mismatched document is never
// attributed).
//
// Deliberately NOT included: the alias-table retry (that lives in
// CaskSource.fetchUpdateInfo's failure-driven wrapper — the single-token client
// states far less on purpose: ONE token in, ONE outcome out), and any logging
// (lookup is silent, mirroring CaskSource.lookup).
//
// Outcome contract:
//   .info(UpdateInfo) — usable claim, decoded and artifact-validated
//   .notFound         — the endpoint answered HTTP 404: the token does not exist
//   .noResult         — every other honest nil: network failure, non-404 status,
//                       malformed/undecodable JSON, empty body, missing/blank
//                       version, artifact mismatch (mirrors CaskSource.lookup)

import Foundation

public enum CaskLookupOutcome: Sendable {
    case info(UpdateInfo)
    /// The endpoint answered HTTP 404: the token does not exist.
    case notFound
    /// Every other honest nil — see the file header for the exact list.
    case noResult
}

public struct CaskDocumentClient: Sendable {
    private let session: URLSession

    /// Default networking: URLSession default configuration + identifying
    /// User-Agent on every request (CaskSource's double-init pattern).
    public init() {
        self.init(session: URLSession(configuration: Self.defaultConfiguration()))
    }

    /// Injectable for testing (hermetic URLSessionConfiguration + URLProtocol stubs).
    public init(session: URLSession) {
        self.session = session
    }

    /// URLSession default configuration with tightened timeouts — mirrors
    /// CaskSource.defaultConfiguration exactly (15 / 60) so the client and the
    /// single-cask source can be swapped without any behavioral drift.
    static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        return configuration
    }

    private static let userAgent = "AppUpdater/0.1 (macOS)"
    private static let sourceDetail = "Homebrew cask metadata is public but self-attested (sha256 lives in the same unsigned JSON)."

    /// One token-document lookup: fetch, decode, version-check, artifact
    /// validation — the same pipeline CaskSource.lookup runs, exposed for reuse.
    public func lookup(token: String, for app: InstalledApp) async throws -> CaskLookupOutcome {
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
            return .noResult // malformed/undecodable JSON → honest nil
        }

        guard let version = record.version?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else {
            return .noResult // missing/blank version → never synthesize one
        }
        guard CaskMatching.caskMatchesInstalledApp(record, for: app) else {
            return .noResult // artifact mismatch: the cask is for a different app
        }

        return .info(UpdateInfo(
            source: .cask,
            newestShortVersion: version,
            newestBundleVersion: nil,
            downloadURL: Self.downloadURL(from: record.url),
            sha256Hex: record.sha256?.hex?.trimmingCharacters(in: .whitespacesAndNewlines),
            minimumSystemVersion: nil,
            releaseNotes: record.homepage ?? record.desc,
            confidence: .medium,
            sourceDetail: Self.sourceDetail
        ))
    }

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
