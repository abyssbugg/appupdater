// GluePanels.swift — glue-wiring lane: the read-only engine surfaces the
// 2026-10-29 audit found tested-but-unwired (SecurityPanel / Storefront /
// CandidateFilter / Brew pins+doctor+formula-index / proxy settings+env),
// exposed as ONE app-scoped observable model the window, detail inspector
// and sheets bind through.
//
// CONSENT BOUNDARIES (hard, restated at the wiring site per the engines' own
// headers):
// - Security (SecInspector): read-only codesign/spctl/entitlements probes.
//   Never writes, never spawns anything beyond the four documented probes.
// - CandidateFilter: read-only FILE reads only (installer-bundle names,
//   InstallBuilder markers, Mach-O header parsing) over the selected app's
//   bundle. No processes, no writes; display data — the filter never
//   overrides the security floor, and a receipt here is not a gate.
// - Storefront (SetappSupport / IOSAppOnMac / Storefront): read-only path
//   classification + StoreKit storefront read. MAS lookups keep their locked
//   `us` country pin — the storefront verdict is DISPLAY data only; nothing
//   here re-routes a lookup by country.
// - Brew (BrewPinsParser / BrewPrefixResolver / BrewPinWatcher /
//   BrewDoctorCheck / BrewFormulaIndexStore): pins are READ-ONLY. The watcher
//   stats two files' mtimes and its callback re-reads + re-parses the pinned
//   files — it never runs brew, mas, or any install/update; command execution
//   stays with the owner. `brew doctor` is the engine-sanctioned read-only
//   probe (no sudo, hardening env applied by the engine itself). The formula
//   index is the engine's own ETag-cached GET of the public formulae.brew.sh
//   catalog — read-only data plane, loaded ONLY on an explicit button press
//   (no launch-time or sheet-open network), cache files in the shared
//   Application Support home.
// - Proxy (ProxySettingsStore / SystemProxyMonitor / ProxyEnvironment):
//   read-only display + configuration. The monitor only READS SCDynamicStore
//   state; the env passthrough is a pure process-environment read (the
//   engine's own posture: "reading env is introspection, not traffic") and is
//   REPORT-ONLY — no precedence decision is acted on here. Saving settings
//   writes proxy_settings.json (the store's own contract); proxy passwords go
//   to the Keychain via the engine's ProxyKeychain seam. Nothing here opens a
//   connection or mutates system proxy state.
//
// LIFECYCLE: the model is app-scoped (created in AppUpdaterApp's scene and
// injected as an environment object). The brew watcher and the proxy monitor
// are STARTED AND STOPPED BY THEIR SHEETS (on appear / on disappear) — a
// deliberate lean choice: no launch-time subprocess or SC store is created
// unless the owner opens the surface, and nothing outlives the sheet that
// started it. The formula-index load is button-initiated. Stated here rather
// than implied.
//
// HERMETIC-TEST NOTE: this type lives in the app target; the package's only
// test target links AppUpdaterCore alone (Package.swift is frozen), so this
// glue is exercised by build + the live CLI gate, not by the hermetic suite.
// The JSON/verdict contracts it renders are pinned in
// Tests/AppUpdaterCoreTests/GlueWireJSONTests.swift at the Core type level.

import Foundation
import SwiftUI
import AppUpdaterCore

@MainActor
final class GluePanelsModel: ObservableObject {

    /// The shared session-adoption controller (AppState owns it — the engines
    /// are constructed with its session; the proxy sheet drives it from here).
    /// One source of truth: the sheet's "save & apply" goes through this
    /// controller, so the engines' next check pass picks the settings up.
    let proxySession: ProxySessionController

    /// The Application-Support home the brew formula-index store caches into
    /// (injected from AppState — the SAME home every disk-backed store uses).
    private let brewIndexDirectory: URL

    init(proxySession: ProxySessionController, brewIndexDirectory: URL) {
        self.proxySession = proxySession
        self.brewIndexDirectory = brewIndexDirectory
    }

    // MARK: Security (SecInspector + bundle forensics)

    /// One SecReport per inspected app path (cached for the session; the
    /// Inspect button re-runs the probes).
    @Published private(set) var securityReports: [String: SecReport] = [:]
    /// Paths whose inspection is currently running (re-entrancy guard).
    @Published private(set) var securityInFlight: Set<String> = []

    /// One iOS-app-on-Mac classification per bundle path (cached).
    @Published private(set) var iosOnMacReports: [String: IOSAppOnMacInfo] = [:]
    @Published private(set) var iosOnMacInFlight: Set<String> = []

    /// The machine's storefront verdict (loaded once per session; StoreKit
    /// probe, no network).
    @Published private(set) var storefront: StorefrontInfo?

