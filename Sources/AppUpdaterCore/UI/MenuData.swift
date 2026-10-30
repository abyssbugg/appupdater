import Foundation

// Menu-bar DATA layer — Phase 4, lane "menudata".
//
// PURE transform: (rows, schedule snapshot, now) → menu-bar contents.
// No SwiftUI, no AppKit, no timers, no live polling, no engine calls.
// Everything below is derived deterministically from the three inputs; two
// constructions with the same inputs yield equal MenuData values (see
// MenuDataTests).
//
// How the (future, coordinator-wired) MenuBarExtra renders these values:
//   - headline           → top buttons, in order: Check for Updates (coordinator
//                          triggers the real check pipeline), Open AppUpdater
//                          (`openWindow(id:)`, macOS-15 seam), Quit (terminate).
//   - pendingSection     → one row per pending update, already alphabetical.
//                          Each item binds pendingSection.actions (label + ID);
//                          the coordinator maps IDs to handlers at merge. MAS
//                          rows carry the Store honesty label and NO installNow
//                          (Store apps cannot be user-space installed —
//                          MacUpdater parity).
//   - currentApps(count:)→ filled by the coordinator from rows classified as
//                          non-pending; MenuData exposes no possibly-dishonest
//                          "current" derivation (failed/unknown checks are
//                          neither pending nor current — they stay uncounted
//                          here rather than being silently relabeled).
//   - schedule           → Text lines from scheduleSection (UTC clock, honest
//                          countdown, catch-up/error honesty lines).
//   - footer             → coordinator-local content (e.g. version line).
//
// The coordinator owns the app shell (Sources/AppUpdaterApp/*): it will bind
// MenuAction IDs to real handlers (Pasteboard, openWindow, terminate) at merge.
// This file NEVER touches the app shell.

/// Render skeleton of the menu bar: the canonical section ORDER the
/// coordinator's MenuBarExtra walks so the menu bar and the tests share one
/// truth. Sections carry no state of their own; every section's payload comes
/// from `MenuData` at render time.
public enum MenuSection: Sendable, Hashable {
    case headline
    case pendingUpdates
    /// `count` is whatever the coordinator computes for the non-pending rows;
    /// the static layout below carries a placeholder 0 and is an ORDER list
    /// only.
    case currentApps(count: Int)
    case schedule
    case footer

    /// Canonical render order for the menu bar (top → bottom).
    public static let standardLayout: [MenuSection] = [
        .headline, .pendingUpdates, .currentApps(count: 0), .schedule, .footer,
    ]
}

/// One actionable menu-bar item: a stable machine identity plus a plain,
/// deterministic user-facing label (no emoji — coordinators may prefix/suffix
/// icons; the data layer never does).
public struct MenuAction: Sendable, Hashable {
    /// NOTE: the design brief wrote `enum ID: String`, but Swift forbids raw
    /// values on enums whose cases carry associated values
    /// (`installNow(bundleID:)` / `viewDetails(bundleID:)`). The case names and
    /// payloads are kept exactly as briefed and `stableID` restores the stable
    /// string identity the raw value would have provided.
    public enum ID: Sendable, Equatable, Hashable {
        case checkNow
        case openMainWindow
        case openSettings
        case quit
        case installNow(bundleID: String)
        case viewDetails(bundleID: String)

        /// Deterministic string form (stable item identity for logs, tests and
        /// coordinator-side wiring): `"installNow:com.vendor.app"` etc.
        public var stableID: String {
            switch self {
            case .checkNow: return "checkNow"
            case .openMainWindow: return "openMainWindow"
            case .openSettings: return "openSettings"
            case .quit: return "quit"
            case .installNow(let bundleID): return "installNow:\(bundleID)"
            case .viewDetails(let bundleID): return "viewDetails:\(bundleID)"
            }
        }
    }

    /// Plain user string; no emoji, no locale-dependent formatting.
    public let label: String
    public let id: ID

