// NotificationActionTests — PURE decision tests for the actionable
// notification surface: the frozen identifiers, the planner (which fires get
// actions and which app they name), and the router (what a response means).
// Swift Testing, NOT XCTest (XCTest discovery is broken on this toolchain —
// AGENTS.md gotcha ledger); Foundation imported explicitly because Swift
// Testing does not re-export it. No I/O, no fixtures, NO
// UNUserNotificationCenter — the UserNotifications import here is ONLY to
// byte-verify the mirrored default-action constant against Apple's.
// Tier-2 gap "notify-actions" lane · exclusive file of this lane.

import Foundation
import Testing
import UserNotifications
@testable import AppUpdaterCore

// MARK: - Frozen identifier surface

@Suite
struct NotificationActionIDsTests {

    /// Every identifier lives in the app's reverse-DNS space — a collision
    /// with any other app's category would be a silent cross-contamination.
    @Test
    func identifiersAreNamespaced() {
        #expect(NotificationActionIDs.categoryPendingUpdate
            .hasPrefix("io.appupdater.AppUpdater."))
        #expect(NotificationActionIDs.actionOpen
            .hasPrefix("io.appupdater.AppUpdater."))
        #expect(NotificationActionIDs.actionStageInstall
            .hasPrefix("io.appupdater.AppUpdater."))
    }

    /// The action identifiers are distinct from the category identifier and
    /// from each other — one collision would route a tap to the wrong
    /// handler (the router switches on exact equality).
    @Test
    func identifiersAreDistinct() {
        let all = [
            NotificationActionIDs.categoryPendingUpdate,
            NotificationActionIDs.actionOpen,
            NotificationActionIDs.actionStageInstall,
            NotificationActionIDs.defaultActionIdentifier,
        ]
        #expect(Set(all).count == all.count)
    }

    /// BYTE VERIFICATION of the mirrored constant: core stays
    /// framework-free, so ``NotificationActionIDs/defaultActionIdentifier``
    /// carries Apple's `UNNotificationDefaultActionIdentifier` as a literal.
    /// If Apple ever changed the constant, the router's body-tap branch
    /// would silently die — this test is the tripwire.
    @Test
    func defaultActionIdentifierMatchesAppleConstant() {
        #expect(NotificationActionIDs.defaultActionIdentifier
            == UNNotificationDefaultActionIdentifier)
    }

    /// The payload builder emits ONLY plist-safe Strings under the frozen
    /// keys — the same round-trip guarantee the scheduledFire payload has.
    @Test
    func pendingUpdateUserInfoIsStringValuedUnderFrozenKeys() {
        let payload = NotificationActionIDs.pendingUpdateUserInfo(
            appName: "Ghostty", bundleID: "com.mitchellh.ghostty")
        #expect(payload == [
            NotificationActionIDs.keyAppName: "Ghostty",
            NotificationActionIDs.keyBundleID: "com.mitchellh.ghostty",
        ])
        // Every value survives a plist round-trip as String (the shape the
        // delegate casts to).
        let data = try? PropertyListSerialization.data(
            fromPropertyList: payload, format: .binary, options: 0)
        let round = try? PropertyListSerialization.propertyList(
            from: data ?? Data(), options: [], format: nil) as? [String: String]
        #expect(round == payload)
    }
}

// MARK: - Planner (which fires get actions, which app they name)

@Suite
struct NotificationActionPlannerTests {

    private func candidate(
        _ name: String, _ bundleID: String, stageable: Bool = true
    ) -> NotificationActionPlanner.PendingCandidate {
        NotificationActionPlanner.PendingCandidate(
            appName: name, bundleID: bundleID, stageable: stageable)
    }

