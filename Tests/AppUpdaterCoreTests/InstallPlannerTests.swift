// InstallPlanner tests — pure planning logic, no I/O, no network, no processes.
// Swift Testing only (XCTest discovery is broken on this toolchain).

import Foundation
import Testing
@testable import AppUpdaterCore

@Suite struct InstallPlannerTests {
    private let planner = InstallPlanner()

    private func app(short: String? = "1.0", mas: Bool = false) -> InstalledApp {
        InstalledApp(
            bundleIdentifier: "io.appupdater.plan",
            name: "Plan Victim",
            path: "/tmp/PlanVictim.app",
            shortVersion: short,
            bundleVersion: "10",
            isMacAppStore: mas
        )
    }

    private func update(url: String, sha: String? = "9f8f1c0f7b3a4d5e6f7089f2a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0", confidence: UpdateConfidence = .medium, version: String = "2.0") -> UpdateInfo {
        UpdateInfo(
            source: .cask,
            newestShortVersion: version,
            downloadURL: URL(string: url),
            sha256Hex: sha,
            confidence: confidence
        )
    }

    @Test func dmgPlanHasLockedStepOrder() throws {
        let plan = try planner.plan(app: app(), update: update(url: "https://example.com/Victim.dmg"))
        #expect(plan.kind == .dmg)
        #expect(plan.steps == [.download, .verifySha256, .verifyArtifactMagic, .backup, .quitRunningApp, .deployArtifact, .swapBundles, .relaunch, .postScan])
        #expect(plan.warnings.isEmpty)
    }

    @Test func zipKindPlanned() throws {
        let plan = try planner.plan(app: app(), update: update(url: "https://example.com/victim.zip"))
        #expect(plan.kind == .zip)
    }

    // QUERY-STRING ARTIFACTS (live-test finding, 2026-10-29): distributors
    // like Warp put the kind in the query (`…/download/brew?…&package=dmg`)
    // with an extensionless path — the plan must still be a dmg, and a
    // queryless extensionless URL must still refuse with an honest reason.
    @Test func queryStringKindHintPlansWhenPathHasNoExtension() throws {
        let plan = try planner.plan(
            app: app(),
            update: update(url: "https://app.warp.dev/download/brew?version=v1&package=dmg"))
        #expect(plan.kind == .dmg)
    }

    @Test func queryStringZipAndPkgHintsAlsoHonored() throws {
        #expect(InstallPlanner.kind(from: URL(string: "https://example.com/get?type=zip")!) == .zip)
        #expect(InstallPlanner.kind(from: URL(string: "https://example.com/get?file=x.pkg")!) == .pkg)
    }

    @Test func extensionlessURLWithoutQueryHintStillRefusedHonestly() {
        #expect(throws: InstallerError.self) {
            try planner.plan(
                app: app(),
                update: update(url: "https://example.com/download/latest?token=abc&os=mac"))
        }
        #expect(InstallPlanner.kind(from: URL(string: "https://example.com/download/latest?token=abc")!) == nil)
    }

    @Test func nonEmptyPathExtensionNeverFallsBackToQuery() {
        // a path extension the planner cannot use must refuse on its own
        // merits — the query fallback is only for EMPTY extensions.
        #expect(InstallPlanner.kind(from: URL(string: "https://example.com/victim.tbz?type=zip")!) == nil)
    }

    @Test func missingDownloadURLRefused() {
        #expect(throws: InstallerError.self) {
            try planner.plan(app: app(), update: UpdateInfo(source: .cask, newestShortVersion: "2.0", downloadURL: nil, sha256Hex: "aa"))
        }
    }

    @Test func httpSchemeRefused() {
        #expect(throws: InstallerError.self) {
            try planner.plan(app: app(), update: update(url: "http://example.com/victim.dmg"))
        }
    }

    @Test func unsupportedExtensionsRefused() {
        // tbz/bin are not user-space v1 and not stageable — honest refusal, no guessing.
        // (.pkg left this list 2026-10-27: it is now the staged-owner-command kind.)
        for ext in ["tbz", "bin"] {
            #expect(throws: InstallerError.self) {
                try planner.plan(app: app(), update: update(url: "https://example.com/victim.\(ext)"))
            }
        }
    }

    @Test func pkgPlanStagesOwnerCommandNeverExecutes() throws {
        let plan = try planner.plan(app: app(), update: update(url: "https://example.com/Victim-2.0.pkg"))
        #expect(plan.kind == .pkg)
        #expect(plan.steps == [.download, .verifySha256, .verifyArtifactMagic, .stageOwnerCommand])
        // The consent boundary, pinned in the plan itself:
        #expect(plan.warnings.contains { $0.contains("never runs installer(8)") })
        #expect(plan.stagedCommand == "sudo installer -pkg <staged-pkg-path> -target /")
    }

    @Test func pkgKeepsTheSecurityFloor() {
        // The staged-command convenience adds NOTHING past the floor:
        // HTTP pkg and sha256-less pkg are still honest refusals.
        #expect(throws: InstallerError.self) {
            try planner.plan(app: app(), update: update(url: "http://example.com/victim.pkg"))
        }
        #expect(throws: InstallerError.self) {
            try planner.plan(app: app(), update: update(url: "https://example.com/victim.pkg", sha: nil))
        }
    }

    @Test func missingSha256RefusedEvenForHighConfidence() {
        #expect(throws: InstallerError.self) {
            try planner.plan(app: app(), update: update(url: "https://example.com/victim.dmg", sha: nil, confidence: .high))
        }
    }

    @Test func downgradeIsPlannedWithExplicitWarning() throws {
        let plan = try planner.plan(app: app(short: "3.2"), update: update(url: "https://example.com/victim.dmg", version: "3.0"))
        #expect(plan.warnings.contains { $0.contains("OLDER than installed") && $0.contains("downgrade") })
    }

    @Test func macAppStoreTargetGetsStoreWarning() throws {
        let plan = try planner.plan(app: app(mas: true), update: update(url: "https://example.com/victim.dmg"))
        #expect(plan.warnings.contains { $0.contains("Mac App Store") && $0.contains("entitlements") })
    }

    @Test func lowConfidenceGetWarningHighGetNone() throws {
        let low = try planner.plan(app: app(), update: update(url: "https://example.com/victim.dmg", confidence: .low))
        #expect(low.warnings.contains { $0.contains("confidence is LOW") })
        let high = try planner.plan(app: app(), update: update(url: "https://example.com/victim.dmg", confidence: .high))
        #expect(!high.warnings.contains { $0.contains("confidence") })
    }
}
