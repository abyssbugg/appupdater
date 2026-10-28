// SecReport.swift — the per-app security panel's report type (GAP #19).
//
// Contract (docs/reverse/GAP-ANALYSIS.md #19 + UPDATEST-FINDINGS.md §3.14):
//   Updatest's SecurityService/SecurityInfo reads other apps' code signatures and
//   entitlements (notarization, Gatekeeper, hardened runtime, sandbox) via
//   /usr/bin/codesign and Security.framework. This type is OUR read-only,
//   user-space, network-free equivalent: one SecReport per inspected app bundle.
//
// Honesty discipline (the repo's standing rule — unknown is a verdict, never a
// guess), encoded structurally:
//   • Every probe that could not produce a verdict lands as an explicit note
//     string carrying its evidence (exit code + verbatim first diagnostic line).
//     A failed/unreadable probe is NEVER a silent omission and NEVER a guessed
//     default. There is no path that produces a silent zero/false.
//   • Optional fields are nil when the underlying fact is genuinely absent
//     (e.g. TeamIdentifier on an ad-hoc signature), NOT when a probe broke —
//     a broken probe leaves the field nil AND adds a note. Read the notes.
//   • Boolean verdicts are `Bool?`: nil = unjudged (probe failed/unparseable).
//     true/false only when the probe gave a definitive answer.
//   • Gatekeeper's assessment is a three-way enum: accepted / rejected /
//     unknown. `unknown` covers probe failures AND assessments that are
//     neither word (e.g. spctl exiting 1 with "a required plist file or
//     resource is malformed" — an error, not a rejection).
//   • Notarization is never inferred by us: the report carries codesign's own
//     `Notarization Ticket=` label verbatim (e.g. "stapled") and Gatekeeper's
//     `source=`/`origin=` labels verbatim (e.g. "Notarized Developer ID").
//     Whether to call an app "notarized" is the consumer's call on verbatim
//     evidence, not our invention.
//
// Values taken verbatim from tool output (timestamp, ticket label, source
// labels, CDHash, TeamIdentifier) are stored as captured — never re-formatted,
// never localized, so a report is diffable and a lie in the tool output would
// stay visible as the lie it is.

import Foundation

/// Security-panel verdict for one app bundle: what codesign/spctl say about its
/// code signature, Gatekeeper assessment, hardened runtime, sandbox, and
/// entitlements — plus an honest notes trail for every probe outcome.
///
/// Codable + Hashable (both auto-synthesized): reports persist into panel state
/// and compare field-for-field in tests. Sendable: plain value type.
public struct SecReport: Codable, Hashable, Sendable {

    /// Gatekeeper's verdict word. `.unknown` is a first-class outcome: probe
    /// failure, spawn failure, or an exit/word pair that is neither accepted
    /// nor rejected. Never collapses into a boolean.
    public enum GatekeeperAssessment: String, Codable, Hashable, Sendable {
        case accepted
        case rejected
        case unknown
    }

    /// The bundle path as inspected (verbatim spelling from the caller).
    public let appPath: String

    // MARK: - Signature (codesign -dv -vvvv display probe)

    /// Does the bundle carry a code signature at all? true = the display probe
    /// succeeded; false = codesign itself reported "not signed at all"; nil =
    /// the probe failed for another reason (note carries why). This separates
    /// "unsigned" from "signed but tampered" — codesignValid alone cannot.
    public var signaturePresent: Bool?

    // MARK: - Strict verification (codesign --verify --deep --strict)

    /// true = strict deep verification passed (exit 0); false = it failed
    /// (nonzero exit — the note carries the reason); nil = the probe could not
    /// run or its outcome was unreadable.
    public var codesignValid: Bool?

    // MARK: - Gatekeeper (spctl -a -vv)

    public var gatekeeperAssessment: GatekeeperAssessment
    /// spctl's `source=` label, verbatim (e.g. "Apple System",
    /// "Notarized Developer ID"); nil when spctl printed none.
    public var gatekeeperSource: String?
    /// spctl's `origin=` label, verbatim; nil when spctl printed none.
    public var gatekeeperOrigin: String?

