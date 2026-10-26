// ListViewModel.swift — the window list surface's state engine. Lane listvm
// (Phase 4, window list view-model) only.
//
// FROZEN CONTRACT (Sources/AppUpdaterCore/Model/ScheduleStore.swift —
// coordinator-owned; never edited by this lane):
//   AppRow (app + check + decision + honest updateAvailable), RuleDecision,
//   RuleKind. The VM transforms rows; it never invents its own merge type.
//
// OBSERVATION-ONLY (no SwiftUI): the coordinator binds SwiftUI at merge. The
// VM is a plain `@Observable` state machine — `import Observation` only — so
// it stays usable from the app shell AND from tests without a UI target in
// the loop. Every mutation flows through a marked entry point; computed
// surfaces (`filteredRows`, `stats`, `row(for:)`) are pure and never mutate.
//
// PIPELINE ORDER (deterministic, single definition):
//   master rows -> query (name OR bundleIdentifier, case-insensitive; empty
//   = all) -> ListFilter mode (all / pendingOnly = updateAvailable /
//   ignoredOnly = decision.ignoredBundle) -> SortKey order.
//
// Sendable JUDGMENT (recorded, per lane brief — not silent): the class is
// written `@Observable @MainActor … : Sendable`. Global-actor isolation makes
// the type safe to cross concurrency domains (every access hops to the main
// actor), all stored state is value-type or `@Sendable` closures, and the
// @Observable registrar is itself Sendable. If a future toolchain macro
// rejects the explicit conformance, the honest fallback is dropping the
// annotation WITH this comment updated — never a silent removal.
//
// lastError CONTRACT (never swallowed silently): every seam-backed action
// (`refresh()`, `ignoreBundle`, `ignoreVersion`) clears `lastError` on
// success and stores the underlying error text on failure, with rows left
// untouched — a failed refresh never fabricates an empty list, and a failed
// ignore action never pretends the rule applied. The UI turns `lastError`
// into an alert at merge. Manual `setRows` does not touch `lastError` (it
// cannot fail and must not hide a still-standing failure it didn't cause).

import Foundation
import Observation

/// Why the VM refused an action in the shipped (unwired) configuration.
/// The coordinator replaces both seams at merge; until then the default
/// behavior fails loudly instead of silently doing nothing.
public enum ListViewModelError: Error, Sendable, CustomStringConvertible {
    /// `refresh()` was called before any source was wired; the VM refuses to
    /// fabricate rows.
    case refreshSourceNotWired

    public var description: String {
        switch self {
        case .refreshSourceNotWired:
            return "no refresh source wired yet — the coordinator binds the real scan/check pipeline at merge"
        }
    }
}

/// Deterministic list orders for the window surface.
public enum SortKey: Hashable, Sendable, CaseIterable {
    /// Name ascending (case-insensitive), stable id tie-break.
    case name
    /// Pending-update blocks first (`updateAvailable`), then name ascending.
    case updateFirst
    /// Check date descending (`InstalledApp.checkedAt`); never-checked rows
    /// go last. NOTE on the mapping: `UpdateCheck` carries no date of its own,
    /// so "the check date" is `app.checkedAt` — the field the frozen model
    /// owns for exactly this staleness purpose.
    case recentlyChecked
}

/// Row-visibility modes over the master list.
public enum ListFilter: Hashable, Sendable, CaseIterable {
    /// Everything the scan produced.
    case all
    /// Only rows the rules engine lets through as pending (`updateAvailable`).
    case pendingOnly
    /// Only bundle-ignored rows (`decision.ignoredBundle`). Version-ignored
    /// rows deliberately stay visible under `all`/queries — they are current,
    /// but the owner may want to revisit or un-ignore a specific version.
    case ignoredOnly
}

