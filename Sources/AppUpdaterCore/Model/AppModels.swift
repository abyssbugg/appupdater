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
        sourceDetail: String? = nil
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
    }
}
