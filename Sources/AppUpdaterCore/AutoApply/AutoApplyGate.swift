// AutoApplyGate.swift — the PURE decision core for per-app auto-apply (GAP #22).
// Gap-sprint wave · lane autoapply · exclusive file of this lane.
//
// ============================================================================
// README — CONSENT BOUNDARY (LOCKED DECISION 14, owner amendment 2026-10-28)
// ============================================================================
// The app's DEFAULT remains click-driven: nothing auto-applies unless the
// owner opts in. Opt-in per-app auto-apply is authorized with MacUpdater's
// safety gates, for USER-SPACE updates only (zip/dmg via the existing verified
// install chain): a global master switch (default OFF) AND a per-app opt-in
// (default OFF) must BOTH be on. PKG/privileged paths are NEVER auto-applied
// (the staged owner-command flow is the only pkg path, unchanged). Every
// auto-apply produces full verbatim receipts (AutoApplyOutcome.swift).
//
// ============================================================================
// GATE-OVER-INSTALL SEPARATION (structural, not advisory)
// ============================================================================
// ``AutoApplyGate`` DECIDES; it never installs. The gate is a total,
// side-effect-free function from hermetic input to ``AutoApplyDecision`` —
// no network, no processes, no file I/O, no clocks. The EXISTING
// InstallCoordinator chain runs for `.apply` and ONLY the coordinator wires
// that call (the wiring lands after this lane merges); the gate has no
// reference to any executor and no way to produce an ``InstallOutcome``.
//
// ============================================================================
// THE EXCLUSION MATRIX (implemented order; FIRST match wins)
// ============================================================================
// Precedence rationale: CONSENT boundaries first (their answer is "no"
// regardless of everything else), then the system boundary, then the owner's
// standing per-app directives, then claim validity, then artifact safety, and
// TRANSIENT environment conditions LAST — a permanent refusal must never be
// masked by a retryable skip, so a receipt never advises "retry later" for a
// refusal that retrying cannot fix.
//
//  #  skip reason              condition
//  1  autoApplyDisabled        global master switch OFF (decision 14 default)
//  2  perAppNotOptedIn         per-app opt-in flag OFF (decision 14 default)
//  3  macAppStoreApp           the app is a Mac App Store install (never
//                             bundle-replaced — decision 4's MAS path is
//                             inform/Store, never an auto user-space swap)
//  4  ignoredByRule            the app's RuleDecision says ignoredBundle, or
//                             ignoredVersion for THIS claim (evaluated by the
//                             RuleStore evaluator against the resolved claim)
//  5  noResolvedClaim          check.resolved == nil — nothing to install
//                             (verdict "current"/"failed"/"unknown" all land
//                             here; the strictly-greater version gate lives
//                             in VersionOracle, the gate trusts its verdict)
//  6  verdictNotUpdate         resolved claim EXISTS but verdict != "update"
//                             — consistency guard for a hand-crafted/legacy
//                             check. Unreachable for engine-produced checks
//                             (the verdict is derived from `resolved`), kept
//                             because the gate consumes UpdateCheck as DATA.
//  7  installerBundleArtifact  the download artifact's file name matches a
//                             documented installer-bundle signal (the deep
//                             filter's name list — see the ADAPTATIONS note)
//  8  nonUserSpaceArtifact     pkg (staged-owner-command flow is the ONLY pkg
//                             path), plus tbz/tgz — the brief groups these
//                             archive kinds with the non-user-space refusals
//                             (decision 14 authorizes zip/dmg ONLY)
//  9  artifactKindUnknown      no download URL, or an extension that maps to
//                             no known kind — an unclassifiable artifact is
//                             never auto-applied (OUR addition beyond the
//                             brief's minimum list: honest fail-closed)
// 10  onBattery                policy.skipOnBattery AND the battery seam says
//                             on battery
// 11  offline                  policy.deferWhenOffline AND the online seam
//                             says no network path
// 12  appCurrentlyRunning      the app's bundle identifier is in the
//                             runningApps seam value
//
// ============================================================================
// ADAPTATIONS FROM MACUPDATER (labeled, per the lane brief)
// ============================================================================
// Source: docs/reverse/MACUPDATER-FINDINGS.md §7 "Post-scan auto-update" —
// MacUpdater logs `performing post-scheduled-scan AutoUpdate: N apps … M
// excluded` with these documented exclusion reasons. Where OUR system lacks
// the machinery a reason presumes, the adaptation is stated here — never
// papered over:
//
// - "not eligible" → our claim/artifact gates (#5–#9): our concrete
//   restatement of eligibility (a strictly-newer resolved claim for a
//   zip/dmg artifact that no documented installer signal disqualifies).
// - "paid/major" → HONEST GAP, NOT IMPLEMENTED: v1 has no paid-upgrade or
//   major-version policy for auto-apply. The strictly-greater comparison in
//   VersionOracle still prevents equal/older claims from ever resolving.
// - "MAS-replacement" → #3 macAppStoreApp, but STRONGER: MacUpdater's reason
//   tracks a replacement flow; ours refuses ALL auto application of MAS apps.
// - "deleted-since-scan" → NOT APPLICABLE structurally: the gate consumes a
//   fresh UpdateCheck for a live app row; a deleted app has no row and no
//   check (the engine's inventory is re-scanned each fire).
// - "needs-explanation-read" / "first-time manual confirmation" → HONEST GAP,
//   NOT IMPLEMENTED: v1 has no explanation-confirmation store; consent is
//   expressed by the two switches (#1–#2) instead.
// - "currently running" → #12, adapted: the teardown does not document
//   MacUpdater's matching key, so OUR convention is bundle-identifier match
//   (case-insensitive) against the caller-supplied runningApps seam value.
// - "manually excluded" → #4 ignoredByRule via the frozen RuleDecision
//   (ignoreBundle / ignoreVersion-for-this-claim, evaluated by RuleStore).
//
// The installer-bundle signal (#7) is the deep filter's documented NAME check
// (CandidateFilter.installerBundleNames + the "*.install" glob, ONE source of
// truth — reused, not duplicated), applied here to the download artifact's
// file name. ADAPTATION, labeled: MacUpdater applies the list to unarchived
// .app candidates AFTER download (§5 step 8); pre-download, only the name
// signal is applicable — the disk-based detectors (InstallBuilder markers,
// Electron wrong-arch) need bytes on disk and are NOT claimed to run here
// (CandidateFilter is a standalone module today; wiring it into the install
// chain is coordinator work). Apple InstallAssistant detection beyond the
// documented name list stays an honest gap by design — see
// CandidateFilter.installAssistantUndocumentedNote.
//
// Ordering note for #7 vs #8: the name check runs BEFORE artifact-kind
// classification so it stays reachable for every artifact shape — every
// documented name ends in ".app", ends in ".install", or is bare, so kind
// classification would otherwise shadow the name signal completely.
//
// FAIL-CLOSED SEAM DEFAULTS: the input's battery/online seam states default
// to "assume on battery" / "assume offline" and both consent flags default
// OFF — an incompletely wired caller can never auto-apply by omission.

