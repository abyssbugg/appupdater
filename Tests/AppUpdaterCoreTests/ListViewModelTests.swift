// ListViewModelTests — hermetic, seam-injected ONLY. Swift Testing (not
// XCTest): XCTest discovery is broken on this toolchain (Xcode 27 beta,
// AGENTS.md gotcha ledger). The VM is @MainActor, so the whole suite is
// annotated @MainActor — async tests hop where the VM lives, sync tests run
// main-confined too. No SwiftUI anywhere: the VM is Observation-only.
//
// Seam-recording discipline: @Sendable closures may not capture mutable
// locals in Swift 6.4, so scripted/recorded seams go through LockedBox —
// reusing the test-target's helper from CaskSourceTests.swift (existing
// cross-test-file pattern, also used by AppQuitTests).

import Foundation
import Testing
@testable import AppUpdaterCore

// MARK: - Fixtures

/// Verdict script applied through the real `UpdateCheck` constructors, so
/// fixture rows carry the SAME machine-lineage verdict strings the engine
/// produces ("update" / "current" / "unknown" / "failed").
private enum ProbeVerdict {
    case update
    case current
    case unknown
    case failed
    case neverChecked   // check == nil (no verdict string at all)
}

/// One recorded rule-mutator invocation (Sendable + Equatable for LockedBox
/// assertions).
private struct RecordedCall: Sendable, Equatable {
    let kind: RuleKind
    let bundleID: String
    let version: String?
}

private enum ProbeFailure: Error {
    case aborted
}

@Suite @MainActor
struct ListViewModelTests {

    private let older = Date(timeIntervalSince1970: 1_700_000_000)
    private var newer: Date { older.addingTimeInterval(60) }
    private var newest: Date { older.addingTimeInterval(120) }

    // MARK: helpers

    private func makeApp(bundleID: String, name: String, checkedAt: Date? = nil) -> InstalledApp {
        InstalledApp(
            bundleIdentifier: bundleID,
            name: name,
            path: "/Applications/\(name).app",
            checkedAt: checkedAt
        )
    }

    private func makeCheck(_ app: InstalledApp, _ verdict: ProbeVerdict) -> UpdateCheck? {
        switch verdict {
        case .update:
            // resolved non-nil => UpdateCheck computes verdict "update".
            return UpdateCheck(
                app: app,
                candidates: [],
                resolved: UpdateInfo(source: .cask, newestShortVersion: "9.9.9")
            )
        case .current:
            return UpdateCheck(
                app: app,
                candidates: [UpdateInfo(source: .cask, newestShortVersion: "1.0")],
                resolved: nil
            )
        case .unknown:
            return UpdateCheck(app: app, candidates: [], resolved: nil)
        case .failed:
            return UpdateCheck(
                app: app,
                candidates: [],
                failures: [CheckSourceFailure(kind: .cask, message: "fixture probe failed")],
                resolved: nil
            )
        case .neverChecked:
            return nil
        }
    }

    private func makeRow(
        bundleID: String,
        name: String,
        verdict: ProbeVerdict,
        decision: RuleDecision = RuleDecision(),
        checkedAt: Date? = nil
    ) -> AppRow {
        let app = makeApp(bundleID: bundleID, name: name, checkedAt: checkedAt)
        return AppRow(app: app, check: makeCheck(app, verdict), decision: decision)
    }

    private func makeVM(
        refreshSource: @escaping @MainActor @Sendable () async throws -> [AppRow] = { [] },
        ruleMutator: @escaping @MainActor @Sendable (RuleKind, String, String?) async throws -> [AppRow] = { _, _, _ in [] }
    ) -> ListViewModel {
        ListViewModel(refreshSource: refreshSource, ruleMutator: ruleMutator)
    }

    // MARK: - (1) empty state + zero stats

    @Test func emptyVMStartsHonestAndZero() {
        let vm = makeVM()

        #expect(vm.rows.isEmpty)
        #expect(vm.filteredRows.isEmpty)
        #expect(vm.stats == (pending: 0, total: 0, ignored: 0))
        #expect(vm.selection == nil)
        #expect(vm.lastError == nil)
        #expect(vm.row(for: "io.appupdater.tests.anything") == nil)
        #expect(vm.query == "")
        #expect(vm.sort == .name)
        #expect(vm.filter == .all)
    }

