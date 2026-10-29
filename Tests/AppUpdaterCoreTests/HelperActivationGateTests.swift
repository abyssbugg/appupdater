// HelperActivationGateTests.swift — hermetic tests for the privileged
// helper's fail-closed activation gate
// (Sources/AppUpdaterCore/PrivilegedHelper/HelperActivationGate.swift).
//
// Swift Testing ONLY — XCTest discovery is broken on this toolchain (AGENTS.md
// gotcha ledger). Swift Testing does not re-export Foundation, so
// `import Foundation` is required here.
//
// Hermeticity: the matrix tests run the PURE gate (no seam exists in decide's
// signature — it cannot probe anything by construction); the evaluate()
// tests inject a RECORDING closure stub (never a process); the settings tests
// use per-test UUID temp roots (Phase-4 fixture-collision rule). No network,
// no keychain, no SMAppService, no spawned processes anywhere in this file.
// No force unwraps anywhere (the lint gate treats force_unwrapping as an
// error, tests included).
//
// Coverage map (the implemented matrix order, HelperActivationGate.swift
// header): dev-class "Spike0 Signing" → refuse; Developer-ID + flags OFF →
// refuse; Developer-ID + flags ON + unsigned helper → refuse; ALL three pass
// → allow with receipt; fail-closed probe failures; Developer-ID-without-
// team-id refusals; consent-before-signature precedence; default settings
// OFF everywhere (fresh init, partial decode, garbage file, missing file);
// the two-switch mirror (both required); evaluate()'s probe sequencing (app
// first, helper second, exactly two invocations); receipts carry verbatim
// facts + the dormancy note and round-trip through Codable.

import Foundation
import Testing
@testable import AppUpdaterCore

/// Tiny thread-safe box for stub state (independent copy from CaskIndexTests'
/// StubBox so this lane's test file is self-contained against merge drift).
final class HelperProbeStubBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ initial: Value) { value = initial }

    func with<Result>(_ mutate: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return mutate(&value)
    }
}

@Suite
struct HelperActivationGateTests {

    // MARK: - Fixture helpers

    private static let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    /// The ONLY activatable signature shape: Developer-ID class WITH a team id.
    private func developerIDFacts(
        team: String? = "TEAM1234AB",
        authority: String = "Developer ID Application: AppUpdater Project (TEAM1234AB)"
    ) -> HelperSignatureFacts {
        HelperSignatureFacts(
            certificateKind: .developerID,
            teamIdentifier: team,
            authoritySummary: authority)
    }

    /// The dev machine's only signing identity: development-class "Spike0
    /// Signing" — MUST refuse (task §3a; the doc's §6 ordering dependency).
    private func devClassFacts() -> HelperSignatureFacts {
        HelperSignatureFacts(
            certificateKind: .development,
            teamIdentifier: "SPIKE0TEAM",
            authoritySummary: "Apple Development: Spike0 Signing (SPIKE0TEAM)")
    }

    /// Nothing signed at all.
    private func unsignedFacts() -> HelperSignatureFacts {
        HelperSignatureFacts(
            certificateKind: .absent,
            teamIdentifier: nil,
            authoritySummary: nil,
            probeNote: "codesign reports the bundle is not signed")
    }

    /// A probe that failed to read a signature at all — fail-closed facts.
    private func unreadableFacts() -> HelperSignatureFacts {
        HelperSignatureFacts(
            certificateKind: .unrecognized,
            teamIdentifier: nil,
            authoritySummary: nil,
            probeNote: "codesign -dv could not be launched: permission denied")
    }

    private func activatedSettings() -> HelperActivationSettings {
        HelperActivationSettings(helperConsented: true, ownerActivated: true)
    }

    private func input(
        app: HelperSignatureFacts? = nil,
        helper: HelperSignatureFacts? = nil,
        settings: HelperActivationSettings
    ) -> HelperActivationGateInput {
        HelperActivationGateInput(
            appSignatureFacts: app ?? developerIDFacts(),
            helperSignatureFacts: helper ?? developerIDFacts(),
            settings: settings)
    }

    private func refusal(of decision: HelperActivationDecision) -> HelperActivationRefusal? {
        if case .refused(let receipt) = decision { return receipt.refusal }
        return nil
    }

