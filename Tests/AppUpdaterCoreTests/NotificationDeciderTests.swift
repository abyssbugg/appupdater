// NotificationDeciderTests — PURE policy tests (no I/O, no frameworks, no
// fixtures). Swift Testing, NOT XCTest: XCTest discovery is broken on this
// toolchain (Xcode 27 beta, AGENTS.md gotcha ledger) — Foundation imported
// explicitly because Swift Testing does not re-export it.
//
// These tests pin the DECIDED v1 policy (coordinator 2026-10-26): a
// scheduled fire informs only about changes SINCE the previous scheduled
// fire — nil baseline suppresses (the launch surfaces the UI), equal sets
// are quiet, removals are never news, and only newly pending names surface
// (deduped, sorted).

import Foundation
import Testing
@testable import AppUpdaterCore

@Suite
struct NotificationDeciderTests {

    // MARK: - Baseline (previous == nil: never ran since launch)

    /// The first scheduled fire EVER suppresses even when apps are already
    /// pending — the whole first fire is one baseline event, and a
    /// launch-time blast would be spam (the launch itself surfaces the UI).
    @Test
    func firstScheduledFireWithPendingAppsIsBaseline() {
        let advice = NotificationDecider.advise(
            previousScheduledPending: nil,
            currentPending: ["Alpha", "Beta"])
        #expect(advice == .baselineAfterLaunch)
    }

    /// Empty current after a nil baseline is the SAME one baseline event —
    /// nil means "never ran", so the empty first fire just sets the
    /// baseline quietly (nil ≠ [] is the load-bearing distinction).
    @Test
    func firstScheduledFireWithEmptyPendingIsAlsoBaseline() {
        let advice = NotificationDecider.advise(
            previousScheduledPending: nil,
            currentPending: [])
        #expect(advice == .baselineAfterLaunch)
    }

    // MARK: - No-change shapes

    /// Semantically equal multisets (same names, arbitrary order — order
    /// never matters) stay quiet.
    @Test
    func equalPendingSetInAnyOrderIsNoChange() {
        let advice = NotificationDecider.advise(
            previousScheduledPending: ["Alpha", "Beta"],
            currentPending: ["Beta", "Alpha"])
        #expect(advice == .noChange)
    }

    /// [] → [] AFTER the first fire is a real ran-and-quiet fire: noChange,
    /// NOT baseline (the nil-vs-empty distinction, second half).
    @Test
    func emptyToEmptyAfterRanIsNoChangeNotBaseline() {
        let advice = NotificationDecider.advise(
            previousScheduledPending: [],
            currentPending: [])
        #expect(advice == .noChange)
    }

    // MARK: - Diff shapes

    /// An app transitioning INTO pending after a quiet fired baseline IS
    /// news — this is the case baseline suppression must never swallow.
    @Test
    func firstPendingAfterQuietBaselineIsNews() {
        let advice = NotificationDecider.advise(
            previousScheduledPending: [],
            currentPending: ["Alpha"])
        #expect(advice == .newlyPending(names: ["Alpha"]))
    }

    /// Two additions surface both, sorted ascending (stable order for the
    /// summary body).
    @Test
    func twoAdditionsSurfaceBothSorted() {
        let advice = NotificationDecider.advise(
            previousScheduledPending: ["Zebra", "Mint"],
            currentPending: ["Zebra", "Mint", "Beta", "Apple"])
        #expect(advice == .newlyPending(names: ["Apple", "Beta"]))
    }

    /// Mixed add+remove: only the ADDS surface. Apps that left the pending
    /// set are recovery, and recovery is not news.
    @Test
    func mixedAddAndRemoveYieldsOnlyAdds() {
        let advice = NotificationDecider.advise(
            previousScheduledPending: ["Alpha", "Beta"],
            currentPending: ["Beta", "Gamma", "Delta"])
        #expect(advice == .newlyPending(names: ["Delta", "Gamma"]))
    }

    /// A REMOVAL-ONLY diff (apps recovered, nothing new) stays quiet — the
    /// documented consequence of "otherwise = current-minus-previous" with
    /// zero additions (recovery is not news; the window list shows it).
    @Test
    func removalOnlyDiffIsNoChange() {
        let advice = NotificationDecider.advise(
            previousScheduledPending: ["Alpha", "Beta"],
            currentPending: ["Alpha"])
        #expect(advice == .noChange)
    }

    /// Duplicate names in current never fabricate additions against a
    /// single prior name; output is the DEDUPED sorted set.
    @Test
    func duplicatesDoNotFabricateAddsAndOutputIsDedupedSorted() {
        let advice = NotificationDecider.advise(
            previousScheduledPending: ["Alpha"],
            currentPending: ["Alpha", "Alpha", "Beta", "Beta", "Alpha"])
        #expect(advice == .newlyPending(names: ["Beta"]))
    }
}