    // MARK: - (2) query filtering (5-row fixture, name + bundle id, both cases)

    @Test func queryFiltersNamesAndBundleIDsCaseInsensitively() async throws {
        let fixture = [
            makeRow(bundleID: "io.reader.zebra", name: "Zebra Reader", verdict: .current),
            makeRow(bundleID: "io.editor.alpha", name: "alpha Editor", verdict: .current),
            makeRow(bundleID: "io.mail.middle", name: "middle Mail", verdict: .current),
            makeRow(bundleID: "io.notes.beta", name: "Beta Notes", verdict: .current),
            makeRow(bundleID: "io.chat.gamma", name: "Gamma Chat", verdict: .neverChecked),
        ]
        let vm = makeVM()
        await vm.setRows(fixture)

        // Empty query = every row.
        #expect(vm.query == "" && vm.filteredRows.count == 5)

        // Name match, case-insensitive (query lowercase, name has caps).
        vm.setQuery("reader")
        #expect(vm.filteredRows.map(\.app.name) == ["Zebra Reader"])

        // Bundle-identifier match that the NAME cannot satisfy:
        // "Beta Notes" does not contain the substring "notes.beta".
        vm.setQuery("NOTES.BETA")
        #expect(vm.filteredRows.map(\.app.name) == ["Beta Notes"])

        // No hit at all.
        vm.setQuery("nothing-matches-this")
        #expect(vm.filteredRows.isEmpty)

        // Back to everything.
        vm.setQuery("")
        #expect(vm.filteredRows.count == 5)
    }

    // MARK: - (3a) name sort: case-insensitive asc + stable-id tie-break