    // MARK: - THE ACTIVATION MATRIX (task §3; gate file header order)

    @Test
    func devClassSignatureRefuses() throws {
        // (a) main app signed with the dev machine's "Spike0 Signing"
        // (development class) → REFUSE, even with everything else favorable.
        let decision = HelperActivationGate.decide(
            input(app: devClassFacts(), settings: activatedSettings()),
            decidedAt: Self.fixedDate)
        let refused = try #require(refusal(of: decision))
        #expect(refused.reason == .appSignatureNotDeveloperID)
        // The receipt carries the verbatim observed evidence.
        let detail = try #require(refused.detail)
        #expect(detail.contains("development"))
        #expect(detail.contains("Spike0 Signing"))
    }

    @Test
    func developerIDWithFlagsOffRefuses() throws {
        // (b) Developer-ID signature but the persisted owner-activation flag
        // is OFF → REFUSE. Consent fully OFF (both defaults) hits the FIRST
        // switch; the mirrored second switch hits ownerActivationOff.
        let decision = HelperActivationGate.decide(
            input(settings: HelperActivationSettings()),
            decidedAt: Self.fixedDate)
        #expect(refusal(of: decision)?.reason == .helperConsentOff)

        let onlyConsentOn = HelperActivationSettings(helperConsented: true, ownerActivated: false)
        let decision2 = HelperActivationGate.decide(
            input(settings: onlyConsentOn),
            decidedAt: Self.fixedDate)
        #expect(refusal(of: decision2)?.reason == .ownerActivationOff)
    }

    @Test
    func developerIDFlagsOnUnsignedHelperRefuses() throws {
        // (c) Developer-ID app + both flags ON + unsigned helper → REFUSE.
        let decision = HelperActivationGate.decide(
            input(helper: unsignedFacts(), settings: activatedSettings()),
            decidedAt: Self.fixedDate)
        let refused = try #require(refusal(of: decision))
        #expect(refused.reason == .helperSignatureNotDeveloperID)
        let detail = try #require(refused.detail)
        #expect(detail.contains("absent"))
        #expect(detail.contains("codesign reports the bundle is not signed"))
    }

    @Test
    func allThreePassAllowsWithReceipt() throws {
        let settings = activatedSettings()
        let decision = HelperActivationGate.decide(
            input(settings: settings),
            decidedAt: Self.fixedDate)
        guard case .allowed(let receipt) = decision else {
            Issue.record("expected allowed, got \(decision)")
            return
        }
        #expect(receipt.verdict == "allowed")
        #expect(receipt.refusal == nil)
        #expect(receipt.settings == settings)
        #expect(receipt.decidedAt == Self.fixedDate)
        #expect(receipt.appSignatureFacts.isDeveloperID)
        #expect(receipt.helperSignatureFacts.isDeveloperID)
        // Every receipt carries the signed §6 honesty note verbatim.
        #expect(receipt.dormancyNote == HelperActivationReceipt.dormancyNote)
        #expect(receipt.dormancyNote.contains("BUILT-DORMANT"))
        #expect(receipt.dormancyNote.contains("staged owner-command flow"))
    }

    // MARK: - Matrix precedence (consent boundaries first)

    @Test
    func consentBeatsSignatureEvidence() {
        // Bad signature AND flags OFF → the CONSENT refusal wins (first match).
        let decision = HelperActivationGate.decide(
            input(app: devClassFacts(), settings: HelperActivationSettings()),
            decidedAt: Self.fixedDate)
        #expect(refusal(of: decision)?.reason == .helperConsentOff)
    }

    @Test
    func ownerActivationBeatsSignatureEvidence() {
        let onlyConsentOn = HelperActivationSettings(helperConsented: true, ownerActivated: false)
        let decision = HelperActivationGate.decide(
            input(app: devClassFacts(), settings: onlyConsentOn),
            decidedAt: Self.fixedDate)
        #expect(refusal(of: decision)?.reason == .ownerActivationOff)
    }

    // MARK: - Fail-closed everywhere

