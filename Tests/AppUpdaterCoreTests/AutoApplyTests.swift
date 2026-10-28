// AutoApplyTests.swift — hermetic tests for the auto-apply consent core
// (Sources/AppUpdaterCore/AutoApply/, GAP #22, decision 14).
//
// Swift Testing ONLY — XCTest discovery is broken on this toolchain (AGENTS.md
// gotcha ledger). Swift Testing does not re-export Foundation, so
// `import Foundation` is required here.
//
// Hermeticity: the gate consumes ONLY the seam-provided state in its input —
// no network, no processes, no file I/O, no clocks. The settings-store tests
// use per-test UUID temp roots (the Phase-4 fixture-collision rule: never a
// shared fixed root). No force unwraps anywhere (the lint gate treats
// force_unwrapping as an error, tests included).
//
// Coverage map (the implemented exclusion matrix, AutoApplyGate.swift header):
// every reason exercised independently, precedence pairs for the documented
// order, opt-in defaults FALSE everywhere, user-space-only enforcement
// (pkg/tbz/tgz refused even when fully opted in), MAS refusal, the decoded
// inconsistent-check guard, settings persistence conventions, and the
// gate-over-install separation (the gate decides; outcomes are assembled by
// the caller).

import Foundation
import Testing
@testable import AppUpdaterCore

@Suite
struct AutoApplyTests {

    // MARK: - Fixture helpers

    private func makeApp(
        bundleID: String = "com.example.app",
        name: String = "Example App",
        isMAS: Bool = false
    ) -> InstalledApp {
        InstalledApp(
            bundleIdentifier: bundleID,
            name: name,
            path: "/Applications/Example App.app",
            shortVersion: "1.0",
            isMacAppStore: isMAS
        )
    }

    private func makeClaim(downloadURL: String?) -> UpdateInfo {
        UpdateInfo(
            source: .cask,
            newestShortVersion: "2.0",
            downloadURL: downloadURL.flatMap { URL(string: $0) },
            sha256Hex: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            confidence: .high
        )
    }

    /// Default check: verdict "update" (resolved claim, zip URL).
    private func makeCheck(
        downloadURL: String? = "https://releases.example.com/Example-2.0.zip",
        candidates: [UpdateInfo]? = nil,
        failures: [CheckSourceFailure] = []
    ) -> UpdateCheck {
        let app = makeApp()
        let claim = downloadURL.map { makeClaim(downloadURL: $0) }
        let resolvedCandidates: [UpdateInfo] = candidates ?? (claim.map { [$0] } ?? [])
        return UpdateCheck(
            app: app,
            candidates: resolvedCandidates,
            failures: failures,
            resolved: claim
        )
    }

    /// A check with NO resolved claim — the memberwise init derives the
    /// verdict honestly from what the sources produced.
    private func unresolvedCheck(
        candidates: [UpdateInfo] = [],
        failures: [CheckSourceFailure] = []
    ) -> UpdateCheck {
        UpdateCheck(app: makeApp(), candidates: candidates, failures: failures, resolved: nil)
    }

    /// Fully favorable baseline: both consent switches ON, AC power, online,
    /// nothing running, no rules, zip claim — the gate must say `.apply`.
    private func favorableInput(
        app: InstalledApp? = nil,
        check: UpdateCheck? = nil
    ) -> AutoApplyGateInput {
        AutoApplyGateInput(
            app: app ?? makeApp(),
            check: check ?? makeCheck(),
            autoApplyEnabled: true,
            perAppOptIn: true,
            policy: SchedulePolicy(),
            onBattery: false,
            isOnline: true,
            runningBundleIdentifiers: []
        )
    }

    private func skipReason(_ decision: AutoApplyDecision) -> AutoApplySkipReason? {
        if case .skip(let skip) = decision { return skip.reason }
        return nil
    }

    private func skipDetail(_ decision: AutoApplyDecision) -> String? {
        if case .skip(let skip) = decision { return skip.detail }
        return nil
    }

