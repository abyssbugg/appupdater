// Installer tier: MAS→Homebrew ADOPTION gate (LOCKED decision 4's force-update
// path for Mac App Store apps — the staged-command variant).
//
// WHAT THIS IS: for a MAS-detected installed app whose identity resolves to a
// whole-index cask, this module decides adopt-eligibility and produces the
// OWNER-RUN command `brew install --cask --adopt <token>` (force variant:
// `brew install --cask --force --adopt <token>`). The command is data on the
// outcome — AppUpdater NEVER executes brew, never installs, never touches the
// app bundle. This mirrors the staged-PKG honesty surface (commit 94bfd25:
// `InstallOutcome.stagedCommand` + a stderr note in the CLI; stdout stays pure
// JSON) while adding nothing to the frozen installer types — the adopt decision
// is its own type here because InstallModels.swift is coordinator-owned.
//
// COMPETITOR EVIDENCE (docs/reverse/UPDATEST-FINDINGS.md §3.3, [confirmed]
// binary strings): `brew install --cask --adopt` adopts an App-Store-installed
// app as a cask; the version-mismatch gate says "Your installed version (…)
// doesn't match the Homebrew cask version (…). Force-adopting will replace the
// app with the cask version."; the paid-MAS warning says adopting replaces the
// App Store version with the Homebrew build and the purchase/license does not
// transfer.
//
// REFUSAL MATRIX (each refusal is a DECISION VALUE with a stable machine code +
// documented reason — the gate is total, it never throws, never guesses):
//   R1 not-mac-app-store  — target is not a MAS install. Adoption is the
//                           MAS→cask path; vendor installs already resolve
//                           through the cask pipeline. Force does NOT override.
//   R2 no-cask            — the whole-index resolver found no artifact-
//                           validating cask. Force does NOT override (force is
//                           a consent flag, never a matcher).
//   R3 ambiguous-match    — the resolver reports more than one plausible cask.
//                           Refuse rather than guess which token to adopt.
//                           Force does NOT override.
//   R4 version-mismatch   — cask version compares non-equal to the installed
//                           short version (BIDIRECTIONAL: cask newer or older —
//                           either replaces the app with the cask build).
//                           Refused WITHOUT an explicit force flag; WITH force
//                           the plan carries a version-mismatch-override
//                           warning receipt (the teardown's force-adopt gate).
//   R5 version-unverifiable — installed or cask version unreadable, so the
//                           version gate cannot be judged. Same force
//                           discipline as R4 (conservative: unverifiable is
//                           the same replacement risk as mismatch).
// WARNING RECEIPTS on every eligible decision:
//   W1 paid-MAS warning (UNCONDITIONAL — payment is not detectable, so the
//      teardown's paid-app warning is attached as a receipt note instead of a
//      detection result, exactly as the mission brief directs).
//   W2 identity note — adoption replaces the App Store receipt/entitlements
//      with the Homebrew (vendor) build; the app's update identity becomes the
//      cask from then on.
//   W3/W4 force-override warning receipts (which gate was overridden and why).
//
// VERSION SEMANTICS: the mismatch gate uses VersionOracle.compare — the
// project's canonical comparator — so "1.0" vs "1.0.0" zero-fills to equal.
// An unparseable version would fall into R5 territory only if EMPTY/absent; a
// present-but-unparseable string still compares (deterministic lexicographic
// fallback) and is judged as-is, honestly.
//
// SEAM: cask resolution is injected (MASAdoptCaskResolver) so the gate is pure
// and tests hit no network. The production adapter adapts CaskIndexStore's
// whole-index matcher (same module, internal API — no shared-file edits).

import Foundation

// MARK: - Resolver seam

/// Seam for the adopt gate's cask lookup. Tests inject a pure function; the
/// production adapter (below) wraps the whole-index store. Deliberately NOT
/// the `UpdateSource` protocol: adoption needs the cask's TOKEN and self-
/// attested version for a gate decision, not an update claim — and it must
/// never be consulted as a source by the check engine.
public struct MASAdoptCaskResolver: Sendable {

    /// One artifact-validating cask match, reduced to what the gate needs.
    public struct Match: Sendable, Hashable {
        /// The cask token the owner-run command names (brew index identifier).
        public let token: String
        /// The cask's self-attested version, trimmed; nil when the record
        /// declares none (never synthesized — CaskIndexSource's rule).
        public let version: String?
        /// How the match was found (the whole-index basis fragment, e.g.
        /// "token 'google-chrome'") — surfaces in the decision's matchBasis.
        public let basis: String

        public init(token: String, version: String?, basis: String) {
            self.token = token
            self.version = version
            self.basis = basis
        }
    }

    public enum Resolution: Sendable {
        /// Exactly one plausible cask (per the resolver's judgment).
        case unique(Match)
        /// More than one plausible cask — the gate refuses rather than guesses.
        case ambiguous(detail: String)
        /// No artifact-validating cask exists for this app.
        case none
    }

    public typealias Resolve = @Sendable (InstalledApp) async -> Resolution

    public let resolve: Resolve

