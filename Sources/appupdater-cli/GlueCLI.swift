// GlueCLI.swift — the glue-wiring read-only CLI modes + their wire shapes
// (coordinator extraction from Main.swift for file-length/complexity lint).
// Consent note: every mode here is READ-ONLY user-space inspection;
// brew-doctor runs through the engine's own runner seam and nothing else
// spawns. The dispatchGlueMode guard keeps these modes returning BEFORE
// any scan/source-roster work (they need none).

import Foundation
import AppUpdaterCore

extension CliMain {
    /// Handles the glue modes; true = handled (the caller returns).
    static func dispatchGlueMode(
        mode: String, securityPath: String?, appSupport: URL, outFile: String?
    ) async throws -> Bool {
        switch mode {
        case "security":
            try await runSecurity(appPath: securityPath, outFile: outFile)
            return true
        case "brew-pins":
            try await runBrewPins(outFile: outFile)
            return true
        case "brew-doctor":
            try await runBrewDoctor(outFile: outFile)
            return true
        case "brew-index":
            try await runBrewIndex(appSupport: appSupport, outFile: outFile)
            return true
        case "proxy":
            try await runProxyShow(outFile: outFile)
            return true
        default:
            return false
        }
    }

    // MARK: - Glue-wiring read-only modes (security / brew-pins / brew-doctor / proxy show)

    /// `security <app-path>`: one app's security panel — SecInspector's
    /// read-only codesign/spctl/entitlement probes plus the bundle-forensics
    /// classifications (iOS-app-on-Mac wrapper receipts, Setapp membership).
    /// All engines are read-only user-space probes; nothing is modified,
    /// nothing is installed. Probe failures land in the report's honest notes
    /// (SecReport's structural honesty), never as silent omissions.
    static func runSecurity(appPath: String?, outFile: String?) async throws {
        guard let appPath, !appPath.isEmpty else {
            printUsage("security requires an app bundle path: appupdater-cli security /Applications/Foo.app")
        }
        async let security = SecInspector.inspect(appAt: URL(fileURLWithPath: appPath))
        async let iosOnMac = IOSAppOnMac.classify(bundlePath: appPath)
        let setapp = SetappClassification(SetappSupport.classify(bundlePath: appPath))
        try emit(
            SecurityPanelReport(
                mode: "security",
                appPath: appPath,
                security: await security,
                iosOnMac: IOSOnMacClassification(await iosOnMac),
                setapp: setapp),
            outFile)
    }

    /// `brew-pins`: the Homebrew prefix + the pinned formulae/casks.
    /// Read-only end to end (one `brew --prefix` path probe + two file
    /// reads); a missing pinned file observes as "no pins", never an error;
    /// an unresolvable prefix is an honest note, never a guessed root.
    static func runBrewPins(outFile: String?) async throws {
        guard let prefix = await BrewPrefixResolver(runner: .live()).resolve() else {
            try emit(
                BrewPinsReport(
                    mode: "brew-pins", prefix: nil,
                    prefixNote: "`brew --prefix` unresolvable (brew missing, non-zero exit, or "
                        + "empty output) — pins unknown, never guessed",
                    formulae: [], casks: [], notes: []),
                outFile)
            return
        }
        let (formulaeURL, casksURL) = BrewPrefixResolver.pinnedFileURLs(prefix: prefix)
        var notes: [String] = []
        var formulae = Set<String>()
        var casks = Set<String>()
        if let text = try? String(contentsOf: formulaeURL, encoding: .utf8) {
            let parsed = BrewPinsParser.parse(text)
            formulae = parsed.pins.formulae
            notes.append(contentsOf: parsed.notes)
        } else {
            notes.append("\(formulaeURL.path) absent — no pinned formulae recorded (a missing "
                + "pinned file observes as \"no pins\", never an error)")
        }
        if let text = try? String(contentsOf: casksURL, encoding: .utf8) {
            let parsed = BrewPinsParser.parse(text)
            casks = parsed.pins.casks
            notes.append(contentsOf: parsed.notes)
        } else {
            notes.append("\(casksURL.path) absent — no pinned casks recorded")
        }
        try emit(
            BrewPinsReport(
                mode: "brew-pins", prefix: prefix.path, prefixNote: nil,
                formulae: formulae.sorted(), casks: casks.sorted(), notes: notes),
            outFile)
    }

    /// `brew-doctor`: the engine-sanctioned read-only probe (no sudo; the
    /// hardening environment is the engine's own). Output verbatim; nothing
    /// is fixed automatically — the report is the owner's to act on.
    static func runBrewDoctor(outFile: String?) async throws {
        let result = await BrewDoctorCheck(runner: .live()).run()
        try emit(BrewDoctorReport(result: result), outFile)
    }