    /// A hand-crafted INCONSISTENT check (resolved claim present, verdict
    /// "current") via the Codable round door — impossible through the
    /// memberwise init (the verdict is derived), exactly what the #6 guard
    /// defends against for legacy-decoded or hand-assembled payloads.
    private func decodedInconsistentCheck() throws -> UpdateCheck {
        let json = """
        {
          "app": {"bundleIdentifier": "com.example.legacy", "name": "Legacy",
                  "path": "/Applications/Legacy.app", "isMacAppStore": false},
          "candidates": [{"source": "cask", "newestShortVersion": "9.9", "confidence": "high"}],
          "failures": [],
          "resolved": {"source": "cask", "newestShortVersion": "9.9", "confidence": "high",
                       "downloadURL": "https://releases.example.com/Legacy-9.9.zip"},
          "verdict": "current"
        }
        """
        return try JSONDecoder().decode(UpdateCheck.self, from: Data(json.utf8))
    }

    // MARK: - Positive control (all gates pass)

    @Test func favorableInputApplies() {
        let decision = AutoApplyGate.decide(favorableInput())
        #expect(decision == .apply)
    }

    @Test func gateIsDeterministic() {
        let input = favorableInput()
        let first = AutoApplyGate.decide(input)
        for _ in 0..<100 {
            #expect(AutoApplyGate.decide(input) == first)
        }
    }

    // MARK: - #1/#2 Consent (decision 14: default OFF everywhere)

    @Test func globalOffSkipsEvenWhenEverythingElseFavorsApply() {
        var input = favorableInput()
        input.autoApplyEnabled = false
        let decision = AutoApplyGate.decide(input)
        #expect(skipReason(decision) == .autoApplyDisabled)
        #expect(skipDetail(decision)?.contains("OFF") == true)
    }

    @Test func perAppNotOptedInSkips() {
        var input = favorableInput()
        input.perAppOptIn = false
        let decision = AutoApplyGate.decide(input)
        #expect(skipReason(decision) == .perAppNotOptedIn)
    }

    @Test func inputDefaultsAreFailClosed() {
        // Bare input (defaults): global switch OFF first.
        let bare = AutoApplyGateInput(app: makeApp(), check: makeCheck())
        #expect(skipReason(AutoApplyGate.decide(bare)) == .autoApplyDisabled)
        // Global granted but the per-app flag omitted: still refuses.
        let globalOnly = AutoApplyGateInput(app: makeApp(), check: makeCheck(), autoApplyEnabled: true)
        #expect(skipReason(AutoApplyGate.decide(globalOnly)) == .perAppNotOptedIn)
    }

    // MARK: - #3/#4 System boundary + standing rules

    @Test func macAppStoreAppNeverAutoApplies() {
        let input = favorableInput(app: makeApp(isMAS: true))
        let decision = AutoApplyGate.decide(input)
        #expect(skipReason(decision) == .macAppStoreApp)
    }

    @Test func ignoreBundleRuleSkips() {
        var input = favorableInput()
        input.ruleDecision = RuleDecision(ignoredBundle: true)
        let decision = AutoApplyGate.decide(input)
        #expect(skipReason(decision) == .ignoredByRule)
        #expect(skipDetail(decision)?.contains("ignoreBundle") == true)
    }

    @Test func ignoreVersionRuleSkipsThisClaim() {
        var input = favorableInput()
        input.ruleDecision = RuleDecision(ignoredVersion: true)
        let decision = AutoApplyGate.decide(input)
        #expect(skipReason(decision) == .ignoredByRule)
        #expect(skipDetail(decision)?.contains("ignoreVersion") == true)
        #expect(skipDetail(decision)?.contains("2.0") == true)
    }

    // MARK: - #5/#6 Claim validity

    @Test func noResolvedClaimSkipsWhenVerdictCurrent() {
        let check = unresolvedCheck(candidates: [makeClaim(downloadURL: "https://releases.example.com/Example-2.0.zip")])
        // The memberwise init derives the verdict: candidates exist, none resolved → "current".
        #expect(check.verdict == "current")
        let input = favorableInput(check: check)
        #expect(skipReason(AutoApplyGate.decide(input)) == .noResolvedClaim)
    }

    @Test func noResolvedClaimSkipsWhenVerdictUnknown() {
        let check = unresolvedCheck()
        #expect(check.verdict == "unknown")
        let input = favorableInput(check: check)
        #expect(skipReason(AutoApplyGate.decide(input)) == .noResolvedClaim)
    }