    public init(_ resolve: @escaping Resolve) {
        self.resolve = resolve
    }
}

// MARK: - Production adapter (whole-index store)

extension MASAdoptCaskResolver {

    /// Adapts the whole-index CaskIndexStore. `resolvedMatch(for:)` already
    /// guarantees the returned record artifact-validates the installed app
    /// (its own honest boundary), which is exactly the adopt-eligibility core:
    /// "a cask exists whose artifact matches the installed bundle".
    ///
    /// LOAD CONTRACT: the caller must have ensured the store is loaded
    /// (`ensureLoaded`) BEFORE resolution — `resolvedMatch` matches only the
    /// in-memory records, so an unloaded store would report `.none` (a false
    /// "no cask") and a refusal would claim a certainty it does not have. The
    /// CLI honors this by refusing with its own "cask catalog unavailable"
    /// reason when the index cannot be loaded; the gate never receives an
    /// empty-store verdict from production.
    ///
    /// HONEST LIMITATION (flagged, not hidden): `.ambiguous` is a seam
    /// capability this adapter currently cannot produce — CaskIndexStore's
    /// frozen API resolves scan-path ties internally (displayName-equal
    /// preferred, else first-in-index order, ambiguity logged to the
    /// "cask-index" os category) and does not expose the candidate count.
    /// The gate still refuses on `.ambiguous` whenever a resolver reports it,
    /// and exposing the store's match count would need a store change outside
    /// this lane's file ownership (reported to the coordinator). The
    /// displayName-preference tie-break is pinned by CaskIndexTests and
    /// inherited here verbatim.
    public static func store(_ store: CaskIndexStore) -> MASAdoptCaskResolver {
        MASAdoptCaskResolver { app in
            guard let match = await store.resolvedMatch(for: app) else { return .none }
            // A record with NO token is not an adoptable cask: the owner-run
            // command NAMES the token, and an empty token would fabricate a
            // broken command from an index gap. Honest `.none`.
            guard let token = match.record.token?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !token.isEmpty else { return .none }
            // Same trim rule as CaskIndexSource: blank version → nil (never
            // synthesize a version the record does not carry).
            let rawVersion = match.record.version?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let version = (rawVersion?.isEmpty == false) ? rawVersion : nil
            return .unique(Match(
                token: token,
                version: version,
                basis: match.basisFragment))
        }
    }
}

// MARK: - Decision (the report projection)

/// The adopt gate's verdict for one app, serialized flat for the CLI's JSON
/// report (mirrors how InstallPlanEntry carries a note). INVARIANT (by
/// construction in the gate, pinned by tests): `stagedCommand != nil` XOR
/// `refusalReason != nil` — an eligible decision carries the owner-run command
/// and no refusal; a refusal carries a reason + code and no command. Neither
/// field is ever both-nil.
public struct MASAdoptDecision: Codable, Hashable, Sendable {
    /// The target app, verbatim as scanned.
    public var app: InstalledApp
    /// The cask token the command names (nil when refused before a match).
    public var caskToken: String?
    /// The cask's self-attested version verbatim (nil when refused or absent).
    public var caskVersion: String?
    /// The installed short version verbatim (nil when the scan found none).
    public var installedVersion: String?
    /// True when the explicit force flag overrode the version gate (R4/R5).
    public var forced: Bool
    /// How the cask matched (whole-index basis fragment), when matched.
    public var matchBasis: String?
    /// Receipt notes: W1 paid-MAS (always on eligible), W2 identity note,
    /// W3/W4 force-override receipts. Refusals carry none (the reason IS the
    /// note — nothing was or will be done).
    public var warnings: [String]
    /// The OWNER-RUN command. Present only on an eligible decision. NEVER
    /// executed by AppUpdater — the owner runs it (same honesty surface as
    /// InstallOutcome.stagedCommand).
    public var stagedCommand: String?
    /// Documented refusal reason (nil = eligible).
    public var refusalReason: String?
    /// Machine-readable refusal code (nil = eligible); see MASAdoptGate codes.
    public var refusalCode: String?

    public init(
        app: InstalledApp,
        caskToken: String? = nil,
        caskVersion: String? = nil,
        installedVersion: String? = nil,
        forced: Bool = false,
        matchBasis: String? = nil,
        warnings: [String] = [],
        stagedCommand: String? = nil,
        refusalReason: String? = nil,
        refusalCode: String? = nil
    ) {
        self.app = app
        self.caskToken = caskToken
        self.caskVersion = caskVersion
        self.installedVersion = installedVersion
        self.forced = forced
        self.matchBasis = matchBasis
        self.warnings = warnings
        self.stagedCommand = stagedCommand
        self.refusalReason = refusalReason
        self.refusalCode = refusalCode
    }
}

// MARK: - The gate

public struct MASAdoptGate: Sendable {

    // Stable machine-readable refusal codes (the JSON report's R1–R5 above).
    public static let codeNotMacAppStore = "not-mac-app-store"
    public static let codeNoCask = "no-cask"
    public static let codeAmbiguousMatch = "ambiguous-match"
    public static let codeVersionMismatch = "version-mismatch"
    public static let codeVersionUnverifiable = "version-unverifiable"

