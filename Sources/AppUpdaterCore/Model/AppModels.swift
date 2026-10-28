import Foundation

/// One installed app on this Mac (one instalation location, since duplicate installs are
/// tracked separately — mirrors MacUpdater's duplicate-bundle-id policy).
public struct InstalledApp: Codable, Hashable, Sendable, Identifiable {
    public var bundleIdentifier: String
    public var name: String
    public var path: String
    public var shortVersion: String?
    public var bundleVersion: String?
    public var minimumSystemVersion: String?
    public var signatureTeamID: String?
    public var isMacAppStore: Bool
    /// Hint read from the app's own Info.plist `SUFeedURL` if present at scan time.
    public var sparkleFeedURL: String?
    /// Sparkle's own SUDefaultChannel Info.plist key, captured verbatim by the scanner;
    /// nil = the app declares no custom channel (or pre-addition JSON decode).
    /// AMENDMENT RECORD: coordinator-owned interchange type, additive field lane channels
    /// 2026-10-26; previously-written encoded UpdateCheck/rules JSON WITHOUT this key must keep
    /// decoding (proved by the old-fixture decode test in ScannerTests).
    public var suDefaultChannel: String? = nil
    public var checkedAt: Date?

    public var id: String { bundleIdentifier + "|" + path }

    public init(
        bundleIdentifier: String,
        name: String,
        path: String,
        shortVersion: String? = nil,
        bundleVersion: String? = nil,
        minimumSystemVersion: String? = nil,
        signatureTeamID: String? = nil,
        isMacAppStore: Bool = false,
        sparkleFeedURL: String? = nil,
        suDefaultChannel: String? = nil,
        checkedAt: Date? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.path = path
        self.shortVersion = shortVersion
        self.bundleVersion = bundleVersion
        self.minimumSystemVersion = minimumSystemVersion
        self.signatureTeamID = signatureTeamID
        self.isMacAppStore = isMacAppStore
        self.sparkleFeedURL = sparkleFeedURL
        self.suDefaultChannel = suDefaultChannel
        self.checkedAt = checkedAt
    }
}

/// Where an update claim came from.
public enum SourceKind: String, Codable, Hashable, Sendable {
    case cask
    case sparkle
    case mas      // Mac App Store (iTunes lookup / receipts)
    case github
    case unknown
}

/// How trustworthy the claim is (Updatest-style labels).
public enum UpdateConfidence: String, Codable, Hashable, Sendable {
    case high       // signed feed or first-party data
    case medium     // heuristics with strong signals
    case low        // best-effort match, needs UI disclosure
}

/// One delta-update enclosure parsed from a Sparkle appcast item's `<sparkle:deltas>`
/// element (Sparkle 2 ships delta artifacts as `<enclosure>` children of that element,
/// keyed by the `sparkle:deltaFrom` attribute — the version the delta patch applies FROM).
///
/// Information-only surface (v1): AppUpdater NEVER installs delta artifacts — it always
/// downloads the item's full enclosure — so the UI/CLI can honestly state "delta updates
/// available but not used". Fields are kept verbatim from the feed; nothing is inferred.
/// AMENDMENT RECORD: additive Codable field carrier, lane delta-backup 2026-10-28;
/// previously-written encoded UpdateInfo JSON WITHOUT `sparkleDeltas` keeps decoding
/// (optional + synthesized `decodeIfPresent`; proved by the legacy-JSON decode test).
public struct SparkleDelta: Codable, Hashable, Sendable {
    /// `sparkle:deltaFrom` — the version the delta patch upgrades FROM. Required: Sparkle
    /// itself skips delta enclosures without it (`SUAppcastItem.m` — `if (!deltaFrom) continue`).
    public var fromVersion: String
    /// Enclosure `url` attribute, resolved as a URL when absolute; nil when absent/malformed.
    public var url: URL?
    /// Enclosure `length` attribute (bytes) when present and numeric; nil otherwise.
    public var lengthBytes: Int64?
    /// `sparkle:edSignature` attribute on the delta enclosure, when present.
    public var edSignature: String?

    public init(fromVersion: String, url: URL?, lengthBytes: Int64?, edSignature: String?) {
        self.fromVersion = fromVersion
        self.url = url
        self.lengthBytes = lengthBytes
        self.edSignature = edSignature
    }
}

/// Normalized "what's the newest release" payload any source returns.
public struct UpdateInfo: Codable, Hashable, Sendable {
    public var source: SourceKind
    public var newestShortVersion: String
    public var newestBundleVersion: String?
    public var downloadURL: URL?
    public var sha256Hex: String?
    public var minimumSystemVersion: String?
    public var releaseDate: Date?
    public var releaseNotes: String?
    public var confidence: UpdateConfidence
    /// Source-specific extras kept out of the shared model (per-source types own their details).
    public var sourceDetail: String?
    /// Delta-update enclosures parsed from the chosen Sparkle item's `<sparkle:deltas>`
    /// element, verbatim. nil = the item (or the source kind) carries no deltas, OR the
    /// payload was written before this field existed (legacy JSON decodes to nil).
    /// INFORMATION-ONLY: v1 installs full artifacts, never deltas — see `SparkleDelta`.
    public var sparkleDeltas: [SparkleDelta]?

    public init(
        source: SourceKind,
        newestShortVersion: String,
        newestBundleVersion: String? = nil,
        downloadURL: URL? = nil,
        sha256Hex: String? = nil,
        minimumSystemVersion: String? = nil,
        releaseDate: Date? = nil,
        releaseNotes: String? = nil,
        confidence: UpdateConfidence = .medium,
        sourceDetail: String? = nil,
        sparkleDeltas: [SparkleDelta]? = nil
    ) {
        self.source = source
        self.newestShortVersion = newestShortVersion
        self.newestBundleVersion = newestBundleVersion
        self.downloadURL = downloadURL
        self.sha256Hex = sha256Hex
        self.minimumSystemVersion = minimumSystemVersion
        self.releaseDate = releaseDate
        self.releaseNotes = releaseNotes
        self.confidence = confidence
        self.sourceDetail = sourceDetail
        self.sparkleDeltas = sparkleDeltas
    }
}
