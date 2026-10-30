import Foundation
import AppUpdaterCore

// appupdater-cli — scriptable surface for the scan + check + install-plan engines,
// plus the glue-wiring read-only introspection modes (security / brew-pins /
// brew-doctor / proxy show).
//
//   appupdater-cli scan [--dir PATH]... [--apps NAME[,NAME...]] [--out FILE]
//       Scan directories (default /Applications) and emit what is INSTALLED. No network.
//
//   appupdater-cli check [--dir PATH]... [--apps NAME[,NAME...]] [--out FILE]
//       Scan + live lookups via cask → sparkle → mas (locked precedence) and emit a
//       per-app report with candidates, failures, and the resolved verdict (or its
//       honest absence). NEVER synthesizes an update claim.
//
//   appupdater-cli install [--apps NAME] [--out FILE] [--apply] [--relaunch]
//                          [--adopt] [--force]
//       Resolves the newest claim for the named app and prints an INSTALL PLAN.
//       WITHOUT --apply this is a dry-run: pure data, nothing downloads or moves.
//       WITH --apply the executor chain runs for real (download → independent
//       sha256/magic verify → backup → graceful quit → deploy → atomic swap →
//       postScan). PKG distributions (staged-PKG v1): the chain stops after
//       download → sha256 → xar-magic verify, leaves the verified pkg in
//       persistent staging, and prints the owner-run
//       `sudo installer -pkg <path> -target /` — installer(8) is NEVER executed
//       here. Refusals (no claim / security floor) exit 3 before anything
//       is touched; an aborted step exits 1 with the full receipt chain.
//       Applying is strictly per-app (exactly one --apps match) and is the
//       user's explicit action — the CLI never batches silently. --relaunch
//       additionally asks LaunchServices to open the swapped bundle.
//
//       --adopt (MAS→Homebrew adoption, staged-command lane): for the named
//       MAS-installed app the gate decides adopt-eligibility against the
//       whole-index cask catalog ONLY (no sparkle/MAS/github lookups) and
//       stages the OWNER-RUN `brew install --cask --adopt <token>` — brew is
//       NEVER executed here. Refusals (not a MAS install / no cask / ambiguous
//       cask match) exit 3 with the reason; a version mismatch or an unreadable
//       version refuses unless --force is also passed (then the --force command
//       variant is staged with an override warning receipt). The paid-App-Store
//       warning is attached unconditionally (payment is not detectable).
//       Dry-run (--adopt without --apply) emits the decisions as pure data,
//       exit 0, refusals recorded in the report; --apply is the consent path.
//
// Glue-wiring read-only modes (all exit 0 with honest data; 2 usage, 1 failure):
//   appupdater-cli security <app-path> [--out FILE]
//       One app's security panel: SecInspector's read-only codesign/spctl/
//       entitlement probes + the bundle-forensics classifications
//       (iOS-app-on-Mac, Setapp). Nothing is modified.
//   appupdater-cli brew-pins [--out FILE]
//       The Homebrew prefix + the pinned formulae/casks (read-only; a missing
//       pinned file observes as "no pins"). brew is never executed.
//   appupdater-cli brew-doctor [--out FILE]
//       The engine-sanctioned read-only `brew doctor` probe (no sudo; output
//       verbatim). Nothing is fixed automatically.
//   appupdater-cli brew-index [--out FILE]
//       The brew FORMULA whole-index status: one ETag-cached GET of the public
//       formulae.brew.sh/api/formula.json catalog (the engine's own data plane
//       — brew is never executed), reporting loaded / record count / the
//       verbatim lastError. Read-only: cache files in Application Support only.
//   appupdater-cli proxy show [--out FILE]
//       The persisted proxy settings, what a session built from them would do,
//       and a one-shot READ-ONLY system-proxy snapshot (SCDynamicStore read,
//       no monitor left running). There is deliberately NO `proxy set`: the
//       CLI has no settings-mutation precedent — edit proxy_settings.json via
//       the app's Proxy sheet.
//
// Output: JSON on stdout (or a file via --out). Exit codes: 0 ok, 2 usage error,
// 3 honest-refusal (not wired / plan rejected), 1 failure.

