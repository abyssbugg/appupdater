// NotificationActionPlanner.swift — the PURE decision for WHICH scheduled
// fires get an actionable notification and WHICH app such a notification
// names. No frameworks (Foundation only, no UserNotifications): the planner
// only THINKS; the app target (AppState) does the posting. Unit-proven in
// NotificationActionTests.
// Tier-2 gap "notify-actions" lane · exclusive file of this lane.
//
// # DECIDED POLICY (v1, 2026-10-28)
//
// The planner runs AFTER `NotificationDecider.advise` has already decided
// that a fire is news at all (`newlyPending`). It receives those newly
// pending names PLUS the fire's own pending rows shaped as
// ``PendingCandidate`` (name, bundle ID, stageable) and returns a
// ``NotificationActionPlanner/Plan``:
//
// - ``Plan/actionableSingleApp(name:bundleID:)`` — EXACTLY ONE newly
//   pending name, and that name resolves to EXACTLY ONE distinct bundle ID
//   among the candidates, and that candidate is stageable. The notification
//   carries the ``NotificationActionIDs/categoryPendingUpdate`` category,
//   whose actions are "Open AppUpdater" and "Stage Install Command".
// - ``Plan/passiveSummary(names:)`` — everything else, which is the
//   EXISTING summary notification unchanged:
//   · zero names (the decider never yields empty `newlyPending`, but the
//     planner is a total function — the caller posts nothing for it),
//   · more than one newly pending name ("Stage Install Command" would be
//     ambiguous — a summary names the whole set, it does not pick one),
//   · one name that matches NO candidate row (should not happen — the
//     names come from the same rows — but the honest answer is the
//     summary, never a guessed bundle ID),
//   · one name shared by MULTIPLE distinct bundle IDs (the same-name
//     collision the summary policy already documents — staging "the app"
//     would be a guess),
//   · one resolvable name whose candidate is NOT stageable (Mac App Store
//     apps: updates happen in the Store, the existing consent boundary
//     never stages them — the window's own Stage button is hidden for
//     them, and so is this notification's stage action).
//
// COMPARISON CONTRACT (documented, tested):
// - Name matching is EXACT and case-sensitive — the same discipline the
//   decider's name sets use; "alpha" does not resolve "Alpha".
// - Distinctness is over BUNDLE IDs: two candidate rows with the same name
//   and the same bundle ID collapse to one (duplicates never make an
//   unambiguous app look ambiguous).
// - Empty bundle IDs are unresolvable (staging an empty bundle ID would
//   silently do nothing — the planner refuses instead).
//
// This unit has NO state and does NO I/O: the caller owns the rows and the
// posting; feeding it inconsistent inputs yields the documented passive
// shape, never a guess.

import Foundation

public enum NotificationActionPlanner {

    /// One pending row the caller offers for possible actioning. `stageable`
    /// is the CALLER's attestation that the existing consent boundary would
    /// stage this app (false for Mac App Store apps — mirroring the window's
    /// own Stage-button visibility).
    public struct PendingCandidate: Equatable, Hashable, Sendable {
        public let appName: String
        public let bundleID: String
        public let stageable: Bool

        public init(appName: String, bundleID: String, stageable: Bool) {
            self.appName = appName
            self.bundleID = bundleID
            self.stageable = stageable
        }
    }

    /// What to post for this fire. `Equatable` for the tests (+ `Hashable`/
    /// `Sendable` as the core's strict-superset convention, no behavior).
    public enum Plan: Equatable, Hashable, Sendable {
        /// Attach the actionable category naming THIS app. Never produced
        /// for an ambiguous, unstaged, or multi-app shape.
        case actionableSingleApp(name: String, bundleID: String)
        /// The existing passive summary for these names (the caller posts
        /// nothing when the list is empty — a decider-impossible shape it
        /// still handles honestly).
        case passiveSummary(names: [String])
    }

    /// Decides the notification shape for one fire's newly pending names,
    /// per the doc block. Pure: no I/O, no clocks, no state.
    public static func plan(
        newlyPendingNames: [String],
        candidates: [PendingCandidate]
    ) -> Plan {
        // The summary shape covers every non-actionable outcome, including
        // the decider-impossible empty case (caller posts nothing).
        guard newlyPendingNames.count == 1,
              let name = newlyPendingNames.first
        else { return .passiveSummary(names: newlyPendingNames) }

        // Resolve the name over DISTINCT bundle IDs (duplicates of the same
        // bundle ID never make an app look ambiguous).
        let matching = candidates.filter { $0.appName == name }
        let distinctBundleIDs = Set(matching.map { $0.bundleID })
        guard distinctBundleIDs.count == 1,
              let bundleID = distinctBundleIDs.first,
              !bundleID.isEmpty
        else { return .passiveSummary(names: newlyPendingNames) }

        // The one bundle ID may still be backed by several candidate rows
        // (same name, same bundle ID) — stageable if ANY of them is (they
        // are the same app; the window would show the Stage button for it).
        let stageable = matching.contains { $0.bundleID == bundleID && $0.stageable }
        guard stageable else { return .passiveSummary(names: newlyPendingNames) }

        return .actionableSingleApp(name: name, bundleID: bundleID)
    }
}