    /// `brew-index`: the brew FORMULA whole-index status through the engine's
    /// own store (BrewFormulaIndexStore — one ETag-cached GET of the public
    /// formulae.brew.sh catalog; the same data plane the app reads). Read-only
    /// end to end: the store's cache files live in Application Support; brew
    /// is NEVER executed. A failed load is NOT a failure exit: the report
    /// carries loaded=false + the store's verbatim lastError (honest data,
    /// exit 0 — the same posture as the other glue modes).
    static func runBrewIndex(appSupport: URL, outFile: String?) async throws {
        let session = await buildProxiedSession()
        let store = BrewFormulaIndexStore(directory: appSupport, session: session)
        let loaded = await store.ensureLoaded()
        let recordCount = await store.cachedRecordCount
        let lastError = await store.lastError
        try emit(
            BrewIndexReport(
                mode: "brew-index",
                loaded: loaded,
                recordCount: recordCount,
                cacheDirectory: appSupport.path,
                lastError: lastError),
            outFile)
    }

    /// `proxy show`: the persisted settings, the effective session semantics,
    /// and a one-shot READ-ONLY system snapshot (a single SCDynamicStore read
    /// through the engine's seam, invalidated immediately — no monitor is
    /// left running). Deliberately keychain-free: credential probes from a
    /// second binary can trigger user-facing keychain prompts, and password
    /// presence is the app's Proxy-sheet surface. Deliberately without any
    /// setter: the CLI has no settings-mutation precedent.
    static func runProxyShow(outFile: String?) async throws {
        let settings: ProxySettings
        do {
            settings = try await ProxySettingsStore().load()
        } catch {
            errLine("warning: proxy settings load failed (\(error)) — reporting defaults\n")
            settings = ProxySettings()
        }
        var snapshot: SystemProxySnapshot?
        var snapshotNote: String?
        if let seam = SCProxyStore.live() {
            snapshot = SystemProxyParser.parse(seam.readDictionary())
            seam.invalidate()
        } else {
            snapshotNote =
                "SCDynamicStore creation failed (the documented \"Failed to create SCDynamicStore\" "
                    + "branch) — no system snapshot is shown rather than a fake empty one"
        }
        // The documented proxy environment variables as THIS process sees them
        // (ProxyEnvironment.current() — a pure env read; the engine's own
        // posture: "reading env is introspection, not traffic"). Report-only:
        // the coordinator owns any precedence decision between env vars,
        // system proxies, and manual settings — nothing here acts on them.
        let env = ProxyEnvironment.current()
        try emit(
            ProxyShowReport(
                mode: "proxy-show", settings: settings,
                effective: Self.effectiveDescription(settings),
                validation: settings.validationFailureReason(),
                pacNote: settings.mode == .system ? ProxyConfiguration.pacLimitationNote : nil,
                systemSnapshot: snapshot, systemSnapshotNote: snapshotNote,
                envPassthrough: EnvPassthroughAnnotation(env)),
            outFile)
    }

    /// The effective session semantics for `proxy show` (mirrors the app's
    /// ProxySessionController wording — one honest line per mode).
    static func effectiveDescription(_ settings: ProxySettings) -> String {
        switch settings.mode {
        case .system:
            return "no override dictionary — URLSession follows the system configuration "
                + "(incl. system PAC handling)"
        case .none:
            return "explicit empty override — the session uses no proxy"
        case .manual:
            var parts: [String] = []
            if let entry = settings.http { parts.append("http \(entry.host):\(entry.port)") }
            if let entry = settings.https { parts.append("https \(entry.host):\(entry.port)") }
            if let entry = settings.socks5 { parts.append("socks5 \(entry.host):\(entry.port)") }
            return "per-protocol overrides: " + parts.joined(separator: ", ")
        }
    }

    /// Builds the engine-facing URLSession from the persisted ProxySettings
    /// (glue-wiring). Adoption is best-effort with honest stderr notes: the
    /// CLI completes its report under the system configuration rather than
    /// refusing on proxy configuration (stdout stays pure JSON either way).
    static func buildProxiedSession() async -> URLSession {
        let settings: ProxySettings
        do {
            settings = try await ProxySettingsStore().load()
        } catch {
            errLine(
                "warning: proxy settings load failed (\(error)) — the session keeps the system configuration\n")
            return .shared
        }
        do {
            let dictionary = try ProxyConfiguration.connectionProxyDictionary(for: settings)
            let configuration = URLSessionConfiguration.default
            configuration.connectionProxyDictionary = dictionary
            switch settings.mode {
            case .system:
                errLine(
                    "note: proxy mode 'system' — the session follows the system configuration ("
                        + ProxyConfiguration.pacLimitationNote + ")\n")
            case .none:
                errLine("note: proxy mode 'none' — the session uses no proxy (explicit empty override)\n")
            case .manual:
                errLine("note: proxy mode 'manual' — the session applies the configured per-protocol overrides\n")
            }
            return URLSession(configuration: configuration)
        } catch {
            errLine("warning: \(error) — the session keeps the system configuration\n")
            return .shared
        }
    }