private let usage = """
USAGE:
  appupdater-cli scan    [--dir PATH]... [--apps NAME[,NAME...] ] [--out FILE]
  appupdater-cli check   [--dir PATH]... [--apps NAME[,NAME...] ] [--out FILE]
  appupdater-cli install [--apps NAME] --out FILE [--apply] [--relaunch] [--adopt] [--force]
  appupdater-cli security <app-path> [--out FILE]
  appupdater-cli brew-pins      [--out FILE]
  appupdater-cli brew-doctor    [--out FILE]
  appupdater-cli brew-index     [--out FILE]
  appupdater-cli proxy show     [--out FILE]

scan   : enumerate installed apps (no network). Default roots are
         /Applications plus your custom scan locations (unless --dir given).
check  : scan + live source lookups (cask > sparkle > mas > github; electron
         claims only when nothing stronger exists — locked precedence). A
         per-app manual pin (manual_sources.json) is consulted INSTEAD of
         every built-in source for that app (manual-over-builtin).
install: dry-run install PLAN per --apps (one app for --apply; refusals are
         honest: exit 3, nothing touched). dmg/zip --apply executes the plan
         for real with receipts; .pkg --apply downloads + verifies the pkg
         (same HTTPS + sha256 floor), leaves it STAGED, and prints the
         owner-run `sudo installer` command — AppUpdater never runs
         installer(8). Exit 0 = applied/staged, 1 = aborted (see
         outcome.abortedStep), 3 = plan refused (security floor / no claim),
         2 = usage/target error.
--adopt: MAS→Homebrew adoption lane for the named app (one app per run).
         Decides adopt-eligibility against the whole-index cask catalog ONLY
         and stages the OWNER-RUN `brew install --cask --adopt <token>` —
         brew is NEVER executed. Not a MAS install / no cask / ambiguous cask
         match refuse outright (exit 3 with --apply); version mismatch or an
         unreadable version refuses unless --force is also passed (then the
         --force command variant is staged with an override warning receipt).
         The paid-App-Store warning is ALWAYS attached (payment not
         detectable). Without --apply this is a dry-run: decisions as pure
         JSON data, exit 0, refusals recorded in the report. --relaunch has
         no meaning here and is a usage error with --adopt.
security: one app's security panel — read-only codesign/spctl/entitlement
         probes (SecReport) + the bundle classifications (iOS-app-on-Mac,
         Setapp). Nothing is modified, nothing is installed.
brew-pins : the Homebrew prefix + pinned formulae/casks (read-only file
         reads; a missing pinned file observes as "no pins", never an error).
         brew is never executed.
brew-doctor: the read-only `brew doctor` probe (no sudo, hardening env
         applied by the engine; verbatim output). Nothing is fixed for you.
brew-index: the brew FORMULA whole-index status — one ETag-cached GET of the
         public formulae.brew.sh catalog through the engine's own store
         (read-only data plane; brew is never executed), reporting loaded,
         the cached record count, the cache directory, and the verbatim
         lastError. Exit 0 with honest data even on a failed load.
proxy show: the persisted proxy settings (proxy_settings.json), what a
         session built from them does, a one-shot read-only system-proxy
         snapshot (no monitor left running), and the documented proxy
         environment variables as the process sees them (pure env read).
         There is deliberately NO
         `proxy set` — the CLI has no settings-mutation modes; edit the
         settings in the app's Proxy sheet.
--out FILE writes the JSON there instead of stdout (parent dir must exist).
"""

@main
struct CliMain {
    /// The parsed CLI surface (see `parseCli` for the grammar contract).
    struct CliArguments {
        var mode = "scan"
        var dirs: [URL] = []
        var nameFilters: [String] = []
        var outFile: String?
        var applyRequested = false
        var relaunchRequested = false
        var adoptRequested = false
        var forceRequested = false
        var securityPath: String?
    }

