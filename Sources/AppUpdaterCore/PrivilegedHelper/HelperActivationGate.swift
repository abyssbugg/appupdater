// HelperActivationGate.swift — THE fail-closed activation gate for the
// privileged helper. PrivilegedHelper lane · exclusive file of this lane.
//
// ============================================================================
// HONESTY BOUNDARY — BUILT-DORMANT (docs/threat-model/PRIVILEGED-HELPER-REVIEW.md
// §6, SIGNED BY THE OWNER 2026-10-29): "PROCEED — build dormant."
// ============================================================================
// The helper module is built + tested but PERMANENTLY INERT unless THIS gate
// says `.allowed` — and activation is ADDITIONALLY frozen pending real Apple
// Developer ID enrollment (§6 box + §4 residual risk 2). Until both, the
// shipped privileged path remains the staged owner-command flow (staged-PKG
// v1, 94bfd25). The gate refuses BEFORE anything else is even considered.
//
// ============================================================================
// THE ACTIVATION MATRIX (§6 box, owner-signed; implemented order, first match
// wins — consent boundaries first, then signatures, helper last)
// ============================================================================
//   #  refusal                        condition
//   1  helperConsentOff               the persisted consent switch (master
//                                     "the helper surface may exist at all")
//                                     is OFF (default; two-switch mirror of
//                                     AutoApplySettings)
//   2  ownerActivationOff             the persisted owner-activation switch
//                                     (the explicit, deliberate activation
//                                     gesture §6 requires) is OFF (default)
//   3  appSignatureNotDeveloperID     the MAIN app's code signature is not
//                                     Developer-ID class (observed kind is
//                                     carried verbatim in the receipt — the
//                                     dev machine's "Spike0 Signing" identity
//                                     is development-class and MUST refuse)
//   4  appTeamIdentifierMissing       Developer-ID kind observed but no team
//                                     identifier came back from the probe
//                                     (fail-closed: allow requires BOTH)
//   5  helperSignatureNotDeveloperID  the HELPER binary itself is not
//                                     Developer-ID signed
//   6  helperTeamIdentifierMissing    helper Developer-ID kind but no team id
//   7  — none —                       ALL hold → `.allowed` with receipt
//
// FAIL-CLOSED EVERYWHERE: an unreadable/failed signature probe arrives as
// `.absent`/`.unrecognized` facts (never an exception path to allow), both
// consent switches default OFF, a settings file that fails to parse decodes
// to OFF, and an incompletely-wired caller (default input) refuses.
//
// ============================================================================
// PURE + SEAM-INJECTED (mirrors AutoApplyGate / SecInspector discipline)
// ============================================================================
// ``HelperActivationGate/decide(_:)`` is a total, side-effect-free function
// from Codable input to a Codable decision — no network, no processes, no
// file I/O, no clocks (the caller supplies `decidedAt`). The signature facts
// come from the caller-provided ``HelperSignatureProbe`` seam (evaluate()).
// DELIBERATE DORMANCY HARDENING: this module ships NO live probe and NO live
// registrar — there is no production closure anywhere in PrivilegedHelper/
// that spawns a process or touches ServiceManagement; the codesign-backed
// probe and the SMAppService registrar are post-enrollment wiring (they are
// trivially derivable from SecProcessRunner when wiring lands). So NO code
// in this module can probe, register, or launch anything, at test time or by
// default — stronger than the §6 contract, asserted by tests.
//
// Settings persistence mirrors AutoApplySettingsStore verbatim (same file
// conventions, same atomic-write contract, same unparseable→defaults rule).
//
// NOT wired into the scanner/UI/CLI — the coordinator owns that glue; there
// is no glue to wire until this gate can honestly allow (enrollment + owner
// activation).

import Foundation
import os

// MARK: - Signature facts (what the injected probe returns)

/// The certificate class of an observed code signature, as the probe seam
/// classifies it from codesign's Authority line. The gate requires
/// `.developerID`; every other kind refuses (the dev machine's "Spike0
/// Signing" identity classifies as `.development` → refuse, by design).
public enum HelperCertificateKind: String, Codable, CaseIterable, Sendable, Hashable {
    /// "Authority=Developer ID Application: …" — the ONLY activatable class.
    case developerID
    /// Apple Development-class identity (dev machine, e.g. "Spike0 Signing").
    case development
    /// Apple Distribution-class identity (still not Developer ID).
    case distribution
    /// Ad-hoc / linker-signed — no identity at all.
    case adHoc
    /// Nothing signed at all.
    case absent
    /// Signed with something the probe could not classify — fail-closed.
    case unrecognized
}