    public init() {}

    /// Decide adopt-eligibility for one app. Total and side-effect-free: the
    /// only async work is the injected resolver; nothing is downloaded, staged
    /// or executed — the eligible decision's `stagedCommand` is a string for
    /// the OWNER to run.
    public func decide(
        app: InstalledApp,
        resolver: MASAdoptCaskResolver,
        force: Bool = false
    ) async -> MASAdoptDecision {
        var decision = MASAdoptDecision(
            app: app,
            installedVersion: app.shortVersion,
            forced: force)

        // R1 — identity gate. Force is a consent flag for the VERSION gate
        // only; it can never turn a non-MAS app into an adoptable one.
        guard app.isMacAppStore else {
            return decision.refused(
                code: Self.codeNotMacAppStore,
                reason: "target is not a Mac App Store install (\(app.bundleIdentifier)) — "
                    + "adoption is the MAS→Homebrew path; vendor installs already resolve "
                    + "through the cask pipeline and are never adopt targets")
        }

        // R2/R3 — existence + uniqueness of the cask match.
        let resolution = await resolver.resolve(app)
        switch resolution {
        case .none:
            return decision.refused(
                code: Self.codeNoCask,
                reason: "no Homebrew cask installs this app (whole-index artifact scan found "
                    + "no cask whose artifacts match the installed bundle) — nothing to adopt")
        case .ambiguous(let detail):
            return decision.refused(
                code: Self.codeAmbiguousMatch,
                reason: "ambiguous cask match: \(detail) — refusing rather than guessing "
                    + "which cask to adopt")
        case .unique(let match):
            decision.caskToken = match.token
            decision.caskVersion = match.version
            decision.matchBasis = match.basis

            // R4/R5 — the version gate (force-overridable, warning receipted).
            let installed = Self.trimmed(app.shortVersion)
            let cask = Self.trimmed(match.version)
            if installed == nil || cask == nil {
                let missing = (installed == nil) ? "installed" : "cask"
                let reason = "cannot verify the version gate (\(missing) version unreadable) — "
                    + "adopting may replace the app with a different version than installed"
                guard force else {
                    return decision.refused(
                        code: Self.codeVersionUnverifiable,
                        reason: reason + "; pass --force to adopt anyway")
                }
                decision.warnings.append(
                    "VERSION-UNVERIFIABLE OVERRIDE: \(reason); force-adopting proceeds "
                        + "without version verification")
            } else if let installed, let cask,
                      VersionOracle().compare(cask, installed) != .equal {
                guard force else {
                    return decision.refused(
                        code: Self.codeVersionMismatch,
                        reason: "installed version (\(installed)) doesn't match the Homebrew "
                            + "cask version (\(cask)) — adopting replaces the app with the "
                            + "cask build; pass --force to override")
                }
                // The teardown's force-adopt wording, as a warning receipt.
                decision.warnings.append(
                    "VERSION-MISMATCH OVERRIDE: your installed version (\(installed)) doesn't "
                        + "match the Homebrew cask version (\(cask)). Force-adopting will "
                        + "replace the app with the cask version (\(cask)).")
            }

            // W1 — paid-MAS warning, UNCONDITIONAL on every eligible decision:
            // payment is not detectable, so the teardown's paid-app warning is
            // attached as a receipt note instead of a detection result.
            decision.warnings.append(
                "PAID-APP-STORE WARNING (unconditional — AppUpdater cannot detect whether this "
                    + "app was paid): adopting a paid App Store app to Homebrew will replace "
                    + "your App Store version with the Homebrew build. That build may have "
                    + "different features or require a separate license. Your App Store "
                    + "purchase and license will not transfer.")
            // W2 — identity note: adoption is a one-way update-identity change.
            decision.warnings.append(
                "Adoption replaces the App Store build (receipt + entitlements) with the "
                    + "Homebrew (vendor) build; from then on the app's update identity is "
                    + "the cask '\(match.token)'.")

            decision.stagedCommand = Self.command(token: match.token, force: force)
            return decision
        }
    }

    /// The exact command shapes (teardown §3.3 literal + the force variant for
    /// the version-mismatch override). Cask tokens are brew-index identifiers
    /// (lowercase alphanumeric + dashes) so the token is emitted unquoted; the
    /// command is a STRING the owner runs — nothing here ever spawns a process.
    public static func command(token: String, force: Bool) -> String {
        force
            ? "brew install --cask --force --adopt \(token)"
            : "brew install --cask --adopt \(token)"
    }

    private static func trimmed(_ raw: String?) -> String? {
        let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }
}

// MARK: - Decision construction helpers (refusal closure discipline)

extension MASAdoptDecision {
    /// Terminal refusal: reason + code set, command stays nil, warnings stay
    /// empty (the reason is the note — nothing was or will be done).
    func refused(code: String, reason: String) -> MASAdoptDecision {
        var copy = self
        copy.refusalCode = code
        copy.refusalReason = reason
        copy.warnings = []
        copy.stagedCommand = nil
        return copy
    }
}
