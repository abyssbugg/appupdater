// AutoApplyOutcome.swift — verbatim auto-apply receipts (GAP #22).
// Gap-sprint wave · lane autoapply · exclusive file of this lane.
//
// DECISION 14 CONTRACT these types serve: "every auto-apply produces full
// verbatim receipts". One ``AutoApplyOutcome`` records, per app: WHO (the app
// row), WHEN (the decision timestamp), WHAT THE GATE SAID (the
// ``AutoApplyDecision`` — skip reasons carry their stable machine-readable
// vocabulary), and — only for a `.apply` that the coordinator actually
// executed — the EXISTING ``InstallOutcome`` of the InstallCoordinator chain,
// embedded verbatim. The GATE never fills `installOutcome`: it only decides
// (gate-over-install separation); the coordinator owns the chain call and the
// receipt assembly after this lane merges.
//
// Codable notes: `installOutcome` is optional (nil for every skip — a skip
// has no install to report), so older/shorter payloads keep decoding.
// `AutoApplyRunReceipt` is the run-level container the coordinator will
// persist/emit for a whole post-scan auto-apply pass; its counts are
// computed, never stored (stored numbers can drift from their list —
// computed ones cannot).

import Foundation

/// Per-app record of one auto-apply decision, plus the executed install when
/// there was one.
public struct AutoApplyOutcome: Codable, Hashable, Sendable {
    /// The app the decision was made for (verbatim from the gate input).
    public var app: InstalledApp
    /// When the gate decided (caller-supplied timestamp — the gate itself
    /// owns no clock, keeping it pure).
    public var decidedAt: Date
    /// The gate's decision: `.apply` or `.skip(reason)`.
    public var decision: AutoApplyDecision
    /// The EXISTING InstallCoordinator chain's outcome, embedded verbatim by
    /// the coordinator — ONLY for a `.apply` decision that was actually
    /// executed. nil for every skip, and for an apply the coordinator could
    /// not run (that fact belongs in the caller's own error surface, never
    /// in a fabricated outcome).
    public var installOutcome: InstallOutcome?
    /// Set when the gate said .apply but PLANNING failed (e.g. the security
    /// floor refused a claim without a verifiable sha256) — the honest record
    /// of an apply attempt that never reached the executor. Additive field
    /// (coordinator, decision-14 wiring): legacy JSON decodes with nil.
    public var planningNote: String?

    public init(
        app: InstalledApp, decidedAt: Date, decision: AutoApplyDecision,
        installOutcome: InstallOutcome? = nil, planningNote: String? = nil
    ) {
        self.app = app
        self.decidedAt = decidedAt
        self.decision = decision
        self.installOutcome = installOutcome
        self.planningNote = planningNote
    }
}

/// Run-level receipt for one post-scan auto-apply pass over many apps.
public struct AutoApplyRunReceipt: Codable, Hashable, Sendable {
    /// When the pass started (caller-supplied).
    public var startedAt: Date
    /// When the pass ended; nil until the caller closes the run.
    public var finishedAt: Date?
    /// One outcome per app considered, in the caller's processing order.
    public var outcomes: [AutoApplyOutcome]

    public init(startedAt: Date, finishedAt: Date? = nil, outcomes: [AutoApplyOutcome] = []) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcomes = outcomes
    }

    /// Apps whose decision was `.apply` (computed — never a stored count).
    public var appliedCount: Int {
        outcomes.lazy.filter { $0.decision == .apply }.count
    }

    /// Apps whose decision was a skip (computed — never a stored count).
    public var skippedCount: Int {
        outcomes.count - appliedCount
    }
}