    @Test func noResolvedClaimSkipsWhenVerdictFailed() {
        let check = unresolvedCheck(
            failures: [CheckSourceFailure(kind: .cask, message: "network unreachable")]
        )
        #expect(check.verdict == "failed")
        let input = favorableInput(check: check)
        #expect(skipReason(AutoApplyGate.decide(input)) == .noResolvedClaim)
    }

    @Test func verdictNotUpdateRefusesInconsistentCheck() throws {
        let check = try decodedInconsistentCheck()
        #expect(check.resolved != nil)
        #expect(check.verdict == "current")
        var input = favorableInput(check: check)
        input.app = check.app
        let decision = AutoApplyGate.decide(input)
        #expect(skipReason(decision) == .verdictNotUpdate)
    }

    // MARK: - #7 Installer-bundle name signal (deep-filter adaptation)

    @Test func documentedInstallerBundleNamesRefuseDownloadURLs() {
        let installerURLs = [
            "https://vendor.example/downloads/update",     // bare documented name
            "https://vendor.example/downloads/installer",  // bare documented name
            "https://vendor.example/Setup.app",            // exact documented name
            "https://vendor.example/Click_to_Install.app", // ".app"-stripped bare name
            "https://vendor.example/Widget.install",       // the "*.install" glob
            "https://vendor.example/UPDATER",              // case-insensitive
        ]
        for urlString in installerURLs {
            let input = favorableInput(check: makeCheck(downloadURL: urlString))
            let decision = AutoApplyGate.decide(input)
            #expect(skipReason(decision) == .installerBundleArtifact, "URL: \(urlString)")
            #expect(skipDetail(decision)?.contains("installer-bundle") == true, "URL: \(urlString)")
        }
    }

    @Test func ordinaryArtifactNamesProceedToApply() {
        for urlString in [
            "https://releases.example.com/Example-2.0.zip",
            "https://releases.example.com/Tool.dmg",
        ] {
            let input = favorableInput(check: makeCheck(downloadURL: urlString))
            #expect(AutoApplyGate.decide(input) == .apply, "URL: \(urlString)")
        }
    }

    // MARK: - #8/#9 User-space-only enforcement (pkg/tbz/tgz/unclassifiable)

    @Test func pkgNeverAutoAppliesEvenWhenFullyOptedIn() {
        let input = favorableInput(check: makeCheck(downloadURL: "https://releases.example.com/Tool.pkg"))
        let decision = AutoApplyGate.decide(input)
        #expect(skipReason(decision) == .nonUserSpaceArtifact)
        #expect(skipDetail(decision)?.contains("pkg") == true)
        #expect(skipDetail(decision)?.contains("owner-command") == true)
    }

    @Test func tbzAndTgzRefuse() {
        for urlString in ["https://releases.example.com/Tool.tbz", "https://releases.example.com/Tool.tgz"] {
            let input = favorableInput(check: makeCheck(downloadURL: urlString))
            let decision = AutoApplyGate.decide(input)
            #expect(skipReason(decision) == .nonUserSpaceArtifact, "URL: \(urlString)")
        }
    }

    @Test func unknownArtifactKindRefuses() {
        for urlString in ["https://releases.example.com/tool.bin", "https://releases.example.com/App-2.0"] {
            let input = favorableInput(check: makeCheck(downloadURL: urlString))
            let decision = AutoApplyGate.decide(input)
            #expect(skipReason(decision) == .artifactKindUnknown, "URL: \(urlString)")
        }
    }

    @Test func missingDownloadURLRefuses() {
        let claim = makeClaim(downloadURL: nil)
        let check = UpdateCheck(app: makeApp(), candidates: [claim], resolved: claim)
        #expect(check.verdict == "update")
        let input = favorableInput(check: check)
        let decision = AutoApplyGate.decide(input)
        #expect(skipReason(decision) == .artifactKindUnknown)
        #expect(skipDetail(decision)?.contains("no download URL") == true)
    }

    // MARK: - #10–#12 Transient environment (retryable, matrix tail)