import Foundation

// MARK: - Skip reasons (stable machine-readable vocabulary)

/// The stable, machine-readable exclusion reasons. Raw values are
/// WIRE-STABLE (never renamed — persisted receipts depend on them). The
/// documented matrix order lives on ``AutoApplyGate``; this enum is the
/// vocabulary only.
public enum AutoApplySkipReason: String, Codable, CaseIterable, Sendable, Hashable {
    /// Global master switch is OFF (decision 14 default).
    case autoApplyDisabled
    /// The app is not opted in for auto-apply (decision 14 default).
    case perAppNotOptedIn
    /// Mac App Store install — never auto-applied.
    case macAppStoreApp
    /// An active rule excludes the app (ignoreBundle) or this exact claim
    /// (ignoreVersion).
    case ignoredByRule
    /// The check resolved no claim — nothing to install.
    case noResolvedClaim
    /// A resolved claim exists but the check's verdict is not "update" —
    /// an inconsistent check is refused, never guessed around.
    case verdictNotUpdate
    /// The artifact is outside the verified user-space chain: pkg (staged
    /// owner-command flow only) and the brief-grouped tbz/tgz archive kinds.
    case nonUserSpaceArtifact
    /// No download URL or an unrecognized extension — an unclassifiable
    /// artifact is never auto-applied.
    case artifactKindUnknown
    /// The download artifact's file name matches a documented
    /// installer-bundle signal (vendor/OS installers are not app updates).
    case installerBundleArtifact
    /// The skipOnBattery policy is active and the machine is on battery.
    case onBattery
    /// The deferWhenOffline policy is active and no network path is reachable.
    case offline
    /// The app is currently running (runningApps seam match); not auto-applied
    /// while running.
    case appCurrentlyRunning
}

