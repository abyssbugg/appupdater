// NotificationDecider.swift — the PURE policy for local notifications about
// newly discovered updates. No frameworks (no UserNotifications, no AppKit):
// the decider only THINKS; the app target (AppState) does the asking and the
// posting. Unit-proven in NotificationDeciderTests.
// Phase-4-lane notifications · exclusive file of this lane.
//
// # DECIDED POLICY (v1, coordinator 2026-10-26)
//
// A scheduled fire informs only about changes SINCE THE PREVIOUS SCHEDULED
// fire — a fire-to-fire diff, not a diff against the world's opinion:
//
// - ``Advice/baselineAfterLaunch`` — the caller has never recorded a fired
//   pending set (`previous == nil`, i.e. never ran since launch). The whole
//   first fire after launch is ONE baseline event: the launch itself already
//   surfaces the window UI, so a launch-time blast would be spam. This is
//   suppression-by-design, and it holds for BOTH first-fire shapes —
//   empty current AND already-pending current. The nil-vs-empty distinction
//   is the load-bearing one (nil = never ran; [] = ran, nothing pending).
// - ``Advice/noChange`` — the pending NAME SET is unchanged since the
//   previous scheduled fire (duplicates collapse; order is irrelevant —
//   "semantically equal multisets"). Also returned when the ONLY difference
//   is apps LEAVING pending: an app that recovered (was updated by its own
//   vendor path, or the claim dried up) is NOT news — recovery is not news,
//   the window list already shows the honest state. Documented consequence
//   of the decided wording: the "otherwise" case yields current-minus-
//   previous, and with zero additions there is nothing to surface.
// - ``Advice/newlyPending(names:)`` — names that are pending NOW and were
//   NOT pending at the previous scheduled fire, deduped and sorted ascending
//   (stable order for the summary notification's body). Mixed add+remove
//   fires yield ONLY the adds.
//
// COMPARISON CONTRACT (documented, tested):
// - Compared over NAME SETS, not app identities: the summary notification
//   counts distinct app names; the window list carries the per-app truth
//   (two same-named apps with different bundle IDs would collapse in the
//   summary — an accepted, documented v1 simplification, NOT silent).
// - Duplicates in the current list never fabricate a delta against a
//   previously-single name.
// - Only scheduled fires feed the previous set (see AppState's
//   `lastScheduledPendingNames`); MANUAL Check Now never mutates it and
//   never advises — a manual nudge must never tune the scheduled-fire
//   baseline.
//
// This unit has NO state: the caller owns the baseline persistence; feeding
// stale/nil data yields the documented advice, never a guess.

import Foundation

public enum NotificationDecider {

    /// What the policy advises the caller to do with a scheduled fire's
    /// pending set. `Equatable` per the product spec (+ `Hashable`/`Sendable`
    /// for the core's cross-surface carriers — strict superset, no behavior).
    public enum Advice: Equatable, Hashable, Sendable {
        /// First scheduled fire since launch: suppress (launch already
        /// surfaces the UI). Applies regardless of how full the first
        /// fire's pending set was.
        case baselineAfterLaunch
        /// Nothing newly pending (equal set, or an only-removals diff).
        case noChange
        /// Names pending now that were NOT pending at the previous
        /// scheduled fire — deduped, ascending. Never empty by contract
        /// (a zero-addition diff is `noChange`, never an empty "news").
        case newlyPending(names: [String])
    }

    /// Compares this scheduled fire's pending names against the previous
    /// scheduled fire's (nil = never ran since launch) and returns the
    /// policy's advice per the doc block. Pure: no I/O, no clocks.
    public static func advise(
        previousScheduledPending: [String]?,
        currentPending: [String]
    ) -> Advice {
        // Never-ran-since-launch: the launch is the surface; the whole
        // first fire is the baseline (empty or not).
        guard let previous = previousScheduledPending else {
            return .baselineAfterLaunch
        }
        let currentNames = Set(currentPending)
        if currentNames == Set(previous) {
            return .noChange
        }
        let additions = currentNames.subtracting(previous).sorted()
        if additions.isEmpty {
            // Removal-only diff: the only difference is apps that LEFT the
            // pending set. Recovery is not news (documented above).
            return .noChange
        }
        return .newlyPending(names: additions)
    }
}
