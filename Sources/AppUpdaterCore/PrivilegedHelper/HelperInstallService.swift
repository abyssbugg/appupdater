// HelperInstallService.swift — the helper's launchd plist template + the
// SMAppService registration plan, produced PURELY AS DATA behind injected
// seams. PrivilegedHelper lane · exclusive file of this lane.
//
// ============================================================================
// HONESTY BOUNDARY — BUILT-DORMANT (docs/threat-model/PRIVILEGED-HELPER-REVIEW.md
// §6, SIGNED BY THE OWNER 2026-10-29): "PROCEED — build dormant."
// ============================================================================
// Built + tested, PERMANENTLY INERT by default: nothing here registers,
// unregisters, or launches anything. There is deliberately NO `live()`
// registrar in this module — ServiceManagement is not even imported, so no
// code path in AppUpdaterCore can reach SMAppService.register/unregister
// (stronger than the §6 "permanently inert" requirement). The real registrar
// closure is provided by post-enrollment wiring, ONLY behind an allowed
// HelperActivationGate decision (the gate module owns that decision).
// Until then, the SHIPPED privileged path remains the staged owner-command
// flow (staged-PKG v1, 94bfd25) — activation is additionally frozen pending
// real Developer ID enrollment (§6 box).
//
// SHAPE (per the review doc):
//   §1    SMAppService daemon, launchd-managed, "no root login shape".
//   §3.4  the launchd entry pins the code requirement — see the honest note
//         below; the pinned requirement string travels as PLAN DATA here.
//   §2/§3.4  helper downgrade/revive-kill: the plan records the version
//         handshake expectation ("version handshake beats file path").
//   §3.1  the pinned caller requirement string (TeamID/designators of the
//         AppUpdater app bundle only) is carried for review.
//
// UNSPECIFIED BY THE DOC — HONEST NOTES (never invented silently):
//   • LAUNCHD HAS NO CODE-REQUIREMENT KEY in this shape. The doc's "launchd
//     entry pins the code requirement" (§3.4, MacUpdater's design) cannot be
//     expressed as a plist key; the plist template below carries ONLY real
//     launchd keys (Label, Program, ProgramArguments, RunAtLoad,
//     AssociatedBundleIdentifiers). The pinned requirement is enforced the
//     two places it CAN be: in-protocol caller verification (§3.1, helper
//     runtime, future) and the version handshake (§3.4). The requirement
//     string is carried here as plan data so the review sees exactly what
//     would be pinned.
//   • The pinned requirement's TEAM ID is unknown (enrollment pending): the
//     template carries a `<TEAMID>` placeholder that is NOT activatable —
//     the activation gate refuses long before any registration could run.
//   • RunAtLoad is written FALSE: a loaded-but-dormant entry that never
//     auto-starts. (The doc does not specify this key; never-auto-start is
//     the strictly-more-dormant reading of §6.)
//   • The plist destination (the app bundle's Contents/Library/LaunchDaemons
//     directory, SMAppService daemon convention) is stated as plan data; the
//     doc does not fix it.
//
// SEAM STYLE (mirrors SecurityPanel/SecInspector.swift): a small closure
// struct, no protocol, tests inject recording stubs; plan-building functions
// NEVER invoke the seam (asserted in tests). The seam's result type is
// Codable so receipts stay verbatim and persistable.

import Foundation

// MARK: - Launchd plist template

/// The launchd plist a registered daemon WOULD carry — produced as data.
/// Every key is a real launchd key; nothing is written that launchd would
/// ignore or that the doc does not sanction (see the header's honest notes).
public struct HelperLaunchdTemplate: Codable, Hashable, Sendable {

    /// The launchd label == the helper's bundle identifier (frozen in
    /// HelperProtocol so template + plan + receipts agree).
    public var label: String
    /// Absolute path of the helper executable the plist would point at.
    public var programPath: String
    /// The app bundle identifiers this daemon is associated with (the
    /// SMAppService daemon convention ties it to AppUpdater itself).
    public var associatedBundleIdentifiers: [String]
    /// Always FALSE in this module (never auto-start; see the header note).
    public var runAtLoad: Bool

