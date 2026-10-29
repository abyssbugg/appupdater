import Foundation
import Observation

// Scheduler + UI interchange types — FROZEN contract for Phase 4 lanes.
// Written by the coordinator; lanes implement engines/stores/view-models over
// these shapes. If a lane needs a change here: STOP and report it; shared
// files are coordinator-owned.
//
// ADDITIVE change 2026-10-28 (tracked Tier-2 gap "scheduling depth", lane
// sched-depth): the coordinator's lane brief transferred ownership of this
// file for exactly two deferral capabilities on SchedulePolicy —
// `deferWhenOffline` and the `activeWindowStartMinute`/`activeWindowEndMinute`
// pair. The change is strictly additive: every new field has a default, the
// memberwise init grows only defaulted trailing parameters (all pre-existing
// call sites compile untouched), and `init(from:)` decodes the new keys with
// `decodeIfPresent` so policies persisted by older builds decode cleanly.
// Everything else in this file is untouched frozen contract.
//
// Persistence responsibility (Lane 2's store):
//   ~/Library/Application Support/AppUpdater/schedule.json  (SchedulePolicy + ScheduleState)
//   ~/Library/Application Support/AppUpdater/rules.json     ([IgnoreRule])
// Loaders must be robust: unknown fields ignored (Codable default), garbage
// files replaced by defaults (honest log line, never a crash).

/// User-visible scheduling policy (persisted).
public struct SchedulePolicy: Codable, Hashable, Sendable {
    /// Minutes between automatic scan fires. Stored value must be >= 15
    /// (loader clamps down to 15; 0 / negative treated as "never scheduled"
    /// ONLY when intervalMinutes <= 0 — explicit off state, documented).
    public var intervalMinutes: Int
    /// Skip a fire while on battery power (energy-aware policy, seam-injected
    /// probe in the engine; skipped fire reschedules, never cancels).
    public var skipOnBattery: Bool
    /// When a fire was missed (Mac asleep at nextFireAt), fire immediately on
    /// wake (Missed-scan catch-up). false = wait for the next future slot.
    public var onWakeCatchUp: Bool
    /// Defer a due fire while no network path is reachable (MacUpdater's
    /// `shouldDeferScanDueToOffline` gate). The engine probes the seam
    /// (`ScheduleEngine.isOnline`) at the decision moment; a deferred slot is a
    /// POLICY SKIP — no fire, no state record — and the next eligible slot
    /// fires normally (never mislabeled as catch-up). Default false: existing
    /// policies keep their exact behavior.
    public var deferWhenOffline: Bool
    /// Active window (quiet hours inverse), in LOCAL minutes-of-day 0...1439:
    /// a due fire whose decision moment sits OUTSIDE `[start, end)` is a policy
    /// skip exactly like the battery gate. nil/nil = no restriction (default).
    /// Semantics decided + documented on the engine (sched-depth lane, 2026-10-28):
    /// start inclusive, end exclusive; BOTH endpoints must be set, in range, and
    /// start < end — anything else is an invalid window and is treated as no
    /// restriction (the loader clamps invalid windows to nil/nil so what the
    /// settings pane shows matches what is enforced). No overnight wrap: a
    /// window that crosses midnight is not representable and normalizes to
    /// no restriction.
    public var activeWindowStartMinute: Int?
    /// See ``SchedulePolicy/activeWindowStartMinute``. End is EXCLUSIVE: a
    /// decision moment exactly at `activeWindowEndMinute` is outside the window.
    public var activeWindowEndMinute: Int?

    public init(
        intervalMinutes: Int = 240,
        skipOnBattery: Bool = true,
        onWakeCatchUp: Bool = true,
        deferWhenOffline: Bool = false,
        activeWindowStartMinute: Int? = nil,
        activeWindowEndMinute: Int? = nil
    ) {
        self.intervalMinutes = intervalMinutes
        self.skipOnBattery = skipOnBattery
        self.onWakeCatchUp = onWakeCatchUp
        self.deferWhenOffline = deferWhenOffline
        self.activeWindowStartMinute = activeWindowStartMinute
        self.activeWindowEndMinute = activeWindowEndMinute
    }

    /// Decode tolerance (additive-contract requirement): policies persisted by
    /// older builds carry only the three original keys. The three original keys
    /// stay REQUIRED (identical behavior to the synthesized decoder — a file
    /// missing them was already garbage and the loader replaces it with
    /// defaults); the new keys decode with their defaults when absent. Encoding
    /// stays synthesized (every key always written).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intervalMinutes = try container.decode(Int.self, forKey: .intervalMinutes)
        skipOnBattery = try container.decode(Bool.self, forKey: .skipOnBattery)
        onWakeCatchUp = try container.decode(Bool.self, forKey: .onWakeCatchUp)
        deferWhenOffline = try container.decodeIfPresent(Bool.self, forKey: .deferWhenOffline) ?? false
        activeWindowStartMinute = try container.decodeIfPresent(Int.self, forKey: .activeWindowStartMinute)
        activeWindowEndMinute = try container.decodeIfPresent(Int.self, forKey: .activeWindowEndMinute)
    }

    private enum CodingKeys: String, CodingKey {
        case intervalMinutes
        case skipOnBattery
        case onWakeCatchUp
        case deferWhenOffline
        case activeWindowStartMinute
        case activeWindowEndMinute
    }
}