    /// The full argument grammar: positional modes, glue modes (with their
    /// positional followers), flags, and the adopt/force/relaunch discipline.
    /// Usage problems exit 2 via printUsage; -h/--help prints and exits 0.
    static func parseCli(_ arguments: [String]) -> CliArguments {
        var args = CliArguments()
        var positionalModeCount = 0

        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "scan", "check", "install":
                if positionalModeCount > 0 {
                    errLine("error: mode specified twice\n")
                    exit(2)
                }
                args.mode = arg
                positionalModeCount += 1
            case "security":
                if positionalModeCount > 0 {
                    errLine("error: mode specified twice\n")
                    exit(2)
                }
                args.mode = "security"
                positionalModeCount += 1
                // The app path is a POSITIONAL value (documented grammar:
                // `security <app-path>`) — it must not look like a flag.
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else {
                    printUsage("security requires an app bundle path: appupdater-cli security /Applications/Foo.app")
                }
                index += 1
                args.securityPath = arguments[index]
            case "brew-pins", "brew-doctor", "brew-index":
                if positionalModeCount > 0 {
                    errLine("error: mode specified twice\n")
                    exit(2)
                }
                args.mode = arg
                positionalModeCount += 1
            case "proxy":
                if positionalModeCount > 0 {
                    errLine("error: mode specified twice\n")
                    exit(2)
                }
                args.mode = "proxy"
                positionalModeCount += 1
                // Only `proxy show` exists — deliberately (the CLI has no
                // settings-mutation modes; see the usage text).
                guard index + 1 < arguments.count, arguments[index + 1] == "show" else {
                    printUsage("proxy requires 'show' (only `proxy show` exists — there is no `proxy set`; edit the settings in the app's Proxy sheet)")
                }
                index += 1
            case "--dir":
                guard index + 1 < arguments.count else { printUsage("missing value for --dir") }
                index += 1
                args.dirs.append(URL(fileURLWithPath: arguments[index], isDirectory: true))
            case "--apps":
                guard index + 1 < arguments.count else { printUsage("missing value for --apps") }
                index += 1
                args.nameFilters = arguments[index]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { !$0.isEmpty }
            case "--out":
                guard index + 1 < arguments.count else { printUsage("missing value for --out") }
                index += 1
                args.outFile = arguments[index]
            case "--apply":
                args.applyRequested = true
            case "--relaunch":
                args.relaunchRequested = true
            case "--adopt":
                args.adoptRequested = true
            case "--force":
                args.forceRequested = true
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                printUsage("unknown argument: \(arg)")
            }
            index += 1
        }

        // --adopt flag discipline: adoption is an install-mode lane, --force is
        // only its version-gate override consent, and nothing is ever installed
        // or relaunched by AppUpdater on the adopt path.
        if args.adoptRequested, args.mode != "install" {
            printUsage("--adopt applies to install only")
        }
        if args.forceRequested, !args.adoptRequested {
            printUsage("--force is only meaningful with --adopt")
        }
        if args.adoptRequested, args.relaunchRequested {
            printUsage("--relaunch has no meaning with --adopt (AppUpdater never installs or relaunches on the adopt path)")
        }
        return args
    }

    static func main() async {
        let parsed = parseCli(Array(CommandLine.arguments.dropFirst()))
        var mode = parsed.mode
        var dirs = parsed.dirs
        var nameFilters = parsed.nameFilters
        let outFile = parsed.outFile
        let applyRequested = parsed.applyRequested
        let relaunchRequested = parsed.relaunchRequested
        let adoptRequested = parsed.adoptRequested
        let forceRequested = parsed.forceRequested
        let securityPath = parsed.securityPath

        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AppUpdater", isDirectory: true)

        // Default scan roots: /Applications ALWAYS, extended by the custom
        // scan-location store (the same store the app reads — gap #18), but
        // ONLY when the caller gave no explicit --dir set: an explicit
        // override must stay exactly what the operator typed. A failed store
        // read is a loud stderr warning + /Applications-only continue.
        if dirs.isEmpty {
            dirs = [URL(fileURLWithPath: "/Applications", isDirectory: true)]
            do {
                for root in try ScanLocationStore(directory: appSupport).resolvedRoots() {
                    if let url = root.url {
                        dirs.append(url)
                    }
                }
            } catch {
                errLine("warning: custom scan locations unreadable (\(error)) — scanning /Applications only\n")
            }
        }

        if mode == "install" {
            if nameFilters.count != 1 {
                printUsage("install requires exactly one app via --apps NAME (target discipline; dry-run or apply is per-app)")
            }
        }

        do {
            // Glue-wiring read-only modes return BEFORE any scan or source
            // roster is built (they need no scan, no session, no stores).
            if try await dispatchGlueMode(
                mode: mode, securityPath: securityPath,
                appSupport: appSupport, outFile: outFile)
            {
                return
            }

            let scanner = ProductionAppScanner()
            var apps = try await scanner.scan(directoryURLs: dirs)
            if !nameFilters.isEmpty {
                apps = apps.filter { app in
                    // Display name, bundle id, AND the bundle's file name ("Brave Browser.app"
                    // whose display name is "Brave"); needle-in-field substring only.
                    let fileName = URL(fileURLWithPath: app.path).deletingPathExtension().lastPathComponent
                    let stack = [app.name, app.bundleIdentifier, fileName].map { $0.lowercased() }
                    return nameFilters.contains { needle in stack.contains { $0.contains(needle.lowercased()) } }
                }
            }
            apps.sort { ($0.name, $0.path) < ($1.name, $1.path) }

            if mode == "scan" {
                try emit(ScanReport(mode: mode, count: apps.count, apps: apps.map(ScanAppSummary.init)), outFile)
                return
            }

            // Proxied session (glue-wiring): adopt the persisted ProxySettings
            // through the engine's documented dictionary bridge. Adoption is
            // best-effort with honest stderr notes: the CLI completes its
            // report under the system configuration rather than refusing on
            // proxy configuration (stdout stays pure JSON either way).
            let cliSession = await Self.buildProxiedSession()

            // --adopt: the MAS→Homebrew adoption lane. Consults ONLY the
            // whole-index cask store (no sparkle/MAS/github/electron lookups —
            // adoption needs the cask identity, not an update claim), so this
            // branch returns BEFORE the source roster is built below.
            if mode == "install", adoptRequested {
                try await runAdopt(
                    apps: apps, appSupport: appSupport, session: cliSession,
                    apply: applyRequested, force: forceRequested, outFile: outFile)
                return
            }

            // Source roster — the same locked-precedence policy the app uses:
            // whole-index cask (ETag-cached, alias-free matching) with an
            // honest fallback to the per-token pipeline; Sparkle; MAS;
            // GitHub (bounded sparkle-feed harvest); Electron (unknown lane,
            // oracle-gated strictly-newer-only). Every networked source is
            // constructed with the proxied session adopted above.
            let caskIndex = CaskIndexStore(directory: appSupport, session: cliSession)
            var sources: [any UpdateSource] = []
            let revalidated = await caskIndex.ensureLoaded()
            var indexUsable = revalidated
            if !indexUsable {
                indexUsable = await caskIndex.isLoaded
            }
            if indexUsable {
                sources.append(CaskIndexSource(store: caskIndex))
            } else {
                sources.append(CaskSource(session: cliSession))
            }
            sources.append(SparkleSource())
            sources.append(MASSource(session: cliSession))
            sources.append(GithubSource(directory: appSupport, session: cliSession))
            sources.append(ElectronSource())
            let manualService = ManualSourceResolverService(store: ManualSourceStore(directory: appSupport))
            let engine = UpdateCheckEngine(
                sources: sources,
                manualSource: manualService.engineResolver(
                    session: cliSession, githubCacheDirectory: appSupport),
                feedDerivation: FeedDerivationResolver { app in
                    SparkleFeedDerivation.candidateFeeds(appBundlePath: app.path)
                })
            let checks = await engine.checkAll(apps: apps)

            if mode == "check" {
                // Storefront annotation (glue-wiring, display-only): the
                // machine's storefront verdict rides along on the check
                // report. It NEVER re-routes a lookup — the MAS source keeps
                // its locked `us` country pin regardless.
                let storefront = await Storefront.currentStorefront()
                try emit(
                    CheckReport(
                        mode: mode, count: checks.count, apps: checks,
                        storefront: StorefrontAnnotation(storefront)),
                    outFile)
                return
            }

            // mode == "install".
            if applyRequested {
                // APPLY — strictly one target, claim-gated, security-floored.
                // Refusal paths touch NOTHING: staging/backups dirs are only
                // created after the plan is accepted.
                guard apps.count == 1, let target = apps.first else {
                    let matched = apps.map { $0.name }.joined(separator: ", ")
                    let listing = matched.isEmpty ? "" : ": \(matched)"
                    errLine(
                        "install target discipline: the filter must match exactly ONE installed app (matched \(apps.count)\(listing)).\n"
                    )
                    exit(2)
                }
                guard let check = checks.first else {
                    errLine("install refused: nothing was checked\n")
                    exit(1)
                }
                guard check.verdict == "update", let update = check.resolved else {
                    errLine(
                        "install refused: no newer claim to install (verdict '\(check.verdict)') — never installs from a missing or non-newer claim.\n"
                    )
                    exit(3)
                }
                let plan: InstallPlan
                do {
                    plan = try InstallPlanner().plan(app: target, update: update)
                } catch {
                    errLine(
                        "install refused (plan rejected: \(error)) — nothing was touched.\n"
                    )
                    exit(3)
                }

                let fm = FileManager.default
                let stagingRoot = appSupport.appendingPathComponent("staging", isDirectory: true)
                let backupsRoot = appSupport.appendingPathComponent("backups", isDirectory: true)
                try? fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
                try? fm.createDirectory(at: backupsRoot, withIntermediateDirectories: true)

                let coordinator = InstallCoordinator()
                let outcome = await coordinator.run(
                    plan, stagingRoot: stagingRoot, backupsRoot: backupsRoot,
                    relaunchRequested: relaunchRequested)

                // Candidate-filter receipts (glue-wiring, candidates lane):
                // the deep filter over the FINAL artifact of a completed
                // dmg/zip apply — the deployed bundle at the app's original
                // path. Data-only: the filter never overrides the security
                // floor (its own header documents that). A pkg staging has no
                // bundle to judge (the owner judges the pkg with pkgutil
                // before the owner-run installer command); an aborted apply
                // leaves nothing final to filter.
                let candidateFilter: CandidateFilterReport?
                let candidateFilterNote: String?
                if let aborted = outcome.abortedStep {
                    candidateFilter = nil
                    candidateFilterNote =
                        "no final artifact to filter — the apply aborted at \(aborted.rawValue)"
                } else if outcome.stagedCommand != nil {
                    candidateFilter = nil
                    candidateFilterNote =
                        "pkg staging: the bundle-shape candidate filters do not apply to a .pkg "
                            + "artifact — judge the staged pkg with `pkgutil --check-signature` "
                            + "before the owner-run installer command"
                } else {
                    candidateFilter = CandidateFilter.filter(
                        candidateURL: URL(fileURLWithPath: plan.app.path))
                    candidateFilterNote =
                        "filter receipts over the deployed bundle at \(plan.app.path) — display "
                            + "data; the security floor (HTTPS + sha256 + artifact magic) is the "
                            + "unchanged gate"
                }

                try emit(InstallApplyReport(
                    mode: "install-apply",
                    applied: outcome.abortedStep == nil,
                    outcome: outcome,
                    candidateFilter: candidateFilter,
                    candidateFilterNote: candidateFilterNote), outFile)

                // STAGED-PKG v1: a green pkg staging ends with the owner-run
                // command — print it where a human reads (stderr; stdout stays
                // pure JSON for piping) with the honest boundaries spelled out.
                if let command = outcome.stagedCommand, outcome.abortedStep == nil {
                    errLine(
                        "\nstaged pkg ready — AppUpdater never runs installer(8). Run this yourself:\n"
                            + "  \(command)\n"
                            + "The verified pkg stays on disk until you delete it. "
                            + "Review `pkgutil --check-signature` on that path first if you want.\n"
                    )
                }

                // Exit policy: a failed relaunch is auxiliary — the swap itself
                // succeeded; everything else aborts with 1.
                if let aborted = outcome.abortedStep, aborted != .relaunch {
                    exit(1)
                }
                return
            }
            let planner = InstallPlanner()
            var entries: [InstallPlanEntry] = []
            for check in checks {
                if check.verdict != "update", let update = check.resolved {
                    entries.append(.init(app: check.app, update: update, plan: nil, note: "resolved claim is not newer than installed; nothing to plan"))
                    continue
                }
                guard let update = check.resolved else {
                    entries.append(.init(app: check.app, update: nil, plan: nil, note: "no resolved claim (\(check.verdict)); refusing to invent one"))
                    continue
                }
                do {
                    let plan = try planner.plan(app: check.app, update: update)
                    entries.append(.init(app: check.app, update: update, plan: plan, note: "dry-run: plan only; nothing downloaded or moved"))
                } catch {
                    entries.append(.init(app: check.app, update: update, plan: nil, note: "plan rejected: \(error)"))
                }
            }
            try emit(InstallPlanReport(mode: mode, count: entries.count, apps: entries, applied: false), outFile)
        } catch {
            errLine("error: \(error)\n")
            exit(1)
        }
    }

    /// MAS→Homebrew adoption lane (--adopt; see MASAdoptGate for the full
    /// refusal matrix). Dry-run: JSON adopt decisions, exit 0, refusals
    /// recorded honestly as decision values — nothing touched. --apply is the
    /// consent path: refusals exit 3 with the reason on stderr and write NO
    /// output file (exit precedes any artifact — the standing gate
    /// discipline); an eligible decision emits the report and prints the
    /// owner-run command on stderr (stdout stays pure JSON). brew is NEVER
    /// executed here; the command is a string for the owner's hand.
    private static func runAdopt(
        apps: [InstalledApp], appSupport: URL, session: URLSession,
        apply: Bool, force: Bool, outFile: String?
    ) async throws {
        let caskIndex = CaskIndexStore(directory: appSupport, session: session)
        let revalidated = await caskIndex.ensureLoaded()
        var indexUsable = revalidated
        if !indexUsable {
            indexUsable = await caskIndex.isLoaded
        }
        guard indexUsable else {
            let lastError = await caskIndex.lastError
            errLine(
                "install --adopt refused: the whole-index cask catalog is unavailable "
                    + "(\(lastError ?? "not loaded")) — refusing to guess an adopt token.\n"
            )
            exit(3)
        }

        if apply {
            // Same one-target consent discipline as the artifact apply path.
            guard apps.count == 1 else {
                let matched = apps.map { $0.name }.joined(separator: ", ")
                let listing = matched.isEmpty ? "" : ": \(matched)"
                errLine(
                    "install --adopt target discipline: the filter must match exactly ONE installed app (matched \(apps.count)\(listing)).\n"
                )
                exit(2)
            }
        }

        let gate = MASAdoptGate()
        let resolver = MASAdoptCaskResolver.store(caskIndex)
        var decisions: [MASAdoptDecision] = []
        for app in apps {
            decisions.append(await gate.decide(app: app, resolver: resolver, force: force))
        }

        if apply {
            guard decisions.count == 1, let decision = decisions.first else {
                errLine("error: adopt decision missing for the single target\n")
                exit(1)
            }
            if let reason = decision.refusalReason {
                errLine(
                    "install --adopt refused (\(decision.refusalCode ?? "unknown")): \(reason)\n"
                        + "Nothing was touched and no output file was written.\n"
                )
                exit(3)
            }
            try emit(
                InstallAdoptReport(mode: "install-adopt", count: decisions.count, apps: decisions, applied: true),
                outFile)
            if let command = decision.stagedCommand {
                errLine(
                    "\nadopt command staged — AppUpdater never runs brew. Run this yourself:\n"
                        + "  \(command)\n"
                        + "This replaces the App Store build with the Homebrew (vendor) build; "
                        + "read the paid-App-Store warning in the report before you run it.\n"
                )
            }
            return
        }

        // Dry-run: pure data, nothing touched, exit 0 — refusals are honest
        // decision values in the report (refusalCode/refusalReason), not exits.
        try emit(
            InstallAdoptReport(mode: "install-adopt", count: decisions.count, apps: decisions, applied: false),
            outFile)
    }

    static func errLine(_ text: String) {
        if let utf8 = text.data(using: .utf8) {
            FileHandle.standardError.write(utf8)
        }
    }

    static func printUsage(_ problem: String) -> Never {
        errLine("error: \(problem)\n\n\(usage)\n")
        exit(2)
    }

    static func emit(_ value: some Encodable, _ outFile: String?) throws {
        var json: Data = try JSONEncoder.appUpdaterReport.encode(value)
        json.append(0x0A)
        if let outFile {
            try json.write(to: URL(fileURLWithPath: outFile, isDirectory: false), options: .atomic)
        } else {
            FileHandle.standardOutput.write(json)
        }
    }
}

// MARK: - Report models

/// What `scan` shows: the honest installed-environment inventory.
struct ScanAppSummary: Codable, Hashable {
    var name: String
    var path: String
    var bundleIdentifier: String
    var shortVersion: String?
    var bundleVersion: String?
    var isMacAppStore: Bool
    var hasSparkleFeed: Bool
    /// Glue-wiring additive (Setapp lane): the app's Setapp classification —
    /// a pure, synchronous documented-root path check. Display data only; it
    /// never gates or re-routes anything.
    var setapp: SetappClassification

    init(_ app: InstalledApp) {
        name = app.name
        path = app.path
        bundleIdentifier = app.bundleIdentifier
        shortVersion = app.shortVersion
        bundleVersion = app.bundleVersion
        isMacAppStore = app.isMacAppStore
        hasSparkleFeed = !(app.sparkleFeedURL ?? "").isEmpty
        setapp = SetappClassification(SetappSupport.classify(bundlePath: app.path))
    }
}

// MARK: - Encoder policy (deterministic reports)

extension JSONEncoder {
    /// Stable, sorted, human-readable reports — machine diffs stay meaningful.
    static let appUpdaterReport: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