    public init(id: ID, label: String) {
        self.id = id
        self.label = label
    }
}

/// Everything the menu bar needs, computed once and purely from frozen model
/// types (`AppRow`, `ScheduleSnapshot`) and one `now` date. Capsule-plain:
/// the coordinator binds `MenuSection.standardLayout` to these values in its
/// MenuBarExtra; the data layer refuses to invent SwiftUI/AppKit.
public struct MenuData: Sendable, Equatable {
    /// "Check for Updates" (.checkNow), "Open AppUpdater" (.openMainWindow),
    /// "Quit" (.quit) — contract order, contract labels.
    public let headline: [MenuAction]

    /// Pending-update surface.
    /// - `updates`: rows where `AppRow.updateAvailable` is true (the honest
    ///   computed flag — rule ignores respected), sorted alphabetically by app
    ///   name (case-insensitive, deterministic tie-break).
    /// - `actions`: one contiguous block per row in the same order; MAS rows
    ///   contribute a Store-noted details action and NEVER an installNow.
    public let pendingSection: (updates: [AppRow], actions: [MenuAction])

    /// Readable schedule lines over ScheduleSnapshot ONLY (persisted state —
    /// never the live engine loop): next fire / overdue catch-up / scheduled
    /// off, last-fire honesty (clock, app count, never), catch-up note, and a
    /// verbatim-ish error line when the last fire failed. UTC HH:mm clock,
    /// countdown vs `now`; deterministic.
    public let scheduleSection: [String]

    /// Menu-bar badge source: `pending` > 0 → numeric badge; 0 → nothing
    /// shown. `total` = every inventoried row, honest — ignorers and unknowns
    /// are included, so the menu never inflates either number.
    public let counts: (pending: Int, total: Int)

    public init(appRowSummary: [AppRow], schedule: ScheduleSnapshot, now: Date) {
        self.headline = [
            MenuAction(id: .checkNow, label: "Check for Updates"),
            MenuAction(id: .openMainWindow, label: "Open AppUpdater"),
            MenuAction(id: .quit, label: "Quit"),
        ]

        let pending = Self.pendingRows(from: appRowSummary)
        self.pendingSection = (updates: pending, actions: pending.flatMap { Self.actions(for: $0) })
        self.scheduleSection = Self.scheduleLines(
            schedule: schedule, now: now,
            checkedCount: appRowSummary.filter { $0.check != nil }.count
        )
        self.counts = (pending: pending.count, total: appRowSummary.count)
    }

    // MARK: - Pending surface

    /// Honest pending filter: the frozen `AppRow.updateAvailable` flag already
    /// fuses the rule decision (ignoredBundle / ignoredVersion) with the check
    /// verdict — this layer re-derives nothing.
    internal static func pendingRows(from appRowSummary: [AppRow]) -> [AppRow] {
        appRowSummary
            .filter { $0.updateAvailable }
            .sorted { Self.nameOrder($0.app, $1.app) }
    }

    /// Actions for ONE row (DRY helper used by `pendingSection`). Returns
    /// `[]` for rows that are not pending updates — the menu shows an empty
    /// pending tray rather than ever faking affordances.
    ///
    /// Store honesty (MacUpdater parity): an app scanned with
    /// `InstalledApp.isMacAppStore` CANNOT be user-space installed, so its
    /// only truthful affordance is a details action whose label honestly says
    /// the update lives in the Mac App Store. The installNow action is
    /// REPLACED — never offered for MAS rows.
    public static func actions(for row: AppRow) -> [MenuAction] {
        guard row.updateAvailable else { return [] }
        let bundleID = row.app.bundleIdentifier
        if row.app.isMacAppStore {
            return [
                MenuAction(
                    id: .viewDetails(bundleID: bundleID),
                    label: "View Details: \(row.app.name) — update available in the Mac App Store"
                ),
            ]
        }
        return [
            MenuAction(id: .installNow(bundleID: bundleID), label: "Install \(row.app.name)"),
            MenuAction(id: .viewDetails(bundleID: bundleID), label: "View Details: \(row.app.name)"),
        ]
    }