/// What the engine records after every fire attempt (persisted next to the
/// policy). Explicit absence fields — the UI treats nil as "never ran".
public struct ScheduleState: Codable, Hashable, Sendable {
    public var lastFireAt: Date?
    /// Number of apps the last fire inventoried (nil until the first fire).
    public var lastFireAppsChecked: Int?
    /// true when this fire was a catch-up for a missed time slot.
    public var lastFireWasCatchUp: Bool?
    /// Opaque error text of the last failed fire (honest surface for the UI).
    public var lastFireError: String?

    public init(
        lastFireAt: Date? = nil,
        lastFireAppsChecked: Int? = nil,
        lastFireWasCatchUp: Bool? = nil,
        lastFireError: String? = nil
    ) {
        self.lastFireAt = lastFireAt
        self.lastFireAppsChecked = lastFireAppsChecked
        self.lastFireWasCatchUp = lastFireWasCatchUp
        self.lastFireError = lastFireError
    }
}

/// Rule kinds (v1): never auto-APPLY remains the standing owner boundary —
/// autoCheck rules govern automatic CHECKS + notifications only.
public enum RuleKind: String, Codable, Hashable, Sendable {
    /// Never surface this app in "updates available" (silently current).
    case ignoreBundle
    /// Ignore this specific version claim for this app (same-major-happy).
    case ignoreVersion
    /// Include this app in automatic timed checks (legacy opt-IN marker from
    /// the v1 default-OFF era; kept for persisted-file compatibility — the
    /// evaluator treats it the same as the default).
    case autoCheck
    /// Exclude this app from automatic timed checks (the explicit OPT-OUT;
    /// automatic checks are ON by default — read-only source lookups only,
    /// and auto-APPLY consent is a separate, still-default-OFF boundary).
    case noAutoCheck
}

/// One per-app rule row.
public struct IgnoreRule: Codable, Hashable, Sendable {
    public var kind: RuleKind
    public var bundleIdentifier: String
    /// Non-nil ONLY for .ignoreVersion (the exact short version string ignored).
    public var version: String?
    public var createdAt: Date

    public init(kind: RuleKind, bundleIdentifier: String, version: String? = nil, createdAt: Date = Date()) {
        self.kind = kind
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.createdAt = createdAt
    }
}

/// Everything a rule set says about one app + a candidate claim. The
/// evaluator (Lane 2) produces it; both UI lanes and the engine consume it.
public struct RuleDecision: Codable, Hashable, Sendable {
    /// .ignoreBundle active → this app never appears as a pending update.
    public var ignoredBundle: Bool
    /// .ignoreVersion active for this exact (app, version) pair.
    public var ignoredVersion: Bool
    /// Included in timed scans (default ON; an explicit .noAutoCheck rule
    /// turns it off — automatic checks are read-only source lookups, and
    /// auto-APPLY consent stays a separate default-OFF boundary).
    public var autoCheck: Bool

    public init(ignoredBundle: Bool = false, ignoredVersion: Bool = false, autoCheck: Bool = true) {
        self.ignoredBundle = ignoredBundle
        self.ignoredVersion = ignoredVersion
        self.autoCheck = autoCheck
    }
}

/// The merged per-app row BOTH UI surfaces consume (window list + menu bar).
/// View-model lanes transform this; no lane invents its own merge type.
public struct AppRow: Codable, Hashable, Sendable, Identifiable {
    public var app: InstalledApp
    /// nil when never checked or check failed with no candidates.
    public var check: UpdateCheck?
    public var decision: RuleDecision

    public var id: String { app.id }
    /// Honest staleness marker for list ordering/filtering.
    public var updateAvailable: Bool {
        guard !decision.ignoredBundle, !(decision.ignoredVersion) else { return false }
        return check?.verdict == "update"
    }

    public init(app: InstalledApp, check: UpdateCheck?, decision: RuleDecision) {
        self.app = app
        self.check = check
        self.decision = decision
    }
}

/// UI-facing schedule snapshot the window settings pane and the menu bar both
/// read via view models (Lane 3 + Lane 4). Kept tiny on purpose: the full
/// persisted pair, no favorites inside.
public struct ScheduleSnapshot: Codable, Hashable, Sendable {
    public var policy: SchedulePolicy
    public var state: ScheduleState

    public init(policy: SchedulePolicy, state: ScheduleState) {
        self.policy = policy
        self.state = state
    }
}