    public init(
        label: String = HelperProtocol.helperLabel,
        programPath: String,
        associatedBundleIdentifiers: [String] = ["io.appupdater.AppUpdater"]
    ) {
        self.label = label
        self.programPath = programPath
        self.associatedBundleIdentifiers = associatedBundleIdentifiers
        self.runAtLoad = false
    }

    /// The plist AS DATA — exactly the real launchd keys, nothing else.
    /// Keys: Label, Program, ProgramArguments ([programPath]), RunAtLoad,
    /// AssociatedBundleIdentifiers.
    public func plistDictionary() -> [String: Any] {
        return [
            "Label": label,
            "Program": programPath,
            "ProgramArguments": [programPath],
            "RunAtLoad": runAtLoad,
            "AssociatedBundleIdentifiers": associatedBundleIdentifiers,
        ]
    }

    /// The plist rendered as XML bytes (PropertyListSerialization, `.xml`).
    /// Tests parse this back and assert field-for-field correctness.
    public func plistXMLData() throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: plistDictionary(), format: .xml, options: 0)
    }
}

// MARK: - Registration plan

/// What a registration action WOULD do — pure plan data, never an effect.
public enum HelperRegistrationAction: String, Codable, CaseIterable, Sendable, Hashable {
    /// Register the daemon with SMAppService (ONLY after an allowed
    /// activation decision — post-enrollment wiring, not this module).
    case register
    /// Remove the daemon (the deactivation path; equally gated).
    case unregister
    /// Read-only inventory query (is the daemon registered, and as what).
    case status
}

/// The complete, reviewable plan for one registration action. Everything the
/// (future, gated) registrar closure would need is carried here as data.
public struct HelperRegistrationPlan: Codable, Hashable, Sendable {

    /// Which action the plan describes.
    public var action: HelperRegistrationAction
    /// The launchd label this plan concerns (HelperProtocol.helperLabel).
    public var label: String
    /// Where the plist WOULD be installed: the app bundle's
    /// Contents/Library/LaunchDaemons directory (SMAppService daemon
    /// convention; see the header's honest note — doc does not fix it).
    public var plistDestinationDirectory: String
    /// The plist file name (label + ".plist").
    public var plistFileName: String
    /// The pinned caller requirement string (§3.1: TeamID/designators of the
    /// AppUpdater app bundle ONLY). Carried for review as plan data — see the
    /// header's honest note on why it is not a plist key, and why the team id
    /// is a non-activatable placeholder until real enrollment.
    public var pinnedCallerRequirement: String
    /// §3.4's downgrade defense, stated as plan data: the caller verifies the
    /// helper's version + signature on first contact and refuses an
    /// unversioned or unsigned helper ("version handshake beats file path").
    public var versionHandshakeRequired: Bool
    /// The template the plan was built from (verbatim inside the plan).
    public var launchdTemplate: HelperLaunchdTemplate
    /// Embedded honesty notes (the dormancy + enrollment notes above, so the
    /// plan is self-describing wherever it is serialized).
    public var notes: [String]

    /// The pinned caller requirement TEMPLATE. `<TEAMID>` is a placeholder:
    /// the real team identifier exists only after Developer ID enrollment.
    public static let pinnedCallerRequirementTemplate =
        "identifier \"io.appupdater.AppUpdater\" and anchor apple generic "
            + "and certificate leaf[subject.OU] = \"<TEAMID>\""

    public init(
        action: HelperRegistrationAction,
        label: String = HelperProtocol.helperLabel,
        plistDestinationDirectory: String,
        pinnedCallerRequirement: String = HelperRegistrationPlan.pinnedCallerRequirementTemplate,
        versionHandshakeRequired: Bool = true,
        launchdTemplate: HelperLaunchdTemplate,
        notes: [String] = []
    ) {
        self.action = action
        self.label = label
        self.plistDestinationDirectory = plistDestinationDirectory
        self.plistFileName = label + ".plist"
        self.pinnedCallerRequirement = pinnedCallerRequirement
        self.versionHandshakeRequired = versionHandshakeRequired
        self.launchdTemplate = launchdTemplate
        self.notes = notes
    }

