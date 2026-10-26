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
        // pkg is the privileged lane; tbz/bin are not user-space v1 — honest refusal, no guessing.
        for ext in ["pkg", "tbz", "bin"] {
            #expect(throws: InstallerError.self) {
                try planner.plan(app: app(), update: update(url: "https://example.com/victim.\(ext)"))
            }
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
