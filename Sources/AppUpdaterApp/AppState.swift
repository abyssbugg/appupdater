import SwiftUI
import AppKit
import AppUpdaterCore

/// Shared observable bridge + Phase-4 coordinator wiring: the menu-bar
/// surface, the window list surface and the scheduler engine all bind
/// through this state.
///
/// Boundaries honored (LOCKED decisions, restated because they decide this
/// file's shape):
/// - The scheduled engine stream is the ONLY automatic check path. Which
///   apps burn check requests is the RuleStore's `.autoCheck` rules
///   (default OFF per app in v1); the engine consults the supplier before
///   every fire, so rule changes apply without a stream restart.
/// - "Install Now" NEVER executes anything from the UI. It stages the exact
///   owner-run CLI command (pasteboard + verbatim published text). No
///   Process, no download, no bundle mutation from this app — applying to a
///   real app is always the user's explicit hand action in the terminal.
/// - Manual Check Now refreshes the list but does NOT touch ScheduleState:
///   that state describes SCHEDULED fires only (a manual check is not a
///   schedule event and must not shift the catch-up machinery's anchor).
/// - Schedule.json persistence is real (ScheduleFileStore): every engine
///   snapshot lands on disk; the UI's schedule lines always reflect the
///   last snapshot the engine emitted.
@MainActor
final class AppState: ObservableObject {

    /// Honest refusal reasons surfaced from direct actions and the
    /// not-yet-wired seam bridge.
    enum ActionFailure: Error, CustomStringConvertible {
        case ignoreVersionNeedsClaim
        case wiringNotComplete

        var description: String {
            switch self {
            case .ignoreVersionNeedsClaim:
                return "ignore-version needs the claimed version — refresh the list first"
            case .wiringNotComplete:
                return "app state not fully initialized yet — the call failed honestly, try again after launch"
            }
        }
    }

    /// Capture bridge for the init-scoped closures: on this toolchain a
    /// closure may not capture a partially-initialized `self` (definite-init
    /// is enforced even for weak captures), so the two VM seams bind THIS
    /// router — a fully-initialized `@MainActor` object created BEFORE any
    /// closure exists. The router holds a weak owner, assigned by init's
    /// final statement (self fully initialized by then). A bridge call
    /// arriving before that assignment throws honestly, never crashes.
    /// (Closures INSIDE methods keep plain weak-self captures — method
    /// bodies are not analyzed against init's definite-init state.)
    @MainActor
    private final class SeamRouter: Sendable {
        fileprivate weak var owner: AppState?

        fileprivate func refreshRows() async throws -> [AppRow] {
            guard let owner else { throw ActionFailure.wiringNotComplete }
            return try await owner.pipelineRows()
        }

        fileprivate func mutateRule(
            _ kind: RuleKind, _ bundleID: String, _ version: String?
        ) async throws -> [AppRow] {
            guard let owner else { throw ActionFailure.wiringNotComplete }
            return try await owner.applyRule(kind, bundleID, version)
        }
    }

    /// Static factory so the init-scoped closures capture ONLY the router
    /// (no `self` — the definite-init rule never engages).
    private static func makeListViewModel(router: SeamRouter) -> ListViewModel {
        ListViewModel(
            refreshSource: { try await router.refreshRows() },
            ruleMutator: { kind, bundleID, version in
                try await router.mutateRule(kind, bundleID, version)
            })
    }

    // MARK: Published schedule-domain state

    /// Latest snapshot the scheduler stream emitted (policy + state).
    @Published private(set) var schedule = ScheduleSnapshot(
        policy: SchedulePolicy(), state: ScheduleState())

    /// Verbatim schedule.json failure text (settings sheet renders it).
    @Published private(set) var scheduleError: String?

    /// Verbatim failure of a DIRECT action (auto-check toggle, rules
    /// cleanup). The list VM carries its own `lastError` for seam-backed
    /// actions; this field exists so unseamed actions keep the same
    /// no-silent-failure contract.
    @Published private(set) var actionError: String?

    /// The exact owner-run command staged by the last Install Now press
    /// (nil until then). Shown verbatim in the window — the app itself
    /// never runs it.
    @Published private(set) var lastInstallCommand: String?

    // MARK: Composition root

    /// Window list view model, wired to the REAL refresh + rule seams below
    /// (this is the merge requirement ListViewModel's class doc names).
    let list: ListViewModel

    /// Per-app rules, persisted to rules.json.
    let rules: RuleStore

    private let scheduleStore: ScheduleFileStore
    private let scanDirectories: [URL]
    private let seams: SeamRouter

    // MARK: Private bookkeeping

    /// The authoritative last pipeline outputs; every re-evaluation (rule
    /// mutation, scheduled fire) rebuilds rows from this pair.
    private var lastApps: [InstalledApp] = []
    private var lastChecks: [UpdateCheck] = []
    private var engineTask: Task<Void, Never>?