/// The window list state machine: search, sort, filter, selection, refresh
/// and rule actions over the frozen `AppRow` stream.
///
/// # Ownership of mutability
/// Every stored property is `public private(set)` (honest observability +
/// testability: tests read freely, mutate only through entry points) and
/// mutation happens ONLY through the marked entry points:
/// - synchronous: `select(_:)`, `setQuery(_:)`, `setSort(_:)`, `setFilter(_:)`
/// - asynchronous (seam-backed): `setRows(_:)`, `refresh()`, `ignoreBundle`,
///   `ignoreVersion`
/// Direct property writes are the past tense of an entry point, nothing else.
///
/// # Selection semantics
/// Selection is by stable `AppRow.id` (= `InstalledApp.id`, i.e.
/// bundleIdentifier|path). It is cleared ONLY when the selected row vanishes
/// from the MASTER list (`setRows`/seam success paths); narrowing by query or
/// filter never clears it — the master row still exists, hiding it from view
/// is not the same as the row being gone.
///
/// # Entry points and the seams (why closures, why value refs — AppQuit-style)
/// The VM owns no scan engine and no rule store. The world arrives as two
/// `@MainActor @Sendable` closures:
/// - `refreshSource: () async throws -> [AppRow]` — the coordinator wires the
///   real scan/check pipeline at merge.
/// - `ruleMutator: (RuleKind, String, String?) async throws -> [AppRow]` —
///   the coordinator wires a closure that applies the rule to the real
///   RuleStore and returns the new authoritative rows.
///
/// SIGNATURE DEVIATION (recorded, per lane brief): the brief writes both seam
/// types as `(...) async -> [AppRow]` without `throws`, but its own semantics
/// demand expressible failure ("lastError set, rows untouched on failure",
/// "honestly surfaces an error when the mutator throws"). A non-throwing
/// closure has no failure channel at all, so the sealed type carries
/// `throws`; injecting a NON-throwing closure still compiles (a non-throwing
/// closure is assignable to a throwing parameter type). Nothing else about
/// the shape changed.
///
/// # Shipped (unwired) default behavior — AGENTS.md honesty floor
/// `init()` wires HONEST placeholders, not success theater:
/// - the default refresh source throws `ListViewModelError
///   .refreshSourceNotWired` → VM callers see it land in `lastError` with rows
///   untouched, instead of a silently empty list;
/// - the default rule mutator re-fetches rows through the refresh source
///   (brief-mandated) and lets every thrown error propagate verbatim. It
///   deliberately does NOT mutate its own `decision` copies: a local-only
///   ignore would fabricate persistence and vanish on the next refresh —
///   silent lying. MERGE REQUIREMENT: the coordinator must wire the real
///   RuleStore-backed mutator, or ignore actions only refresh the view.
///
/// # Reality check (honesty notes)
/// - `UpdateCheck.verdict` drives `AppRow.updateAvailable`; the VM trusts the
///   frozen model's gating (bundle- and version-ignored rows are never
///   pending) rather than re-deriving its own rule.
/// - Query matching is `.caseInsensitive` `String.compare` (Unicode order,
///   machine-independent — `localizedStandardContains` was rejected because
///   locale collation would make row ORDER environment-dependent and the
///   brief freezes determinism).
/// - Duplicate ids from a buggy coordinator would break every `id`
///   assumption above (selection, `row(for:)`); the VM does not hide that —
///   `row(for:)` returns the first match and the seam is the coordinator's
///   responsibility, flagged here rather than patched over.
@Observable
@MainActor
public final class ListViewModel: Sendable {

    // MARK: - State (public read, entry-point mutations only)

    /// The master list exactly as the rules engine emitted it (latest source
    /// of truth; never pre-filtered by view concerns).
    public private(set) var rows: [AppRow] = []

    /// Live search text. Empty string = every row.
    public private(set) var query: String = ""

    /// Current deterministic order.
    public private(set) var sort: SortKey = .name

    /// Current visibility mode.
    public private(set) var filter: ListFilter = .all

    /// Selected row by stable id, or nil. Entry point: `select(_:)`.
    public private(set) var selection: String?

    /// Verbatim failure text of the last thrown action, or nil. UI turned
    /// into an alert at merge. Set by refresh/ignore paths; never by
    /// `setRows` (manual row pushes cannot fail).
    public private(set) var lastError: String?