    @Test func batterySkipRequiresBothPolicyAndState() {
        var input = favorableInput()
        input.onBattery = true
        #expect(skipReason(AutoApplyGate.decide(input)) == .onBattery)

        input.policy.skipOnBattery = false
        #expect(AutoApplyGate.decide(input) == .apply)

        input.policy.skipOnBattery = true
        input.onBattery = false
        #expect(AutoApplyGate.decide(input) == .apply)
    }

    @Test func offlineSkipRequiresBothPolicyAndState() {
        var input = favorableInput()
        input.isOnline = false
        #expect(AutoApplyGate.decide(input) == .apply) // policy default: deferWhenOffline false

        input.policy.deferWhenOffline = true
        #expect(skipReason(AutoApplyGate.decide(input)) == .offline)

        input.isOnline = true
        #expect(AutoApplyGate.decide(input) == .apply)
    }

    @Test func runningAppSkipsByBundleIdentifier() {
        var input = favorableInput()
        input.runningBundleIdentifiers = ["com.example.app"]
        let decision = AutoApplyGate.decide(input)
        #expect(skipReason(decision) == .appCurrentlyRunning)

        input.runningBundleIdentifiers = ["COM.EXAMPLE.APP"] // documented case-insensitive match
        #expect(skipReason(AutoApplyGate.decide(input)) == .appCurrentlyRunning)

        input.runningBundleIdentifiers = ["com.other.somewhere"]
        #expect(AutoApplyGate.decide(input) == .apply)
    }

    // MARK: - Precedence (documented order; FIRST match wins)

    @Test func globalOffBeatsEverything() {
        var input = favorableInput(
            app: makeApp(isMAS: true),
            check: makeCheck(downloadURL: "https://releases.example.com/Tool.pkg")
        )
        input.autoApplyEnabled = false
        input.perAppOptIn = false
        input.ruleDecision = RuleDecision(ignoredBundle: true)
        input.onBattery = true
        input.isOnline = false
        input.runningBundleIdentifiers = ["com.example.app"]
        input.policy.deferWhenOffline = true
        #expect(skipReason(AutoApplyGate.decide(input)) == .autoApplyDisabled)
    }

    @Test func perAppConsentBeatsSystemBoundaryAndRules() {
        let input = favorableInput(app: makeApp(isMAS: true))
        var optedOut = input
        optedOut.perAppOptIn = false
        optedOut.ruleDecision = RuleDecision(ignoredBundle: true)
        #expect(skipReason(AutoApplyGate.decide(optedOut)) == .perAppNotOptedIn)
    }

    @Test func systemBoundaryBeatsRules() {
        var input = favorableInput(app: makeApp(isMAS: true))
        input.ruleDecision = RuleDecision(ignoredBundle: true)
        #expect(skipReason(AutoApplyGate.decide(input)) == .macAppStoreApp)
    }

    @Test func rulesBeatClaimValidity() {
        // An ignoredVersion app whose check never resolved: the rule reason wins.
        var input = favorableInput(check: unresolvedCheck())
        input.ruleDecision = RuleDecision(ignoredVersion: true)
        #expect(skipReason(AutoApplyGate.decide(input)) == .ignoredByRule)
    }

    @Test func noResolvedClaimBeatsArtifactClassification() {
        // No claim at all: nothing to classify, the claim reason wins.
        let input = favorableInput(check: unresolvedCheck())
        #expect(skipReason(AutoApplyGate.decide(input)) == .noResolvedClaim)
    }

    @Test func installerNameBeatsKindClassification() {
        // Bare documented name + no recognizable extension: the name signal
        // wins (this ordering keeps the name check reachable for every shape).
        let input = favorableInput(check: makeCheck(downloadURL: "https://vendor.example/downloads/install"))
        #expect(skipReason(AutoApplyGate.decide(input)) == .installerBundleArtifact)
    }

    @Test func kindClassificationBeatsTransientSkips() {
        var input = favorableInput(check: makeCheck(downloadURL: "https://releases.example.com/Tool.pkg"))
        input.onBattery = true
        input.isOnline = false
        input.policy.deferWhenOffline = true
        input.runningBundleIdentifiers = ["com.example.app"]
        #expect(skipReason(AutoApplyGate.decide(input)) == .nonUserSpaceArtifact)
    }