    /// Runs (or re-runs) the security panel's four read-only probes for one
    /// app path. Never throws — the inspector folds every failure into the
    /// report's honest notes.
    func inspectSecurity(appPath: String) async {
        guard !securityInFlight.contains(appPath) else { return }
        securityInFlight.insert(appPath)
        defer { securityInFlight.remove(appPath) }
        let report = await SecInspector.inspect(appAt: URL(fileURLWithPath: appPath))
        securityReports[appPath] = report
    }

    /// Runs (or re-runs) the iOS-app-on-Mac classification for one bundle
    /// path (read-only file reads + the two documented local probes).
    func classifyIOSOnMac(bundlePath: String) async {
        guard !iosOnMacInFlight.contains(bundlePath) else { return }
        iosOnMacInFlight.insert(bundlePath)
        defer { iosOnMacInFlight.remove(bundlePath) }
        let info = await IOSAppOnMac.classify(bundlePath: bundlePath)
        iosOnMacReports[bundlePath] = info
    }

    /// Loads the machine storefront verdict once (later calls keep the first
    /// verdict — a storefront does not change mid-session).
    func loadStorefront() async {
        guard storefront == nil else { return }
        storefront = await Storefront.currentStorefront()
    }

    // MARK: Candidates (deep artifact signals over the selected app's bundle)

    /// One CandidateFilterReport per app path (cached for the session; the
    /// button re-runs the three read-only detectors).
    @Published private(set) var candidateReports: [String: CandidateFilterReport] = [:]
    /// Paths whose filter run is currently in flight (re-entrancy guard).
    @Published private(set) var candidateInFlight: Set<String> = []

    /// Runs the deep candidate-filter's three read-only detectors
    /// (installer-bundle names, InstallBuilder markers, Electron wrong-arch)
    /// over the selected app's deployed bundle. FILE READS ONLY — no
    /// processes, no writes. The receipts are display data: they never
    /// override the security floor and never gate anything here.
    func filterCandidate(appPath: String) async {
        guard !candidateInFlight.contains(appPath) else { return }
        candidateInFlight.insert(appPath)
        defer { candidateInFlight.remove(appPath) }
        let report = CandidateFilter.filter(candidateURL: URL(fileURLWithPath: appPath))
        candidateReports[appPath] = report
    }

    // MARK: Brew (pins + doctor + watcher)

    /// The resolved Homebrew prefix (nil = `brew --prefix` unresolvable —
    /// honest unknown, never a guessed install root).
    @Published private(set) var brewPrefixURL: URL?
    @Published private(set) var brewPrefixNote: String?

    /// The pinned sets as last parsed (nil = never read this session).
    @Published private(set) var brewPins: BrewPins?
    /// Honest parse + read notes (what was skipped, which file was absent).
    @Published private(set) var brewNotes: [String] = []
    /// The last `brew doctor` verdict (nil = never run this session).
    @Published private(set) var brewDoctor: BrewDoctorResult?
    /// The doctor probe's re-entrancy guard (button disabled while running).
    @Published private(set) var brewDoctorInFlight = false
    /// The watcher's last mtime observation (nil = watcher never fired).
    @Published private(set) var brewLastObservation: BrewPinsObservation?
    @Published private(set) var brewWatcherRunning = false

    /// The poll-loop task (canceled on stop — cancellation surfaces at the
    /// watcher's sleep and the loop exits without firing).
    private var brewWatcherTask: Task<Void, Never>?

    /// Sane poll cadence for the mtime watcher (the engine leaves the cadence
    /// to the wiring; two stat() calls per tick are negligible).
    private static let brewWatcherInterval: TimeInterval = 2.0

    /// Resolves the prefix and reads + parses the two pinned files. Read-only
    /// end to end: one `brew --prefix` path probe + two file reads. A missing
    /// pinned file is a legal "no pins" observation, never an error.
    func refreshBrewPins() async {
        let prefix = await BrewPrefixResolver(runner: .live()).resolve()
        guard let prefix else {
            brewPrefixURL = nil
            brewPrefixNote = "`brew --prefix` unresolvable (brew missing, non-zero exit, or empty "
                + "output) — pins unknown, never guessed"
            brewPins = nil
            brewNotes = []
            return
        }
        brewPrefixURL = prefix
        brewPrefixNote = nil
        let (formulaeURL, casksURL) = BrewPrefixResolver.pinnedFileURLs(prefix: prefix)
        var notes: [String] = []
        var formulae = Set<String>()
        var casks = Set<String>()

        if let text = Self.readText(formulaeURL) {
            let parsed = BrewPinsParser.parse(text)
            formulae = parsed.pins.formulae
            notes.append(contentsOf: parsed.notes)
        } else {
            notes.append("\(formulaeURL.path) absent — no pinned formulae recorded (a missing "
                + "pinned file observes as \"no pins\", never an error)")
        }
        if let text = Self.readText(casksURL) {
            let parsed = BrewPinsParser.parse(text)
            casks = parsed.pins.casks
            notes.append(contentsOf: parsed.notes)
        } else {
            notes.append("\(casksURL.path) absent — no pinned casks recorded")
        }
        brewPins = BrewPins(formulae: formulae, casks: casks)
        brewNotes = notes
    }