/// The verdict of ONE signature probe: what class, whose team, and the
/// bounded verbatim evidence. A failed probe is NOT an error — it is facts
/// with an honest kind + note (fail-closed).
public struct HelperSignatureFacts: Codable, Hashable, Sendable {
    /// The certificate class the probe classified (fail-closed default).
    public var certificateKind: HelperCertificateKind
    /// The team identifier as codesign reports it (nil = not set/unknown).
    public var teamIdentifier: String?
    /// The first Authority line, verbatim and bounded (the evidence a receipt
    /// shows the owner — e.g. "Apple Development: Spike0 Signing (XXXXXXXXXX)").
    public var authoritySummary: String?
    /// The probe's honesty note when something could not be read (nil when
    /// the probe succeeded cleanly).
    public var probeNote: String?

    public init(
        certificateKind: HelperCertificateKind,
        teamIdentifier: String? = nil,
        authoritySummary: String? = nil,
        probeNote: String? = nil
    ) {
        self.certificateKind = certificateKind
        self.teamIdentifier = teamIdentifier
        self.authoritySummary = authoritySummary
        self.probeNote = probeNote
    }

    /// Allow requires Developer-ID class AND a team identifier — BOTH, never
    /// either (fail-closed).
    public var isDeveloperID: Bool {
        certificateKind == .developerID && teamIdentifier != nil
    }
}

/// The injected signature-probe seam (SecProcessRunner's shape, one path in,
/// facts out). Production's codesign-backed implementation is post-enrollment
/// wiring — this module ships NONE, so nothing here can spawn a process.
/// A failed probe returns `.absent`/`.unrecognized` facts + note; it never
/// throws and never allows.
public struct HelperSignatureProbe: Sendable {

    public typealias Invoke = @Sendable (_ path: String) async -> HelperSignatureFacts

    private let invoke: Invoke

    public init(invoke: @escaping Invoke) {
        self.invoke = invoke
    }

    public func facts(for path: String) async -> HelperSignatureFacts {
        await invoke(path)
    }
}

// MARK: - Persisted activation settings (two-switch fail-closed mirror)

/// The persisted activation consent state — the two-switch fail-closed mirror
/// of ``AutoApplySettings`` (task §3b: "defaults OFF, same two-switch
/// fail-closed style"). The signed §6 box names ONE owner activation step;
/// mirroring the sibling store's TWO-switch shape and requiring BOTH is the
/// strictly-more-conservative reading (never less fail-closed than the doc).
/// Defaults are FALSE everywhere; absence decodes to OFF; there is no code
/// path in this module that turns consent on by default.
public struct HelperActivationSettings: Codable, Hashable, Sendable {

    /// Master consent: the privileged-helper surface may be provisioned at
    /// all. DEFAULT FALSE (fail-closed; wire-stable key).
    public var helperConsented: Bool

    /// The explicit, deliberate owner activation gesture §6 requires.
    /// DEFAULT FALSE (fail-closed; wire-stable key).
    public var ownerActivated: Bool

    public init(helperConsented: Bool = false, ownerActivated: Bool = false) {
        self.helperConsented = helperConsented
        self.ownerActivated = ownerActivated
    }

    /// Decode tolerance (AutoApplySettings pattern): every key decodes with
    /// `decodeIfPresent` and falls back to the fail-closed OFF default, so an
    /// old/partial/hand-edited file can never decode into "activated".
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        helperConsented = try container.decodeIfPresent(Bool.self, forKey: .helperConsented) ?? false
        ownerActivated = try container.decodeIfPresent(Bool.self, forKey: .ownerActivated) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case helperConsented
        case ownerActivated
    }
}

/// Persistence for ``HelperActivationSettings`` (an AutoApplySettingsStore
/// mirror; see that file's header for the full contract it copies).
/// `Sendable` by construction; every method re-derives from disk.
public struct HelperActivationSettingsStore: Sendable {

