// VendorInstallerFlow.swift — owner-run staging for vendor-installer artifacts
// (GAP #13, lane vendor-rules). Concept source: MACUPDATER-FINDINGS.md §5
// step 9 — MacUpdater's "installer-type updates (vendor .app installers)" are
// launched via `open`, the app is marked waiting-for-installer, and
// `watchForExternalUpdateOfApp:` observes the old path and auto-rescans after
// the user runs the vendor installer. We adapt the CONCEPT with our own
// honesty rules; we do not copy their mechanisms:
//
//   • NOTHING is executed here. The flow produces the exact OWNER-RUN command
//     string(s) plus the directory/bundle identity the app is expected to
//     appear under — the same shape as the landed staged-PKG pattern
//     (`InstallOutcome.stagedCommand`). The vendor installer's own UI and
//     password prompts stay with the owner, user-attended.
//   • Classification REUSES the deep filter's typed verdicts
//     (Candidates/CandidateFilter.swift, GAP #14): an artifact is an
//     installer-bundle/InstallBuilder candidate only when the combined filter
//     verdict is `.reject` AND the rejection comes from the documented
//     installer-bundle NAME check or the documented InstallBuilder marker
//     check. An Electron wrong-arch rejection is a DIFFERENT documented
//     disqualifier — it classifies a payload as unusable, not as a vendor
//     installer — and never triggers this flow.
//   • The security floor (LOCKED decision 6: HTTPS-only download, SHA-256
//     verification, artifact-magic re-check) runs upstream in the download/
//     plan path and is untouched here. This staging adds no trust of its own;
//     its notes say so verbatim.
//   • `.pkg` plans are OUT OF SCOPE for this flow: the landed staged-PKG
//     command path (GAP #11) owns `sudo installer` staging. Passing a pkg
//     plan here yields an honest typed refusal, never a guess.
//
// Expected-install-directory honesty: the default is the PARENT DIRECTORY of
// the currently installed bundle (where the app lives today — the analogue of
// MacUpdater observing the old path). That is an EXPECTATION, not a guarantee:
// vendor installers frequently write elsewhere (or let the owner choose a
// destination). The caller may override it; either way the watch (see
// PostInstallRescan.swift) reports honestly what it actually sees.

import Foundation

// MARK: - Outcome types

/// How the flow classified the plan/artifact pairing. Every value is a
/// first-class honest outcome — `.staged` is the only one that produced a
/// command, and its receipt travels with the result.
public enum VendorFlowClassification: String, Codable, Hashable, Sendable {
    /// Deep-filter signals classified the artifact as a vendor installer and
    /// the owner-run staging was produced (`staging != nil`).
    case staged
    /// The filter's verdict says this is NOT an installer-classified artifact
    /// (normal app-update candidate, or an Electron wrong-arch reject) — no
    /// staging was produced. The filter report travels verbatim.
    case notAnInstallerCandidate
    /// The filter could not decide (`.unknown` — unreadable/missing path,
    /// conflicting evidence). No staging; the verbatim report travels.
    case unproven
    /// The plan's kind is `.pkg`, which belongs to the staged-PKG command
    /// flow (GAP #11). This flow refuses to stage anything for it.
    case refusedPkgPlan
    /// The plan input itself was unusable (empty app path / empty bundle
    /// identifier) — nothing was classified and nothing was staged.
    case invalidInput
}

/// The flow's full result: classification + optional staging + optional
/// filter receipt + honest notes. Codable + Hashable so a coordinator can
/// persist it inside receipts exactly like `InstallOutcome`.
public struct VendorFlowOutcome: Codable, Hashable, Sendable {
    public let classification: VendorFlowClassification
    /// Non-nil ONLY for `.staged`.
    public let staging: VendorInstallerStaging?
    /// The deep-filter report whenever the filter ran (staged /
    /// notAnInstallerCandidate / unproven); nil for refusedPkgPlan and
    /// invalidInput, where no filter verdict exists to show.
    public let filterReport: CandidateFilterReport?
    /// Honesty trail: why nothing happened, or what the owner is being asked
    /// to do. Never empty.
    public let notes: [String]