    /// Builds the REGISTER plan for a helper executable inside `appBundlePath`
    /// (the plist destination is derived from the same bundle). Pure: builds
    /// data, touches nothing, invokes no seam.
    public static func register(helperExecutablePath: String, appBundlePath: String) -> HelperRegistrationPlan {
        let template = HelperLaunchdTemplate(programPath: helperExecutablePath)
        return HelperRegistrationPlan(
            action: .register,
            plistDestinationDirectory: appBundlePath + "/Contents/Library/LaunchDaemons",
            launchdTemplate: template,
            notes: [
                "BUILT-DORMANT per docs/threat-model/PRIVILEGED-HELPER-REVIEW.md §6 (signed 2026-10-29): "
                    + "this plan is data; nothing registers or launches the helper.",
                "Activation additionally frozen pending real Developer ID enrollment; "
                    + "the pinned caller requirement carries a <TEAMID> placeholder until then.",
                "Shipped privileged path remains the staged owner-command flow (staged-PKG v1).",
            ])
    }

    /// Builds the UNREGISTER plan (deactivation path; equally gated in
    /// practice — this module only produces the plan data).
    public static func unregister(appBundlePath: String, helperExecutablePath: String) -> HelperRegistrationPlan {
        let template = HelperLaunchdTemplate(programPath: helperExecutablePath)
        return HelperRegistrationPlan(
            action: .unregister,
            plistDestinationDirectory: appBundlePath + "/Contents/Library/LaunchDaemons",
            launchdTemplate: template,
            notes: [
                "BUILT-DORMANT per docs/threat-model/PRIVILEGED-HELPER-REVIEW.md §6 (signed 2026-10-29): "
                    + "this plan is data; nothing unregisters the helper.",
            ])
    }

    /// Builds the read-only STATUS plan (inventory: is the daemon registered).
    public static func status(appBundlePath: String, helperExecutablePath: String) -> HelperRegistrationPlan {
        let template = HelperLaunchdTemplate(programPath: helperExecutablePath)
        return HelperRegistrationPlan(
            action: .status,
            plistDestinationDirectory: appBundlePath + "/Contents/Library/LaunchDaemons",
            launchdTemplate: template,
            notes: [
                "status is a read-only inventory query — still plan data, still dormant.",
            ])
    }

    /// The plist the plan would install (template rendered for the plan's
    /// destination file). Pure data.
    public func plistXMLData() throws -> Data {
        try launchdTemplate.plistXMLData()
    }
}

// MARK: - Registrar seam (dormant by construction)

/// The injected seam a POST-ENROLLMENT wiring would use to perform a
/// registration action. This module provides NO live implementation and does
/// not import ServiceManagement — the only way anything registers is for
/// future wiring to construct this seam itself, behind an ALLOWED activation
/// decision. Tests inject recording stubs and assert the plan builders never
/// invoke it.
public struct HelperRegistrar: Sendable {

    /// Perform (or simulate, in tests) one plan. Throwing = the action could
    /// not be attempted at all; a completed attempt is a result either way.
    public typealias Invoke = @Sendable (_ plan: HelperRegistrationPlan) async throws -> HelperRegistrationResult

    private let invoke: Invoke

    public init(invoke: @escaping Invoke) {
        self.invoke = invoke
    }

    /// Runs the seam's closure against a plan. Note what this is NOT: there
    /// is no default registrar anywhere in this module — `HelperRegistrar` is
    /// inert unless a caller explicitly constructs one.
    public func perform(_ plan: HelperRegistrationPlan) async throws -> HelperRegistrationResult {
        try await invoke(plan)
    }
}

/// The verbatim record of one attempted registration action (Codable so it
/// can join the receipt chain; §3.8 auditability applies to the helper's
/// lifecycle, not just installs).
public struct HelperRegistrationResult: Codable, Hashable, Sendable {
    public var action: HelperRegistrationAction
    public var succeeded: Bool
    /// Verbatim detail (system message, honest failure text).
    public var detail: String
    public var recordedAt: Date

    public init(action: HelperRegistrationAction, succeeded: Bool, detail: String, recordedAt: Date) {
        self.action = action
        self.succeeded = succeeded
        self.detail = detail
        self.recordedAt = recordedAt
    }
}