    @Test func nameSortIsDeterministicCaseInsensitiveWithStableTieBreak() async throws {
        let bundleA = "io.appupdater.tests.same-tier-a"
        let bundleB = "io.appupdater.tests.same-tier-b"
        let fixture = [
            makeRow(bundleID: "io.appupdater.tests.zebra", name: "zebra", verdict: .current),
            makeRow(bundleID: "io.appupdater.tests.alpha", name: "Alpha", verdict: .current),
            makeRow(bundleID: "io.appupdater.tests.beta", name: "beta", verdict: .current),
            makeRow(bundleID: bundleA, name: "Same Name", verdict: .current),
            makeRow(bundleID: bundleB, name: "same name", verdict: .current),
        ]
        let vm = makeVM()
        await vm.setRows(fixture)
        vm.setSort(.name)

        let order = vm.filteredRows.map(\.app.bundleIdentifier)
        #expect(order == [
            "io.appupdater.tests.alpha",
            "io.appupdater.tests.beta",
            bundleA,  // equal names resolve by STABLE ID ascending, deterministically
            bundleB,
            "io.appupdater.tests.zebra",
        ])
    }

    // MARK: - (3b) updateFirst: pending first regardless of name, then name asc

    @Test func updateFirstPutsPendingFirstThenNameAscending() async throws {
        let pending = makeRow(bundleID: "io.appupdater.tests.pending", name: "zzz Pending", verdict: .update)
        let aaa = makeRow(bundleID: "io.appupdater.tests.aaa", name: "aaa Quiet", verdict: .current)
        // Verdict "update" but bundle-ignored => AppRow.updateAvailable is
        // FALSE, so it must NOT take the pending slot (frozen model's gating).
        let ignored = makeRow(
            bundleID: "io.appupdater.tests.mmm",
            name: "mmm Ignored",
            verdict: .update,
            decision: RuleDecision(ignoredBundle: true)
        )
        let vm = makeVM()
        await vm.setRows([aaa, ignored, pending])
        vm.setSort(.updateFirst)

        let order = vm.filteredRows.map(\.app.name)
        #expect(order == ["zzz Pending", "aaa Quiet", "mmm Ignored"])
    }

    // MARK: - (3c) recentlyChecked: nil last, then check date desc

    @Test func recentlyCheckedSortsNewestFirstAndNeverCheckedLast() async throws {
        let d1 = makeRow(bundleID: "io.appupdater.tests.d1", name: "newest check", verdict: .current, checkedAt: newest)
        let d2 = makeRow(bundleID: "io.appupdater.tests.d2", name: "middle check", verdict: .current, checkedAt: newer)
        let d3 = makeRow(bundleID: "io.appupdater.tests.d3", name: "oldest check", verdict: .current, checkedAt: older)
        let n1 = makeRow(bundleID: "io.appupdater.tests.na", name: "never checked a", verdict: .neverChecked)
        let n2 = makeRow(bundleID: "io.appupdater.tests.nb", name: "never checked b", verdict: .unknown)
        let vm = makeVM()
        await vm.setRows([n1, d3, n2, d1, d2])
        vm.setSort(.recentlyChecked)

        let order = vm.filteredRows.map(\.app.name)
        #expect(order == [
            "newest check",
            "middle check",
            "oldest check",
            "never checked a",  // nil checkedAt rows go last, stable-id order
            "never checked b",
        ])
    }

    // MARK: - (4) filter modes respect RuleDecision

    @Test func pendingOnlyFilterIsEmptyWhenEveryRowIsIgnored() async throws {
        // One even claims "update" — the frozen AppRow gating (ignoredBundle)
        // must keep it out of pendingOnly regardless.
        let fixture = [
            makeRow(bundleID: "io.ign.1", name: "Ignored One", verdict: .update,
                    decision: RuleDecision(ignoredBundle: true)),
            makeRow(bundleID: "io.ign.2", name: "Ignored Two", verdict: .current,
                    decision: RuleDecision(ignoredBundle: true)),
            makeRow(bundleID: "io.ign.3", name: "Ignored Three", verdict: .neverChecked,
                    decision: RuleDecision(ignoredBundle: true)),
        ]
        let vm = makeVM()
        await vm.setRows(fixture)
        vm.setFilter(.pendingOnly)

        #expect(vm.filteredRows.isEmpty)
        #expect(vm.stats.pending == 0)

        // ignoredOnly is exactly the bundle-ignored rows. Order is the
        // default name sort: One < Three < Two (case-insensitive "three"
        // precedes "two" — h < w), NOT bundle-id numeric order.
        vm.setFilter(.ignoredOnly)
        #expect(vm.filteredRows.map(\.app.name) == ["Ignored One", "Ignored Three", "Ignored Two"])

        // all restores everything.
        vm.setFilter(.all)
        #expect(vm.filteredRows.count == 3)
    }

    @Test func ignoredOnlyFilterSelectsExactlyBundleIgnoredRows() async throws {
        let plain = makeRow(bundleID: "io.mix.plain", name: "Plain", verdict: .current)
        let bundleIgnored = makeRow(bundleID: "io.mix.bundle", name: "Bundle Ignored", verdict: .update,
                                    decision: RuleDecision(ignoredBundle: true))
        let versionIgnored = makeRow(bundleID: "io.mix.version", name: "Version Ignored", verdict: .update,
                                     decision: RuleDecision(ignoredVersion: true))
        let vm = makeVM()
        await vm.setRows([plain, bundleIgnored, versionIgnored])
        vm.setFilter(.ignoredOnly)

        // Version-ignored rows are NOT bundle-ignored: they stay visible
        // (the owner may want to un-ignore one specific version claim).
        #expect(vm.filteredRows.map(\.app.name) == ["Bundle Ignored"])
        #expect(vm.stats.ignored == 1)
    }

    // MARK: - (5) selection survival across setRows

    @Test func setRowsClearsSelectionOnlyWhenRowVanished() async throws {
        let a = makeRow(bundleID: "io.sel.a", name: "Alpha", verdict: .current)
        let b = makeRow(bundleID: "io.sel.b", name: "Beta", verdict: .current)
        let vm = makeVM()

        await vm.setRows([a])
        vm.select(a.id)
        #expect(vm.selection == a.id)

        // Same row still present (fresh scan) => selection retained.
        await vm.setRows([a, b])
        #expect(vm.selection == a.id)

        // Row vanished => selection cleared honestly.
        await vm.setRows([b])
        #expect(vm.selection == nil)
    }

    // MARK: - (6) refresh: success replaces, failure is honest

    @Test func refreshSuccessReplacesRowsAndClearsStaleError() async throws {
        let source = [
            makeRow(bundleID: "io.refresh.one", name: "One", verdict: .current),
        ]
        let refuseFirst = LockedBox<Bool>(true)
        let refreshSource: @MainActor @Sendable () async throws -> [AppRow] = { () async throws -> [AppRow] in
            let refuse = refuseFirst.with { flag -> Bool in
                let old = flag
                flag = false
                return old
            }
            if refuse { throw ProbeFailure.aborted }
            return source
        }
        let vm = makeVM(refreshSource: refreshSource)

        // First call fails: rows untouched, error surfaced.
        await vm.refresh()
        #expect(vm.rows.isEmpty)
        #expect(vm.lastError != nil)

        // Second call succeeds: rows replaced, stale error cleared.
        await vm.refresh()
        #expect(vm.rows == source)
        #expect(vm.lastError == nil)
    }

    @Test func refreshFailureKeepsRowsAndSelectionAndReportsLastError() async throws {
        let a = makeRow(bundleID: "io.keep.a", name: "Alpha", verdict: .current)
        let refreshSource: @MainActor @Sendable () async throws -> [AppRow] = { () async throws -> [AppRow] in
            throw ProbeFailure.aborted
        }
        let vm = makeVM(refreshSource: refreshSource)
        await vm.setRows([a])
        vm.select(a.id)

        await vm.refresh()

        // Honest refusal: nothing fabricated, nothing dropped.
        #expect(vm.rows.count == 1 && vm.rows.first?.id == a.id)
        #expect(vm.selection == a.id)
        #expect(vm.lastError?.contains("aborted") == true)
    }

    // MARK: - (7) ignore actions: right RuleKind, fresh rows, selection kept

    @Test func ignoreBundleAppliesMutatorReturnAndPreservesSelection() async throws {
        let calls = LockedBox<[RecordedCall]>([])
        let prior = makeRow(bundleID: "io.rule.prior", name: "Prior", verdict: .current)
        let after = makeRow(bundleID: "io.rule.prior", name: "Prior", verdict: .update,
                            decision: RuleDecision(ignoredBundle: true))
        let mutator: @MainActor @Sendable (RuleKind, String, String?) async throws -> [AppRow] = { kind, id, version in
            calls.with { $0.append(RecordedCall(kind: kind, bundleID: id, version: version)) }
            return [after]  // the mutator's authoritative return, NOT a local edit
        }
        let vm = makeVM(ruleMutator: mutator)
        await vm.setRows([prior])
        vm.select(prior.id)

        await vm.ignoreBundle(prior.app.bundleIdentifier)

        // Invoked with the right RuleKind + bundle id + nil version.
        #expect(calls.with { $0 } == [RecordedCall(kind: .ignoreBundle, bundleID: "io.rule.prior", version: nil)])
        // Rows are the mutator's return, not the stale list.
        #expect(vm.rows == [after])
        // Prior selection preserved (same stable id).
        #expect(vm.selection == prior.id)
        #expect(vm.lastError == nil)
    }

    @Test func ignoreVersionPassesExactKindIDAndVersion() async throws {
        let calls = LockedBox<[RecordedCall]>([])
        let versionIgnored = makeRow(bundleID: "io.rule.version", name: "Version", verdict: .update,
                                     decision: RuleDecision(ignoredVersion: true))
        let mutator: @MainActor @Sendable (RuleKind, String, String?) async throws -> [AppRow] = { kind, id, version in
            calls.with { $0.append(RecordedCall(kind: kind, bundleID: id, version: version)) }
            return [versionIgnored]
        }
        let vm = makeVM(ruleMutator: mutator)

        await vm.ignoreVersion("io.rule.version", "1.2.3")

        #expect(calls.with { $0 } == [RecordedCall(kind: .ignoreVersion, bundleID: "io.rule.version", version: "1.2.3")])
        #expect(vm.rows == [versionIgnored])
    }

    @Test func ignoreBundleFailureSetsLastErrorAndLeavesRowsUntouched() async throws {
        let prior = makeRow(bundleID: "io.rule.unmoved", name: "Unmoved", verdict: .current)
        let mutator: @MainActor @Sendable (RuleKind, String, String?) async throws -> [AppRow] = { _, _, _ in
            throw ProbeFailure.aborted
        }
        let vm = makeVM(ruleMutator: mutator)
        await vm.setRows([prior])
        vm.select(prior.id)

        await vm.ignoreBundle("io.rule.unmoved")

        // Honest: error surfaced, nothing touched.
        #expect(vm.rows.count == 1 && vm.rows.first?.id == prior.id)
        #expect(vm.selection == prior.id)
        #expect(vm.lastError?.contains("aborted") == true)
    }

    // MARK: - shipped default init: honest refusal when nothing is wired

    @Test func defaultVMFailsHonestlyWhenSeamsAreUnwired() async {
        // Brief-pinned default: refresh throws -> lastError, rows untouched.
        let vm = ListViewModel()
        await vm.refresh()
        #expect(vm.rows.isEmpty)
        #expect(vm.lastError?.contains("no refresh source wired") == true)

        // Default rule mutator re-fetches via the (unwired) refresh source ->
        // the same honest failure, never a pretend success.
        await vm.ignoreBundle("io.rule.anything")
        #expect(vm.lastError?.contains("no refresh source wired") == true)
        #expect(vm.rows.isEmpty)
    }

    // MARK: - (8) stats across a 7-row fixture: 1 pending + 2 ignored + 4 current

    @Test func statsReflectPendingIgnoredTotalAcrossSevenRowFixture() async throws {
        let pending = makeRow(bundleID: "io.seven.pending", name: "Pending One", verdict: .update)
        let ignored1 = makeRow(bundleID: "io.seven.ign1", name: "Ignored One", verdict: .update,
                               decision: RuleDecision(ignoredBundle: true))
        let ignored2 = makeRow(bundleID: "io.seven.ign2", name: "Ignored Two", verdict: .update,
                               decision: RuleDecision(ignoredBundle: true, ignoredVersion: true))
        let current1 = makeRow(bundleID: "io.seven.cur1", name: "Current One", verdict: .current)
        let current2 = makeRow(bundleID: "io.seven.cur2", name: "Current Two", verdict: .unknown)
        let current3 = makeRow(bundleID: "io.seven.cur3", name: "Current Three", verdict: .failed)
        let current4 = makeRow(bundleID: "io.seven.cur4", name: "Current Four", verdict: .neverChecked)
        let vm = makeVM()
        await vm.setRows([pending, ignored1, ignored2, current1, current2, current3, current4])

        let stats = vm.stats
        #expect(stats == (pending: 1, total: 7, ignored: 2))

        // pendingOnly keeps exactly the ONE gated-through row (ignored rows
        // with "update" verdicts stay out — frozen AppRow gating).
        vm.setFilter(.pendingOnly)
        #expect(vm.filteredRows.map(\.app.name) == ["Pending One"])
    }

    // MARK: - master-vs-view lookup + full pipeline composition

    @Test func rowForReadsTheMasterListNotTheFilteredView() async throws {
        let hidden = makeRow(bundleID: "io.find.hidden", name: "Hidden One", verdict: .current)
        let shown = makeRow(bundleID: "io.find.shown", name: "Shown", verdict: .update)
        let vm = makeVM()
        await vm.setRows([hidden, shown])

        // Filter the view away from `hidden`...
        vm.setFilter(.pendingOnly)
        #expect(vm.filteredRows.map(\.app.name) == ["Shown"])

        // ...but the master list still answers (that is the documented
        // lookup surface; the view hides, it does not delete).
        #expect(vm.row(for: hidden.id) == hidden)
        #expect(vm.row(for: shown.id) == shown)
        #expect(vm.row(for: "io.find.missing") == nil)
    }

    @Test func queryFilterAndSortCompose() async throws {
        let p = makeRow(bundleID: "io.compose.pending", name: "alpha Pending", verdict: .update)
        let z = makeRow(bundleID: "io.compose.zeta", name: "zeta Current", verdict: .current)
        let ignored = makeRow(bundleID: "io.compose.other", name: "alpha Ignored", verdict: .update,
                              decision: RuleDecision(ignoredBundle: true))
        let vm = makeVM()
        await vm.setRows([z, ignored, p])

        // Query "alpha" hits pending + ignored; pendingOnly drops the ignored
        // one; updateFirst is moot with one row but pinned anyway.
        vm.setQuery("alpha")
        vm.setFilter(.pendingOnly)
        vm.setSort(.updateFirst)

        #expect(vm.filteredRows.map(\.app.name) == ["alpha Pending"])
        #expect(vm.stats.total == 3)  // stats count the MASTER list, never the view
    }
}