    public init(classification: VendorFlowClassification,
                staging: VendorInstallerStaging?,
                filterReport: CandidateFilterReport?,
                notes: [String]) {
        self.classification = classification
        self.staging = staging
        self.filterReport = filterReport
        self.notes = notes
    }
}

/// The owner-run staging produced for an installer-classified artifact.
/// Strings only — every field is something a human (or the coordinator's
/// report renderer) reads and the OWNER executes; AppUpdater runs none of it.
public struct VendorInstallerStaging: Codable, Hashable, Sendable {
    /// The staged vendor installer path, verbatim (an extracted `.app`
    /// installer bundle on disk).
    public let installerPath: String
    /// The exact owner-run command to launch the installer, shell-quoted.
    /// Current shape: `open "<installerPath>"` — the vendor installer's own
    /// UI/password prompts stay with the owner (user-attended).
    public let launchCommand: String
    /// Where the updated app is EXPECTED to appear (an expectation, not a
    /// guarantee — see the module header). String form of the watch target.
    public let expectedInstallDirectory: String
    /// The installed bundle's name the watch should match under the expected
    /// directory (e.g. "Foo.app") — display hint only; matching is by BID.
    public let expectedAppBundleName: String
    /// The ready-made watch target for PostInstallRescan — same directory +
    /// bundle identifier, so the coordinator wires staging → watch with no
    /// re-derivation.
    public let watch: PostInstallWatchTarget
    /// The filter receipt that classified this artifact (the rejection reason
    /// from the documented signal that matched).
    public let classificationReason: String
    /// Honesty notes: user-attended, security floor upstream, expectation
    /// semantics of the directory.
    public let notes: [String]

    public init(installerPath: String,
                launchCommand: String,
                expectedInstallDirectory: String,
                expectedAppBundleName: String,
                watch: PostInstallWatchTarget,
                classificationReason: String,
                notes: [String]) {
        self.installerPath = installerPath
        self.launchCommand = launchCommand
        self.expectedInstallDirectory = expectedInstallDirectory
        self.expectedAppBundleName = expectedAppBundleName
        self.watch = watch
        self.classificationReason = classificationReason
        self.notes = notes
    }
}

// MARK: - The flow

public enum VendorInstallerFlow {

    /// Where the classification contract is documented.
    public static let documentedSource =
        "docs/reverse/MACUPDATER-FINDINGS.md §5 step 9 (installer-type updates: open + watchForExternalUpdateOfApp) "
            + "over the §5 step 8 candidate signals (Candidates/CandidateFilter.swift)"

    /// The filter verdict that classifies an artifact as a vendor installer,
    /// or nil when none does. Rule (documented above): the combined report
    /// must be `.reject`, and the rejection must come from the documented
    /// installer-bundle NAME check or the documented InstallBuilder marker
    /// check — NOT from the Electron wrong-arch detector, which classifies a
    /// payload as unusable, not as an installer.
    public static func installerClassification(in report: CandidateFilterReport) -> CandidateVerdict? {
        guard report.overall.outcome == .reject else { return nil }
        if report.installerBundle.outcome == .reject { return report.installerBundle }
        if report.installBuilder.outcome == .reject { return report.installBuilder }
        return nil
    }