    @Test func transientOrderBatteryThenOfflineThenRunning() {
        var input = favorableInput()
        input.onBattery = true
        input.isOnline = false
        input.policy.deferWhenOffline = true
        input.runningBundleIdentifiers = ["com.example.app"]
        #expect(skipReason(AutoApplyGate.decide(input)) == .onBattery)

        input.onBattery = false
        #expect(skipReason(AutoApplyGate.decide(input)) == .offline)

        input.isOnline = true
        #expect(skipReason(AutoApplyGate.decide(input)) == .appCurrentlyRunning)
    }

    // MARK: - Gate-over-install separation + receipt types

    @Test func skipOutcomeCarriesNoInstallOutcome() {
        let decision = AutoApplyGate.decide(favorableInput())
        #expect(decision == .apply)

        let skipped = AutoApplyGate.decide(favorableInput(app: makeApp(isMAS: true)))
        let outcome = AutoApplyOutcome(app: makeApp(isMAS: true), decidedAt: Date(), decision: skipped)
        #expect(outcome.installOutcome == nil)
    }

    @Test func applyOutcomeCanCarryExistingInstallOutcome() {
        let app = makeApp()
        let check = makeCheck()
        let decision = AutoApplyGate.decide(favorableInput(app: app, check: check))
        #expect(decision == .apply)
        // The coordinator (not the gate) assembles this: a plan + an outcome
        // from the EXISTING chain, embedded verbatim.
        let plan = InstallPlan(
            app: app,
            update: makeClaim(downloadURL: "https://releases.example.com/Example-2.0.zip"),
            kind: .zip,
            steps: [.download, .verifySha256],
            warnings: []
        )
        let installOutcome = InstallOutcome(
            plan: plan, receipts: [], abortedStep: nil,
            finalInstalledShortVersion: "2.0", backup: nil
        )
        let outcome = AutoApplyOutcome(
            app: app, decidedAt: Date(), decision: decision, installOutcome: installOutcome
        )
        #expect(outcome.installOutcome?.plan.kind == .zip)
    }

    @Test func decisionCodableRoundTripAndUnknownActionRefusal() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let applyData = try encoder.encode(AutoApplyDecision.apply)
        #expect(try decoder.decode(AutoApplyDecision.self, from: applyData) == .apply)

        let skip = AutoApplyDecision.skip(AutoApplySkip(reason: .nonUserSpaceArtifact, detail: "pkg path"))
        let skipData = try encoder.encode(skip)
        #expect(try decoder.decode(AutoApplyDecision.self, from: skipData) == skip)

        // Skip WITHOUT detail round-trips (optional stays optional).
        let bareSkipData = try encoder.encode(AutoApplyDecision.skip(AutoApplySkip(reason: .onBattery)))
        let bareSkip = try decoder.decode(AutoApplyDecision.self, from: bareSkipData)
        #expect(bareSkip == .skip(AutoApplySkip(reason: .onBattery, detail: nil)))