    /// Runs the engine-sanctioned read-only `brew doctor` probe (hardening env
    /// and no-sudo discipline are the engine's own; never throws).
    func runBrewDoctor() async {
        guard !brewDoctorInFlight else { return }
        brewDoctorInFlight = true
        defer { brewDoctorInFlight = false }
        brewDoctor = await BrewDoctorCheck(runner: .live()).run()
    }

    /// Starts/stops the pinned-file mtime watcher. The callback's ONLY action
    /// is re-reading + re-parsing the pinned files (read-only) — this is the
    /// written re-affirmation the BrewPinWatcher contract requires at the
    /// wiring site: NO brew/mas/install execution, ever, from this consumer.
    func setBrewWatcherRunning(_ running: Bool) async {
        if !running {
            brewWatcherTask?.cancel()
            brewWatcherTask = nil
            brewWatcherRunning = false
            return
        }
        guard !brewWatcherRunning else { return }
        // The watcher needs the pinned file locations; resolve on demand (the
        // sheet's refresh already did when it could). The resolver call is
        // hoisted because `??`'s right side is a non-concurrent autoclosure.
        let resolvedPrefix = await BrewPrefixResolver(runner: .live()).resolve()
        let prefix = brewPrefixURL ?? resolvedPrefix
        guard let prefix else {
            brewPrefixNote = "`brew --prefix` unresolvable — the watcher has no pinned locations "
                + "to watch (nothing guessed)"
            return
        }
        brewPrefixURL = prefix
        let (formulaeURL, casksURL) = BrewPrefixResolver.pinnedFileURLs(prefix: prefix)
        let watcher = BrewPinWatcher(
            interval: Self.brewWatcherInterval,
            formulaePinsURL: formulaeURL,
            casksPinsURL: casksURL)
        brewWatcherTask = watcher.start { [weak self] observation in
            guard let self else { return }
            Task { @MainActor in
                self.brewLastObservation = observation
                // Delta observed — the pinned files moved. Re-read their
                // contents (read-only) so the displayed pins stay the truth.
                await self.refreshBrewPins()
            }
        }
        brewWatcherRunning = true
    }

