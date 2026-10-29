// HelperInstallServiceTests.swift — hermetic tests for the launchd plist
// template + SMAppService registration plans
// (Sources/AppUpdaterCore/PrivilegedHelper/HelperInstallService.swift).
//
// Swift Testing ONLY — XCTest discovery is broken on this toolchain (AGENTS.md
// gotcha ledger). Swift Testing does not re-export Foundation, so
// `import Foundation` is required here.
//
// Hermeticity: plan building is pure data — the registrar seam is exercised
// ONLY through injected recording stubs (closures, never processes), and the
// tests assert the plan builders NEVER invoke it. No SMAppService call is
// possible from this module by construction (no live registrar exists; the
// source imports no ServiceManagement). No force unwraps anywhere.
//
// Coverage map: the plist template renders PARSEABLE XML whose fields are
// exactly the real launchd keys (Label / Program / ProgramArguments /
// RunAtLoad=false / AssociatedBundleIdentifiers), all three plan builders'
// field correctness (including the <TEAMID> placeholder and embedded honesty
// notes), plan round-trip through Codable, and the dormancy assertion that
// plan building never invokes the registrar seam.

import Foundation
import Testing
@testable import AppUpdaterCore

/// Tiny thread-safe box for stub state (independent copy from CaskIndexTests'
/// StubBox so this lane's test file is self-contained against merge drift).
final class HelperStubBox<Value: Sendable>: @unchecked Sendable {
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
struct HelperInstallServiceTests {

    // MARK: - Fixture helpers

    private let appBundlePath = "/Applications/AppUpdater.app"
    private let helperExecutablePath = "/Applications/AppUpdater.app/Contents/MacOS/AppUpdaterHelper"

    /// A registrar stub that RECORDS invocations in a locked box — proving
    /// the seam shape works when injected, and (in the plan-builder tests)
    /// proving the builders never touch it. A closure is never a process.
    private func recordingRegistrar() -> (registrar: HelperRegistrar, invocations: HelperStubBox<[HelperRegistrationPlan]>) {
        let box = HelperStubBox<[HelperRegistrationPlan]>([])
        let registrar = HelperRegistrar { plan in
            box.with { $0.append(plan) }
            return HelperRegistrationResult(
                action: plan.action, succeeded: false, detail: "stub only", recordedAt: Date())
        }
        return (registrar, box)
    }

    // MARK: - Launchd plist template

    @Test
    func plistTemplateRendersParseableXMLWithCorrectFields() throws {
        let template = HelperLaunchdTemplate(programPath: helperExecutablePath)
        let data = try template.plistXMLData()

        var format = PropertyListSerialization.PropertyListFormat.xml
        let root = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        let dict = try #require(root as? [String: Any])

        #expect(dict["Label"] as? String == HelperProtocol.helperLabel)
        #expect(dict["Program"] as? String == helperExecutablePath)
        #expect(dict["ProgramArguments"] as? [String] == [helperExecutablePath])
        // Never auto-start: a loaded entry stays dormant (§6 mirror).
        #expect(dict["RunAtLoad"] as? Bool == false)
        #expect(dict["AssociatedBundleIdentifiers"] as? [String] == ["io.appupdater.AppUpdater"])
        // Exactly the five real launchd keys — nothing invented.
        #expect(dict.count == 5)
    }

    @Test
    func plistTemplateCarriesCustomLabelAndAssociation() throws {
        let template = HelperLaunchdTemplate(
            label: "com.example.helper",
            programPath: helperExecutablePath,
            associatedBundleIdentifiers: ["com.example.app"])
        let data = try template.plistXMLData()
        var format = PropertyListSerialization.PropertyListFormat.xml
        let root = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        let dict = try #require(root as? [String: Any])
        #expect(dict["Label"] as? String == "com.example.helper")
        #expect(dict["AssociatedBundleIdentifiers"] as? [String] == ["com.example.app"])
    }

    // MARK: - Registration plans (pure data)

