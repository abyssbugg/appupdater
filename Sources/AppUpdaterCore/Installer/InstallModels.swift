import Foundation

// Installer interchange types — FROZEN contract for Phase 3 lanes.
// Written by the coordinator; lanes implement executors over these shapes.
// If a lane needs a change here: STOP and report it; shared files are coordinator-owned.

/// What KIND of artifact an update is. v1 handles dmg + zip user-space.
/// pkg/tbz/tgz are honest hard errors in v1 (pkg is the privileged lane's scope).
public enum InstallKind: String, Codable, Hashable, Sendable {
    case dmg
    case zip
}

/// One actionable step of an install plan. Order is the coordinator's fixed policy.
public enum InstallStep: String, Codable, Hashable, CaseIterable, Sendable {
    case download
    case verifySha256
    case verifyArtifactMagic
    case backup
    case quitRunningApp
    case deployArtifact
    case swapBundles
    case relaunch
    /// Post-scan identity check (scanner re-run on the swapped bundle).
    case postScan
}

/// Path of one artifact staged for installation.
public struct DownloadedUpdate: Codable, Hashable, Sendable {
    public var stagedURL: URL
    public var kind: InstallKind
    /// The sha256 the artifact claims (from the source). Installer re-verifies bytes itself.
    public var expectedSha256Hex: String?

    public init(stagedURL: URL, kind: InstallKind, expectedSha256Hex: String?) {
        self.stagedURL = stagedURL
        self.kind = kind
        self.expectedSha256Hex = expectedSha256Hex
    }
}

/// A performed backup — leave the record for the receipt chain.
public struct BackupReceipt: Codable, Hashable, Sendable {
    public var zipURL: URL
    public var originalPath: String
    public var originalShortVersion: String?
    public var originalBundleVersion: String?
    public var createdAt: Date
    /// Size on disk (bytes) — used as cheap integrity check + honest reporting.
    public var byteCount: Int64

    public init(zipURL: URL, originalPath: String, originalShortVersion: String?, originalBundleVersion: String?, createdAt: Date, byteCount: Int64) {
        self.zipURL = zipURL
        self.originalPath = originalPath
        self.originalShortVersion = originalShortVersion
        self.originalBundleVersion = originalBundleVersion
        self.createdAt = createdAt
        self.byteCount = byteCount
    }
}

/// Result of putting the new app bundle into a staging location ready for the swap.
public struct DeployedBundle: Codable, Hashable, Sendable {
    public var stagedAppURL: URL
    public var kind: InstallKind

    public init(stagedAppURL: URL, kind: InstallKind) {
        self.stagedAppURL = stagedAppURL
        self.kind = kind
    }
}

/// Everything a dry-run reports — a plan is data; nothing on disk moved.
public struct InstallPlan: Codable, Hashable, Sendable {
    public var app: InstalledApp
    public var update: UpdateInfo
    public var kind: InstallKind
    public var steps: [InstallStep]
    /// Human-consumable warnings (e.g. downgrade, missing sha256, non-https remediations).
    public var warnings: [String]

    public init(app: InstalledApp, update: UpdateInfo, kind: InstallKind, steps: [InstallStep], warnings: [String]) {
        self.app = app
        self.update = update
        self.kind = kind
        self.steps = steps
        self.warnings = warnings
    }
}

/// Receipt of ONE executed step. Failures carry the underlying message honestly.
public struct StepReceipt: Codable, Hashable, Sendable {
    public var step: InstallStep
    public var startedAt: Date
    public var endedAt: Date
    public var succeeded: Bool
    public var detail: String

    public init(step: InstallStep, startedAt: Date, endedAt: Date, succeeded: Bool, detail: String) {
        self.step = step
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.succeeded = succeeded
        self.detail = detail
    }
}

/// Full outcome of an apply. Redundant-at-creation but version-pinned in reports.
public struct InstallOutcome: Codable, Hashable, Sendable {
    public var plan: InstallPlan
    public var receipts: [StepReceipt]
    public var abortedStep: InstallStep?
    /// What the swapped bundle now claims, straight from a post-scan read of the bundle.
    public var finalInstalledShortVersion: String?
    public var backup: BackupReceipt?
    // AMENDMENT RECORD: coordinator-owned frozen type, additive amendment 2026-10-26
    // lane retention, decode-tolerant for older JSON (optional field, synthesized
    // {en,de}codeIfPresent — every previously written report still decodes).
    /// BACKUP RETENTION v1 hygiene note from the coordinator (decision recorded at
    /// the InstallCoordinator head): nil = retention disabled (`retentionKeep: nil`)
    /// OR the apply never reached the green retention point (refusal/abort paths
    /// never prune); non-nil = what the best-effort prune kept/pruned, or
    /// "retention skipped: <reason>" when the prune itself failed. Hygiene only —
    /// never alters `success` semantics, receipts or exit codes.
    public var retentionNote: String?

    public init(plan: InstallPlan, receipts: [StepReceipt], abortedStep: InstallStep?, finalInstalledShortVersion: String?, backup: BackupReceipt?, retentionNote: String? = nil) {
        self.plan = plan
        self.receipts = receipts
        self.abortedStep = abortedStep
        self.finalInstalledShortVersion = finalInstalledShortVersion
        self.backup = backup
        self.retentionNote = retentionNote
    }
}

/// Honest installer error domain (no layered unknowns).
public enum InstallerError: Error, CustomStringConvertible, Sendable {
    case unsupportedArtifact(reason: String)
    case httpsRequired(url: String)
    case sha256Missing(what: String)
    case sha256Mismatch(expected: String, actual: String)
    case magicMismatch(reason: String)
    case noAppFoundInArtifact(kind: InstallKind)
    case quitTimedOut(app: String, foundRunning: Bool)
    case swapFailed(reason: String)
    case backupFailed(reason: String)

    public var description: String {
        switch self {
        case .unsupportedArtifact(let r): return "unsupported artifact: \(r)"
        case .httpsRequired(let url): return "HTTPS-only policy: refusing \(url)"
        case .sha256Missing(let what): return "no sha256 available to verify (\(what)) — refusing install"
        case .sha256Mismatch(let expected, let actual): return "sha256 mismatch: expected \(expected), got \(actual)"
        case .magicMismatch(let r): return "artifact magic/extension mismatch: \(r)"
        case .noAppFoundInArtifact(let k): return "no .app bundle found inside \(k.rawValue)"
        case .quitTimedOut(let app, let found): return "could not quit \(app) (running: \(found))"
        case .swapFailed(let r): return "swap failed: \(r)"
        case .backupFailed(let r): return "backup failed: \(r)"
        }
    }
}