    /// The core shape: one newly pending app, resolvable, stageable → the
    /// actionable notification naming exactly that app.
    @Test
    func singleResolvableStageableNameIsActionable() {
        let plan = NotificationActionPlanner.plan(
            newlyPendingNames: ["Ghostty"],
            candidates: [candidate("Ghostty", "com.mitchellh.ghostty")])
        #expect(plan == .actionableSingleApp(
            name: "Ghostty", bundleID: "com.mitchellh.ghostty"))
    }

    /// Unrelated candidates never interfere — the planner picks by name.
    @Test
    func unrelatedCandidatesAreIgnored() {
        let plan = NotificationActionPlanner.plan(
            newlyPendingNames: ["Ghostty"],
            candidates: [
                candidate("Chrome", "com.google.Chrome"),
                candidate("Ghostty", "com.mitchellh.ghostty"),
                candidate("AdGuard", "com.adguard.mac"),
            ])
        #expect(plan == .actionableSingleApp(
            name: "Ghostty", bundleID: "com.mitchellh.ghostty"))
    }

    /// More than one newly pending name stays on the PASSIVE summary — a
    /// "Stage Install Command" button would have to guess which app.
    @Test
    func twoNewlyPendingNamesStayPassive() {
        let plan = NotificationActionPlanner.plan(
            newlyPendingNames: ["Alpha", "Beta"],
            candidates: [
                candidate("Alpha", "a.id"), candidate("Beta", "b.id"),
            ])
        #expect(plan == .passiveSummary(names: ["Alpha", "Beta"]))
    }

    /// A name that matches no candidate row never yields an actionable
    /// notification (honest total-function shape: the names come from the
    /// same rows in the real pipeline; a mismatch degrades to the summary,
    /// never to a guessed bundle ID).
    @Test
    func unmatchedNameStaysPassive() {
        let plan = NotificationActionPlanner.plan(
            newlyPendingNames: ["Ghostty"],
            candidates: [candidate("Chrome", "com.google.Chrome")])
        #expect(plan == .passiveSummary(names: ["Ghostty"]))
    }

    /// Name matching is EXACT and case-sensitive — the same discipline the
    /// decider's name sets use ("alpha" does not resolve "Alpha").
    @Test
    func nameMatchingIsCaseSensitive() {
        let plan = NotificationActionPlanner.plan(
            newlyPendingNames: ["ghostty"],
            candidates: [candidate("Ghostty", "com.mitchellh.ghostty")])
        #expect(plan == .passiveSummary(names: ["ghostty"]))
    }

    /// The same-name collision: two DISTINCT bundle IDs behind one name make
    /// staging a guess — the fire stays on the passive summary.
    @Test
    func sameNameTwoBundleIDsIsAmbiguousAndStaysPassive() {
        let plan = NotificationActionPlanner.plan(
            newlyPendingNames: ["VLC"],
            candidates: [
                candidate("VLC", "org.videolan.vlc"),
                candidate("VLC", "org.videolan.vlc.nightly"),
            ])
        #expect(plan == .passiveSummary(names: ["VLC"]))
    }

    /// Duplicate rows of the SAME app (same name, same bundle ID) collapse —
    /// they never make an unambiguous app look ambiguous.
    @Test
    func duplicateRowsOfSameAppStayActionable() {
        let plan = NotificationActionPlanner.plan(
            newlyPendingNames: ["Ghostty"],
            candidates: [
                candidate("Ghostty", "com.mitchellh.ghostty"),
                candidate("Ghostty", "com.mitchellh.ghostty"),
            ])
        #expect(plan == .actionableSingleApp(
            name: "Ghostty", bundleID: "com.mitchellh.ghostty"))
    }

    /// Mac App Store apps are never stageable by the existing consent
    /// boundary (the window hides its Stage button for them) — a MAS-only
    /// fire keeps the EXISTING passive summary.
    @Test
    func nonStageableCandidateStaysPassive() {
        let plan = NotificationActionPlanner.plan(
            newlyPendingNames: ["AdGuard"],
            candidates: [candidate("AdGuard", "com.adguard.mac", stageable: false)])
        #expect(plan == .passiveSummary(names: ["AdGuard"]))
    }

    /// An EMPTY bundle ID is unresolvable: staging it would silently do
    /// nothing, so the planner refuses to the summary instead.
    @Test
    func emptyBundleIDStaysPassive() {
        let plan = NotificationActionPlanner.plan(
            newlyPendingNames: ["Mystery"],
            candidates: [candidate("Mystery", "")])
        #expect(plan == .passiveSummary(names: ["Mystery"]))
    }

    /// Zero names is the decider-impossible shape the total function still
    /// answers honestly: a passive (empty) summary the caller posts nothing
    /// for — never an actionable notification.
    @Test
    func emptyNamesYieldPassiveEmptySummary() {
        let plan = NotificationActionPlanner.plan(
            newlyPendingNames: [], candidates: [])
        #expect(plan == .passiveSummary(names: []))
    }

    /// Stageability over one bundle ID backed by several rows is ANY-row
    /// semantics: the rows are the same app; if the boundary stages it once
    /// it stages it.
    @Test
    func stageabilityIsAnyRowOverTheSingleBundleID() {
        let plan = NotificationActionPlanner.plan(
            newlyPendingNames: ["Ghostty"],
            candidates: [
                candidate("Ghostty", "com.mitchellh.ghostty", stageable: false),
                candidate("Ghostty", "com.mitchellh.ghostty", stageable: true),
            ])
        #expect(plan == .actionableSingleApp(
            name: "Ghostty", bundleID: "com.mitchellh.ghostty"))
    }
}