    // MARK: - Schedule surface

    /// Schedule lines over the frozen snapshot only. Line 0 carries the
    /// scheduled state; history honesty lines (last fire, catch-up, error)
    /// follow and appear regardless of the on/off policy.
    internal static func scheduleLines(
        schedule: ScheduleSnapshot, now: Date, checkedCount: Int = 0
    ) -> [String] {
        var lines: [String] = []

        if schedule.policy.intervalMinutes <= 0 {
            // Explicit off state documented on SchedulePolicy.intervalMinutes.
            lines.append("Automatic checks: off")
        } else if let last = schedule.state.lastFireAt {
            let next = last.addingTimeInterval(TimeInterval(schedule.policy.intervalMinutes * 60))
            if next > now {
                lines.append(
                    "Next automatic check: \(Self.clockText(next)) UTC (in \(Self.countdownText(from: now, to: next)))"
                )
            } else if schedule.policy.onWakeCatchUp {
                lines.append("Automatic check overdue — catch-up pending")
            } else {
                lines.append("Automatic check overdue — waiting for the next slot")
            }
        } else {
            // Never ran: no reliable next slot to render honestly.
            lines.append("Next automatic check: pending (no check has run yet)")
        }

        if let last = schedule.state.lastFireAt {
            var line = "Last automatic check: \(Self.clockText(last)) UTC"
            if let checked = schedule.state.lastFireAppsChecked {
                line += " (checked \(checked) apps)"
            }
            lines.append(line)
        } else {
            // ScheduleState doc: nil is treated as "never ran".
            lines.append("Last automatic check: never")
        }

        // Missed-slot catch-up honesty, both directions:
        if schedule.state.lastFireWasCatchUp == true {
            lines.append("Last check was a wake catch-up for a missed slot")
        }

        if let error = schedule.state.lastFireError, !error.isEmpty {
            // Verbatim-ish: the engine's own error text passed through untouched.
            lines.append("Last check error: \(error)")
        }

        return lines
    }

    /// Fixed-width UTC clock "HH:mm" for a date, computed with pure integer
    /// math on the Unix epoch (no Calendar/TimeZone optionals to crash on,
    /// no mutable DateFormatter instance, no locale, no `Date()`).
    static func clockText(_ date: Date) -> String {
        let seconds = Int(date.timeIntervalSince1970)
        let hour = (seconds / 3600) % 24
        let minute = (seconds / 60) % 60
        return String(format: "%02d:%02d", hour, minute)
    }

    /// Deterministic countdown ("in 2h 25m" / "in 45m" / "in <1m"), whole
    /// minutes vs `now`. Only meaningful when `to` >= `from`.
    static func countdownText(from now: Date, to target: Date) -> String {
        let minutes = Int((target.timeIntervalSince(now) / 60.0).rounded(.down))
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        if minutes > 0 {
            return "\(minutes)m"
        }
        return "<1m"
    }

    /// Locale-free alphabetical order by app name, deterministic tie-break for
    /// duplicate names (InstalledApp.id = bundle|path).
    internal static func nameOrder(_ lhs: InstalledApp, _ rhs: InstalledApp) -> Bool {
        let left = lhs.name.lowercased()
        let right = rhs.name.lowercased()
        if left != right { return left < right }
        return lhs.id < rhs.id
    }

    // MARK: - Equality (hand-written: stored tuples cannot be synthesized)

    public static func == (lhs: MenuData, rhs: MenuData) -> Bool {
        lhs.headline == rhs.headline
            && lhs.pendingSection.updates == rhs.pendingSection.updates
            && lhs.pendingSection.actions == rhs.pendingSection.actions
            && lhs.scheduleSection == rhs.scheduleSection
            && lhs.counts.pending == rhs.counts.pending
            && lhs.counts.total == rhs.counts.total
    }
}