    /// The one place stderr bytes come from: argument and refusal messages
    /// are literals here (always UTF-8-encodable), so if encoding somehow
    /// ever failed, this writes nothing instead of crashing a tool that is
    /// already reporting an error — the exit code at the call site stays
    /// committed as the truth (forced encode would be a crash, not a receipt).

}

// MARK: - Glue-wiring report shapes

/// Glue-wiring flat JSON shape for the Setapp verdict (SetappInfo itself is
/// not Codable; this flat, sorted-keys-friendly shape is the wire contract).
struct SetappClassification: Codable, Hashable {
    /// `member` | `notMember` | `unknown`.
    var verdict: String
    var evidence: [String]
    var note: String

    init(_ info: SetappInfo) {
        switch info.verdict {
        case .member: verdict = "member"
        case .notMember: verdict = "notMember"
        case .unknown: verdict = "unknown"
        }
        evidence = info.evidence
        note = info.note
    }
}

struct ScanReport: Codable {
    var mode: String
    var count: Int
    var apps: [ScanAppSummary]
}

/// Full verdict report from `check` (candidates, failures, resolution).
struct CheckReport: Codable {
    var mode: String
    var count: Int
    var apps: [UpdateCheck]
    /// Glue-wiring additive (storefront lane): the machine's storefront
    /// verdict, display-only. MAS lookups keep their locked `us` country pin
    /// regardless — this annotation never re-routes a lookup.
    var storefront: StorefrontAnnotation
}

/// Glue-wiring flat JSON shape for the storefront verdict (StorefrontInfo is
/// not Codable; flat is the wire contract).
struct StorefrontAnnotation: Codable, Hashable {
    /// `eligible` | `excluded` | `unknown`.
    var status: String
    var countryCode: String?
    var note: String

    init(_ info: StorefrontInfo) {
        switch info.status {
        case .eligible: status = "eligible"
        case .excluded: status = "excluded"
        case .unknown: status = "unknown"
        }
        countryCode = info.countryCode
        note = info.note
    }
}

/// Install-mode dry-run report: per-app PLAN data with labeled absent claims.
/// The dry-run path always emits `applied: false` — a plan is data, nothing
/// downloaded or moved. The APPLY path emits `InstallApplyReport` instead.
struct InstallPlanEntry: Codable, Hashable {
    var app: ScanAppSummary
    var update: UpdateInfo?
    var plan: InstallPlan?
    var note: String

    init(app: InstalledApp, update: UpdateInfo?, plan: InstallPlan?, note: String) {
        self.app = ScanAppSummary(app)
        self.update = update
        self.plan = plan
        self.note = note
    }
}

struct InstallPlanReport: Codable {
    var mode: String
    var count: Int
    var apps: [InstallPlanEntry]
    var applied: Bool
}

/// The `install --apply` outcome envelope: full receipt chain + abort state.
/// `applied` mirrors `outcome.abortedStep == nil` (redundant, machine-friendly).
struct InstallApplyReport: Codable {
    var mode: String
    var applied: Bool
    var outcome: InstallOutcome
    /// Glue-wiring additive (candidates lane): the deep candidate-filter
    /// receipts over the FINAL artifact of a completed dmg/zip apply (the
    /// deployed bundle at the app's original path). nil for pkg stagings (a
    /// .pkg is owner-judged with pkgutil before the owner-run installer
    /// command) and for aborted applies (no final artifact to judge).
    /// Data-only: the filter never overrides the security floor.
    var candidateFilter: CandidateFilterReport?
    var candidateFilterNote: String?
}

/// The `install --adopt` report: flat MASAdoptDecision values per app.
/// Dry-run always emits `applied: false` (data only, refusals included as
/// decision values). The apply path emits `applied: true` with the staged
/// owner-run command; refusals never reach the report on the apply path
/// (they exit 3 first — refusal runs write no output file, the standing
/// gate discipline).
struct InstallAdoptReport: Codable {
    var mode: String
    var count: Int
    var apps: [MASAdoptDecision]
    var applied: Bool
}

// MARK: - Glue-wiring report shapes