    init(
        rulesDirectory: URL? = nil,
        scheduleDirectory: URL? = nil,
        scanDirectories: [URL] = [URL(fileURLWithPath: "/Applications")]
    ) {
        self.rules = RuleStore(directory: rulesDirectory)
        self.scheduleStore = ScheduleFileStore(directory: scheduleDirectory)
        self.scanDirectories = scanDirectories

        // The router exists before ANY closure (and before `list`) is
        // created, so closures never capture a partially-built AppState.
        let router = SeamRouter()
        self.seams = router
        self.list = Self.makeListViewModel(router: router)

        // Final init statements: self is fully initialized from here on.
        router.owner = self
        startScheduler()
    }

    deinit {
        engineTask?.cancel()
    }

    // MARK: Derived surfaces for the two views

    /// Menu-bar data (pure transform over rows + snapshot; recomputed per
    /// render — MenuData never caches or polls).
    var menuData: MenuData {
        MenuData(appRowSummary: list.rows, schedule: schedule, now: Date())
    }

    /// Coordinator-owned classification for the menu's `.currentApps`
    /// section — exactly the one MenuData deliberately refuses to guess:
    /// ONLY `verdict == "current"` rows count as up to date. Rule-muted
    /// update claims and failed/unknown verdicts are excluded (honest
    /// neither-pending-nor-current stance, stated in MenuData's docs).
    var upToDateCount: Int {
        list.rows.filter { $0.check?.verdict == "current" }.count
    }

    /// Dynamic menu-bar title: pending count shown only when nonzero (the
    /// MenuData counts contract — 0 shows nothing, never a fake number).
    var menuBarTitle: String {
        let pending = list.rows.filter { $0.updateAvailable }.count
        return pending > 0 ? "AppUpdater · \(pending)" : "AppUpdater"
    }

    // MARK: Scheduling lifecycle (engine stream consumer + persistence)

    /// Starts (or restarts) the scheduler stream: load schedule.json,
    /// publish it, run the loop, persist every emitted snapshot.
    ///
    /// Policy is fixed per stream (the engine's own contract), so a policy
    /// change is applied by saving and calling this again.
    private func startScheduler() {
        engineTask?.cancel()

        let supplier: @Sendable () async -> [String] = { [weak self] () async -> [String] in
            guard let self else { return [] }
            return await self.autoCheckBundleIDs()
        }
        let fire: @Sendable ([String]?) async throws -> Int = {
            [weak self] (ids: [String]?) async throws -> Int in
            guard let self else { return 0 }
            return try await self.scheduledFire(ids)
        }

        engineTask = Task { [weak self] in
            guard let self else { return }
            let loaded: ScheduleSnapshot
            do {
                loaded = try await self.scheduleStore.load()
            } catch {
                self.scheduleError = "schedule.json load failed — \(error)"
                loaded = ScheduleSnapshot(policy: SchedulePolicy(), state: ScheduleState())
            }
            self.schedule = loaded

            let engine = ScheduleEngine(fire: fire)
            let stream = await engine.start(
                policy: loaded.policy,
                state: loaded.state,
                autoCheckBundleIDs: supplier)

            for await snapshot in stream {
                self.schedule = snapshot
                do {
                    try await self.scheduleStore.save(snapshot)
                } catch {
                    self.scheduleError = "schedule.json save failed — \(error)"
                }
            }
        }
    }

    /// Applies a policy change: clamp → persist → restart the stream
    /// (policy fixed per stream). The loaded file is the single truth the
    /// restarted stream reads, so the pair stays consistent.
    func applyPolicy(_ newPolicy: SchedulePolicy) async {
        let clamped = RuleStore.clamped(newPolicy)
        let snapshot = ScheduleSnapshot(policy: clamped, state: schedule.state)
        do {
            try await scheduleStore.save(snapshot)
        } catch {
            scheduleError = "schedule.json save failed — \(error)"
        }
        startScheduler()
    }

    /// The supplier the engine consults before every fire: the CURRENT
    /// autoCheck decisions (fresh reads — rule edits apply to the next fire
    /// with no restart, mirroring the engine's seam contract).
    func autoCheckBundleIDs() -> [String] {
        list.rows.filter { $0.decision.autoCheck }.map { $0.app.bundleIdentifier }
    }