    // MARK: - Seams (coordinator-wired at merge; @testable-injected in tests)

    /// Produces fresh authoritative rows. MainActor-confined like every
    /// touch of the VM (AppQuit seam discipline; value refs only cross).
    let refreshSource: @MainActor @Sendable () async throws -> [AppRow]

    /// Applies one rule and returns the new authoritative rows. MainActor-
    /// confined; the VM applies the returned rows verbatim on success.
    let ruleMutator: @MainActor @Sendable (RuleKind, String, String?) async throws -> [AppRow]

    // MARK: - Init

    /// Shipped wiring: honest unwired seams (see the class doc's "shipped
    /// default behavior"). The coordinator re-wires both at merge.
    public init() {
        // Explicit declared-type lets, one per seam (ternary composition
        // loses contextual `@MainActor @Sendable` in Swift 6.4 — gotcha
        // ledger, phase 3).
        let unwiredRefreshSource: @MainActor @Sendable () async throws -> [AppRow] = { () async throws -> [AppRow] in
            throw ListViewModelError.refreshSourceNotWired
        }
        let refetchOnlyRuleMutator: @MainActor @Sendable (RuleKind, String, String?) async throws -> [AppRow] = { _, _, _ in
            // Brief-mandated default: re-fetch fresh rows through the refresh
            // source. The rule itself is NOT applied here — applying belongs
            // to the coordinator's wired mutator (merge requirement, class
            // doc). Unwired refresh source => throw => honest `lastError`.
            try await unwiredRefreshSource()
        }
        self.refreshSource = unwiredRefreshSource
        self.ruleMutator = refetchOnlyRuleMutator
    }

    /// Seam-injected wiring (internal like AppTerminator's; tests open it via
    /// `@testable`, the public surface keeps the brief's shape).
    internal init(
        refreshSource: @escaping @MainActor @Sendable () async throws -> [AppRow],
        ruleMutator: @escaping @MainActor @Sendable (RuleKind, String, String?) async throws -> [AppRow]
    ) {
        self.refreshSource = refreshSource
        self.ruleMutator = ruleMutator
    }

    // MARK: - Computed surface (pure; no mutation, no side effects)

    /// The view pipeline: query -> filter -> sort. Recomputed on access;
    /// every consumer down the window surface renders THIS array.
    public var filteredRows: [AppRow] {
        var result = rows

        if !query.isEmpty {
            result = result.filter { row in
                row.app.name.range(of: query, options: .caseInsensitive) != nil
                    || row.app.bundleIdentifier.range(of: query, options: .caseInsensitive) != nil
            }
        }

        switch filter {
        case .all:
            break
        case .pendingOnly:
            result = result.filter { $0.updateAvailable }
        case .ignoredOnly:
            result = result.filter { $0.decision.ignoredBundle }
        }

        result.sort(by: Self.comparator(for: sort))
        return result
    }

    /// Honest rollup over the MASTER rows (not the filtered view): pending =
    /// updateAvailable rows, ignored = bundle-ignored rows, total = all.
    public var stats: (pending: Int, total: Int, ignored: Int) {
        let pending = rows.lazy.filter(\.updateAvailable).count
        let ignored = rows.lazy.filter { $0.decision.ignoredBundle }.count
        return (pending, rows.count, ignored)
    }

    /// Master-list lookup for a selection id. Returns the FIRST match —
    /// duplicate ids are a coordinator bug the VM refuses to hide (class doc).
    public func row(for id: String) -> AppRow? {
        rows.first { $0.id == id }
    }

    // MARK: - Synchronous entry points (UI settings; MainActor by the class)

    /// Selects a row by id (nil deselects). The ONLY mutation path for
    /// `selection` apart from the automatic clear in row-replacing paths.
    public func select(_ id: String?) {
        selection = id
    }

    /// Sets the live search text. Empty string = every row.
    public func setQuery(_ text: String) {
        query = text
    }

    /// Sets the deterministic order.
    public func setSort(_ key: SortKey) {
        sort = key
    }