// MARK: - Decision types

/// One skip: the stable machine-readable reason plus a human-readable detail
/// line for receipts/logs. Codable with a wire-stable reason rawValue.
public struct AutoApplySkip: Codable, Hashable, Sendable {
    public var reason: AutoApplySkipReason
    /// Human-consumable context (which rule, which extension, which signal).
    /// nil when the reason is self-sufficient.
    public var detail: String?

    public init(reason: AutoApplySkipReason, detail: String? = nil) {
        self.reason = reason
        self.detail = detail
    }
}

/// The gate's typed decision: apply, or skip with a reason. Hashable for
/// tests/sets; Codable for receipts (flat encoding: `action`, plus `reason`
/// and `detail` when skipping). Unknown `action` values on decode are an
/// honest DecodingError — never guessed into a decision.
public enum AutoApplyDecision: Hashable, Sendable {
    /// All gates pass. The COORDINATOR runs the existing InstallCoordinator
    /// chain for this case; the gate itself installs nothing.
    case apply
    /// Excluded, with the stable reason (first match of the documented
    /// matrix order).
    case skip(AutoApplySkip)
}

extension AutoApplyDecision: Codable {
    private enum CodingKeys: String, CodingKey {
        case action
        case reason
        case detail
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .apply:
            try container.encode("apply", forKey: .action)
        case .skip(let skip):
            try container.encode("skip", forKey: .action)
            try container.encode(skip.reason, forKey: .reason)
            try container.encodeIfPresent(skip.detail, forKey: .detail)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .action) {
        case "apply":
            self = .apply
        case "skip":
            let reason = try container.decode(AutoApplySkipReason.self, forKey: .reason)
            let detail = try container.decodeIfPresent(String.self, forKey: .detail)
            self = .skip(AutoApplySkip(reason: reason, detail: detail))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .action, in: container,
                debugDescription: "unknown AutoApplyDecision action '\(other)' — refusing to guess")
        }
    }
}

// MARK: - Gate input

/// Everything the gate reads. Pure data — the caller (coordinator) owns the
/// seams and probes them BEFORE building this value; the gate never probes
/// anything itself.
public struct AutoApplyGateInput: Hashable, Sendable {
    /// The app under consideration (identity + MAS flag). Callers MUST pass
    /// the InstalledApp row the check was produced for (`check.app`) — the
    /// gate reads identity and the MAS flag from this row.
    public var app: InstalledApp
    /// The fresh check (verdict + resolved claim). The strictly-greater
    /// version gate lives in VersionOracle; the gate trusts its verdict.
    public var check: UpdateCheck
    /// The global master switch's CURRENT persisted state (decision 14:
    /// default OFF). Defaults OFF here too — fail-closed.
    public var autoApplyEnabled: Bool
    /// The per-app opt-in flag's CURRENT persisted state (decision 14:
    /// default OFF). Defaults OFF here too — fail-closed.
    public var perAppOptIn: Bool
    /// The active schedule policy (only skipOnBattery/deferWhenOffline are
    /// read by the gate).
    public var policy: SchedulePolicy
    /// CURRENT battery-seam state. Default TRUE ("assume on battery") —
    /// fail-closed: an unwired seam skips under the (default-on) battery
    /// policy, never silently proceeds.
    public var onBattery: Bool
    /// CURRENT online-seam state. Default FALSE ("assume offline") —
    /// fail-closed: an unwired seam defers under the deferWhenOffline policy.
    public var isOnline: Bool
    /// CURRENT running-apps seam value, by bundle identifier (matched
    /// case-insensitively — our documented convention). Empty = nothing
    /// reported running.
    public var runningBundleIdentifiers: Set<String>
    /// The app's precomputed RuleDecision (RuleStore evaluator output for
    /// this app + this claim — see
    /// ``RuleStore/evaluate(bundleIdentifier:claimVersion:)``). Keeping
    /// evaluation in its single existing owner keeps the gate pure. Default:
    /// no rules active (a caller that has not evaluated rules honestly
    /// reports none — the consent gates still hold).
    public var ruleDecision: RuleDecision