    @Test
    func unreadableAppSignatureRefusesWithProbeNote() throws {
        let decision = HelperActivationGate.decide(
            input(app: unreadableFacts(), settings: activatedSettings()),
            decidedAt: Self.fixedDate)
        let refused = try #require(refusal(of: decision))
        #expect(refused.reason == .appSignatureNotDeveloperID)
        let detail = try #require(refused.detail)
        #expect(detail.contains("unrecognized"))
        #expect(detail.contains("permission denied"))
    }

    @Test
    func developerIDKindWithoutTeamIdentifierRefuses() {
        let appSide = HelperActivationGate.decide(
            input(app: developerIDFacts(team: nil), settings: activatedSettings()),
            decidedAt: Self.fixedDate)
        #expect(refusal(of: appSide)?.reason == .appTeamIdentifierMissing)

        let helperSide = HelperActivationGate.decide(
            input(helper: developerIDFacts(team: nil), settings: activatedSettings()),
            decidedAt: Self.fixedDate)
        #expect(refusal(of: helperSide)?.reason == .helperTeamIdentifierMissing)
    }

    @Test
    func defaultSettingsRefuse() {
        // An incompletely wired caller (omitted settings) refuses: both
        // switches default OFF — fail-closed by omission, never by guess.
        let decision = HelperActivationGate.decide(
            HelperActivationGateInput(
                appSignatureFacts: developerIDFacts(),
                helperSignatureFacts: developerIDFacts()),
            decidedAt: Self.fixedDate)
        #expect(refusal(of: decision)?.reason == .helperConsentOff)
    }

    @Test
    func freshSettingsAreOffEverywhere() {
        let settings = HelperActivationSettings()
        #expect(settings.helperConsented == false)
        #expect(settings.ownerActivated == false)
    }

    @Test
    func bothSwitchesRequired() {
        // The two-switch mirror: exactly one ON is still OFF for activation.
        let onlyConsented = HelperActivationSettings(helperConsented: true, ownerActivated: false)
        let decision1 = HelperActivationGate.decide(
            input(settings: onlyConsented), decidedAt: Self.fixedDate)
        #expect(refusal(of: decision1)?.reason == .ownerActivationOff)

        let onlyActivated = HelperActivationSettings(helperConsented: false, ownerActivated: true)
        let decision2 = HelperActivationGate.decide(
            input(settings: onlyActivated), decidedAt: Self.fixedDate)
        #expect(refusal(of: decision2)?.reason == .helperConsentOff)
    }

    // MARK: - Settings persistence (AutoApplySettingsStore conventions)

