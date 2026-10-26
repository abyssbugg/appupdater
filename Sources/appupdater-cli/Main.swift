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
//   appupdater-cli install [--apps NAME] [--out FILE] [--apply]
//       Resolves the newest claim for the named app and prints/plrcodes an INSTALL PLAN.
//       WITHOUT --apply this is a dry-run: pure data, nothing downloads or moves.
//       --apply is only honored when the built binary has executor wiring; otherwise it
//       exits 3 with an honest "not wired" note. NEVER prints a fake "installed".
//
// Output: JSON on stdout (or a file via --out). Exit codes: 0 ok, 2 usage error,
// 3 honest-refusal (not wired / plan rejected), 1 failure.

private let usage = """
USAGE:
  appupdater-cli scan  [--dir PATH]... [--apps NAME[,NAME...] ] [--out FILE]
  appupdater-cli check [--dir PATH]... [--apps NAME[,NAME...] ] [--out FILE]

scan : enumerate installed apps (no network).
check: scan + live source lookups (cask > sparkle > mas precedence).
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
        var positionalModeCount = 0

        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "scan", "check", "install":
                if positionalModeCount > 0 {
                    FileHandle.standardError.write("error: mode specified twice\n".data(using: .utf8)!)
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
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                printUsage("unknown argument: \(arg)")
            }
            index += 1
        }

        if dirs.isEmpty {
            dirs = [URL(fileURLWithPath: "/Applications", isDirectory: true)]
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

            let engine = UpdateCheckEngine(sources: [CaskSource(), SparkleSource(), MASSource()])
            let checks = await engine.checkAll(apps: apps)

            if mode == "check" {
                try emit(CheckReport(mode: mode, count: checks.count, apps: checks), outFile)
                return
            }

            // mode == "install": planner-driven dry-run (or labeled refusal for apply).
            if applyRequested {
                FileHandle.standardError.write(
                    "refusal: --apply executor wiring lands with the Phase-3 lane merge; this binary can PLAN only. dry-run (no --apply) is available now.\n".data(using: .utf8)!
                )
                exit(3)
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
            FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    static func printUsage(_ problem: String) -> Never {
        FileHandle.standardError.write("error: \(problem)\n\n\(usage)\n".data(using: .utf8)!)
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

/// Install-mode report: per-app PLAN data (dry-run) or labeled refusals.
/// `applied` is always false until the executor wiring is real — never fake success.
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