    /// Filename inside the shared store directory (sibling of
    /// auto_apply_settings.json etc. per the frozen store layout).
    private static let fileName = "helper_activation_settings.json"

    static let log = Logger(subsystem: "io.appupdater.AppUpdater", category: "helper-activation-settings")

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    /// Store directory — the ONLY test seam (real temp directories in tests).
    public let directory: URL

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// Builds a store rooted at `directory`. Passing nil selects the shared,
    /// user-visible default directory; nothing is touched on disk here.
    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    /// Same default as the sibling stores, so all settings files live together.
    static var defaultDirectory: URL { RuleStore.defaultDirectory }

    /// Loads the persisted activation state. Robust by contract: missing or
    /// unreadable file → defaults; unparseable bytes → defaults + the
    /// documented log line. A partially-activated file can never load as
    /// activated: both keys fall back to OFF.
    public func load() async throws -> HelperActivationSettings {
        guard let data = try? Data(contentsOf: fileURL) else {
            return HelperActivationSettings()
        }
        do {
            return try Self.decoder.decode(HelperActivationSettings.self, from: data)
        } catch {
            Self.log.error(
                "helper_activation_settings.json unparseable (\(String(describing: error), privacy: .public)) — treating as defaults; next save replaces it"
            )
            return HelperActivationSettings()
        }
    }

    /// Persists `settings` atomically as canonical JSON. Throws on failure —
    /// a consent change the owner made MUST surface its failure, never vanish
    /// into memory-only state (AutoApplySettingsStore convention).
    public func save(_ settings: HelperActivationSettings) async throws {
        let data = try Self.encoder.encode(settings)
        try writeBytesAtomically(data, to: fileURL)
    }

    /// Staging + atomic swap (file-local AutoApplySettingsStore mirror).
    private func writeBytesAtomically(_ data: Data, to target: URL) throws {
        let dir = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staging = dir.appendingPathComponent(
            ".\(target.lastPathComponent)-\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: staging) }

        guard FileManager.default.createFile(atPath: staging.path, contents: Data()) else {
            throw HelperActivationSettingsWriteFailure(
                reason: "could not stage helper_activation_settings.json write in \(dir.path)")
        }
        do {
            let handle = try FileHandle(forWritingTo: staging)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
        } catch {
            throw HelperActivationSettingsWriteFailure(
                reason: "staging helper_activation_settings.json write failed: \(String(describing: error))")
        }

        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: target)
        }
    }
}

/// Honest persistence failure (mirrors AutoApplySettingsWriteFailure).
public struct HelperActivationSettingsWriteFailure: LocalizedError, Sendable {
    public let reason: String
    public var errorDescription: String? { "HelperActivationSettingsStore write failed: \(reason)" }
    public init(reason: String) { self.reason = reason }
}

// MARK: - Gate input (pure data)

/// Everything the gate reads. Pure data — the caller probes signatures via
/// the seam BEFORE building this value; the pure gate never probes anything
/// itself. Defaults are fail-closed (an incompletely wired caller refuses).
public struct HelperActivationGateInput: Hashable, Sendable {
    /// The MAIN app's signature facts (probe output).
    public var appSignatureFacts: HelperSignatureFacts
    /// The HELPER binary's signature facts (probe output).
    public var helperSignatureFacts: HelperSignatureFacts
    /// The CURRENT persisted activation state (defaults = both OFF).
    public var settings: HelperActivationSettings

    public init(
        appSignatureFacts: HelperSignatureFacts,
        helperSignatureFacts: HelperSignatureFacts,
        settings: HelperActivationSettings = HelperActivationSettings()
    ) {
        self.appSignatureFacts = appSignatureFacts
        self.helperSignatureFacts = helperSignatureFacts
        self.settings = settings
    }
}

// MARK: - Refusals (stable machine-readable vocabulary)