    @Test
    func settingsDecodeToleranceKeepsFailClosedDefaults() throws {
        // "{}" (older/shorter payload) decodes to BOTH OFF.
        let empty = try JSONDecoder().decode(
            HelperActivationSettings.self, from: Data("{}".utf8))
        #expect(empty.helperConsented == false)
        #expect(empty.ownerActivated == false)

        // A partial file decodes the present key honestly and keeps the
        // missing one OFF — a partial file can never read "activated".
        let partial = try JSONDecoder().decode(
            HelperActivationSettings.self,
            from: Data(#"{"helperConsented": true}"#.utf8))
        #expect(partial.helperConsented == true)
        #expect(partial.ownerActivated == false)
    }

    @Test
    func settingsStoreRoundTripsInTempRoot() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("helper-gate-\(UUID().uuidString)", isDirectory: true)
        let store = HelperActivationSettingsStore(directory: dir)
        // Missing file → defaults (honest absence, nothing created).
        let loaded = try await store.load()
        #expect(loaded == HelperActivationSettings())
        #expect(FileManager.default.fileExists(atPath: dir.path) == false)

        // Save → load back.
        try await store.save(activatedSettings())
        let afterSave = try await store.load()
        #expect(afterSave == activatedSettings())
        #expect(FileManager.default.fileExists(atPath: dir.path))

        // Overwrite with defaults again — the atomic swap replaces cleanly.
        try await store.save(HelperActivationSettings())
        let afterReset = try await store.load()
        #expect(afterReset == HelperActivationSettings())
    }

    @Test
    func settingsStoreUnparseableFileDecodesToDefaults() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("helper-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = HelperActivationSettingsStore(directory: dir)
        try Data("not json at all".utf8).write(to: store.directory.appendingPathComponent("helper_activation_settings.json"))
        let loaded = try await store.load()
        // Unparseable → defaults: a garbage file can never activate.
        #expect(loaded == HelperActivationSettings())
    }

    // MARK: - evaluate(): the seam-driven connector

    @Test
    func evaluateProbesAppFirstThenHelperAndDecidesPurely() async throws {
        let paths = HelperProbeStubBox<[String]>([])
        let probe = HelperSignatureProbe { path in
            paths.with { $0.append(path) }
            // Dev-class app signature, Developer-ID helper: refusal on the
            // app side proves evaluate() wired the RIGHT facts to the RIGHT
            // slot (a swap would refuse the helper instead).
            return path.contains("Helper") ? HelperSignatureFacts(
                certificateKind: .developerID, teamIdentifier: "TEAM1234AB")
                : devClassFacts()
        }
        let decision = await HelperActivationGate.evaluate(
            appPath: "/Applications/AppUpdater.app",
            helperPath: "/Applications/AppUpdater.app/Contents/MacOS/AppUpdaterHelper",
            settings: activatedSettings(),
            decidedAt: Self.fixedDate,
            using: probe)
        #expect(refusal(of: decision)?.reason == .appSignatureNotDeveloperID)
        // Exactly TWO probe invocations — app first, helper second.
        #expect(paths.with { $0.count } == 2)
        #expect(paths.with { $0.first == "/Applications/AppUpdater.app" })
        #expect(paths.with { $0.last == "/Applications/AppUpdater.app/Contents/MacOS/AppUpdaterHelper" })
    }

    @Test
    func evaluateMatchesPureDecideOnSameFacts() async {
        let probe = HelperSignatureProbe { _ in devClassFacts() }
        let decision = await HelperActivationGate.evaluate(
            appPath: "/Applications/AppUpdater.app",
            helperPath: "/Applications/AppUpdater.app/Contents/MacOS/AppUpdaterHelper",
            settings: activatedSettings(),
            decidedAt: Self.fixedDate,
            using: probe)
        let pure = HelperActivationGate.decide(
            input(app: devClassFacts(), helper: devClassFacts(), settings: activatedSettings()),
            decidedAt: Self.fixedDate)
        #expect(decision == pure)
    }

    // MARK: - Receipts (verbatim + Codable)

    @Test
    func refusedReceiptCarriesVerbatimFactsAndRoundTrips() throws {
        let settings = HelperActivationSettings(helperConsented: true, ownerActivated: false)
        let decision = HelperActivationGate.decide(
            input(app: devClassFacts(), settings: settings),
            decidedAt: Self.fixedDate)
        guard case .refused(let receipt) = decision else {
            Issue.record("expected refused, got \(decision)")
            return
        }
        #expect(receipt.verdict == "refused")
        #expect(receipt.refusal?.reason == .ownerActivationOff)
        // Verbatim facts snapshot.
        #expect(receipt.appSignatureFacts == devClassFacts())
        #expect(receipt.settings == settings)
        // The decision round-trips through Codable with the receipt intact.
        let decoded = try JSONDecoder().decode(
            HelperActivationDecision.self,
            from: try JSONEncoder().encode(decision))
        #expect(decoded == decision)
    }

    @Test
    func allowedDecisionRoundTripsThroughCodable() throws {
        let decision = HelperActivationGate.decide(
            input(settings: activatedSettings()),
            decidedAt: Self.fixedDate)
        let decoded = try JSONDecoder().decode(
            HelperActivationDecision.self,
            from: try JSONEncoder().encode(decision))
        #expect(decoded == decision)
    }

    // MARK: - Vocabulary stability

    @Test
    func refusalVocabularyIsCompleteAndStable() {
        // The six matrix refusals, all wire-stable raw values.
        #expect(Set(HelperActivationRefusalReason.allCases.map(\.rawValue)) == Set([
            "helperConsentOff",
            "ownerActivationOff",
            "appSignatureNotDeveloperID",
            "appTeamIdentifierMissing",
            "helperSignatureNotDeveloperID",
            "helperTeamIdentifierMissing",
        ]))
    }
}