    /// Sets the visibility mode.
    public func setFilter(_ mode: ListFilter) {
        filter = mode
    }

    // MARK: - Asynchronous entry points (seam-backed actions)

    /// Replaces the master list (coordinator pushes scan output) and clears
    /// the selection iff its row vanished. Manual pushes cannot fail, so
    /// `lastError` is deliberately untouched here (class doc, lastError
    /// contract).
    public func setRows(_ fresh: [AppRow]) async {
        replaceRows(fresh)
    }

    /// Pulls fresh rows through `refreshSource`. Success: rows replaced,
    /// selection survives if its stable id still exists, `lastError` cleared.
    /// Failure: `lastError` carries the underlying error's text verbatim;
    /// rows + selection remain exactly as they were — an honest refusal
    /// instead of a fabricated empty list.
    public func refresh() async {
        do {
            let fresh = try await refreshSource()
            replaceRows(fresh)
            lastError = nil
        } catch {
            lastError = "refresh failed — \(error)"
        }
    }

    /// Asks the wired mutator to ignore the WHOLE bundle of the app with the
    /// given id. Success: rows replaced with the mutator's return (NOT the
    /// stale local list), selection survives if its id still exists,
    /// `lastError` cleared. Failure: `lastError` set, everything untouched.
    /// The id is passed through without local validation — rule semantics
    /// (unknown ids included) belong to the real store behind the seam.
    public func ignoreBundle(_ bundleID: String) async {
        do {
            let fresh = try await ruleMutator(.ignoreBundle, bundleID, nil)
            replaceRows(fresh)
            lastError = nil
        } catch {
            lastError = "ignoreBundle(\(bundleID)) failed — \(error)"
        }
    }

    /// Asks the wired mutator to ignore one exact (app, version) claim.
    /// Success/failure contract identical to `ignoreBundle`.
    public func ignoreVersion(_ bundleID: String, _ version: String) async {
        do {
            let fresh = try await ruleMutator(.ignoreVersion, bundleID, version)
            replaceRows(fresh)
            lastError = nil
        } catch {
            lastError = "ignoreVersion(\(bundleID), \(version)) failed — \(error)"
        }
    }

    // MARK: - Internal mechanics (private; single mutation funnel)

    /// The single row-replacing funnel: every path that swaps the master list
    /// lands here so selection-survival semantics exist in exactly one place.
    private func replaceRows(_ fresh: [AppRow]) {
        rows = fresh
        if let current = selection, !fresh.contains(where: { $0.id == current }) {
            selection = nil
        }
    }

    /// Returns a deterministic strict comparator for each sort key. All keys
    /// end with the stable-id tie-break so equal inputs order identically
    /// every run (no reliance on unstable sort behavior).
    private static func comparator(for sort: SortKey) -> (AppRow, AppRow) -> Bool {
        switch sort {
        case .name:
            return { nameOrderBefore($0, $1) }
        case .updateFirst:
            return { lhs, rhs in
                if lhs.updateAvailable != rhs.updateAvailable {
                    return lhs.updateAvailable  // pending blocks first, regardless of name
                }
                return nameOrderBefore(lhs, rhs)
            }
        case .recentlyChecked:
            return { lhs, rhs in
                switch (lhs.app.checkedAt, rhs.app.checkedAt) {
                case let (l?, r?):
                    if l != r { return l > r }  // newest check first
                    return lhs.id < rhs.id
                case (_?, nil):
                    return true   // any dated row sorts before an undated one
                case (nil, _?):
                    return false  // undated rows go last
                case (nil, nil):
                    return lhs.id < rhs.id
                }
            }
        }
    }

    /// Case-insensitive name ascending with stable-id tie-break. Unicode
    /// ordinal comparison — deterministic across machines (see class doc's
    /// reality check on localized collation).
    private static func nameOrderBefore(_ lhs: AppRow, _ rhs: AppRow) -> Bool {
        let comparison = lhs.app.name.compare(rhs.app.name, options: .caseInsensitive)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id < rhs.id
    }
}
