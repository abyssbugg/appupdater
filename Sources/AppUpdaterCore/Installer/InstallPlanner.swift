import Foundation

/// Decides the install plan from live claims + installed state. PURE — no I/O, no
/// process launching; produces the data a dry-run prints and an apply executes.
///
/// Security-floor decisions encoded here (LOCKED decision 6):
/// - The download URL must be HTTPS in intent (`downloadURL` scheme check here); the
///   downloader enforces it again at execution time (defense in depth).
/// - An artifact with no sha256 available cannot be planned for v1 (EdDSA install
///   verification is the Phase-5 Sparkle-lane's job). Honest refusal, not risk-blind trust.
/// - A version DOWNGRADE (available < installed) is planned but carries an explicit
///   warning — real downgrades are sometimes wanted (e.g. pinned toolchains).
public struct InstallPlanner: Sendable {
    public init() {}

    /// The kind a plan assumes, derived from the download URL's path extension.
    /// Returns nil when the extension is not dmg/zip — planner shows the honest reason
    /// instead of guessing.
    public static func kind(from url: URL) -> InstallKind? {
        switch url.pathExtension.lowercased() {
        case "dmg": return .dmg
        case "zip": return .zip
        default: return nil
        }
    }

    public func plan(app: InstalledApp, update: UpdateInfo) throws -> InstallPlan {
        guard let url = update.downloadURL else {
            throw InstallerError.unsupportedArtifact(reason: "source '\(update.source.rawValue)' provided no download URL")
        }
        guard url.scheme?.lowercased() == "https" else {
            throw InstallerError.httpsRequired(url: url.absoluteString)
        }
        guard let kind = Self.kind(from: url) else {
            throw InstallerError.unsupportedArtifact(
                reason: "extension '.\(url.pathExtension)' is not installable user-space in v1 (supported: dmg, zip; pkg needs the privileged lane)"
            )
        }

        var warnings: [String] = []
        if (update.sha256Hex ?? "").isEmpty {
            throw InstallerError.sha256Missing(what: update.source.rawValue)
        }
        let oracle = VersionOracle()
        let installed = app.shortVersion ?? ""
        if !installed.isEmpty, oracle.compare(update.newestShortVersion, installed) == .less {
            warnings.append("claimed version \(update.newestShortVersion) is OLDER than installed \(installed) — this is a downgrade plan")
        }
        if app.isMacAppStore {
            warnings.append("target is a Mac App Store install; replacing it drops Store entitlements — re-download from the Store instead")
        }
        switch update.confidence {
        case .low: warnings.append("source confidence is LOW (\(update.source.rawValue)) — review the claim before applying")
        default: break
        }

        let steps: [InstallStep] = [
            .download,
            .verifySha256,
            .verifyArtifactMagic,
            .backup,
            .quitRunningApp,
            .deployArtifact,
            .swapBundles,
            .relaunch,
            .postScan,
        ]
        return InstallPlan(app: app, update: update, kind: kind, steps: steps, warnings: warnings)
    }
}