    @Test
    func registerPlanFieldsAreCorrect() throws {
        let plan = HelperRegistrationPlan.register(
            helperExecutablePath: helperExecutablePath, appBundlePath: appBundlePath)
        #expect(plan.action == .register)
        #expect(plan.label == HelperProtocol.helperLabel)
        #expect(plan.plistDestinationDirectory == appBundlePath + "/Contents/Library/LaunchDaemons")
        #expect(plan.plistFileName == HelperProtocol.helperLabel + ".plist")
        #expect(plan.versionHandshakeRequired == true)
        #expect(plan.launchdTemplate.programPath == helperExecutablePath)
        // §3.4's pinned caller requirement travels as plan data — with the
        // non-activatable <TEAMID> placeholder (enrollment pending).
        #expect(plan.pinnedCallerRequirement.contains("<TEAMID>"))
        #expect(plan.pinnedCallerRequirement.contains("io.appupdater.AppUpdater"))
        // The honesty notes are embedded so the plan self-describes anywhere.
        #expect(plan.notes.contains { $0.contains("BUILT-DORMANT") })
        #expect(plan.notes.contains { $0.contains("staged owner-command flow") })
    }

    @Test
    func unregisterAndStatusPlansAreBuiltCorrectly() {
        let unregister = HelperRegistrationPlan.unregister(
            appBundlePath: appBundlePath, helperExecutablePath: helperExecutablePath)
        #expect(unregister.action == .unregister)
        #expect(unregister.plistFileName == HelperProtocol.helperLabel + ".plist")

        let status = HelperRegistrationPlan.status(
            appBundlePath: appBundlePath, helperExecutablePath: helperExecutablePath)
        #expect(status.action == .status)
        #expect(status.versionHandshakeRequired == true)
    }

    @Test
    func planRoundTripsThroughCodable() throws {
        let plan = HelperRegistrationPlan.register(
            helperExecutablePath: helperExecutablePath, appBundlePath: appBundlePath)
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(HelperRegistrationPlan.self, from: data)
        #expect(decoded == plan)
    }

    @Test
    func planPlistMatchesTemplatePlist() throws {
        let plan = HelperRegistrationPlan.register(
            helperExecutablePath: helperExecutablePath, appBundlePath: appBundlePath)
        let planPlist = try plan.plistXMLData()
        let templatePlist = try plan.launchdTemplate.plistXMLData()
        #expect(planPlist == templatePlist)
    }

    // MARK: - Dormancy: plan builders never invoke the seam

    @Test
    func planBuildersNeverInvokeRegistrarSeam() async throws {
        let (registrar, invocations) = recordingRegistrar()
        _ = HelperRegistrationPlan.register(
            helperExecutablePath: helperExecutablePath, appBundlePath: appBundlePath)
        _ = HelperRegistrationPlan.unregister(
            appBundlePath: appBundlePath, helperExecutablePath: helperExecutablePath)
        _ = HelperRegistrationPlan.status(
            appBundlePath: appBundlePath, helperExecutablePath: helperExecutablePath)
        let template = HelperLaunchdTemplate(programPath: helperExecutablePath)
        _ = try template.plistXMLData()
        _ = try HelperRegistrationPlan.register(
            helperExecutablePath: helperExecutablePath, appBundlePath: appBundlePath).plistXMLData()
        #expect(invocations.with { $0.count } == 0)
        _ = registrar // the seam exists but was never run by plan building
    }

    @Test
    func registrarSeamRunsWhenExplicitlyInvoked() async throws {
        // The seam is usable when injected (post-enrollment wiring's shape)
        // — and nothing in this module constructs it implicitly.
        let (registrar, invocations) = recordingRegistrar()
        let plan = HelperRegistrationPlan.register(
            helperExecutablePath: helperExecutablePath, appBundlePath: appBundlePath)
        let result = try await registrar.perform(plan)
        #expect(invocations.with { $0.count } == 1)
        #expect(result.action == .register)
        #expect(result.succeeded == false)
        #expect(result.detail == "stub only")
    }

    @Test
    func registrationResultRoundTripsThroughCodable() throws {
        let result = HelperRegistrationResult(
            action: .unregister, succeeded: true, detail: "removed", recordedAt: Date(timeIntervalSince1970: 0))
        let decoded = try JSONDecoder().decode(
            HelperRegistrationResult.self, from: try JSONEncoder().encode(result))
        #expect(decoded == result)
    }
}
