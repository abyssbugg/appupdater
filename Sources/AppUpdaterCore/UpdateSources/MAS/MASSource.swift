import Foundation

/// Mac App Store update source — v1 ground truth = Apple's own iTunes lookup endpoint.
///
/// Endpoint (v1, per phase brief): `https://itunes.apple.com/lookup?bundleId=<bundleIdentifier>
/// &country=us`. Country is **pinned to `us`** so "newest version" always reads from one
/// storefront catalog (regional lookups can differ); revisit with the owner before localizing.
/// Requests identify as `AppUpdater/0.1 (macOS)` (see `ITunesLookupClient`).
///
/// Honesty boundaries (AGENTS.md product model — "unknown, never guessed"):
/// - Only speaks for installs flagged `isMacAppStore`. Anything else returns nil with **zero
///   network traffic** — this source must not pretend to cover vendor installs.
/// - A successfully decoded lookup with no results means "unknown to the storefront" → nil,
///   not an error.
/// - A hit without a non-empty `version` string also carries no claim → nil (never guess).
/// - `downloadURL` is always nil: MAS binaries have no legitimate direct download exposed by
///   the lookup; forcing an out-of-store replace is the installer/force-update lane's later
///   decision, not something this source claims.
/// - Errors: URLSession transport failures and JSON decode failures (e.g. an HTML error page
///   instead of the expected JSON) **throw** — only a successfully decoded payload is mapped.
///
/// Receipt verification intentionally does NOT live here — the scanner/installer lanes own it.
public struct MASSource: UpdateSource {
    public static var kind: SourceKind { .mas }

    private let client: ITunesLookupClient

    public init(session: URLSession = .shared) {
        self.client = ITunesLookupClient(session: session)
    }

    public func fetchUpdateInfo(for app: InstalledApp) async throws -> UpdateInfo? {
        guard app.isMacAppStore else { return nil }

        let response = try await client.lookup(bundleIdentifier: app.bundleIdentifier)

        // The `results` array is the truth; take the storefront's best-match (first) hit.
        guard let hit = response.results.first, let version = hit.version, !version.isEmpty else {
            return nil
        }

        let detail: String
        if let trackId = hit.trackId {
            detail = "Apple iTunes lookup (first-party data), trackId \(trackId)"
        } else {
            detail = "Apple iTunes lookup (first-party data)"
        }

        return UpdateInfo(
            source: .mas,
            newestShortVersion: version,
            // The lookup exposes no separate bundle-version field for the current track
            // release; stays nil even when a stray `bundleVersion` key appears in the payload.
            newestBundleVersion: nil,
            downloadURL: nil,
            sha256Hex: nil,
            minimumSystemVersion: hit.minimumOsVersion,
            releaseDate: hit.parsedCurrentVersionReleaseDate,
            releaseNotes: hit.releaseNotes,
            confidence: .high, // first-party Apple data — the highest-trust tier this source has
            sourceDetail: detail
        )
    }
}