/// The stable, wire-stable refusal reasons (matrix order lives on the gate
/// doc header; raw values are persisted in receipts — never renamed).
public enum HelperActivationRefusalReason: String, Codable, CaseIterable, Sendable, Hashable {
    /// Persisted consent switch OFF (default; matrix #1).
    case helperConsentOff
    /// Persisted owner-activation switch OFF (default; matrix #2).
    case ownerActivationOff
    /// The main app's signature is not Developer-ID class (matrix #3).
    case appSignatureNotDeveloperID
    /// Developer-ID kind observed for the app but no team identifier (matrix #4).
    case appTeamIdentifierMissing
    /// The helper binary's signature is not Developer-ID class (matrix #5).
    case helperSignatureNotDeveloperID
    /// Developer-ID kind observed for the helper but no team identifier (matrix #6).
    case helperTeamIdentifierMissing
}

/// One refusal: the stable reason plus the verbatim observed evidence.
public struct HelperActivationRefusal: Codable, Hashable, Sendable {
    public var reason: HelperActivationRefusalReason
    /// Human-consumable, VERBATIM context: the observed certificate kind +
    /// team identifier + the probe's own note when present. Receipts show
    /// this to the owner — it carries what was seen, never a summary.
    public var detail: String?

    public init(reason: HelperActivationRefusalReason, detail: String? = nil) {
        self.reason = reason
        self.detail = detail
    }
}

// MARK: - Receipts (verbatim, Codable)

/// The full verbatim record of ONE activation-gate evaluation — produced for
/// every allow AND every refusal (task contract: "Every refusal and allow
/// produces a verbatim receipt"). Codable + Hashable for the receipt chain.
public struct HelperActivationReceipt: Codable, Hashable, Sendable {

    /// The constant honesty note every receipt carries (BUILT-DORMANT per the
    /// signed §6 box; activation frozen pending Developer ID enrollment).
    public static let dormancyNote =
        "BUILT-DORMANT per docs/threat-model/PRIVILEGED-HELPER-REVIEW.md §6 (signed 2026-10-29); "
            + "activation additionally frozen pending real Developer ID enrollment; the shipped "
            + "privileged path remains the staged owner-command flow."

    /// The gate's verdict for this evaluation ("allowed" | "refused").
    public var verdict: String
    /// The refusal when verdict == "refused" (nil on allow).
    public var refusal: HelperActivationRefusal?
    /// The main app's signature facts, verbatim.
    public var appSignatureFacts: HelperSignatureFacts
    /// The helper binary's signature facts, verbatim.
    public var helperSignatureFacts: HelperSignatureFacts
    /// The persisted switches as the gate read them (verbatim snapshot).
    public var settings: HelperActivationSettings
    /// Caller-supplied timestamp (the gate owns no clock — pure).
    public var decidedAt: Date
    /// The dormancy honesty note (constant; receipts stay self-describing).
    public var dormancyNote: String

    public init(
        verdict: String,
        refusal: HelperActivationRefusal?,
        appSignatureFacts: HelperSignatureFacts,
        helperSignatureFacts: HelperSignatureFacts,
        settings: HelperActivationSettings,
        decidedAt: Date,
        dormancyNote: String = HelperActivationReceipt.dormancyNote
    ) {
        self.verdict = verdict
        self.refusal = refusal
        self.appSignatureFacts = appSignatureFacts
        self.helperSignatureFacts = helperSignatureFacts
        self.settings = settings
        self.decidedAt = decidedAt
        self.dormancyNote = dormancyNote
    }
}

// MARK: - The decision

/// The gate's typed decision: allowed, or refused with the typed reason.
/// Codable by synthesis (the receipt payload is Codable itself); Hashable
/// for tests/sets.
public enum HelperActivationDecision: Codable, Hashable, Sendable {
    /// ALL gates held. The (future, post-enrollment) wiring may provision —
    /// and even then only via the separately-gated registrar seam; the gate
    /// itself registers nothing.
    case allowed(HelperActivationReceipt)
    /// Excluded, with the typed refusal + full verbatim receipt.
    case refused(HelperActivationReceipt)
}

// MARK: - The gate

public enum HelperActivationGate {

