import Foundation
import AppUpdaterCore

// appupdater-cli — scriptable surface for the scan + check + install-plan engines.
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
//       Resolves the newest claim for the named app and prints an INSTALL PLAN.
//       WITHOUT --apply this is a dry-run: pure data, nothing downloads or moves.
//       WITH --apply the executor chain runs for real (download → independent
//       sha256/magic verify → backup → graceful quit → deploy → atomic swap →
//       postScan). Refusals (no claim / security floor) exit 3 before anything
//       is touched; an aborted step exits 1 with the full receipt chain.
//       Applying is strictly per-app (exactly one --apps match) and is the
//       user's explicit action — the CLI never batches silently. --relaunch
//       additionally asks LaunchServices to open the swapped bundle.
//
// Output: JSON on stdout (or a file via --out). Exit codes: 0 ok, 2 usage error,
// 3 honest-refusal (not wired / plan rejected), 1 failure.

private let usage = """
USAGE:
  appupdater-cli scan    [--dir PATH]... [--apps NAME[,NAME...] ] [--out FILE]
  appupdater-cli check   [--dir PATH]... [--apps NAME[,NAME...] ] [--out FILE]
  appupdater-cli install [--apps NAME] --out FILE [--apply] [--relaunch]

scan   : enumerate installed apps (no network). Default roots are
         /Applications plus your custom scan locations (unless --dir given).
check  : scan + live source lookups (cask > sparkle > mas > github; electron
         claims only when nothing stronger exists — locked precedence). A
         per-app manual pin (manual_sources.json) is consulted INSTEAD of
         every built-in source for that app (manual-over-builtin).
install: dry-run install PLAN per --apps (one app for --apply; refusals are
         honest: exit 3, nothing touched). --apply executes the plan for real
         with receipts; exit 0 = applied, 1 = aborted (see outcome.abortedStep),
         3 = plan refused (security floor / no claim), 2 = usage/target error.
--out FILE writes the JSON there instead of stdout (parent dir must exist).
"""

@main
struct CliMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        var mode = "scan"
        var dirs: [URL] = []
        var nameFilters: [String] = []
        var outFile: String?
        var applyRequested = false
        var relaunchRequested = false
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
                mode = arg
                positionalModeCount += 1
            case "--dir":
                guard index + 1 < arguments.count else { printUsage("missing value for --dir") }
                index += 1
                dirs.append(URL(fileURLWithPath: arguments[index], isDirectory: true))
            case "--apps":
                guard index + 1 < arguments.count else { printUsage("missing value for --apps") }
                index += 1
                nameFilters = arguments[index]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    .filter { !$0.isEmpty }
            case "--out":
                guard index + 1 < arguments.count else { printUsage("missing value for --out") }
                index += 1
                outFile = arguments[index]
            case "--apply":
                applyRequested = true
            case "--relaunch":
                relaunchRequested = true
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                printUsage("unknown argument: \(arg)")
            }
            index += 1
        }

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
            let scanner = ProductionAppScanner()
            var apps = try await scanner.scan(directoryURLs: dirs)
            if !nameFilters.isEmpty {
                apps = apps.filter { app in
                    let stack = [app.name.lowercased(), app.bundleIdentifier.lowercased()]
                    return nameFilters.contains { needle in stack.contains { $0.contains(needle) } }
                }
            }
            apps.sort { ($0.name, $0.path) < ($1.name, $1.path) }

            if mode == "scan" {
                try emit(ScanReport(mode: mode, count: apps.count, apps: apps.map(ScanAppSummary.init)), outFile)
                return
            }

            // Source roster — the same locked-precedence policy the app uses:
            // whole-index cask (ETag-cached, alias-free matching) with an
            // honest fallback to the per-token pipeline; Sparkle; MAS;
            // GitHub (bounded sparkle-feed harvest); Electron (unknown lane,
            // oracle-gated strictly-newer-only).
            let caskIndex = CaskIndexStore(directory: appSupport)
            var sources: [any UpdateSource] = []
            let revalidated = await caskIndex.ensureLoaded()
            var indexUsable = revalidated
            if !indexUsable {
                indexUsable = await caskIndex.isLoaded
            }
            if indexUsable {
                sources.append(CaskIndexSource(store: caskIndex))
            } else {
                sources.append(CaskSource())
            }
            sources.append(SparkleSource())
            sources.append(MASSource())
            sources.append(GithubSource(directory: appSupport, session: .shared))
            sources.append(ElectronSource())
            let manualService = ManualSourceResolverService(store: ManualSourceStore(directory: appSupport))
            let engine = UpdateCheckEngine(
                sources: sources,
                manualSource: manualService.engineResolver(
                    session: .shared, githubCacheDirectory: appSupport))
            let checks = await engine.checkAll(apps: apps)

            if mode == "check" {
                try emit(CheckReport(mode: mode, count: checks.count, apps: checks), outFile)
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

                try emit(InstallApplyReport(
                    mode: "install-apply",
                    applied: outcome.abortedStep == nil,
                    outcome: outcome), outFile)

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

    /// The one place stderr bytes come from: argument and refusal messages
    /// are literals here (always UTF-8-encodable), so if encoding somehow
    /// ever failed, this writes nothing instead of crashing a tool that is
    /// already reporting an error — the exit code at the call site stays
    /// committed as the truth (forced encode would be a crash, not a receipt).
    private static func errLine(_ text: String) {
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

    init(_ app: InstalledApp) {
        name = app.name
        path = app.path
        bundleIdentifier = app.bundleIdentifier
        shortVersion = app.shortVersion
        bundleVersion = app.bundleVersion
        isMacAppStore = app.isMacAppStore
        hasSparkleFeed = !(app.sparkleFeedURL ?? "").isEmpty
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