    /// Stage the owner-run vendor-installer flow for a plan whose staged
    /// artifact the deep filter classified as an installer bundle.
    ///
    /// Pure: reads the staged artifact path (through CandidateFilter's
    /// read-only detectors), writes nothing, spawns nothing, and returns the
    /// typed outcome. `expectedInstallDirectory` overrides the default
    /// (parent directory of the installed app's path) when supplied.
    public static func stageOwnerRunInstall(
        plan: InstallPlan,
        stagedInstallerURL: URL,
        expectedInstallDirectory: URL? = nil
    ) -> VendorFlowOutcome {
        // Input sanity first: without a path and a bundle identifier there is
        // nothing honest to watch, so nothing may be staged.
        let appPath = plan.app.path.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleID = plan.app.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appPath.isEmpty, !bundleID.isEmpty else {
            return VendorFlowOutcome(
                classification: .invalidInput,
                staging: nil,
                filterReport: nil,
                notes: ["plan input unusable: empty app path or empty bundle identifier — "
                    + "no honest watch target exists, so no staging was produced"])
        }

        // pkg plans belong to the landed staged-PKG command flow (GAP #11).
        if plan.kind == .pkg {
            return VendorFlowOutcome(
                classification: .refusedPkgPlan,
                staging: nil,
                filterReport: nil,
                notes: ["plan kind is pkg — the staged-PKG command flow (GAP #11) owns owner-run `sudo installer` "
                    + "staging for packages; the vendor-installer flow stages only installer-bundle APP artifacts "
                    + "and refuses pkg plans honestly rather than guessing"])
        }

        // Reuse the deep filter's typed verdicts verbatim (read-only probes
        // over the staged path).
        let report = CandidateFilter.filter(candidateURL: stagedInstallerURL)
        guard let verdict = installerClassification(in: report) else {
            let classification: VendorFlowClassification = report.overall.outcome == .unknown ? .unproven : .notAnInstallerCandidate
            var notes = ["no installer classification: the deep filter's combined verdict is "
                + "\(report.overall.outcome.rawValue) and neither the documented installer-bundle NAME check nor the "
                + "documented InstallBuilder marker check rejected — this artifact is not staged as a vendor installer"]
            if classification == .unproven {
                notes.append("the filter could not decide — treat the artifact as unproven, never as either category")
            }
            notes.append("filter receipt travels verbatim in filterReport")
            return VendorFlowOutcome(
                classification: classification,
                staging: nil,
                filterReport: report,
                notes: notes)
        }

        // Expected directory: caller override, else the installed bundle's
        // parent (the app's current home — the honest default).
        let directory = expectedInstallDirectory
            ?? URL(fileURLWithPath: appPath).deletingLastPathComponent()
        let bundleName = URL(fileURLWithPath: appPath).lastPathComponent
        let target = PostInstallWatchTarget(
            expectedDirectory: directory.path,
            expectedBundleIdentifier: bundleID,
            expectedAppBundleName: bundleName)

        let installerPath = stagedInstallerURL.path
        let staging = VendorInstallerStaging(
            installerPath: installerPath,
            launchCommand: "open " + Self.shellQuoted(installerPath),
            expectedInstallDirectory: directory.path,
            expectedAppBundleName: bundleName,
            watch: target,
            classificationReason: verdict.reason ?? "installer-classified (reason unavailable)",
            notes: [
                "NOTHING is executed by AppUpdater — the OWNER runs the launch command; the vendor installer's own "
                    + "UI and password prompts stay with the owner (user-attended), exactly like the staged-PKG pattern",
                "the security floor (HTTPS-only download, SHA-256 verification, artifact-magic re-check) ran upstream "
                    + "in the download/plan path and is unchanged — this staging adds no trust of its own",
                "expectedInstallDirectory is an EXPECTATION (default: the installed app's current directory); vendor "
                    + "installers may write elsewhere — the watch reports honestly what it sees and never pretends",
                "concept source: " + documentedSource,
            ])
        return VendorFlowOutcome(
            classification: .staged,
            staging: staging,
            filterReport: report,
            notes: ["staged for owner-run execution; rescan after the owner finishes via the watch target in staging"])
    }

    // MARK: - Shell quoting

    /// Shell-quote one path for the staged command: wrap in double quotes and
    /// escape the characters a POSIX double-quoted string treats specially
    /// (`\`, `"`, `$`, and backtick). Test-pinned.
    static func shellQuoted(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
        return "\"" + escaped + "\""
    }
}
