import Foundation

/// Sparkle appcast source: resolves update claims from an app's own Sparkle feed
/// (`InstalledApp.sparkleFeedURL`, read from the app's Info.plist `SUFeedURL` at scan time).
///
/// Documented policy (v1):
/// - **Untrusted items are skipped**: appcast items with no `sparkle:version` can never be ordered
///   against the installed version and are ignored (see `AppcastParser`).
/// - **Channel policy**: only the default channel is considered (`sparkle:channel` absent or
///   "default"). Beta channels are an opt-in feature for later.
/// - **No-updater-than-installed ⇒ nil**: if the newest default-channel item is not strictly newer
///   than the app's installed `bundleVersion`, this returns nil. When the app has no installed
///   version info, the newest-looking item is reported anyway (the install side shows "What's new
///   / choose to update" from an unknown base) — a per-lane decision documented for merge review.
/// - **EdDSA boundary**: real Ed25519 verification belongs to the INSTALLER phase (it must check
///   the signature against the vendor's `SUPublicEDKey`). Here we only surface whether the chosen
///   item CARRIES a signature-like string, and embed the signature in `sourceDetail`. Confidence is
///   guarded by rough shape, never by proof: a plausible base64-ish signature ≥ 20 chars ⇒ `.high`,
///   otherwise `.medium` — never a claim that the artifact was cryptographically validated.
/// - **SHA-256 is nil by definition here**: Sparkle authenticates via EdDSA, not sha256.
/// - The version comparator used today is a temporary numeric-aware dot comparator
///   (`SparkleVersionComparator`, see `AppcastParser.swift`); it is replaced by VersionOracle at merge.
public struct SparkleSource: UpdateSource {
    /// Fetch User-Agent mandated for this lane.
    public static let userAgent = "AppUpdater/0.1 (macOS)"

    private let injectedURLProtocolClasses: [AnyClass]?

    public init() {
        injectedURLProtocolClasses = nil
    }

    /// Test/hermetic seam: URLProtocol classes injected into the session configuration so suite
    /// fixtures answer requests locally. Not used by production call sites (`SparkleSource()`).
    init(urlProtocolClasses: [AnyClass]) {
        injectedURLProtocolClasses = urlProtocolClasses
    }

    public static var kind: SourceKind { .sparkle }

    public func fetchUpdateInfo(for app: InstalledApp) async throws -> UpdateInfo? {
        // Feed-less app ⇒ nil immediately, before any URLSession work (no network hit at all).
        guard let feedURLString = app.sparkleFeedURL else { return nil }
        let trimmedFeed = feedURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFeed.isEmpty, let feedURL = URL(string: trimmedFeed) else { return nil }
        // HTTPS-only per the project security floor (LOCKED decision 6); anything else is ignored.
        guard feedURL.scheme?.lowercased() == "https" else { return nil }

        var request = URLRequest(url: feedURL)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let configuration = URLSessionConfiguration.ephemeral
        if let injected = injectedURLProtocolClasses {
            configuration.protocolClasses = injected
        } else {
            // Default, conservative fetch posture (no shared caches between apps being checked).
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        }
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let parsed = AppcastParser.parse(data: data)
        guard let selected = AppcastParser.selectNewest(
            from: parsed.items,
            installedBundleVersion: app.bundleVersion
        ) else {
            return nil
        }

        // EdDSA note: signature is surfaced verbatim for the installer phase to verify; this source
        // only claims it plausibly looks like one (base64 charset, >= 20 chars).
        let signature = selected.edSignature
        let carriesSignature = signature.map(Self.looksLikeEdDSASignature) ?? false

        var detailParts: [String] = []
        if let signature, carriesSignature {
            detailParts.append("EdDSA signature present (verify against the feed's public key at install): \(signature)")
        } else if let signature {
            detailParts.append("edSignature attribute present but malformed: \(signature)")
        } else {
            detailParts.append("no EdDSA signature in appcast; artifact authenticity not attestable at source level")
        }
        if selected.criticalUpdate {
            detailParts.append("critical")
        }
        detailParts.append("channel: \(selected.channel ?? "default")")

        return UpdateInfo(
            source: .sparkle,
            // shortVersionString is the human-facing version; fall back to sparkle:version, which is
            // guaranteed non-empty for any selected item.
            newestShortVersion: selected.shortVersionString ?? selected.sparkleVersion ?? "",
            newestBundleVersion: selected.sparkleVersion,
            downloadURL: selected.enclosureURL,
            sha256Hex: nil,  // Sparkle authenticates with EdDSA, not sha256
            minimumSystemVersion: selected.minimumSystemVersion,
            releaseDate: selected.pubDate,
            releaseNotes: selected.releaseNotes,
            confidence: carriesSignature ? .high : .medium,
            sourceDetail: detailParts.joined(separator: "; ")
        )
    }

    /// Rough plausibility check for an EdDSA signature string: up to the installer to actually verify.
    static func looksLikeEdDSASignature(_ value: String) -> Bool {
        guard value.count >= 20 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
