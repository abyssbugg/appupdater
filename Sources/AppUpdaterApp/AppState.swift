import SwiftUI
import AppKit
import UserNotifications
import os
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
///   Actionable extension (tier-2 gap, 2026-10-28): when the diff is
///   EXACTLY ONE updateable app, the notification carries the
///   `NotificationActionIDs.categoryPendingUpdate` category ("Open
///   AppUpdater" / "Install Update") and its actions route through
///   the SAME consent boundary — Open brings the main window forward,
///   Install runs the clicked-install chain via ``requestInstall`` (since
///   the 2026-10-29 clicked-install fix this REALLY installs user-space
///   updates; .pkg stages the owner command). Fires without actionable
///   content keep the existing passive summary byte-for-byte.
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

    // Honest refusal reasons surfaced from direct actions and the seam
    // bridge (ActionFailure — now in SeamRouter.swift, moved with the bridge
    // for the file_length gate; behavior unchanged).

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

    /// The exact owner-run command staged by the last Install press
    /// (nil until then). Shown verbatim in the window — the app itself
    /// never runs it.
    @Published private(set) var lastInstallCommand: String?

    /// The bundle the staged command belongs to (replaces string-matching the
    /// command text, which broke for app names containing spaces).
    @Published private(set) var lastInstallBundleID: String?

    /// The last clicked-install OUTCOME — a real verified apply (user-space)
    /// or a green pkg staging carrying the owner-run command. Scoped to its
    /// row via ``lastInstallOutcomeBundleID``; the detail card renders the
    /// honest receipt from this.
    @Published private(set) var lastInstallOutcome: InstallOutcome?
    @Published private(set) var lastInstallOutcomeBundleID: String?

    /// The row a clicked install is currently running for (nil = idle).
    /// Serialization guard: one install at a time; buttons disable and show
    /// progress off this.
    @Published private(set) var installInFlightBundleID: String?

    /// The last clicked-install REFUSAL (pre-planning or planner rejection),
    /// scoped to its row. LIVED-TEST FIX 2026-10-29: refusals previously
    /// surfaced ONLY via ``actionError`` on the list column's banner — which
    /// the click's own `showDetails` navigates AWAY from, so a refused
    /// install looked like a dead button. The detail card now renders this
    /// inline, exactly where the user is looking.
    @Published private(set) var lastInstallError: String?
    @Published private(set) var lastInstallErrorBundleID: String?

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

    /// The live UNUserNotificationCenter delegate. UNUserNotificationCenter
    /// holds its delegate WEAKLY, so AppState keeps the strong reference for
    /// the app's lifetime. The delegate carries NO decisions — it only
    /// translates UN types to plain strings, consults the pure core router
    /// (`NotificationActionRouter`, unit-proven) and hops to this actor for
    /// execution.
    private var notificationDelegate: NotificationResponseDelegate?

    /// Optional SwiftUI window-opening seam for the notification "Open"
    /// action. `openWindow(id:)` exists ONLY in view context (the scenes
    /// live in AppUpdaterApp.swift — outside this lane's file ownership), so
    /// the default implementation in ``openMainWindowFromNotification``
    /// brings the EXISTING main window forward via AppKit. This property is
    /// the one-line wiring point for the scene owner. HONEST LIMITATION
    /// while it stays unwired: with the seam nil and the window already
    /// closed by the user, the action still activates the app (menu bar
    /// forward) but cannot recreate the closed SwiftUI scene window — stated
    /// here rather than faked as success.
    var mainWindowOpener: (() -> Void)?

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
    /// Internal (was private) so the glue-wiring model can point the brew
    /// formula-index store at the same home — one path, one source of truth.
    let appSupportDirectory: URL

    /// Custom scan-location store (gap #18). /Applications is ALWAYS scanned;
    /// these directories add to it. AppState only READS it — the settings
    /// sheet mutates through its own view (which owns the NSOpenPanel).
    let scanLocationStore: ScanLocationStore

    /// Whole-index cask store (gap #1): one ETag-cached `cask.json` +
    /// alias-free artifact matching. `ensureLoaded` runs exactly once per
    /// check pass (the store's contract); an unusable index degrades to the
    /// proven per-token pipeline.
    private let caskIndexStore: CaskIndexStore

    /// Manual per-app source pins (gap #2): the owner's attestations. The
    /// sheet MUTATES this store; the resolver service READS it — one shared
    /// store, both wired below.
    let manualSourceStore: ManualSourceStore

    /// Builds the engine's per-app manual-source seam from the shared store.
    private let manualSourceResolver: ManualSourceResolverService

    let proxySession = ProxySessionController()  // glue-wiring: engines' sources adopt this proxied session (see ProxySession.swift)

    /// The real Application-Support home (the CLI uses the same path).
    private static let defaultAppSupportDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AppUpdater", isDirectory: true)

    /// Log surface for the welcome-tour persistence degradation (see
    /// AppState+Polish.swift `teardownWelcomeTour`).
    static let welcomeTourLog = Logger(subsystem: "io.appupdater.AppUpdater", category: "welcome-tour")

    // MARK: GAP #26 polish state (dock presence, welcome tour, migration)

    /// Persisted "Show in: Menu Bar / Menu Bar + Dock" choice. Loaded at
    /// init; written ONLY via ``setDisplayMode(showInDock:)`` (the settings
    /// picker's Binding). The launch-time policy/badge decision is
    /// ``launchShowInDock`` — a mid-session change persists for the NEXT
    /// launch only (the honest relaunch contract the settings caption
    /// states verbatim).
    @Published private(set) var displaySettings: DisplaySettings

    /// Verbatim settings-migration outcome line (nil = the normal
    /// fresh-envelope / already-current case). A migration FAILURE lands
    /// here verbatim — never swallowed, never launch-blocking.
    @Published private(set) var settingsMigrationNote: String?

    /// Verbatim failure of a display-setting save (nil = healthy). Kept
    /// separate from ``actionError`` so the settings sheet can show it next
    /// to the control that caused it.
    @Published private(set) var displayError: String?

    /// The display choice THIS launch was decided with — the activation-
    /// policy and dock-badge authority. The picker writes
    /// ``displaySettings`` for the next launch only.
    /// (Internal, not private: the polish extension AppState+Polish.swift
    /// owns these behaviors and extensions in another file cannot see
    /// private members — the same cross-file reality that put
    /// ``setNotificationsEnabled`` here.)
    let launchShowInDock: Bool

    /// GAP #26 stores over the shared app-support settings directory (both
    /// filenames registered in the core SettingsMigration envelope).
    let displaySettingsStore: DisplaySettingsStore
    let welcomeTourStore: WelcomeTourStateStore

    /// The welcome-tour window + its delegate holder (NSWindow holds its
    /// delegate weakly — this is the strong reference). Non-nil only while
    /// the tour is on screen. Internal: owned by the polish extension
    /// (AppState+Polish.swift).
    var welcomeWindow: NSWindow?
    var welcomeWindowDelegate: WelcomeWindowDelegate?
    /// The deferred first-launch presentation task (canceled on deinit).
    var welcomeTask: Task<Void, Never>?

    // MARK: Private bookkeeping

    /// The authoritative last pipeline outputs; every re-evaluation (rule
    /// mutation, scheduled fire) rebuilds rows from this pair.
    var lastApps: [InstalledApp] = []
    var lastChecks: [UpdateCheck] = []
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

        // GAP #26: the settings-migration pass runs FIRST — before ANY store
        // below is constructed or read (the single launch wiring call;
        // synchronous, so the before-every-store ordering is structural, not
        // a race). v1 is the identity migration: it stamps the envelope,
        // transforms nothing. A failure is recorded verbatim in
        // ``settingsMigrationNote`` and NEVER blocks launch — the stores
        // then load under their own contracts.
        let migration = SettingsMigrationService(directory: support)
        var migrationNoteText: String?
        do {
            switch try migration.runIfNeeded() {
            case .freshEnvelope, .alreadyCurrent:
                break
            case .migrated(let from, let to):
                migrationNoteText = "settings schema migrated \(from) → \(to)"
            }
        } catch {
            migrationNoteText = "settings migration failed — \(error)"
        }

        // GAP #26 stores (display choice + welcome flag): same shared
        // directory; both read synchronously HERE because the launch
        // decisions (activation policy, tour) depend on them before any
        // window exists (rationale in AppUIStateStores.swift's header).
        self.displaySettingsStore = DisplaySettingsStore(directory: support)
        self.welcomeTourStore = WelcomeTourStateStore(directory: support)
        let display = displaySettingsStore.load()
        self.displaySettings = display
        self.launchShowInDock = display.showInDock

        self.rules = RuleStore(directory: rulesDirectory)
        self.scheduleStore = ScheduleFileStore(directory: scheduleDirectory)
        self.scanDirectories = scanDirectories
        self.scanLocationStore = ScanLocationStore(directory: support)
        self.caskIndexStore = CaskIndexStore(directory: support, session: proxySession.session)
        self.manualSourceStore = ManualSourceStore(directory: support)
        self.manualSourceResolver = ManualSourceResolverService(store: manualSourceStore)

        // The router exists before ANY closure (and before `list`) is
        // created, so closures never capture a partially-built AppState.
        let router = SeamRouter()
        self.seams = router
        self.list = router.makeListViewModel()

        // Final init statements: self is fully initialized from here on.
        router.owner = self
        installNotificationActionSupport()
        settingsMigrationNote = migrationNoteText
        applyLaunchDisplayState(display)
        presentWelcomeTourIfNeeded()
        armDockBadgeObserver()
        restoreLastChecks()
        startScheduler()
        startFileSystemMonitor()
    }

    deinit {
        engineTask?.cancel()
        fsMonitorTask?.cancel()
        welcomeTask?.cancel()
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
        // nil ids = the list had nothing to supply (always true at launch, before
        // any rows exist). Resolve targets from THIS scan + the rules' autoCheck
        // decisions (default ON; `.noAutoCheck` opts out), so the first fire
        // really checks. Inventory-only remains only when every app opted out.
        let wanted: Set<String>
        if let ids {
            wanted = Set(ids)
        } else {
            let decided = await rules.evaluate(apps: apps, checks: [])
            wanted = Set(decided.filter { $0.decision.autoCheck }.map { $0.app.bundleIdentifier })
        }
        let targets = apps.filter { wanted.contains($0.bundleIdentifier) }
        guard !targets.isEmpty else {
            lastChecks = carriedChecks(for: apps)
            lastApps = apps
            let evaluated = await rules.evaluate(apps: apps, checks: lastChecks)
            await list.setRows(evaluated)
            // Honest: no source was consulted in an inventory-only fire.
            await recordScheduledFireOutcome(appsChecked: 0, evaluatedRows: evaluated)
            return 0
        }
        let checks = await UpdateCheckEngine(
            sources: await checkSources(),
            manualSource: manualSourceResolver.engineResolver(
                session: proxySession.session, githubCacheDirectory: appSupportDirectory),
            verifiedInstalls: VerifiedInstallLedger(directory: appSupportDirectory),
            feedDerivation: FeedDerivationResolver { app in
                SparkleFeedDerivation.candidateFeeds(appBundlePath: app.path)
            }
        ).checkAll(apps: targets)
        lastApps = apps
        lastChecks = checks
        let evaluated = await rules.evaluate(apps: apps, checks: checks)
        persistLastChecks()
        await list.setRows(evaluated)
        await recordScheduledFireOutcome(appsChecked: targets.count, evaluatedRows: evaluated)
        // Decision-14: opt-in auto-apply pass (master OFF by default).
        lastAutoApplyReceipt = await runAutoApplyPass(evaluated: evaluated)
        return targets.count
    }

    /// Prior verdicts carried onto a fresh scan (`CheckCarryOver`): unchanged
    /// apps keep their check; new, moved, or self-updated apps get an
    /// unchecked placeholder. No source is consulted (LOCKED decision 13).
    func carriedChecks(for apps: [InstalledApp]) -> [UpdateCheck] {
        let carried = CheckCarryOver.carry(previousChecks: lastChecks, previousApps: lastApps, newApps: apps)
        return zip(apps, carried).map { app, check in check ?? UpdateCheck(app: app, candidates: [], resolved: nil) }
    }

    // MARK: Gap-sprint wiring (scan roots, source roster, FS monitor)

    /// The scan roots for this pass: the base roots (default /Applications)
    /// PLUS every resolvable custom location (gap #18). /Applications is
    /// always first (the store refuses to duplicate it); vanished custom
    /// directories are skipped (they stay listed in the settings sheet with
    /// their honest missing-dot); a failed store read never silently drops
    /// locations — it surfaces verbatim in ``scanLocationsError`` and the
    /// scan proceeds on the base roots alone.
    func effectiveScanDirectories() -> [URL] {
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
    /// - **Manual pins** (gap #2) are wired via the engine's
    ///   `manualSource` seam at every engine construction site: a pinned app
    ///   consults ONLY its pin (manual-over-builtin); unpinned apps run the
    ///   roster above untouched.
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
            sources.append(CaskSource(session: proxySession.session))
        }
        sources.append(SparkleSource())
        sources.append(MASSource(session: proxySession.session))
        sources.append(GithubSource(directory: appSupportDirectory, session: proxySession.session))
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
            // Verdicts survive a folder change; only changed/vanished apps lose theirs.
            let checksForEvaluation = carriedChecks(for: apps)
            lastApps = apps
            lastChecks = checksForEvaluation
            let evaluated = await rules.evaluate(apps: apps, checks: checksForEvaluation)
            await list.setRows(evaluated)
        } catch {
            actionError = "rescan after a folder change failed — \(error)"
        }
    }

    // MARK: Scheduled-fire notification side-effects (both branches)

    /// The one place per scheduled-fire completion. Order is deliberate:
    /// 1. The UNCONDITIONAL distributed event (scriptability contract in
    ///    `NotificationNames` — both branches, regardless of any decision).
    /// 2. The fire-to-fire decision (nil baseline suppresses), then the
    ///    new pending set becomes the stored baseline EVEN when suppressed —
    ///    the next fire must diff against THIS fire, whatever this fire did.
    /// 3. Local notification ONLY for `newlyPending` AND
    ///    ``notificationsEnabled`` — actionable when the pure planner says
    ///    the fire names exactly one stageable app, the EXISTING passive
    ///    summary otherwise (shape unchanged from the 2026-10-26 policy).
    ///
    /// Rows come from the fire's OWN evaluation (never from `list.rows`), so
    /// a manual refresh racing a scheduled fire can never bleed into this
    /// decision — the same honesty rule the pre-planner pipeline had.
    ///
    /// wasCatchUp is passed nil on honest purpose: the engine records the
    /// fire's catch-up identity into ScheduleState AFTER the fire returns,
    /// so `schedule.state.lastFireWasCatchUp` read here would be the
    /// PREVIOUS fire's flag — "unknown" beats a stale or invented fact.
    /// `error` is nil at every posting site: this runs on the success path
    /// only (documented in NotificationNames).
    private func recordScheduledFireOutcome(
        appsChecked: Int, evaluatedRows: [AppRow]
    ) async {
        let pending = evaluatedRows.filter { $0.updateAvailable }
        let names = pending.map { $0.app.name }
        let userInfo = NotificationNames.scheduledFireUserInfo(
            appsChecked: appsChecked,
            pendingCount: names.count,
            wasCatchUp: nil,
            error: nil)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(NotificationNames.eventName),
            object: nil,
            userInfo: userInfo,
            deliverImmediately: false)

        let advice = NotificationDecider.advise(
            previousScheduledPending: lastScheduledPendingNames,
            currentPending: names)
        lastScheduledPendingNames = names

        guard case .newlyPending(let newNames) = advice,
              notificationsEnabled
        else { return }
        // Stageability mirrors the window's own Stage-button visibility
        // (`!isMacAppStore`): the notification offers exactly what the
        // existing consent boundary would honor. The DECISION stays pure —
        // the planner owns every actionable-vs-passive rule.
        let candidates = pending.map { row in
            NotificationActionPlanner.PendingCandidate(
                appName: row.app.name,
                bundleID: row.app.bundleIdentifier,
                stageable: !row.app.isMacAppStore)
        }
        await postScheduledFireNotification(
            plan: NotificationActionPlanner.plan(
                newlyPendingNames: newNames, candidates: candidates))
    }

    /// Shapes and posts ONE local notification for this fire. The passive
    /// branch is byte-identical to the pre-actionable summary (same title,
    /// same body, no category, no payload) — the actionable shape EXTENDS,
    /// never replaces.
    ///
    /// IDENTIFIER CHOICE (decided, 2026-10-26): a per-fire UUID. A
    /// deterministic id (hash of the name set) was considered for System
    /// Settings dedupe, but the app target would need a CryptoKit import to
    /// build it and the coordinator decided UUID + documented Settings
    /// behavior. Consequence, stated honestly: identical repeat updates
    /// across fires are NOT collapsed by an identifier we control; macOS
    /// applies its own coalescing we do not guarantee.
    private func postScheduledFireNotification(
        plan: NotificationActionPlanner.Plan
    ) async {
        let content = UNMutableNotificationContent()
        switch plan {
        case .actionableSingleApp(let name, let bundleID):
            content.title = "Update available: \(name)"
            content.body =
                "AppUpdater found a newer version of \(name) — nothing installs by itself."
            content.categoryIdentifier = NotificationActionIDs.categoryPendingUpdate
            content.userInfo = NotificationActionIDs.pendingUpdateUserInfo(
                appName: name, bundleID: bundleID)
        case .passiveSummary(let names):
            // The decider never yields empty news; this guard is the
            // planner's total-function defense — post nothing rather than a
            // fake summary.
            guard !names.isEmpty else { return }
            content.title = "AppUpdater: \(names.count) app updates available"
            content.body = summaryBody(for: names)
        }
        await postLocalNotification(content: content)
    }

    /// The shared authorization + posting path for every local notification
    /// (summary or actionable). Ask-per-fire keeps the flow boring and the
    /// honesty surface single-purpose: every outcome lands verbatim in
    /// ``notificationsState`` (denial is NOT success — no fake green).
    private func postLocalNotification(content: UNMutableNotificationContent) async {
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

    /// Registers the frozen actionable category and installs the response
    /// delegate. Registration is idempotent and done ONCE at launch (before
    /// any fire can post); the delegate is kept alive by
    /// ``notificationDelegate`` (UNUserNotificationCenter holds it weakly).
    private func installNotificationActionSupport() {
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(
                identifier: NotificationActionIDs.categoryPendingUpdate,
                actions: [
                    UNNotificationAction(
                        identifier: NotificationActionIDs.actionOpen,
                        title: "Open AppUpdater",
                        options: [.foreground]),
                    UNNotificationAction(
                        identifier: NotificationActionIDs.actionStageInstall,
                        title: "Update",
                        options: []),
                ],
                intentIdentifiers: [],
                options: []),
        ])
        let delegate = NotificationResponseDelegate { [weak self] outcome in
            self?.handleNotificationAction(outcome)
        }
        notificationDelegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// Executes a notification response's outcome on the MainActor. Every
    /// branch routes through the EXISTING consent boundary — nothing here
    /// downloads, installs, or executes anything:
    /// - `.openMainWindow` → ``openMainWindowFromNotification``.
    /// - `.stageInstall` → ``requestInstall`` ONLY when the app is still in
    ///   the current rows; a vanished row is surfaced through
    ///   ``actionError`` (never a silent no-op, never a fabricated success).
    /// - `.ignored` → executes nothing (unknown/dismissed responses).
    private func handleNotificationAction(
        _ outcome: NotificationActionRouter.Outcome
    ) {
        switch outcome {
        case .openMainWindow:
            openMainWindowFromNotification()
        case .stageInstall(let bundleID, let appName):
            if list.rows.contains(where: { $0.app.bundleIdentifier == bundleID }) {
                Task { await requestInstall(bundleID: bundleID) }
            } else {
                actionError =
                    "Update for \(appName): it is no longer in the current list — run a check and update it from the window."
            }
        case .ignored:
            break
        }
    }

    /// The notification actions' window opening. ``mainWindowOpener`` (the
    /// SwiftUI seam) wins when wired; otherwise the AppKit fallback brings
    /// the EXISTING main window forward (the scene presents it at launch —
    /// the normal case). Honest limitation: neither path can recreate a
    /// window the user closed, because `openWindow(id:)` lives in view
    /// context only — see ``mainWindowOpener``'s doc.
    func openMainWindowFromNotification() {
        NSApp.activate(ignoringOtherApps: true)
        if let opener = mainWindowOpener {
            opener()
            return
        }
        if let window = NSApp.windows.first(where: { $0.title == "AppUpdater" }) {
            window.makeKeyAndOrderFront(nil)
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

    /// Settings-pane writer for the "Show in" picker (GAP #26). Persists
    /// immediately; the activation policy + dock badge apply on the NEXT
    /// launch (the caption in ScheduleSettingsView states this verbatim —
    /// no live-switch theater). On a save failure the in-memory value snaps
    /// back to the DISK truth and the verbatim error lands in
    /// ``displayError``. Lives HERE, like ``setNotificationsEnabled``:
    /// `private(set)` writers cannot be reached from another file's
    /// extension.
    func setDisplayMode(showInDock: Bool) {
        displaySettings = DisplaySettings(showInDock: showInDock)
        do {
            try displaySettingsStore.save(displaySettings)
            displayError = nil
        } catch {
            displayError = "display_settings.json save failed — \(error)"
            displaySettings = displaySettingsStore.load()
        }
    }

    // MARK: Refresh + rule pipelines (the VM's real seams live here)

    /// The full refresh pipeline: scan → per-app source lookups → rules
    /// evaluation → rows. Runs on Check Now (menu + window) and behind the
    /// VM's refresh seam.
    ///
    /// NOTIFICATION BOUNDARY (LOCKED, scheduled-fires-only): this path NEVER
    /// posts the distributed fire event, never advances
    /// ``lastScheduledPendingNames`` and never advises the local notification
    /// decider — a manual nudge must never fake a schedule event or tune the
    /// scheduled-fire baseline. Decision-14 auto-apply: the latest pass's
    /// verbatim receipt (nil = the pass never ran — the master switch defaults
    /// OFF). UI surfaces read this; nothing here is hidden.
    @Published private(set) var lastAutoApplyReceipt: AutoApplyRunReceipt?

    /// Decision-14 settings store (global master switch + per-app opt-ins).
    let autoApplySettingsStore = AutoApplySettingsStore()

    /// The per-use consent surface: the click delegates to the Decision-14
    /// extension and any refusal/failure lands verbatim in the action banner.
    func typeStagedCommandInTerminal(_ command: String) {
        if let error = terminalTypingError(for: command) {
            actionError = error
        }
    }

    func pipelineRows() async throws -> [AppRow] {
        let apps = try await ProductionAppScanner().scan(directoryURLs: effectiveScanDirectories())
        let checks = await UpdateCheckEngine(
            sources: await checkSources(),
            manualSource: manualSourceResolver.engineResolver(
                session: proxySession.session, githubCacheDirectory: appSupportDirectory),
            verifiedInstalls: VerifiedInstallLedger(directory: appSupportDirectory),
            feedDerivation: FeedDerivationResolver { app in
                SparkleFeedDerivation.candidateFeeds(appBundlePath: app.path)
            }
        ).checkAll(apps: apps)
        lastApps = apps
        lastChecks = checks
        persistLastChecks()
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
        case .noAutoCheck:
            try await rules.setAutoCheck(bundleID, false)
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

    // MARK: Clicked-install boundary (the click IS the consent)

    /// The clicked-install entry point (rows, detail card, notifications).
    /// User-space updates (dmg/zip) run the VERIFIED CHAIN in-process —
    /// exactly the sequence `appupdater-cli install --apps <name> --apply`
    /// runs (plan → download → HTTPS + SHA-256 + artifact-magic verify →
    /// backup → quit → swap → postScan); receipts publish verbatim. A green
    /// .pkg staging instead surfaces the owner-run command (pasteboard +
    /// verbatim display) — installer(8) is NEVER executed by this app,
    /// unchanged. Serialized: one install at a time (installs are heavy);
    /// refusals and aborts surface honestly via ``actionError``.
    func requestInstall(bundleID: String) async {
        guard installInFlightBundleID == nil else { return }
        guard let row = list.rows.first(where: { $0.app.bundleIdentifier == bundleID }) else {
            return
        }
        installInFlightBundleID = bundleID
        defer { installInFlightBundleID = nil }
        // A fresh attempt clears the previous refusal for this row — the card
        // shows the CURRENT truth, never a stale complaint.
        lastInstallError = nil
        lastInstallErrorBundleID = nil
        do {
            let outcome = try await performClickedInstall(row: row)
            lastInstallOutcome = outcome
            lastInstallOutcomeBundleID = bundleID
            if let staged = outcome.stagedCommand, outcome.abortedStep == nil {
                lastInstallCommand = staged
                lastInstallBundleID = bundleID
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(staged, forType: .string)
            } else {
                // A real apply (or an abort): drop any stale staged command
                // so the card shows THIS outcome, not a dead command.
                lastInstallCommand = nil
                lastInstallBundleID = nil
            }
            if let aborted = outcome.abortedStep {
                let message =
                    "Update for \(row.app.name) stopped at \(aborted.rawValue) — the receipt shows how far it got; nothing was left half-done silently."
                lastInstallError = message
                lastInstallErrorBundleID = bundleID
                actionError = message
            }
        } catch {
            // Surface the refusal where the user IS (the detail card), not
            // only on the list column's banner — see lastInstallError's doc.
            lastInstallError = "Update for \(row.app.name) refused: \(error.localizedDescription)"
            lastInstallErrorBundleID = bundleID
            actionError = lastInstallError
        }
    }

    /// Menu "View Details": open the window with this row preselected.
    func showDetails(bundleID: String) {
        if let row = list.rows.first(where: { $0.app.bundleIdentifier == bundleID }) {
            list.select(row.id)
        }
    }
}
