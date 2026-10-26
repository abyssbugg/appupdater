// InstallCoordinator.swift — Phase 3 close-out wire-up (coordinator lane).
//
// Composes the four merged installer executors into the LOCKED step order of
// `InstallStep` (download → verifySha256 → verifyArtifactMagic → backup →
// quitRunningApp → deployArtifact → swapBundles → relaunch → postScan),
// producing one honest `StepReceipt` per ATTEMPTED step and aborting at the
// FIRST failure (`abortedStep`). Executed steps before the abort keep their
// green receipts — including a completed backup, which survives into
// `outcome.backup` regardless of where the run aborted.
//
// Executors are NEVER re-implemented here; the coordinator owns only:
//   • sequencing + receipts (timing, detail text, success flags),
//   • the INDEPENDENT sha256 re-verification (`Checksum.sha256Hex(ofFile:)` —
//     a second opinion on the staged bytes; the downloader already hashed
//     while writing, so this is defense in depth against pipeline bugs),
//   • the independent artifact-magic re-verification (zip PK\x03\x04 re-read;
//     dmg carries no leading magic — documented boundary, mount-time
//     authenticity belongs to the deploy lane),
//   • the old-copy DISPOSITION policy (default: move the retained
//     `~~~appupdater-old~~~` copy to the user's Trash, best effort — a failed
//     disposition never downgrades a green swap; the receipt records retention),
//   • per-apply staging hygiene (fresh `apply-<uuid>` workspace under
//     `stagingRoot`, removed after EVERY outcome — `backupsRoot` is separate
//     and cleanup never touches it; no half-artifacts are left behind),
//   • the post-scan identity + version read (direct Info.plist read through
//     Scan's InfoProbe — no Bundle cache, fresh disk truth).
//
// Honesty invariants:
//   • `abortedStep` is the FIRST failed step; following steps are simply not
//     in the receipts (never fabricated).
//   • A green swap is never downgraded by a late failure (a failed relaunch
//     aborts at .relaunch; the swap receipt above it stays green).
//   • postScan failing on a healthy swap still aborts AT postScan — the
//     install happened, but verification would not vouch for it; reports show
//     both truths side by side.
//   • Nothing here shells out to `sudo`; user-space only (project floor).

import Foundation

public struct InstallCoordinator: Sendable {

    public let downloader: UpdateDownloader
    public let backupManager: BackupManager
    public let terminator: AppTerminator
    /// Old-copy disposition policy. Receives the URL of the `~~~appupdater-old~~~`
    /// copy a SUCCESSFUL swap retained at; returns where it now lives (or nil when
    /// the policy hands it off without a destination). Default = one move to the
    /// user's Trash. A throwing disposition never downgrades the swap — the
    /// swapBundles receipt records the retention honestly. Tests inject a fake so
    /// the user's real Trash is never touched.
    public let disposeOfOldCopy: @Sendable (URL) throws -> String?
    /// Test seam (internal): applied immediately after the download receipt is
    /// written, BEFORE the independent sha256 re-verification — mutations it
    /// makes to the staged bytes are exactly what the indepedent verify is
    /// designed to catch. Default nil; production wiring never sets it (doc'd
    /// seam, following the AppTerminator internal-init pattern).
    let postDownloadHook: (@Sendable (DownloadedUpdate) throws -> Void)?

    /// Production wiring: real session, real terminator, Trash disposition.
    public init(
        session: URLSession = .shared,
        terminator: AppTerminator = AppTerminator(),
        disposeOfOldCopy: @escaping @Sendable (URL) throws -> String? = InstallCoordinator.trashDisposition
    ) {
        self.downloader = UpdateDownloader(session: session)
        self.backupManager = BackupManager()
        self.terminator = terminator
        self.disposeOfOldCopy = disposeOfOldCopy
        self.postDownloadHook = nil
    }

    /// Injected-everything init (internal: used by hermetic tests via @testable).
    internal init(
        downloader: UpdateDownloader,
        terminator: AppTerminator,
        disposeOfOldCopy: @escaping @Sendable (URL) throws -> String?,
        postDownloadHook: (@Sendable (DownloadedUpdate) throws -> Void)?
    ) {
        self.downloader = downloader
        self.backupManager = BackupManager()
        self.terminator = terminator
        self.disposeOfOldCopy = disposeOfOldCopy
        self.postDownloadHook = postDownloadHook
    }

    /// Default old-copy policy: a single move to the Trash (Folder semantics via
    /// trashItem — recoverable by the user, not a deletion).
    public static func trashDisposition(for oldCopy: URL) throws -> String? {
        var destination: NSURL?
        try FileManager.default.trashItem(at: oldCopy, resultingItemURL: &destination)
        return (destination as URL?)?.path
    }

