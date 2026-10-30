// AppState+Install.swift — the CLICKED-install engine. THE CLICK IS THE
// CONSENT (locked decision 14's click-driven default): for user-space
// updates (dmg/zip) this runs EXACTLY the sequence the CLI
// `install --apps <name> --apply` runs — plan → InstallCoordinator
// (download → HTTPS + SHA-256 + artifact-magic verify → backup → quit →
// swap → postScan) — in-process, receipts verbatim. A .pkg plan terminates
// in the coordinator's staged owner-command (installer(8) is NEVER executed
// — the outcome carries stagedCommand and the class body surfaces + copies
// it, unchanged UX). Store apps are refused: they cannot be user-space
// installed (the MenuData honesty rule). relaunchRequested is FALSE
// everywhere here — identical to the CLI's default (no --relaunch flag) and
// to the auto-apply pass; the receipt records the swap and the owner
// reopens the app. Serialization lives in the class body's in-flight guard
// (installs are heavy; one at a time).

import Foundation
import AppUpdaterCore

extension AppState {

    enum InstallActionError: LocalizedError {
        /// The row has no newer verified claim right now — same refusal the
        /// CLI prints ("no newer claim to install — never installs from a
        /// missing or non-newer claim").
        case notAnUpdate(name: String)
        /// Store-distributed apps cannot be user-space installed; the Store
        /// itself updates them.
        case storeApp(name: String)

        var errorDescription: String? {
            switch self {
            case .notAnUpdate(let name):
                return "nothing to update — no newer verified claim for \(name) right now (run a check to refresh)"
            case .storeApp(let name):
                return "\(name) came from the Mac App Store — it cannot be user-space installed; update it in the App Store"
            }
        }
    }

    /// Plans + runs the install for one row. Throws honestly BEFORE anything
    /// is touched when the row has no installable newer claim (CLI parity).
    /// Returns the outcome: a green user-space apply (receipts + post-scan
    /// version) OR a green pkg staging carrying the owner-run command.
    func performClickedInstall(row: AppRow) async throws -> InstallOutcome {
        guard row.app.isMacAppStore == false else {
            throw InstallActionError.storeApp(name: row.app.name)
        }
        guard let check = row.check, check.verdict == "update", let update = check.resolved else {
            throw InstallActionError.notAnUpdate(name: row.app.name)
        }
        let plan = try InstallPlanner().plan(app: row.app, update: update)
        let fm = FileManager.default
        let stagingRoot = appSupportDirectory.appendingPathComponent("staging", isDirectory: true)
        let backupsRoot = appSupportDirectory.appendingPathComponent("backups", isDirectory: true)
        try? fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: backupsRoot, withIntermediateDirectories: true)
        // NOTE: run() does NOT throw — it records aborts in outcome.abortedStep
        // (same as the CLI; the pre-existing Decision14 call carries a spurious
        // `try` that warns). Guard/planner failures above DO throw.
        let outcome = await InstallCoordinator().run(
            plan, stagingRoot: stagingRoot, backupsRoot: backupsRoot,
            relaunchRequested: false)
        recordVerifiedInstall(outcome)
        return outcome
    }
}