    /// The engine's fire seam.
    ///
    /// `ids == nil` means "no app opted into autoCheck" — the fire STILL
    /// happens (a cadence event): it refreshes the scanned inventory and
    /// burns NO source lookups in v1; the returned count (the inventory
    /// size) is what ScheduleState records as appsChecked, honestly. With
    /// opted-in ids, sources are consulted for exactly those apps and the
    /// count is the targeted set's size.
    ///
    /// The automatic path NEVER installs anything — it can only produce
    /// rows (`updateAvailable` flags). Installs are the owner's explicit
    /// CLI action; this seam has no access to any installer type at all.
    func scheduledFire(_ ids: [String]?) async throws -> Int {
        let apps = try await ProductionAppScanner().scan(directoryURLs: scanDirectories)
        if let ids {
            let wanted = Set(ids)
            let targets = apps.filter { wanted.contains($0.bundleIdentifier) }
            let checks = await UpdateCheckEngine(
                sources: [CaskSource(), SparkleSource(), MASSource()]
            ).checkAll(apps: targets)
            lastApps = apps
            lastChecks = checks
            await list.setRows(await rules.evaluate(apps: apps, checks: checks))
            return targets.count
        }
        lastApps = apps
        lastChecks = []
        await list.setRows(await rules.evaluate(apps: apps, checks: []))
        return apps.count
    }

    // MARK: Refresh + rule pipelines (the VM's real seams live here)

    /// The full refresh pipeline: scan → per-app source lookups → rules
    /// evaluation → rows. Runs on Check Now (menu + window) and behind the
    /// VM's refresh seam.
    func pipelineRows() async throws -> [AppRow] {
        let apps = try await ProductionAppScanner().scan(directoryURLs: scanDirectories)
        let checks = await UpdateCheckEngine(
            sources: [CaskSource(), SparkleSource(), MASSource()]
        ).checkAll(apps: apps)
        lastApps = apps
        lastChecks = checks
        return await rules.evaluate(apps: apps, checks: checks)
    }

    /// The rule mutator behind the VM's ignore seams: persist the rule,
    /// return re-evaluated rows over the LAST known pipeline outputs so the
    /// decision is visible immediately without a full re-check.
    func applyRule(
        _ kind: RuleKind, _ bundleID: String, _ version: String?
    ) async throws -> [AppRow] {
        // First-ever rule press before any scan ran: populate the inventory
        // so the returned rows are real rows, not an empty artifact.
        if lastApps.isEmpty {
            lastApps = try await ProductionAppScanner().scan(directoryURLs: scanDirectories)
        }
        switch kind {
        case .ignoreBundle:
            try await rules.ignoreBundle(bundleID)
        case .ignoreVersion:
            guard let version, !version.isEmpty else {
                throw ActionFailure.ignoreVersionNeedsClaim
            }
            try await rules.ignoreVersion(bundleID, version: version)
        case .autoCheck:
            try await rules.setAutoCheck(bundleID, true)
        }
        return await rules.evaluate(apps: lastApps, checks: lastChecks)
    }

    /// Per-app automatic-check opt-in/out (window detail toggle). The VM
    /// exposes no two-direction autoCheck seam (its mutator creates rules),
    /// so the window calls HERE for this one; failures surface through
    /// `actionError` — never swallowed silently.
    func setAutoCheck(_ bundleID: String, _ enabled: Bool) async {
        do {
            try await rules.setAutoCheck(bundleID, enabled)
            actionError = nil
            await list.setRows(await rules.evaluate(apps: lastApps, checks: lastChecks))
        } catch {
            actionError = "auto-check toggle failed — \(error)"
        }
    }

    /// Un-ignores everything for one bundle (evaluate → fresh rows).
    func removeRules(for bundleID: String) async {
        do {
            try await rules.removeBundleRules(bundleID)
            actionError = nil
            await list.setRows(await rules.evaluate(apps: lastApps, checks: lastChecks))
        } catch {
            actionError = "rule cleanup failed — \(error)"
        }
    }

    // MARK: Owner-run install boundary

    /// LOCKED boundary in action: stages the exact owner-run CLI command
    /// (pasteboard + verbatim display). NOTHING executes here — the
    /// surface's honesty is the product: the user reads or copies the
    /// command and runs it themselves in the terminal.
    func requestInstall(bundleID: String) {
        guard let row = list.rows.first(where: { $0.app.bundleIdentifier == bundleID }) else {
            return
        }
        let name = row.app.name
        // Minimal honest shell-quoting: quotes around anything with spaces,
        // embedded quotes escaped (CJK app names pass through unquoted).
        let needsQuotes = name.contains(" ") || name.contains("\"")
        let escaped = name.replacingOccurrences(of: "\"", with: "\\\"")
        let shellSafe = needsQuotes ? "\"\(escaped)\"" : escaped
        let command =
            "swift run appupdater-cli install --apps \(shellSafe) --apply"
        lastInstallCommand = command
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
    }

    /// Menu "View Details": open the window with this row preselected.
    func showDetails(bundleID: String) {
        if let row = list.rows.first(where: { $0.app.bundleIdentifier == bundleID }) {
            list.select(row.id)
        }
    }
}