    // MARK: - Signature identity (codesign -dv -vvvv)

    /// Signing-authority chain, first line first (the signing cert, e.g.
    /// "Developer ID Application: Name (TEAMID)"); empty for ad-hoc/linker-
    /// signed/unsigned bundles — an honest empty, not a guess.
    public var signatureAuthorities: [String]
    /// `TeamIdentifier=` value; nil when codesign reports "not set" or the
    /// line is absent (ad-hoc has none — absence is a fact, not an error).
    public var teamIdentifier: String?
    /// The signature's own `Identifier=` (what codesign believes the code is,
    /// which may differ from the Info.plist bundle id).
    public var signedIdentifier: String?
    /// `Executable=` path inside the signature display.
    public var executablePath: String?
    /// `CDHash=` hex, verbatim.
    public var cdHash: String?
    /// codesign's `Timestamp=` (modern spelling) or `Signed Time=` (older),
    /// verbatim; nil when the signature carries neither.
    public var timestamp: String?
    /// codesign's `Notarization Ticket=` label, verbatim (e.g. "stapled").
    /// nil when absent. WE never conclude "notarized" — this is the label only.
    public var notarizationTicket: String?

    // MARK: - Flags

    /// Hardened runtime (CodeDirectory `runtime` flag). true/false only when a
    /// CodeDirectory flags field was actually parsed; nil otherwise.
    public var hardenedRuntime: Bool?
    /// CodeDirectory `linker-signed` flag (signed by the linker at build time).
    public var linkerSigned: Bool?
    /// CodeDirectory `adhoc` flag (or a literal `Signature=adhoc` line).
    public var isAdHoc: Bool?
    /// `Runtime Version=`, verbatim; present only for hardened-runtime code.
    public var runtimeVersion: String?

    // MARK: - Entitlements (codesign -d --entitlements :-)

    /// Sorted entitlement keys; empty when the bundle carries no entitlements
    /// (also implied by `entitlementsPresent == false`) or when the dict could
    /// not be read (nil `entitlementsPresent` + note disambiguates which).
    public var entitlementKeys: [String]
    /// true = entitlement dict parsed; false = codesign reports the bundle has
    /// no entitlements; nil = the dict could not be read (note carries why).
    public var entitlementsPresent: Bool?
    /// Does the bundle claim `com.apple.security.app-sandbox`? nil when the
    /// entitlement dict could not be read (never a guessed false).
    public var sandboxed: Bool?
    /// Count of the `keychain-access-groups` ARRAY when that entitlement is
    /// present; nil when the key is absent or the dict was unreadable. A nil
    /// here is "no such entitlement (or unreadable)" — not a claimed zero.
    public var keychainAccessGroupsCount: Int?

    // MARK: - Honesty trail

    /// One entry per probe outcome that a consumer must see to judge the
    /// report: spawn failures, nonzero exits with their verbatim diagnostics,
    /// unparseable outputs, multi-signature displays. Ordered by probe order.
    public var notes: [String]

    public init(appPath: String) {
        self.appPath = appPath
        self.signaturePresent = nil
        self.codesignValid = nil
        self.gatekeeperAssessment = .unknown
        self.gatekeeperSource = nil
        self.gatekeeperOrigin = nil
        self.signatureAuthorities = []
        self.teamIdentifier = nil
        self.signedIdentifier = nil
        self.executablePath = nil
        self.cdHash = nil
        self.timestamp = nil
        self.notarizationTicket = nil
        self.hardenedRuntime = nil
        self.linkerSigned = nil
        self.isAdHoc = nil
        self.runtimeVersion = nil
        self.entitlementKeys = []
        self.entitlementsPresent = nil
        self.sandboxed = nil
        self.keychainAccessGroupsCount = nil
        self.notes = []
    }
}