    /// Plain text read; nil for a missing/unreadable file (the caller notes
    /// the absence honestly).
    private static func readText(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Brew formula whole-index (BrewFormulaIndexStore)

    /// The formula index status as last ensured (nil = never loaded this
    /// session). The store is the engine's own ETag-cached GET of the public
    /// formulae.brew.sh catalog — read-only data plane, cache files in the
    /// shared Application Support home, brew NEVER executed.
    @Published private(set) var brewIndexLoaded: Bool?
    @Published private(set) var brewIndexRecordCount: Int?
    /// The store's verbatim last load failure (nil = clean cycle).
    @Published private(set) var brewIndexLastError: String?
    /// The load's re-entrancy guard (button disabled while running).
    @Published private(set) var brewIndexInFlight = false

    /// Ensures the formula whole-index (one ETag-cached GET when the disk
    /// cache is stale; 304 revalidation otherwise) and publishes its public
    /// status surface. Button-initiated only — no launch-time or sheet-open
    /// network. A failed load is honest data (loaded=false + verbatim
    /// lastError), never an error dialog; stale-but-verifiable records still
    /// count as loaded per the store's own contract.
    func loadBrewFormulaIndex() async {
        guard !brewIndexInFlight else { return }
        brewIndexInFlight = true
        defer { brewIndexInFlight = false }
        let store = BrewFormulaIndexStore(directory: brewIndexDirectory, session: proxySession.session)
        let loaded = await store.ensureLoaded()
        brewIndexLoaded = loaded
        brewIndexRecordCount = await store.cachedRecordCount
        brewIndexLastError = await store.lastError
    }

    // MARK: Proxy (settings + system monitor display)

    // Settings STATE lives on the shared ProxySessionController (injected
    // above) — the single source of truth both this sheet and the engines'
    // session read. This section owns only the sheet-scoped outcomes (save
    // notes, keychain map, monitor display).

    /// Verbatim store failure (nil = healthy).
    @Published private(set) var proxyError: String?

    /// The last save/validation outcome line (nil = nothing to report).
    @Published private(set) var proxySaveNote: String?

    /// Whether a keychain credential exists per protocol (the honest
    /// "auth configured" probe — never implies the password is valid).
    @Published private(set) var proxyCredentials: [ProxyProtocolName: Bool] = [:]

    /// The live system-proxy snapshot (nil = the monitor never ran this
    /// session; the sheet starts/stops it).
    @Published private(set) var proxyMonitorSnapshot: SystemProxySnapshot?
    @Published private(set) var proxyMonitorRunning = false
    /// Honest monitor status (e.g. SCDynamicStore creation failed).
    @Published private(set) var proxyMonitorNote: String?

    /// The monitor instance for the CURRENT monitoring window (a monitor
    /// retires on documented failures, so a fresh one is created per start).
    private var proxyMonitor: SystemProxyMonitor?

    /// The documented proxy environment variables as the process sees them
    /// (nil = never read this session). Pure env read (ProxyEnvironment's own
    /// posture: "reading env is introspection, not traffic") — REPORT-ONLY:
    /// no precedence decision between env vars, system proxies, and manual
    /// settings is acted on anywhere in this model.
    @Published private(set) var proxyEnvPassthrough: ProxyEnvironmentPassthrough?

    /// Reloads the persisted settings through the shared controller (which
    /// adopts them into the engines' session on success).
    func loadProxySettings() async {
        await proxySession.reloadFromStore()
        refreshProxyCredentialMap()
        proxyEnvPassthrough = ProxyEnvironment.current()
    }

    /// Persists settings (the store's atomic write), then — on success —
    /// adopts them into the engines' session via the shared controller.
    /// Validation failure is NOT a save: the documented
    /// "Invalid proxy configuration" reason is returned for the sheet to
    /// render verbatim, and nothing is adopted.
    @discardableResult
    func saveProxySettings(_ settings: ProxySettings) async -> Bool {
        if let reason = settings.validationFailureReason() {
            proxySaveNote = reason + " — not saved"
            return false
        }
        do {
            try await ProxySettingsStore().save(settings)
            proxySession.adopt(settings)
            proxySaveNote = "saved and applied to the app's session"
            proxyError = nil
            return true
        } catch {
            proxyError = "proxy_settings.json save failed — \(error)"
            return false
        }
    }

    /// Stores (or deletes) one protocol's proxy password in the Keychain via
    /// the engine's ProxyKeychain seam. Failure surfaces the documented
    /// string family verbatim.
    func saveProxyPassword(_ password: String, for protocolName: ProxyProtocolName) {
        do {
            if password.isEmpty {
                try ProxyKeychain(store: SecurityKeychainStore()).deleteProxyPassword(for: protocolName)
            } else {
                try ProxyKeychain(store: SecurityKeychainStore()).saveProxyPassword(password, for: protocolName)
            }
            proxySaveNote = password.isEmpty
                ? "keychain credential for \(protocolName.rawValue) deleted"
                : "keychain credential for \(protocolName.rawValue) stored"
            refreshProxyCredentialMap()
        } catch {
            proxyError = "\(error)"
        }
    }

    private func refreshProxyCredentialMap() {
        let keychain = ProxyKeychain(store: SecurityKeychainStore())
        var map: [ProxyProtocolName: Bool] = [:]
        for name in ProxyProtocolName.allCases {
            map[name] = keychain.hasCredential(for: name)
        }
        proxyCredentials = map
    }

    /// Starts the system-proxy monitor (read-only SCDynamicStore watcher) and
    /// publishes its snapshots. A second start while running is a no-op; a
    /// store-creation failure is recorded as an honest note with NO monitor
    /// started (no fake "no proxy detected" from a broken store).
    func startProxyMonitor() {
        guard !proxyMonitorRunning else { return }
        guard let seam = SCProxyStore.live() else {
            proxyMonitorNote =
                "system proxy monitoring unavailable — SCDynamicStore creation failed "
                + "(the documented \"Failed to create SCDynamicStore\" branch); "
                + "no snapshot is shown rather than a fake empty one"
            proxyMonitorSnapshot = nil
            return
        }
        let monitor = SystemProxyMonitor(makeStore: { seam })
        proxyMonitor = monitor
        monitor.start { [weak self] snapshot in
            guard let self else { return }
            Task { @MainActor in
                self.proxyMonitorSnapshot = snapshot
            }
        }
        // start() delivers the INITIAL snapshot synchronously before it
        // returns (engine contract); a seam failure retired the monitor and
        // left isRunning false — surfaced honestly.
        if monitor.isRunning {
            proxyMonitorRunning = true
            proxyMonitorSnapshot = monitor.currentSnapshot()
            proxyMonitorNote = nil
        } else {
            proxyMonitorRunning = false
            proxyMonitorNote = "system proxy monitoring could not start (seam failure) — "
                + "no snapshot is shown rather than a fake empty one"
            proxyMonitor = nil
        }
    }

    /// Full teardown (idempotent per the engine's contract).
    func stopProxyMonitor() {
        proxyMonitor?.stop()
        proxyMonitor = nil
        proxyMonitorRunning = false
    }
}