    public init(
        app: InstalledApp,
        check: UpdateCheck,
        autoApplyEnabled: Bool = false,
        perAppOptIn: Bool = false,
        policy: SchedulePolicy = SchedulePolicy(),
        onBattery: Bool = true,
        isOnline: Bool = false,
        runningBundleIdentifiers: Set<String> = [],
        ruleDecision: RuleDecision = RuleDecision()
    ) {
        self.app = app
        self.check = check
        self.autoApplyEnabled = autoApplyEnabled
        self.perAppOptIn = perAppOptIn
        self.policy = policy
        self.onBattery = onBattery
        self.isOnline = isOnline
        self.runningBundleIdentifiers = runningBundleIdentifiers
        self.ruleDecision = ruleDecision
    }
}

// MARK: - The gate

/// The total, side-effect-free decision function (see the file header for the
/// consent boundary, the full matrix, and every labeled adaptation).
public enum AutoApplyGate {

    /// Decides whether this app's fresh update claim may be auto-applied.
    /// FIRST matching skip of the documented matrix order wins; no match →
    /// `.apply`. Pure: no I/O, no network, no processes, no clocks.
    public static func decide(_ input: AutoApplyGateInput) -> AutoApplyDecision {
        if let skip = consentSkip(input) { return .skip(skip) }
        if let skip = eligibilitySkip(input) { return .skip(skip) }
        if let skip = artifactSkip(input) { return .skip(skip) }
        if let skip = environmentSkip(input) { return .skip(skip) }
        return .apply
    }

    // MARK: Matrix groups (each small, each documented, in matrix order)

    /// #1–#2: the two consent switches (decision 14). Nothing else matters
    /// while either is off.
    private static func consentSkip(_ input: AutoApplyGateInput) -> AutoApplySkip? {
        if !input.autoApplyEnabled {
            return AutoApplySkip(
                reason: .autoApplyDisabled,
                detail: "global auto-apply master switch is OFF (decision 14 default)")
        }
        if !input.perAppOptIn {
            return AutoApplySkip(
                reason: .perAppNotOptedIn,
                detail: "app '\(input.app.name)' (\(input.app.bundleIdentifier)) is not opted in "
                    + "for auto-apply (per-app opt-in default OFF)")
        }
        return nil
    }

