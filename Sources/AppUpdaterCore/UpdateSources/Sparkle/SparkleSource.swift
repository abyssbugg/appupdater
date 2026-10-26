import Foundation

/// Sparkle appcast source: resolves update claims from an app's own Sparkle feed
/// (`InstalledApp.sparkleFeedURL`, read from the app's Info.plist `SUFeedURL` at scan time).
///
/// Documented policy (v1):
/// - **Untrusted items are skipped**: appcast items with no `sparkle:version` can never be ordered
///   against the installed version and are ignored (see `AppcastParser`).
/// - **Channel policy**: the app's own declared channel is the policy — the scanner captures
///   `SUDefaultChannel` from the app's Info.plist into `InstalledApp.suDefaultChannel` and this
///   source honors it, mirroring how Sparkle itself filters items by the app's allowed channels
///   (upstream `SUAppcastDriver.filterAppcast`: channel-less items are ALWAYS admissible — the
///   default channel is always included — and an item with a `sparkle:channel` is admissible
///   only when its channel is in the allowed set, matched by case-sensitive exact string
///   equality). Concretely:
///   - No declaration (nil ⇒ `sparkle:channel` absent/empty, or "default"; the unchanged
///     default-channel policy), or
///   - declared channel "X" ⇒ default-channel items AND items with `sparkle:channel == "X"`
///     are admissible; items carrying any OTHER channel stay excluded.
///   Matching is EXACT as declared: case-sensitive ("Delta" ≠ "delta", as upstream's
///   `containsObject:`), and the app's declaration is not trimmed. v1 has NO per-app rule and
///   NO UI channel picking (RuleStore untouched) — an app declaring a channel is, by that
///   declaration alone, opted into it; per-app override UI stays deferred as already documented.
/// - The selection helper `selectAdmissible` applies that admissibility set, then still
///   delegates the winner choice to the shared `AppcastParser.selectNewest`. Because the parser
///   selector only ever recognizes the default channel, declared-channel items are re-tagged to
///   the default channel for selection and their true channel is restored on the winner (so the
///   `sourceDetail` channel report stays honest). With NO declaration the items pass through
///   unchanged, keeping the pre-channels behavior byte-for-byte.
/// - **No-updater-than-installed ⇒ nil**: if the newest admissible item is not strictly newer
///   than the app's installed `bundleVersion`, this returns nil. When the app has no installed
///   version info, the newest-looking item is reported anyway (the install side shows "What's new
///   / choose to update" from an unknown base) — a per-lane decision documented for merge review.
/// - **EdDSA boundary**: real Ed25519 verification belongs to the INSTALLER phase (it must check
///   the signature against the vendor's `SUPublicEDKey`). Here we only surface whether the chosen
///   item CARRIES a signature-like string, and embed the signature in `sourceDetail`. Confidence is
///   guarded by rough shape, never by proof: a plausible base64-ish signature ≥ 20 chars ⇒ `.high`,
///   otherwise `.medium` — never a claim that the artifact was cryptographically validated.
/// - **SHA-256 is nil by definition here**: Sparkle authenticates via EdDSA, not sha256.
/// - Version selection uses the shared `VersionOracle` comparator (lane-merge swap;
///   the temporary lane-local dot comparator was removed).
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
        // SECURITY FLOOR POLICY (LOCKED decision 6): HTTPS-only. Anything else is ignored.
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
        let chosen = Self.selectAdmissible(
            parsed.items,
            declaredChannel: app.suDefaultChannel,
            installedBundleVersion: app.bundleVersion
        )
        guard let selected = chosen else {
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

    /// Applies the declared-channel admissibility policy (see the header doc) and delegates the
    /// winner choice to the shared `AppcastParser.selectNewest`.
    ///
    /// - `declaredChannel` nil (or empty — a defensively-handled hand-made/decoded value) ⇒ the
    ///   items pass through unchanged and `selectNewest` applies its own default-channel filter
    ///   on them: this is the pre-channels behavior, byte-for-byte.
    /// - `declaredChannel` "X" ⇒ admissible = default-channel items ∪ items whose channel equals
    ///   "X" EXACTLY (case-sensitive; upstream Sparkle matches via `NSSet containsObject:`, the
    ///   same equality). `selectNewest` only ever sees the default channel, so declared-match
    ///   items are locally re-tagged to a nil channel for selection; the parallel `trueChannels`
    ///   list restores the winner's original channel afterwards so `sourceDetail` can report it
    ///   honestly. Known cosmetic edge: two admissible items identical in EVERY parsed field
    ///   would make the re-tag-to-original mapping ambiguous (first equality match wins); the
    ///   selected update itself is identical either way — only the reported channel string could
    ///   differ.
    static func selectAdmissible(
        _ items: [SparkleAppcastItem],
        declaredChannel: String?,
        installedBundleVersion: String?
    ) -> SparkleAppcastItem? {
        guard let declared = declaredChannel, !declared.isEmpty else {
            return AppcastParser.selectNewest(
                from: items, installedBundleVersion: installedBundleVersion)
        }

        var admissible: [SparkleAppcastItem] = []
        var trueChannels: [String?] = []
        admissible.reserveCapacity(items.count)
        trueChannels.reserveCapacity(items.count)

        for item in items {
            guard let version = item.sparkleVersion, !version.isEmpty else { continue }  // untrusted
            let isDeclaredMatch = item.channel == declared
            guard isDeclaredMatch || AppcastParser.isDefaultChannel(item.channel) else { continue }
            trueChannels.append(item.channel)
            if isDeclaredMatch {
                // Re-tag for the default-only selector; restored on the winner below.
                var retagged = item
                retagged.channel = nil
                admissible.append(retagged)
            } else {
                admissible.append(item)
            }
        }

        guard let winner = AppcastParser.selectNewest(
            from: admissible, installedBundleVersion: installedBundleVersion
        ) else {
            return nil
        }

        // Restore the winner's true channel for honest reporting.
        if let index = admissible.firstIndex(of: winner) {
            var restored = winner
            restored.channel = trueChannels[index]
            return restored
        }
        return winner  // unreachable in practice; prefer the un-corrected item over crashing
    }

    /// Rough plausibility check for an EdDSA signature string: up to the installer to actually verify.
    static func looksLikeEdDSASignature(_ value: String) -> Bool {
        guard value.count >= 20 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
