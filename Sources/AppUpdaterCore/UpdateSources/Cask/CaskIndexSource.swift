// Source tier: UpdateSource over the WHOLE-INDEX cask store (CaskIndexStore).
//
// This source is deliberately THIN: it owns only the UpdateInfo mapping policy —
// exactly the `.info` branch of CaskSource.lookup, replicated field-for-field
// (never rethrowing through the frozen `UpdateSource.throws`) — plus one honesty
// upgrade over the single-cask source: the sourceDetail names HOW the match was
// found, because the whole-index store knows whether the verdict came from the
// derived-token path or the artifact-name scan (the alias-killer path that retires
// CaskAliases maintenance). Exact frozen text:
//   "Homebrew cask whole-index; matched by <token 'x' | artifact-name 'Y.app'>;
//    self-attested (sha256 lives in the same unsigned JSON)."
//
// ORCHESTRATION CONTRACT (for AppState wiring): this source does NOT call
// `store.ensureLoaded()` itself — a ensure cycle costs one conditional network
// request, so the ORCHESTRATOR calls `ensureLoaded()` once per scan pass and the
// per-app `fetchUpdateInfo` calls then match against the loaded index with zero
// additional fetches. A source check on an un-loaded store honestly returns nil
// (nothing to match against) rather than fetching per app.
//
// Version synthesis is still forbidden: a record without a trimmed-usable
// `version` yields nil exactly like CaskSource's noResult branch.

import Foundation

public struct CaskIndexSource: UpdateSource, Sendable {
    public static var kind: SourceKind { .cask }

    private let store: CaskIndexStore

    public init(store: CaskIndexStore) {
        self.store = store
    }

    public func fetchUpdateInfo(for app: InstalledApp) async throws -> UpdateInfo? {
        guard let match = await store.resolvedMatch(for: app) else { return nil }
        guard let version = match.record.version?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !version.isEmpty else {
            return nil // missing/blank version → never synthesize one
        }
        return UpdateInfo(
            source: .cask,
            newestShortVersion: version,
            // Cask JSON carries `bundle_version`, but this phase pins
            // newestBundleVersion = nil per the single-cask source's frozen brief.
            newestBundleVersion: nil,
            downloadURL: Self.downloadURL(from: match.record.url),
            sha256Hex: match.record.sha256?.hex?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            // `depends_on.macos` is an operator map, not a plain floor version;
            // parsing it is deliberately deferred rather than approximated.
            minimumSystemVersion: nil,
            releaseNotes: match.record.homepage ?? match.record.desc,
            confidence: .medium,
            sourceDetail: "Homebrew cask whole-index; matched by \(match.basisFragment); self-attested (sha256 lives in the same unsigned JSON)."
        )
    }

    /// Same space-encode fallback as CaskSource's private helper: some cask urls
    /// carry literal spaces that URL(string:) rejects.
    private static func downloadURL(from string: String?) -> URL? {
        guard let string = string, !string.isEmpty else { return nil }
        if let url = URL(string: string) { return url }
        guard let encoded = string.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: encoded)
    }
}
