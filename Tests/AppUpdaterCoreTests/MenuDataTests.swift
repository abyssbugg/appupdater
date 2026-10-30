// MenuData tests — lane "menudata" (Phase 4).
// Pure construction only: no AppKit, no timers, no engine calls. Swift Testing
// (XCTest discovery is broken on this toolchain — see gotcha ledger).
// Determinism contract: two constructions with identical inputs are EQUAL,
// and a different `now` honestly changes the schedule countdown line.

import Testing
import Foundation
@testable import AppUpdaterCore

@Suite(.serialized)
struct MenuDataTests {
    /// Fixed anchor date (2026-10-26T12:00:00Z); never Date() in these tests.
    private let fixedNow = Date(timeIntervalSince1970: 1_790_006_400)
    private let offSnapshot = ScheduleSnapshot(
        policy: SchedulePolicy(intervalMinutes: 0),
        state: ScheduleState()
    )

    // MARK: Row fixtures (verdict strings mirror UpdateCheck.computeVerdict)

    private func makeRow(
        name: String,
        bid: String,
        verdict: String,
        isMAS: Bool = false,
        decision: RuleDecision = RuleDecision()
    ) -> AppRow {
        let app = InstalledApp(
            bundleIdentifier: bid,
            name: name,
            path: "/Applications/\(bid).app",
            isMacAppStore: isMAS
        )
        let check: UpdateCheck
        switch verdict {
        case "update":
            check = UpdateCheck(
                app: app,
                candidates: [UpdateInfo(source: .mas, newestShortVersion: "9.9")],
                failures: [],
                resolved: UpdateInfo(source: .cask, newestShortVersion: "9.9")
            )
        case "current":
            check = UpdateCheck(
                app: app,
                candidates: [UpdateInfo(source: .cask, newestShortVersion: "1.2.3")],
                failures: [],
                resolved: nil
            )
        case "failed":
            check = UpdateCheck(
                app: app,
                candidates: [],
                failures: [CheckSourceFailure(kind: .cask, message: "boom")],
                resolved: nil
            )
        default:
            // "unknown": sources ran, produced nothing.
            check = UpdateCheck(app: app, candidates: [], failures: [], resolved: nil)
        }
        return AppRow(app: app, check: check, decision: decision)
    }

    // MARK: Emoji honesty check (pure scalar-range test, no AppKit)