    /// Evaluates the activation matrix (first match wins; see the file
    /// header). Pure: total function from hermetic input to a Codable
    /// decision, no side effects, no clock (timestamp supplied by caller).
    /// Every outcome — allow AND refusal — carries a full verbatim receipt.
    public static func decide(_ input: HelperActivationGateInput, decidedAt: Date) -> HelperActivationDecision {

        func receipt(_ refusal: HelperActivationRefusal?) -> HelperActivationReceipt {
            HelperActivationReceipt(
                verdict: refusal == nil ? "allowed" : "refused",
                refusal: refusal,
                appSignatureFacts: input.appSignatureFacts,
                helperSignatureFacts: input.helperSignatureFacts,
                settings: input.settings,
                decidedAt: decidedAt)
        }

        // 1–2: CONSENT BOUNDARIES FIRST — a permanent "no" regardless of
        // signatures. Both switches must be ON (two-switch mirror).
        if !input.settings.helperConsented {
            return .refused(receipt(HelperActivationRefusal(
                reason: .helperConsentOff,
                detail: "helper consent switch is OFF (fail-closed default)")))
        }
        if !input.settings.ownerActivated {
            return .refused(receipt(HelperActivationRefusal(
                reason: .ownerActivationOff,
                detail: "owner activation switch is OFF (fail-closed default)")))
        }

        // 3–4: the MAIN app must be Developer-ID signed, team id included.
        if let refusal = appRefusal(input.appSignatureFacts) {
            return .refused(receipt(refusal))
        }

        // 5–6: the HELPER binary itself must be Developer-ID signed too.
        if let refusal = helperRefusal(input.helperSignatureFacts) {
            return .refused(receipt(refusal))
        }

        // 7: all three gates held — allow, with the full verbatim receipt.
        return .allowed(receipt(nil))
    }

    /// Matrix #3–#4 for one party's facts (shared shape; the detail lines
    /// carry the verbatim observed evidence — kind, team, probe note).
    private static func refusal(
        _ facts: HelperSignatureFacts,
        notDeveloperID reason: HelperActivationRefusalReason,
        teamMissing reason2: HelperActivationRefusalReason
    ) -> HelperActivationRefusal? {
        if facts.certificateKind != .developerID {
            return HelperActivationRefusal(
                reason: reason,
                detail: detailLine(facts))
        }
        if facts.teamIdentifier == nil {
            return HelperActivationRefusal(
                reason: reason2,
                detail: detailLine(facts))
        }
        return nil
    }

    private static func appRefusal(_ facts: HelperSignatureFacts) -> HelperActivationRefusal? {
        refusal(
            facts,
            notDeveloperID: .appSignatureNotDeveloperID,
            teamMissing: .appTeamIdentifierMissing)
    }

    private static func helperRefusal(_ facts: HelperSignatureFacts) -> HelperActivationRefusal? {
        refusal(
            facts,
            notDeveloperID: .helperSignatureNotDeveloperID,
            teamMissing: .helperTeamIdentifierMissing)
    }

    /// The bounded verbatim evidence line a refusal detail carries.
    private static func detailLine(_ facts: HelperSignatureFacts) -> String {
        var parts: [String] = []
        parts.append("observed certificate kind: \(facts.certificateKind.rawValue)")
        if let team = facts.teamIdentifier {
            parts.append("teamIdentifier: \(team)")
        } else {
            parts.append("teamIdentifier: not set")
        }
        if let authority = facts.authoritySummary, !authority.isEmpty {
            parts.append("authority: \(authority)")
        }
        if let note = facts.probeNote, !note.isEmpty {
            parts.append("probe note: \(note)")
        }
        return parts.joined(separator: "; ")
    }

    // MARK: Seam-driven evaluation (the caller's convenience connector)

    /// Probes BOTH parties via the injected seam (main app first, helper
    /// second — the matrix order), then runs the pure `decide`. The probe is
    /// a REQUIRED parameter: this module ships no live probe, so no code path
    /// here can spawn a process (see the file header's dormancy hardening).
    public static func evaluate(
        appPath: String,
        helperPath: String,
        settings: HelperActivationSettings,
        decidedAt: Date,
        using probe: HelperSignatureProbe
    ) async -> HelperActivationDecision {
        let appFacts = await probe.facts(for: appPath)
        let helperFacts = await probe.facts(for: helperPath)
        return decide(
            HelperActivationGateInput(
                appSignatureFacts: appFacts,
                helperSignatureFacts: helperFacts,
                settings: settings),
            decidedAt: decidedAt)
    }
}
