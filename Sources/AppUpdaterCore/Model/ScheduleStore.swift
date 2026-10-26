import Foundation
import Observation

// Scheduler + UI interchange types — FROZEN contract for Phase 4 lanes.
// Written by the coordinator; lanes implement engines/stores/view-models over
// these shapes. If a lane needs a change here: STOP and report it; shared
// files are coordinator-owned.
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

    public init(intervalMinutes: Int = 240, skipOnBattery: Bool = true, onWakeCatchUp: Bool = true) {
        self.intervalMinutes = intervalMinutes
        self.skipOnBattery = skipOnBattery
        self.onWakeCatchUp = onWakeCatchUp
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
    /// Include this app in automatic timed checks (default OFF per app in v1 —
    /// only explicitly enabled apps burn check requests; manual Check-now is unconstrained).
    case autoCheck
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
    /// .autoCheck → included in timed scans.
    public var autoCheck: Bool

    public init(ignoredBundle: Bool = false, ignoredVersion: Bool = false, autoCheck: Bool = false) {
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