/// `security` report. `security` is the engine's own Codable SecReport; the
/// classifications get flat shapes because their engine types are not
/// Codable (the same flat-shape decision as SetappClassification above).
struct SecurityPanelReport: Codable {
    var mode: String
    var appPath: String
    var security: SecReport
    var iosOnMac: IOSOnMacClassification
    var setapp: SetappClassification
}

/// Flat JSON shape for IOSAppOnMacInfo.
struct IOSOnMacClassification: Codable, Hashable {
    /// `iosAppOnMac` | `macAppStoreApp` | `notIOSAppOnMac` | `unknown`.
    var verdict: String
    var trackId: String?
    var purchaseDate: Date?
    var installedDate: Date?
    var evidence: [String]
    var note: String

    init(_ info: IOSAppOnMacInfo) {
        switch info.verdict {
        case .iosAppOnMac: verdict = "iosAppOnMac"
        case .macAppStoreApp: verdict = "macAppStoreApp"
        case .notIOSAppOnMac: verdict = "notIOSAppOnMac"
        case .unknown: verdict = "unknown"
        }
        trackId = info.trackId
        purchaseDate = info.purchaseDate
        installedDate = info.installedDate
        evidence = info.evidence
        note = info.note
    }
}

/// `brew-pins` report (flat; sets sorted for deterministic output).
struct BrewPinsReport: Codable {
    var mode: String
    var prefix: String?
    var prefixNote: String?
    var formulae: [String]
    var casks: [String]
    var notes: [String]
}

/// `brew-doctor` report (flat shape — BrewDoctorResult is not Codable;
/// stdout/stderr ride along verbatim).
struct BrewDoctorReport: Codable {
    var mode: String
    /// `clean` | `issues` | `brewMissing`.
    var verdict: String
    var exitStatus: Int32?
    var stdout: String
    var stderr: String
    var note: String?

    init(result: BrewDoctorResult) {
        mode = "brew-doctor"
        switch result.verdict {
        case .clean: verdict = "clean"
        case .issues: verdict = "issues"
        case .brewMissing: verdict = "brewMissing"
        }
        exitStatus = result.exitStatus
        stdout = result.stdout
        stderr = result.stderr
        note = result.note
    }
}

/// `proxy show` report. ProxySettings and SystemProxySnapshot are the
/// engine's own Codable types — the same JSON contract the app writes/reads.
struct ProxyShowReport: Codable {
    var mode: String
    var settings: ProxySettings
    var effective: String
    /// Verbatim validationFailureReason (nil = valid, session usable).
    var validation: String?
    /// The engine's verbatim PAC limitation (present in .system mode).
    var pacNote: String?
    var systemSnapshot: SystemProxySnapshot?
    var systemSnapshotNote: String?
    /// Glue-wiring additive (env lane): the documented proxy environment
    /// variables as this process sees them (pure env read; report-only).
    var envPassthrough: EnvPassthroughAnnotation
}

/// Glue-wiring flat JSON shape for ProxyEnvironmentPassthrough (the engine
/// type is not Codable; flat is the wire contract). Each entry renders as
/// `scheme host:port` (authRequired appended as a marker when declared —
/// the PASSWORD itself is never in the environment or this report).
struct EnvPassthroughAnnotation: Codable, Hashable {
    /// `http host:port[ auth]`-style strings; nil when the variable set is
    /// absent (honest absence, never an empty-string guess).
    var http: String?
    var https: String?
    var socks5: String?
    /// The engine's verbatim parse notes (unparseable values, ignored
    /// non-SOCKS ALL_PROXY, rejected userinfo, …).
    var notes: [String]

    init(_ passthrough: ProxyEnvironmentPassthrough) {
        http = passthrough.http.map(Self.render)
        https = passthrough.https.map(Self.render)
        socks5 = passthrough.socks5.map(Self.render)
        notes = passthrough.notes
    }

    private static func render(_ entry: ProxyProtocolEntry) -> String {
        var text = "\(entry.host):\(entry.port)"
        if entry.authRequired { text += " (auth required)" }
        return text
    }
}

/// `brew-index` report: the brew formula whole-index status through the
/// engine's own store. Plain value fields — the store's public status
/// surface (isLoaded / cachedRecordCount / lastError), not re-shaped.
struct BrewIndexReport: Codable {
    var mode: String
    /// The store's ensureLoaded() verdict (false = the verbatim lastError
    /// below says why; stale-but-verifiable records still count as loaded).
    var loaded: Bool
    var recordCount: Int
    var cacheDirectory: String
    /// The store's verbatim last load failure (nil = clean cycle).
    var lastError: String?
}