    private func containsEmojiGlyph(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation
                || (0x1F000...0x1FAFF).contains(Int(scalar.value)) // emoji blocks
                || (0x2600...0x27BF).contains(Int(scalar.value)) // misc symbols / dingbats
                || scalar.value == 0xFE0F // variation selector-16 (emoji forcing)
        }
    }

    // MARK: 1 — empty rows

    @Test func emptyRowsGiveZeroCountsContractHeadlineAndOffLine() {
        let data = MenuData(appRowSummary: [], schedule: offSnapshot, now: fixedNow)

        #expect(data.counts.pending == 0)
        #expect(data.counts.total == 0)
        #expect(data.pendingSection.updates.isEmpty)
        #expect(data.pendingSection.actions.isEmpty)

        let labels = data.headline.map(\.label)
        let ids: [MenuAction.ID] = [.checkNow, .openMainWindow, .quit]
        #expect(labels == ["Check for Updates", "Open AppUpdater", "Quit"])
        #expect(data.headline.map(\.id) == ids)

        #expect(data.scheduleSection.contains("Automatic checks: off"))
    }

    // MARK: 2 — mixed rows: MAS honesty DELIBERATE distinction

    /// Mixed rows: 1 non-MAS update + 2 current + 1 MAS update.
    /// Sub-agent brief note documented: the tempting literal "pending = 1" is
    /// WRONG and the brief's own parenthetical corrects it — a MAS row with a
    /// version-different claim IS an "update available" (AppRow.updateAvailable
    /// is true), so counts stay TRUTHFUL (pending = 2 of 4 total). Only the
    /// install affordance differs: installNow is REPLACED by a
    /// Store-mandated label; Store apps cannot be user-space installed
    /// (MacUpdater parity). Rule ignores are what exclude rows — never MAS-hood.
    @Test func mixedRowsCountMASUpdatesTruthfullyWithStoreBoundAction() {
        let zetaUpdate = makeRow(name: "Zeta Edit", bid: "com.example.zeta", verdict: "update")
        let aquaMAS = makeRow(name: "Aqua Store", bid: "com.example.aqua", verdict: "update", isMAS: true)
        let currentOne = makeRow(name: "Beta Current", bid: "com.example.beta", verdict: "current")
        let currentTwo = makeRow(name: "Gamma Current", bid: "com.example.gamma", verdict: "current")

        // Deliberately inserted out of alphabetical order: array must come back sorted.
        let data = MenuData(
            appRowSummary: [zetaUpdate, currentOne, aquaMAS, currentTwo],
            schedule: offSnapshot,
            now: fixedNow
        )

        #expect(data.pendingSection.updates.map { $0.app.name } == ["Aqua Store", "Zeta Edit"])
        #expect(data.counts.pending == 2) // Aqua (MAS) IS pending — counts truthful
        #expect(data.counts.total == 4)

        let actionIDs = data.pendingSection.actions.map(\.id)
        #expect(actionIDs == [
            .viewDetails(bundleID: "com.example.aqua"), // MAS: installNow REPLACED
            .installNow(bundleID: "com.example.zeta"),
            .viewDetails(bundleID: "com.example.zeta"),
        ])
        #expect(data.pendingSection.actions[0].label == "View Details: Aqua Store — update available in the Mac App Store")
        #expect(data.pendingSection.actions[1].label == "Stage Install: Zeta Edit")
        #expect(data.pendingSection.actions[2].label == "View Details: Zeta Edit")
    }

    // MARK: 3 — ignoreBundle respected (RuleDecision honored)

    @Test func ignoreBundleRowExcludedFromPendingAndCounts() {
        let ignored = makeRow(
            name: "Silent App",
            bid: "com.example.silent",
            verdict: "update",
            decision: RuleDecision(ignoredBundle: true)
        )
        let data = MenuData(appRowSummary: [ignored], schedule: offSnapshot, now: fixedNow)

        #expect(data.pendingSection.updates.isEmpty)
        #expect(data.pendingSection.actions.isEmpty)
        #expect(data.counts.pending == 0)
        #expect(data.counts.total == 1) // still inventoried — honest total
        #expect(MenuData.actions(for: ignored).isEmpty)
    }

    // MARK: 4 — ignoreVersion respected for the pinned claim only

    /// Frozen-contract semantics: the rule Evaluator (Lane 2) computes
    /// `decision.ignoredVersion` per (app, claim-version) pair; MenuData reads
    /// the decision verbatim and never re-compares versions. Here the
    /// pinned claim (3.0) is ignored for Bravo, while the same app with an
    /// UN-ignored newer claim (4.0) stays pending.
    @Test func ignoreVersionExcludesPinnedClaimButIncludesOtherClaims() {
        let pinnedRow = makeRow(
            name: "Bravo",
            bid: "com.example.bravo",
            verdict: "update",
            decision: RuleDecision(ignoredVersion: true)
        )
        // Same app identity, a DIFFERENT claim that the rule set does not pin:
        let freshApp = InstalledApp(bundleIdentifier: "com.example.bravo", name: "Bravo", path: "/Applications/com.example.bravo.app")
        let freshClaimRow = AppRow(
            app: freshApp,
            check: UpdateCheck(
                app: freshApp,
                candidates: [],
                failures: [],
                resolved: UpdateInfo(source: .cask, newestShortVersion: "4.0")
            ),
            decision: RuleDecision(ignoredVersion: false)
        )
        // The ignore rule that produced pinnedRow.decision, for documentation value:
        _ = IgnoreRule(kind: .ignoreVersion, bundleIdentifier: "com.example.bravo", version: "3.0")

        let data = MenuData(appRowSummary: [pinnedRow, freshClaimRow], schedule: offSnapshot, now: fixedNow)

        #expect(data.pendingSection.updates.map { $0.check?.verdict } == ["update"])
        #expect(data.pendingSection.updates.map { $0.check?.resolved?.newestShortVersion } == ["4.0"])
        #expect(data.counts.pending == 1)
        #expect(data.counts.total == 2)
    }

    // MARK: 5 — schedule: future next fire with countdown

    @Test func scheduleLinesMentionFutureNextFireWithUTCCountdown() {
        let last = fixedNow.addingTimeInterval(-3_600) // fired 1h ago
        let snapshot = ScheduleSnapshot(
            policy: SchedulePolicy(intervalMinutes: 240, skipOnBattery: true, onWakeCatchUp: true),
            state: ScheduleState(lastFireAt: last, lastFireAppsChecked: 82, lastFireWasCatchUp: false, lastFireError: nil)
        )
        let data = MenuData(appRowSummary: [], schedule: snapshot, now: fixedNow)

        let next = last.addingTimeInterval(TimeInterval(240 * 60))
        #expect(data.scheduleSection[0].hasPrefix("Next automatic check:"))
        #expect(data.scheduleSection[0].contains(MenuData.clockText(next)))
        #expect(data.scheduleSection[0].contains("UTC"))
        #expect(data.scheduleSection[0].contains("in 3h 0m"))
        #expect(data.scheduleSection.contains("Last automatic check: \(MenuData.clockText(last)) UTC (checked 82 apps)"))
    }

    // MARK: 5 — schedule: missed slot → catch-up honesty (both directions)

    @Test func scheduleLinesFlagOverdueCatchUpAndLastFireCatchUp() {
        // Next fire slot is 1h in the PAST (missed while asleep), catch-up on:
        let overdue = ScheduleSnapshot(
            policy: SchedulePolicy(intervalMinutes: 240, skipOnBattery: true, onWakeCatchUp: true),
            state: ScheduleState(lastFireAt: fixedNow.addingTimeInterval(-5 * 3_600))
        )
        let overdueData = MenuData(appRowSummary: [], schedule: overdue, now: fixedNow)
        #expect(overdueData.scheduleSection.contains("Automatic check overdue — catch-up pending"))

        // The last fire itsELF was a wake catch-up:
        let lastWasCatchUp = ScheduleSnapshot(
            policy: SchedulePolicy(intervalMinutes: 240, skipOnBattery: true, onWakeCatchUp: true),
            state: ScheduleState(
                lastFireAt: fixedNow.addingTimeInterval(-600),
                lastFireAppsChecked: 7,
                lastFireWasCatchUp: true
            )
        )
        let catchUpData = MenuData(appRowSummary: [], schedule: lastWasCatchUp, now: fixedNow)
        #expect(catchUpData.scheduleSection.contains("Last check was a wake catch-up for a missed slot"))

        // Catch-up disabled: overdue equally honest, no pretend clock:
        let noCatchUp = ScheduleSnapshot(
            policy: SchedulePolicy(intervalMinutes: 240, skipOnBattery: true, onWakeCatchUp: false),
            state: ScheduleState(lastFireAt: fixedNow.addingTimeInterval(-5 * 3_600))
        )
        let noCatchUpData = MenuData(appRowSummary: [], schedule: noCatchUp, now: fixedNow)
        #expect(noCatchUpData.scheduleSection.contains("Automatic check overdue — waiting for the next slot"))
        #expect(!noCatchUpData.scheduleSection.contains { $0.contains("catch-up") })
    }

    // MARK: 5 — schedule: never-ran + verbatim-ish error honesty

    @Test func scheduleLinesShowNeverRanAndVerbatimError() {
        let neverData = MenuData(appRowSummary: [], schedule: offSnapshot, now: fixedNow)
        #expect(neverData.scheduleSection.contains("Last automatic check: never"))

        let onScheduleNeverRan = ScheduleSnapshot(
            policy: SchedulePolicy(intervalMinutes: 240),
            state: ScheduleState()
        )
        let data = MenuData(appRowSummary: [], schedule: onScheduleNeverRan, now: fixedNow)
        #expect(data.scheduleSection[0].hasPrefix("Next automatic check:"))
        #expect(data.scheduleSection.contains("Last automatic check: never"))

        let failure = ScheduleSnapshot(
            policy: SchedulePolicy(intervalMinutes: 240),
            state: ScheduleState(lastFireAt: fixedNow.addingTimeInterval(-3_600), lastFireError: "lookup failed: no route to host")
        )
        let errored = MenuData(appRowSummary: [], schedule: failure, now: fixedNow)
        #expect(errored.scheduleSection.contains("Last check error: lookup failed: no route to host"))
    }

    // MARK: 6 — labels: plain text, no emoji, no empty trays, installNow rule

    @Test func labelsArePlainNonEmptyAndInstallNowOnlyForNonMASPendingRows() {
        let updateRow = makeRow(name: "Pluto Edit", bid: "com.example.pluto", verdict: "update")
        let masUpdate = makeRow(name: "Orbit Store", bid: "com.example.orbit", verdict: "update", isMAS: true)
        let currentRow = makeRow(name: "Kilo Current", bid: "com.example.kilo", verdict: "current")
        let unknownRow = makeRow(name: "Juliet Unknown", bid: "com.example.juliet", verdict: "unknown")
        let ignoredRow = makeRow(
            name: "Ignoramus",
            bid: "com.example.ignoramus",
            verdict: "update",
            decision: RuleDecision(ignoredBundle: true)
        )
        let data = MenuData(
            appRowSummary: [updateRow, masUpdate, currentRow, unknownRow, ignoredRow],
            schedule: offSnapshot,
            now: fixedNow
        )

        let everyLabel = data.headline.map(\.label) + data.pendingSection.actions.map(\.label)
        for label in everyLabel {
            #expect(!label.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(!containsEmojiGlyph(label))
        }
        for line in data.scheduleSection {
            #expect(!line.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(!containsEmojiGlyph(line))
        }

        // Pending rows guarantee a non-empty tray (every pending row has >= 1 action):
        #expect(!data.pendingSection.updates.isEmpty)
        #expect(!data.pendingSection.actions.isEmpty)
        #expect(data.pendingSection.actions.count >= data.pendingSection.updates.count)

        // installNow is offered ONLY for non-MAS pending rows — crash-safe empty
        // source for bundle IDs is impossible here because actions are derived...
        for action in data.pendingSection.actions {
            switch action.id {
            case .installNow(let bundleID):
                let row = data.pendingSection.updates.first { $0.app.bundleIdentifier == bundleID }
                #expect(row?.app.isMacAppStore == false)
            case .viewDetails, .checkNow, .openMainWindow, .openSettings, .quit:
                break
            }
        }
    }

    // MARK: actions(for:) DRY helper contract

    @Test func actionsForRowMatchesPerRowContract() {
        let current = makeRow(name: "Quiet App", bid: "com.example.quiet", verdict: "current")
        #expect(MenuData.actions(for: current).isEmpty)

        let upsell = makeRow(name: "Sierra Edit", bid: "com.example.sierra", verdict: "update")
        #expect(MenuData.actions(for: upsell).map(\.id) == [
            .installNow(bundleID: "com.example.sierra"),
            .viewDetails(bundleID: "com.example.sierra"),
        ])
        #expect(MenuData.actions(for: upsell).map(\.label) == [
            "Stage Install: Sierra Edit",
            "View Details: Sierra Edit",
        ])

        let storeApp = makeRow(name: "Photo Store", bid: "com.example.photo", verdict: "update", isMAS: true)
        let storeActions = MenuData.actions(for: storeApp)
        #expect(storeActions.count == 1)
        #expect(storeActions.map(\.id) == [.viewDetails(bundleID: "com.example.photo")])
        #expect(storeActions[0].label.contains("Mac App Store"))
        #expect(storeActions[0].label.contains("Photo Store"))
    }

    // MARK: 7 — determinism: same inputs → equal MenuData; `now` honestly matters

    @Test func constructionIsDeterministicAndNowSensitive() {
        let rows = [
            makeRow(name: "Tango Update", bid: "com.example.tango", verdict: "update"),
            makeRow(name: "Uniform Current", bid: "com.example.uniform", verdict: "current"),
            makeRow(name: "Victor Store", bid: "com.example.victor", verdict: "update", isMAS: true),
        ]
        let snapshot = ScheduleSnapshot(
            policy: SchedulePolicy(intervalMinutes: 240, skipOnBattery: true, onWakeCatchUp: true),
            state: ScheduleState(
                lastFireAt: fixedNow.addingTimeInterval(-3_600),
                lastFireAppsChecked: 42,
                lastFireWasCatchUp: false,
                lastFireError: nil
            )
        )

        let first = MenuData(appRowSummary: rows, schedule: snapshot, now: fixedNow)
        let second = MenuData(appRowSummary: rows, schedule: snapshot, now: fixedNow)
        #expect(first == second)

        // Same menu 7 minutes later: identical headline/pending/counts, but the
        // countdown line honestly shifts ("in 3h 0m" → "in 2h 53m").
        let later = MenuData(appRowSummary: rows, schedule: snapshot, now: fixedNow.addingTimeInterval(420 + 5))
        #expect(first.headline == later.headline)
        #expect(first.counts.pending == later.counts.pending)
        #expect(first.counts.total == later.counts.total)
        #expect(first != later)
        #expect(first.scheduleSection[0] != later.scheduleSection[0])
    }

    // MARK: MenuSection layout contract

    @Test func standardLayoutCarriesCanonicalSectionOrder() {
        #expect(MenuSection.standardLayout == [
            .headline, .pendingUpdates, .currentApps(count: 0), .schedule, .footer,
        ])
    }
}