    /// Executes `plan` step by step and returns the full outcome. Never throws
    /// — every failure is captured in `receipts` + `abortedStep` (GUI/CLI
    /// consumers read data, not thrown errors).
    ///
    /// - Parameters:
    ///   - stagingRoot: root for the per-apply download/deploy workspace (a fresh
    ///     `apply-<uuid>` subdir is created and removed after the run).
    ///   - backupsRoot: where the pre-swap zip backup lands.
    ///   - relaunchRequested: when true, the relaunch step asks LaunchServices to
    ///     open the swapped bundle; when false the receipt honestly records
    ///     "not requested — nothing auto-opened".
    ///   - quitTimeout: how long the graceful-quit wait is given to observe the
    ///     app's absence (default 10 s; tests pass a tiny budget).
    public func run(
        _ plan: InstallPlan,
        stagingRoot: URL,
        backupsRoot: URL,
        relaunchRequested: Bool = false,
        quitTimeout: TimeInterval = 10
    ) async -> InstallOutcome {
        var receipts: [StepReceipt] = []
        var backupReceipt: BackupReceipt?
        var finalInstalledVersion: String?
        var abortedStep: InstallStep?
        let fm = FileManager.default

        let workspace = stagingRoot.appendingPathComponent(
            "apply-\(UUID().uuidString)", isDirectory: true)
        let downloadDir = workspace.appendingPathComponent("download", isDirectory: true)
        let deployDir = workspace.appendingPathComponent("deploy", isDirectory: true)

        // Staging hygiene for every outcome — success or abort, the workspace
        // (download artifact + deploy leftovers) is best-effort removed. The
        // backup zip lives under backupsRoot and is NEVER touched by cleanup.
        defer { try? fm.removeItem(at: workspace) }

        func receipt(_ step: InstallStep, startedAt: Date, succeeded: Bool, detail: String) {
            receipts.append(StepReceipt(
                step: step, startedAt: startedAt, endedAt: Date(),
                succeeded: succeeded, detail: detail))
        }

        func abort(_ step: InstallStep, startedAt: Date, error: Error) {
            receipt(step, startedAt: startedAt, succeeded: false, detail: Self.describe(error))
            abortedStep = step
        }

        func done() -> InstallOutcome {
            InstallOutcome(
                plan: plan, receipts: receipts, abortedStep: abortedStep,
                finalInstalledShortVersion: finalInstalledVersion, backup: backupReceipt)
        }

        // MARK: .download — stream + hash-while-writing + SourceHash gate
        let downloaded: DownloadedUpdate
        do {
            let startedAt = Date()
            downloaded = try await downloader.downloadAndVerify(from: plan.update, into: downloadDir)
            let bytes = (try? Checksum.byteCount(ofFile: downloaded.stagedURL)) ?? 0
            receipt(.download, startedAt: startedAt, succeeded: true,
                    detail: "staged \(downloaded.stagedURL.lastPathComponent) (\(bytes) bytes) from "
                        + (plan.update.downloadURL?.host ?? "unknown host"))
        } catch {
            abort(.download, startedAt: Date(), error: error)
            return done()
        }

        // MARK: .verifySha256 — INDEPENDENT second opinion over the staged file
        do {
            let startedAt = Date()
            if let postDownloadHook { try postDownloadHook(downloaded) }
            guard let expected = downloaded.expectedSha256Hex, !expected.isEmpty else {
                throw InstallerError.sha256Missing(what: plan.update.source.rawValue)
            }
            let actual = try Checksum.sha256Hex(ofFile: downloaded.stagedURL)
            guard actual == expected else {
                throw InstallerError.sha256Mismatch(expected: expected, actual: actual)
            }
            receipt(.verifySha256, startedAt: startedAt, succeeded: true,
                    detail: "independent re-verification over the staged bytes passed: sha256 \(actual.prefix(12))…")
        } catch {
            abort(.verifySha256, startedAt: Date(), error: error)
            return done()
        }

        // MARK: .verifyArtifactMagic — zip PK\x03\x04 re-read / dmg honesty
        do {
            let startedAt = Date()
            switch downloaded.kind {
            case .zip:
                try UpdateDownloader.verifyZipMagic(at: downloaded.stagedURL)
                receipt(.verifyArtifactMagic, startedAt: startedAt, succeeded: true,
                        detail: "zip magic PK\\x03\\x04 re-verified over the staged bytes")
            case .dmg:
                // No leading magic exists for UDIF; authenticity is confirmed by
                // hdiutil attach succeeding in the deploy step (documented lane
                // boundary, not a silently skipped check).
                receipt(.verifyArtifactMagic, startedAt: startedAt, succeeded: true,
                        detail: "dmg carries no leading magic (documented boundary) — authenticity confirmed at mount time by deploy")
            }
        } catch {
            abort(.verifyArtifactMagic, startedAt: Date(), error: error)
            return done()
        }

        // MARK: .backup — zip the OLD app before anything moves
        do {
            let startedAt = Date()
            let backup = try await backupManager.backup(app: plan.app, into: backupsRoot)
            backupReceipt = backup
            receipt(.backup, startedAt: startedAt, succeeded: true,
                    detail: "zip backup at \(backup.zipURL.path(percentEncoded: false)) "
                        + "(\(backup.byteCount) bytes); bundle \((backup.originalPath as NSString).lastPathComponent)")
        } catch {
            abort(.backup, startedAt: Date(), error: error)
            return done()
        }

        // MARK: .quitRunningApp — graceful quit only (lane policy)
        do {
            let startedAt = Date()
            let wasRunning = try await terminator.quit(
                bundleIdentifier: plan.app.bundleIdentifier, timeout: quitTimeout)
            receipt(.quitRunningApp, startedAt: startedAt, succeeded: true,
                    detail: wasRunning
                        ? "graceful quit of \(plan.app.bundleIdentifier) observed (instance gone)"
                        : "no running instance of \(plan.app.bundleIdentifier) — nothing to quit")
        } catch {
            abort(.quitRunningApp, startedAt: Date(), error: error)
            return done()
        }

        // MARK: .deployArtifact — zip extract / dmg mount+copy (fresh subdir)
        let deployed: DeployedBundle
        do {
            let startedAt = Date()
            deployed = try await BundleDeployer.deploy(from: downloaded, into: deployDir)
            receipt(.deployArtifact, startedAt: startedAt, succeeded: true,
                    detail: "extracted \(deployed.kind.rawValue) artifact → staged app at \(deployed.stagedAppURL.path(percentEncoded: false))")
        } catch {
            abort(.deployArtifact, startedAt: Date(), error: error)
            return done()
        }

        // MARK: .swapBundles — JMSU semantics + coordinator's old-copy policy
        do {
            let startedAt = Date()
            let result = try await AppSwapper.swap(staged: deployed, into: plan.app.path)
            var dispositionDetail = "old copy retained at \(result.oldAppMovedTo)"
            do {
                if let destination = try disposeOfOldCopy(URL(fileURLWithPath: result.oldAppMovedTo)) {
                    dispositionDetail = "old copy moved to \(destination)"
                }
            } catch {
                dispositionDetail = "old copy RETAINED at \(result.oldAppMovedTo) "
                    + "(disposition failed: \(Self.describe(error)))"
            }
            receipt(.swapBundles, startedAt: startedAt, succeeded: true,
                    detail: "swapped into \(plan.app.path); \(dispositionDetail)")
        } catch {
            abort(.swapBundles, startedAt: Date(), error: error)
            return done()
        }

        // MARK: .relaunch — never auto-open unless explicitly requested
        if relaunchRequested {
            do {
                let startedAt = Date()
                _ = try await terminator.requestRelaunch(at: plan.app.path)
                receipt(.relaunch, startedAt: startedAt, succeeded: true,
                        detail: "relaunch requested for \(plan.app.path)")
            } catch {
                abort(.relaunch, startedAt: Date(), error: error)
                return done()
            }
        } else {
            receipt(.relaunch, startedAt: Date(), succeeded: true,
                    detail: "relaunch not requested — the swapped bundle was not auto-opened")
        }

        // MARK: .postScan — fresh Info.plist read of the swapped bundle
        let postScanStarted = Date()
        let installedInfo = InfoProbe.infoDictionary(appBundleURL: URL(fileURLWithPath: plan.app.path))
        if installedInfo.isEmpty {
            receipt(.postScan, startedAt: postScanStarted, succeeded: false,
                    detail: "post-scan could not read Info.plist at \(plan.app.path)")
            abortedStep = .postScan
            return done()
        }
        let scannedID = InfoProbe.string(for: ["CFBundleIdentifier"], in: installedInfo)
        if !plan.app.bundleIdentifier.isEmpty,
           let scannedID, scannedID != plan.app.bundleIdentifier {
            receipt(.postScan, startedAt: postScanStarted, succeeded: false,
                    detail: "post-scan identity mismatch: installed bundle id \(scannedID) "
                        + "vs planned \(plan.app.bundleIdentifier)")
            abortedStep = .postScan
            return done()
        }
        finalInstalledVersion = InfoProbe.string(for: ["CFBundleShortVersionString"], in: installedInfo)
        receipt(.postScan, startedAt: postScanStarted, succeeded: true,
                detail: "post-scan: \(plan.app.path) serves bundle id \(scannedID ?? "<absent>"), "
                    + "CFBundleShortVersionString = \(finalInstalledVersion ?? "<absent>")")

        return done()
    }

    /// Fluent detail text across BOTH error domains: frozen InstallerError cases
    /// print their honest descriptions; anything else prints with its type so no
    /// context is swallowed.
    private static func describe(_ error: Error) -> String {
        if let installer = error as? InstallerError { return installer.description }
        return String(describing: error)
    }
}
