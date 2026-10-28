import SwiftUI
import AppKit
import UserNotifications
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
///   The SAME boundary covers notifications: a manual refresh never posts
///   the distributed fire event, never advances
///   ``lastScheduledPendingNames`` and never advises the local-notification
///   decider — scheduled fires only.
/// - Notifications (v1 policy, decided 2026-10-26): each scheduled fire
///   completion posts the documented distributed event (see
///   `NotificationNames`) and — ONLY when the fire-to-fire decider says
///   `newlyPending` AND the user's toggle is on — asks macOS for
///   authorization and posts ONE summary. Denial is stated honestly, never
///   faked as success. Ask-per-fire (with `deliverImmediately: false`) keeps
///   the flow boring; macOS itself caches the user's standing answer.
/// - Schedule.json persistence is real (ScheduleFileStore): every engine
///   snapshot lands on disk; the UI's schedule lines always reflect the
///   last snapshot the engine emitted.
/// - Gap-sprint boundaries (2026-10-27): FS events trigger INVENTORY
///   re-scans ONLY — never source checks, notifications, or installs;
///   custom scan locations ADD to /Applications (never replace it); the
///   whole-index cask cache degrades honestly to the per-token pipeline;
///   the scheduled engine stream stays the ONLY automatic check path.
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

    /// Verbatim failure of a custom scan-location store read (nil = healthy).
    /// Set only by the scan-root builder; cleared again on a healthy read.
    @Published private(set) var scanLocationsError: String?

    /// The exact owner-run command staged by the last Install Now press
    /// (nil until then). Shown verbatim in the window — the app itself
    /// never runs it.
    @Published private(set) var lastInstallCommand: String?

    /// Master switch for the LOCAL summary notification (settings pane
    /// toggle; default ON). The distributed fire event is NOT gated on this
    /// — it is the unconditional scriptability surface and fires after every
    /// scheduled fire regardless. Read by the settings pane; written only
    /// via ``setNotificationsEnabled`` (the Binding in the view wires get/set
    /// explicitly — `private(set)` cannot be exposed as a raw `$`-binding
    /// across files on this toolchain).
    @Published private(set) var notificationsEnabled = true

    /// Honest status line for the settings pane: `nil` = normal (no failure
    /// to report). Set ONLY to verbatim failure facts — authorization denial
    /// ("macOS denied notification permission — enable it in System
    /// Settings") or a posting failure with the verbatim reason. Success
    /// clears it back to nil. Never a fake success message; the line stays
    /// as the LAST-KNOWN outcome (toggling the switch alone does not erase a
    /// past denial — the next fire's outcome is what overwrites it).
    @Published private(set) var notificationsState: String?

    // MARK: Composition root

    /// Window list view model, wired to the REAL refresh + rule seams below
    /// (this is the merge requirement ListViewModel's class doc names).
    let list: ListViewModel

    /// Per-app rules, persisted to rules.json.
    let rules: RuleStore

    private let scheduleStore: ScheduleFileStore
    private let scanDirectories: [URL]
    private let seams: SeamRouter

    // MARK: Gap-sprint stores (2026-10-27)

    /// Shared Application-Support home of the disk-backed stores (whole-index
    /// cask cache + custom scan locations). Tests inject an isolated dir.
    private let appSupportDirectory: URL

    /// Custom scan-location store (gap #18). /Applications is ALWAYS scanned;
    /// these directories add to it. AppState only READS it — the settings
    /// sheet mutates through its own view (which owns the NSOpenPanel).
    let scanLocationStore: ScanLocationStore

    /// Whole-index cask store (gap #1): one ETag-cached `cask.json` +
    /// alias-free artifact matching. `ensureLoaded` runs exactly once per
    /// check pass (the store's contract); an unusable index degrades to the
    /// proven per-token pipeline.
    private let caskIndexStore: CaskIndexStore

    /// The real Application-Support home (the CLI uses the same path).
    private static let defaultAppSupportDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AppUpdater", isDirectory: true)

    // MARK: Private bookkeeping

    /// The authoritative last pipeline outputs; every re-evaluation (rule
    /// mutation, scheduled fire) rebuilds rows from this pair.
    private var lastApps: [InstalledApp] = []
    private var lastChecks: [UpdateCheck] = []
    private var engineTask: Task<Void, Never>?

    /// The FS-event monitor consumer task (inventory-refresh scope only).
    private var fsMonitorTask: Task<Void, Never>?
    /// The CURRENT monitor instance; a fresh one is created on every (re)start
    /// because a monitor retires once its event stream has been consumed.
    private var fileSystemMonitor = FileSystemMonitor()

    /// The pending NAME set recorded by the previous SCHEDULED fire
    /// (nil = never ran since launch) — the decider's baseline. MANUAL
    /// Check Now never mutates this (same exclusivity as ScheduleState:
    /// scheduled fires only). Feeding it to `NotificationDecider.advise`
    /// decides whether this fire is worth a local notification.
    private var lastScheduledPendingNames: [String]? = nil

    /// - Parameters:
    ///   - appSupportDirectory: shared home of the disk-backed stores; the
    ///     default is the real ~/Library/Application Support/AppUpdater and
    ///     tests inject an isolated directory instead.
    init(
        rulesDirectory: URL? = nil,
        scheduleDirectory: URL? = nil,
        appSupportDirectory: URL? = nil,
        scanDirectories: [URL] = [URL(fileURLWithPath: "/Applications")]
    ) {
        let support = appSupportDirectory ?? Self.defaultAppSupportDirectory
        self.appSupportDirectory = support
        self.rules = RuleStore(directory: rulesDirectory)
        self.scheduleStore = ScheduleFileStore(directory: scheduleDirectory)
        self.scanDirectories = scanDirectories
        self.scanLocationStore = ScanLocationStore(directory: support)
        self.caskIndexStore = CaskIndexStore(directory: support)

        // The router exists before ANY closure (and before `list`) is
        // created, so closures never capture a partially-built AppState.
        let router = SeamRouter()
        self.seams = router
        self.list = Self.makeListViewModel(router: router)

        // Final init statements: self is fully initialized from here on.
        router.owner = self
        startScheduler()
        startFileSystemMonitor()
    }

    deinit {
        engineTask?.cancel()
        fsMonitorTask?.cancel()
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
    /// After EITHER branch completes, the notification side-effects run:
    /// the unconditional distributed event + the decider-gated local
    /// summary. If the scan/checks THREW above, no branch completed —
    /// nothing is posted and no baseline is advanced (an event a failed fire
    /// would fake success; the engine records the error into ScheduleState
    /// instead).
    ///
    /// MANUAL path note (LOCKED): `pipelineRows()` (Check Now) posts nothing
    /// and touches ``lastScheduledPendingNames`` — scheduled fires only.
    func scheduledFire(_ ids: [String]?) async throws -> Int {
        let apps = try await ProductionAppScanner().scan(directoryURLs: effectiveScanDirectories())
        if let ids {
            let wanted = Set(ids)
            let targets = apps.filter { wanted.contains($0.bundleIdentifier) }
            let checks = await UpdateCheckEngine(
                sources: await checkSources()
            ).checkAll(apps: targets)
            lastApps = apps
            lastChecks = checks
            let evaluated = await rules.evaluate(apps: apps, checks: checks)
            await list.setRows(evaluated)
            await recordScheduledFireOutcome(
                appsChecked: targets.count, pendingNames: pendingNames(in: evaluated))
            return targets.count
        }
        lastApps = apps
        lastChecks = []
        let evaluated = await rules.evaluate(apps: apps, checks: [])
        await list.setRows(evaluated)
        await recordScheduledFireOutcome(
            appsChecked: apps.count, pendingNames: pendingNames(in: evaluated))
        return apps.count
    }

    // MARK: Gap-sprint wiring (scan roots, source roster, FS monitor)

    /// The scan roots for this pass: the base roots (default /Applications)
    /// PLUS every resolvable custom location (gap #18). /Applications is
    /// always first (the store refuses to duplicate it); vanished custom
    /// directories are skipped (they stay listed in the settings sheet with
    /// their honest missing-dot); a failed store read never silently drops
    /// locations — it surfaces verbatim in ``scanLocationsError`` and the
    /// scan proceeds on the base roots alone.
    private func effectiveScanDirectories() -> [URL] {
        var roots = scanDirectories
        do {
            for resolved in try scanLocationStore.resolvedRoots() {
                if let url = resolved.url {
                    roots.append(url)
                }
            }
            scanLocationsError = nil
        } catch {
            scanLocationsError = "custom scan locations unreadable — \(error)"
        }
        return roots
    }

    /// Source roster for ONE check pass — the engine sorts them into the
    /// locked precedence (cask > sparkle > mas > github; unknown last):
    /// - **Cask**: whole-index mode (ETag-cached `cask.json`, alias-free
    ///   artifact matching — gap #1). `ensureLoaded` runs exactly once per
    ///   pass; when the index cannot be revalidated AND holds no usable
    ///   records, the check degrades honestly to the proven per-token
    ///   pipeline (`CaskSource`) — never to a guess.
    /// - **Sparkle / MAS** as before.
    /// - **GitHub** (gap #3): bounded harvest from the app's own
    ///   `sparkleFeedURL` only (zero extra lookups for other apps).
    /// - **Electron** (gap #4): unknown-lane — its claims surface only when
    ///   no stronger source produced one, and (post-amendment) only when
    ///   strictly newer than the installed version.
    private func checkSources() async -> [any UpdateSource] {
        var sources: [any UpdateSource] = []
        let revalidated = await caskIndexStore.ensureLoaded()
        var indexUsable = revalidated
        if !indexUsable {
            indexUsable = await caskIndexStore.isLoaded
        }
        if indexUsable {
            sources.append(CaskIndexSource(store: caskIndexStore))
        } else {
            sources.append(CaskSource())
        }
        sources.append(SparkleSource())
        sources.append(MASSource())
        sources.append(GithubSource(directory: appSupportDirectory, session: .shared))
        sources.append(ElectronSource())
        return sources
    }

    /// FS-event monitor (gap #17). SCOPE GUARD (LOCKED, restated): an FS
    /// event may trigger an INVENTORY re-scan only — never source checks,
    /// never notifications, never any install. One draining consumer per
    /// monitor instance; roots are the effective scan roots at (re)start.
    private func startFileSystemMonitor() {
        fsMonitorTask?.cancel()
        let monitor = FileSystemMonitor()
        fileSystemMonitor = monitor
        let roots = effectiveScanDirectories().map { $0.path }
        fsMonitorTask = Task { [weak self] in
            await monitor.start(rootPaths: roots)
            for await _ in monitor.events {
                guard let self, !Task.isCancelled else { break }
                await self.refreshInventoryOnly()
            }
        }
    }

    /// The location sheet's change seam: re-armed monitor + inventory refresh
    /// over the CURRENT store contents. Scan-only, per the scope guard.
    func scanLocationsDidChange() async {
        startFileSystemMonitor()
        await refreshInventoryOnly()
    }

    /// FS-EVENT / location-change refresh — the locked scan-only shape:
    /// inventory re-scan + rule re-evaluation with EMPTY checks (the same
    /// shape the scheduled engine uses for a fire with no opted-in apps),
    /// rows republished. NEVER: source lookups, notifications, schedule
    /// state, installs. A vanished app leaves the list; a self-updated app's
    /// stale "update available" badge clears until its next real check.
    func refreshInventoryOnly() async {
        do {
            let apps = try await ProductionAppScanner().scan(directoryURLs: effectiveScanDirectories())
            lastApps = apps
            lastChecks = []
            let evaluated = await rules.evaluate(apps: apps, checks: [])
            await list.setRows(evaluated)
        } catch {
            actionError = "rescan after a folder change failed — \(error)"
        }
    }

    // MARK: Scheduled-fire notification side-effects (both branches)

    /// Per-app display names of the pending rows a fire produced
    /// (updateAvailable == true). Pure transform over the evaluated rows —
    /// read from the fire's OWN rows, never from `list.rows`, so a manual
    /// refresh racing a scheduled fire can never bleed into this decision.
    private func pendingNames(in rows: [AppRow]) -> [String] {
        rows.filter { $0.updateAvailable }.map { $0.app.name }
    }

    /// The one place per scheduled-fire completion. Order is deliberate:
    /// 1. The UNCONDITIONAL distributed event (scriptability contract in
    ///    `NotificationNames` — both branches, regardless of any decision).
    /// 2. The fire-to-fire decision (nil baseline suppresses), then the
    ///    new pending set becomes the stored baseline EVEN when suppressed —
    ///    the next fire must diff against THIS fire, whatever this fire did.
    /// 3. Local summary ONLY for `newlyPending` AND ``notificationsEnabled``.
    ///
    /// wasCatchUp is passed nil on honest purpose: the engine records the
    /// fire's catch-up identity into ScheduleState AFTER the fire returns,
    /// so `schedule.state.lastFireWasCatchUp` read here would be the
    /// PREVIOUS fire's flag — "unknown" beats a stale or invented fact.
    /// `error` is nil at every posting site: this runs on the success path
    /// only (documented in NotificationNames).
    private func recordScheduledFireOutcome(
        appsChecked: Int, pendingNames: [String]
    ) async {
        let userInfo = NotificationNames.scheduledFireUserInfo(
            appsChecked: appsChecked,
            pendingCount: pendingNames.count,
            wasCatchUp: nil,
            error: nil)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(NotificationNames.eventName),
            object: nil,
            userInfo: userInfo,
            deliverImmediately: false)

        let advice = NotificationDecider.advise(
            previousScheduledPending: lastScheduledPendingNames,
            currentPending: pendingNames)
        lastScheduledPendingNames = pendingNames

        guard case .newlyPending(let newNames) = advice,
              notificationsEnabled
        else { return }
        await postScheduledFireSummaryNotification(newNames: newNames)
    }

    /// The local ONE-per-fire summary. Ask-per-fire keeps the flow boring
    /// and the honesty surface single-purpose: every outcome lands verbatim
    /// in ``notificationsState`` (denial is NOT success — no fake green).
    ///
    /// IDENTIFIER CHOICE (decided, 2026-10-26): a per-fire UUID. A
    /// deterministic id (hash of the name set) was considered for System
    /// Settings dedupe, but the app target would need a CryptoKit import to
    /// build it and the coordinator decided UUID + documented Settings
    /// behavior. Consequence, stated honestly: identical repeat updates
    /// across fires are NOT collapsed by an identifier we control; macOS
    /// applies its own coalescing we do not guarantee.
    private func postScheduledFireSummaryNotification(newNames: [String]) async {
        let center = UNUserNotificationCenter.current()
        let granted: Bool
        do {
            granted = try await center.requestAuthorization(options: [.alert])
        } catch {
            notificationsState = "notification authorization failed — \(error)"
            return
        }
        guard granted else {
            notificationsState =
                "macOS denied notification permission — enable it in System Settings"
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "AppUpdater: \(newNames.count) app updates available"
        content.body = summaryBody(for: newNames)
        do {
            try await center.add(
                UNNotificationRequest(
                    identifier: UUID().uuidString,
                    content: content,
                    trigger: nil))
            notificationsState = nil
        } catch {
            notificationsState = "notification posting failed — \(error)"
        }
    }

    /// The summary body: up to ~5 names, then an honest "…" (the title
    /// already carries the exact count, so the ellipsis hides nothing the
    /// user cannot read in the window list — the count is stated, the rest
    /// is the stable sorted order).
    private func summaryBody(for names: [String]) -> String {
        let displayLimit = 5
        let shown = names.prefix(displayLimit).joined(separator: ", ")
        return names.count > displayLimit ? shown + ", …" : shown
    }

    /// Settings-pane writer for ``notificationsEnabled`` (the view binds a
    /// get/set Binding to this — see the property's doc note). Does NOT
    /// touch ``notificationsState``: the status line is the last-KNOWN
    /// outcome, not an assertion about the next one.
    func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
    }

    // MARK: Refresh + rule pipelines (the VM's real seams live here)

    /// The full refresh pipeline: scan → per-app source lookups → rules
    /// evaluation → rows. Runs on Check Now (menu + window) and behind the
    /// VM's refresh seam.
    ///
    /// NOTIFICATION BOUNDARY (LOCKED, scheduled-fires-only): this path
    /// NEVER posts the distributed fire event, never advances
    /// ``lastScheduledPendingNames`` and never advises the local
    /// notification decider — a manual nudge must never fake a schedule
    /// event or tune the scheduled-fire baseline.
    func pipelineRows() async throws -> [AppRow] {
        let apps = try await ProductionAppScanner().scan(directoryURLs: effectiveScanDirectories())
        let checks = await UpdateCheckEngine(
            sources: await checkSources()
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
            lastApps = try await ProductionAppScanner().scan(directoryURLs: effectiveScanDirectories())
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