        // Unknown action: honest DecodingError, never guessed into a decision.
        let garbage = Data("{\"action\":\"maybe\"}".utf8)
        #expect(throws: DecodingError.self) { try decoder.decode(AutoApplyDecision.self, from: garbage) }
    }

    @Test func runReceiptCountsAreComputed() throws {
        let apply = AutoApplyOutcome(app: makeApp(), decidedAt: Date(), decision: .apply)
        let skipOne = AutoApplyOutcome(
            app: makeApp(bundleID: "com.example.two"),
            decidedAt: Date(),
            decision: .skip(AutoApplySkip(reason: .macAppStoreApp))
        )
        let skipTwo = AutoApplyOutcome(
            app: makeApp(bundleID: "com.example.three"),
            decidedAt: Date(),
            decision: .skip(AutoApplySkip(reason: .onBattery, detail: "battery"))
        )
        let receipt = AutoApplyRunReceipt(startedAt: Date(), finishedAt: Date(), outcomes: [apply, skipOne, skipTwo])
        #expect(receipt.appliedCount == 1)
        #expect(receipt.skippedCount == 2)

        let roundTripped = try JSONDecoder().decode(
            AutoApplyRunReceipt.self, from: JSONEncoder().encode(receipt))
        #expect(roundTripped == receipt)
    }

    // MARK: - AutoApplySettings: opt-in semantics + persistence conventions

    private func newRoot(created: Bool = true) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("autoapply-tests-\(UUID().uuidString)", isDirectory: true)
        if created {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    @Test func optInLookupDefaultsToFalse() {
        let settings = AutoApplySettings(perAppOptIn: ["com.opted.in": true, "com.declined": false])
        #expect(settings.autoApplyEnabled == false) // global default OFF
        #expect(settings.isOptedIn(bundleIdentifier: "com.opted.in") == true)
        #expect(settings.isOptedIn(bundleIdentifier: "com.declined") == false) // explicit false stays false
        #expect(settings.isOptedIn(bundleIdentifier: "com.unknown.app") == false) // absent = OFF
        #expect(AutoApplySettings().perAppOptIn.isEmpty)
    }

    @Test func freshStoreLoadsDefaultsWithoutTouchingDisk() async throws {
        let root = try newRoot(created: false)
        let store = AutoApplySettingsStore(directory: root)
        let settings = try await store.load()
        #expect(settings == AutoApplySettings())
        // Read-only posture: load() must not have created anything.
        #expect(FileManager.default.fileExists(atPath: root.path) == false)
    }

    @Test func saveLoadRoundTrip() async throws {
        let store = AutoApplySettingsStore(directory: try newRoot())
        var settings = AutoApplySettings()
        settings.autoApplyEnabled = true
        settings.perAppOptIn = ["com.example.app": true, "com.other.app": false]
        try await store.save(settings)
        let loaded = try await store.load()
        #expect(loaded == settings)
    }

    @Test func unparseableFileBecomesDefaultsAndNextSaveReplacesIt() async throws {
        let root = try newRoot()
        let fileURL = root.appendingPathComponent("auto_apply_settings.json")
        try Data("not json at all {".utf8).write(to: fileURL)
        let store = AutoApplySettingsStore(directory: root)
        #expect(try await store.load() == AutoApplySettings()) // fail-closed defaults
        var settings = AutoApplySettings()
        settings.autoApplyEnabled = true
        try await store.save(settings)
        let loaded = try await store.load()
        #expect(loaded.autoApplyEnabled == true) // garbage replaced by canonical bytes
    }

    @Test func decodeToleranceForOlderOrHandEditedFiles() async throws {
        let root = try newRoot()
        let fileURL = root.appendingPathComponent("auto_apply_settings.json")
        // Missing keys + an unknown future key: decodes to the fail-closed default.
        let legacy = Data("{\"futureField\": 1}".utf8)
        try legacy.write(to: fileURL)
        let store = AutoApplySettingsStore(directory: root)
        #expect(try await store.load() == AutoApplySettings())
        // Present keys are honored.
        let partial = Data("{\"autoApplyEnabled\": true, \"perAppOptIn\": {\"com.x\": true}}".utf8)
        try partial.write(to: fileURL)
        let loaded = try await store.load()
        #expect(loaded.autoApplyEnabled == true)
        #expect(loaded.isOptedIn(bundleIdentifier: "com.x") == true)
    }

    @Test func saveCreatesDirectoryLazily() async throws {
        let root = try newRoot(created: false)
        let nested = root.appendingPathComponent("Support", isDirectory: true)
        let store = AutoApplySettingsStore(directory: nested)
        try await store.save(AutoApplySettings())
        #expect(FileManager.default.fileExists(atPath: nested.appendingPathComponent("auto_apply_settings.json").path))
    }

    @Test func saveFailureSurfacesInsteadOfSilentLoss() async throws {
        let root = try newRoot()
        // Occupy the store-directory path with a FILE: createDirectory must fail.
        let blocker = root.appendingPathComponent("occupied")
        try Data("x".utf8).write(to: blocker)
        let store = AutoApplySettingsStore(directory: blocker)
        do {
            try await store.save(AutoApplySettings())
            Issue.record("save into an occupied path must throw, not silently succeed")
        } catch {
            // Expected: the failure surfaces instead of vanishing.
        }
    }
}