// MARK: - Router (what a delivered response means)

@Suite
struct NotificationActionRouterTests {

    private func payload(
        bundleID: String? = "com.mitchellh.ghostty",
        appName: String? = "Ghostty"
    ) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [:]
        if let bundleID { info[NotificationActionIDs.keyBundleID] = bundleID }
        if let appName { info[NotificationActionIDs.keyAppName] = appName }
        return info
    }

    /// The category's "Open AppUpdater" action opens the main window.
    @Test
    func openActionRoutesToOpenMainWindow() {
        let outcome = NotificationActionRouter.route(
            actionIdentifier: NotificationActionIDs.actionOpen,
            userInfo: payload())
        #expect(outcome == .openMainWindow)
    }

    /// Tapping the notification BODY (either shape) opens the main window —
    /// the body tap has always meant "show me".
    @Test
    func defaultBodyTapRoutesToOpenMainWindow() {
        let outcome = NotificationActionRouter.route(
            actionIdentifier: NotificationActionIDs.defaultActionIdentifier,
            userInfo: payload())
        #expect(outcome == .openMainWindow)
    }

    /// "Stage Install Command" routes the NAMED app's bundle ID through the
    /// consent boundary — the outcome carries both strings verbatim.
    @Test
    func stageActionRoutesBundleAndName() {
        let outcome = NotificationActionRouter.route(
            actionIdentifier: NotificationActionIDs.actionStageInstall,
            userInfo: payload())
        #expect(outcome == .stageInstall(
            bundleID: "com.mitchellh.ghostty", appName: "Ghostty"))
    }

    /// A stage action with NO bundle ID in the payload is ignored — staging
    /// an unnamed app would be a guess, and the boundary is never a guess.
    @Test
    func stageActionWithoutBundleIDIsIgnored() {
        let outcome = NotificationActionRouter.route(
            actionIdentifier: NotificationActionIDs.actionStageInstall,
            userInfo: payload(bundleID: nil))
        #expect(outcome == .ignored)
    }

    /// An EMPTY bundle ID is ignored for the same reason.
    @Test
    func stageActionWithEmptyBundleIDIsIgnored() {
        let outcome = NotificationActionRouter.route(
            actionIdentifier: NotificationActionIDs.actionStageInstall,
            userInfo: payload(bundleID: ""))
        #expect(outcome == .ignored)
    }

    /// A missing appName degrades ONLY the naming (falls back to the bundle
    /// ID) — staging still works; malformed payloads never block the
    /// documented action.
    @Test
    func stageActionWithoutAppNameFallsBackToBundleID() {
        let outcome = NotificationActionRouter.route(
            actionIdentifier: NotificationActionIDs.actionStageInstall,
            userInfo: payload(appName: nil))
        #expect(outcome == .stageInstall(
            bundleID: "com.mitchellh.ghostty", appName: "com.mitchellh.ghostty"))
    }

    /// Non-String values under the frozen keys are honest absence (never a
    /// lossy cast) — a numeric bundle ID is ignored, not coerced.
    @Test
    func nonStringBundleIDIsIgnored() {
        var info: [AnyHashable: Any] = [:]
        info[NotificationActionIDs.keyBundleID] = 42
        info[NotificationActionIDs.keyAppName] = "Ghostty"
        let outcome = NotificationActionRouter.route(
            actionIdentifier: NotificationActionIDs.actionStageInstall,
            userInfo: info)
        #expect(outcome == .ignored)
    }

    /// Unknown action identifiers (dismissals, other apps' categories,
    /// anything unregistered) execute nothing.
    @Test
    func unknownActionIsIgnored() {
        let outcome = NotificationActionRouter.route(
            actionIdentifier: "io.appupdater.AppUpdater.action.doesNotExist",
            userInfo: payload())
        #expect(outcome == .ignored)
    }
}