    /// #3–#6: system boundary, standing rules, then claim validity.
    private static func eligibilitySkip(_ input: AutoApplyGateInput) -> AutoApplySkip? {
        if input.app.isMacAppStore {
            return AutoApplySkip(
                reason: .macAppStoreApp,
                detail: "Mac App Store install \(input.app.bundleIdentifier) is never auto-applied")
        }
        // RuleDecision is evaluated by the RuleStore evaluator against the
        // resolved claim's version — the gate consumes the precomputed flags
        // (matrix #4).
        if input.ruleDecision.ignoredBundle {
            return AutoApplySkip(
                reason: .ignoredByRule,
                detail: "ignoreBundle rule is active for '\(input.app.bundleIdentifier)' — the app is "
                    + "excluded from auto-apply")
        }
        if input.ruleDecision.ignoredVersion {
            let claimed = input.check.resolved?.newestShortVersion ?? "(no claim)"
            return AutoApplySkip(
                reason: .ignoredByRule,
                detail: "ignoreVersion rule is active for '\(input.app.bundleIdentifier)' at claimed "
                    + "version '\(claimed)' — this claim is excluded from auto-apply")
        }
        guard let resolved = input.check.resolved else {
            return AutoApplySkip(
                reason: .noResolvedClaim,
                detail: "verdict '\(input.check.verdict)' with no resolved claim — nothing to install")
        }
        if input.check.verdict != "update" {
            return AutoApplySkip(
                reason: .verdictNotUpdate,
                detail: "resolved claim for '\(resolved.newestShortVersion)' exists but verdict is "
                    + "'\(input.check.verdict)', not 'update' — inconsistent check refused")
        }
        return nil
    }

    /// #7–#9: artifact safety (installer-bundle name signal first, then kind
    /// classification — see the header's ordering note).
    private static func artifactSkip(_ input: AutoApplyGateInput) -> AutoApplySkip? {
        guard let url = input.check.resolved?.downloadURL else {
            return AutoApplySkip(
                reason: .artifactKindUnknown,
                detail: "resolved claim carries no download URL — refusing to auto-apply an "
                    + "unclassifiable artifact")
        }
        // The deep filter's documented NAME signal, ONE source of truth
        // (reused, not duplicated). The matcher expects an already-lowercased
        // name (CandidateFilter.installerBundleVerdict's calling convention).
        let fileName = url.lastPathComponent.lowercased()
        let finding = CandidateFilter.installerBundleNameFinding(for: fileName)
        if let matched = finding.matched {
            return AutoApplySkip(
                reason: .installerBundleArtifact,
                detail: "download artifact name '\(url.lastPathComponent)' matches documented "
                    + "installer-bundle signal (\(finding.glob ? "*.install glob" : "exact") '\(matched)') — "
                    + "vendor/OS installers are not app updates and are never auto-applied")
        }
        switch url.pathExtension.lowercased() {
        case "dmg", "zip":
            return nil // the verified user-space chain (decision 14: zip/dmg ONLY)
        case "pkg":
            return AutoApplySkip(
                reason: .nonUserSpaceArtifact,
                detail: "artifact '.pkg': pkg paths are NEVER auto-applied — the staged "
                    + "owner-command flow is the only pkg path (decision 14, unchanged)")
        case "tbz", "tgz":
            return AutoApplySkip(
                reason: .nonUserSpaceArtifact,
                detail: "artifact '.\(url.pathExtension.lowercased())': archive kind outside the "
                    + "verified user-space chain (decision 14 authorizes zip/dmg only)")
        case let other:
            return AutoApplySkip(
                reason: .artifactKindUnknown,
                detail: "artifact extension '.\(other)' is not a recognized kind — refusing to "
                    + "auto-apply an unclassifiable artifact (verified chain installs zip/dmg only)")
        }
    }

    /// #10–#12: transient environment conditions (retryable — deliberately
    /// LAST so a permanent refusal is never masked by one).
    private static func environmentSkip(_ input: AutoApplyGateInput) -> AutoApplySkip? {
        if input.policy.skipOnBattery, input.onBattery {
            return AutoApplySkip(
                reason: .onBattery,
                detail: "skipOnBattery policy is active and the machine is on battery")
        }
        if input.policy.deferWhenOffline, !input.isOnline {
            return AutoApplySkip(
                reason: .offline,
                detail: "deferWhenOffline policy is active and no network path is reachable")
        }
        let bundleID = input.app.bundleIdentifier.lowercased()
        if input.runningBundleIdentifiers.contains(where: { $0.lowercased() == bundleID }) {
            return AutoApplySkip(
                reason: .appCurrentlyRunning,
                detail: "app '\(input.app.name)' is currently running (bundle identifier matches the "
                    + "runningApps seam) — not auto-applied while running")
        }
        return nil
    }
}
