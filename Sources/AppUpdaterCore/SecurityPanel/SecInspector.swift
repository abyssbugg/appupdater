// SecInspector.swift — the security panel's inspection engine (GAP #19).
//
// Contract (docs/reverse/GAP-ANALYSIS.md #19 + UPDATEST-FINDINGS.md §3.14):
//   Updatest's per-app Security panel reads other apps' code signatures and
//   entitlements (notarization, Gatekeeper, hardened runtime, sandbox) via
//   /usr/bin/codesign. This module reproduces that READ-ONLY, user-space,
//   network-free panel: four local probes per app bundle, every outcome
//   (including failure) recorded in the report's notes. No privilege, no
//   writes, no network — probes never modify the inspected bundle.
//
// Probes (paths/arguments frozen here; the panel's data IS these tools):
//   1. `codesign -dv -vvvv <app>`        → display parse: authorities,
//      TeamIdentifier, CDHash, CodeDirectory flags (runtime ⇒ hardened
//      runtime; linker-signed), Timestamp, Notarization Ticket.
//      MACHINE FACT (macOS 27.2 verified): codesign's display output goes to
//      STDERR, not stdout — so the display parser runs over the COMBINED
//      streams, which keeps the parse correct on versions that route it
//      differently instead of trusting one stream.
//   2. `codesign --verify --deep --strict <app>` → exit code ⇒ codesignValid.
//   3. `spctl -a -vv <app>`              → Gatekeeper assessment word
//      (accepted/rejected) + source=/origin= labels. spctl lives in
//      /usr/sbin (NOT /usr/bin — verified absent there on macOS 27.2). Its
//      output is also parsed from the combined streams (macOS 27.2 routes
//      the whole assessment to stderr).
//   4. `codesign -d --entitlements :- <app>` → plist dict (XML on current
//      macOS) → entitlement keys, app-sandbox presence, keychain-access-
//      groups count. The `:-` form prints a deprecation warning to stderr on
//      macOS 12.3+; on versions where it emits DER instead of XML, a single
//      `:-:xml` fallback probe decodes it — the fallback runs ONLY when the
//      primary form yields no parseable plist, and which form won is noted.
//
// SEAM: all process execution goes through an injected SecProcessRunner
// (mirror of BundleDeployer.runProcess's shape — Process + Pipes drained to
// EOF before waitUntilExit, all inside a dispatch closure so no non-Sendable
// state crosses the Swift 6 boundary; written here, NOT shared with Deploy).
// The inspector itself never throws: every probe failure becomes an explicit
// note + the field-level unknown verdict (honesty discipline). Tests inject
// stub runners for spctl failure paths and paste real outputs as fixtures;
// live tests run the real tools against ad-hoc-signed temp fixtures.
//
// NOT wired into the scanner/UI/CLI — the coordinator owns that glue.

import Foundation

// MARK: - Process-runner seam

/// Injected process runner for the security panel's probes. Deliberately its
/// own tiny type (not a protocol, not shared with Deploy): tests inject a
/// closure returning canned runs; production injects `.live()`.
public struct SecProcessRunner: Sendable {

    /// One finished process run: drained pipes + exit status.
    public struct Run: Sendable {
        public let stdout: String
        public let stderr: String
        public let exitStatus: Int32
        public var succeeded: Bool { exitStatus == 0 }

        public init(stdout: String, stderr: String, exitStatus: Int32) {
            self.stdout = stdout
            self.stderr = stderr
            self.exitStatus = exitStatus
        }
    }

    /// Run `launchPath` with `arguments`, returning the drained run or throwing
    /// when the process could not be spawned at all (e.g. binary missing).
    public typealias Invoke = @Sendable (_ launchPath: String, _ arguments: [String]) async throws -> Run

    private let invoke: Invoke

    public init(invoke: @escaping Invoke) {
        self.invoke = invoke
    }

    public func run(launchPath: String, arguments: [String]) async throws -> Run {
        try await invoke(launchPath, arguments)
    }

    /// Production runner — the same mechanics as BundleDeployer.runProcess
    /// (Process created, run, drained to EOF, waited on entirely inside the
    /// dispatch closure; no non-Sendable state crosses the concurrency
    /// boundary). Our probes are single-purpose and quiet, so output is
    /// bounded by design.
    public static func live() -> SecProcessRunner {
        SecProcessRunner { launchPath, arguments in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Run, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: launchPath)
                    process.arguments = arguments
                    let out = Pipe()
                    let err = Pipe()
                    process.standardOutput = out
                    process.standardError = err
                    do { try process.run() } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = err.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: Run(
                        stdout: String(decoding: stdoutData, as: UTF8.self),
                        stderr: String(decoding: stderrData, as: UTF8.self),
                        exitStatus: process.terminationStatus))
                }
            }
        }
    }
}

// MARK: - Inspector

public enum SecInspector {

    /// Tool locations on stock macOS (verified on the 27.2 build host:
    /// codesign in /usr/bin; spctl ONLY in /usr/sbin — /usr/bin/spctl does
    /// not exist). Public: the panel's provenance is part of its honesty.
    public static let codesignPath = "/usr/bin/codesign"
    public static let spctlPath = "/usr/sbin/spctl"

    // Probe argument templates (path is appended last).
    static let displayArguments = ["-dv", "-vvvv"]
    static let verifyArguments = ["--verify", "--deep", "--strict"]
    static let entitlementsArguments = ["-d", "--entitlements", ":-"]
    static let entitlementsFallbackArguments = ["-d", "--entitlements", ":-:xml"]
    static let gatekeeperArguments = ["-a", "-vv"]

    /// Inspects one app bundle and returns its report. NEVER throws: a missing
    /// bundle, an unreadable one, a failed probe, or unparseable output each
    /// become explicit notes with the field-level unknown verdict.
    public static func inspect(appAt appURL: URL, using runner: SecProcessRunner = .live()) async -> SecReport {
        var report = SecReport(appPath: appURL.path)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: appURL.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            report.notes.append(exists
                ? "app path is not a bundle directory — no probes run: \(appURL.path)"
                : "app bundle not found — no probes run: \(appURL.path)")
            return report
        }

        await probeSignatureDisplay(appURL.path, runner: runner, into: &report)
        await probeVerify(appURL.path, runner: runner, into: &report)
        await probeGatekeeper(appURL.path, runner: runner, into: &report)
        await probeEntitlements(appURL.path, runner: runner, into: &report)
        return report
    }

    // MARK: - Probe 1: codesign -dv -vvvv (signature display)

    private static func probeSignatureDisplay(_ path: String, runner: SecProcessRunner, into report: inout SecReport) async {
        let run: SecProcessRunner.Run
        do {
            run = try await runner.run(launchPath: codesignPath, arguments: displayArguments + [path])
        } catch {
            report.notes.append("codesign -dv could not be launched: \(error)")
            return
        }
        // The bundle's signature PRESENCE verdict comes from the probe's own
        // outcome, not from parsing: exit 0 = a signature was displayed;
        // "not signed at all" = honestly unsigned; anything else = unreadable.
        if run.succeeded {
            report.signaturePresent = true
        } else if firstDiagnosticLine(of: run.stderr).contains("not signed at all") {
            report.signaturePresent = false
            report.notes.append("codesign reports the bundle is not signed (exit \(run.exitStatus)): "
                + firstDiagnosticLine(of: run.stderr))
            return
        } else {
            report.notes.append("codesign -dv failed (exit \(run.exitStatus)): "
                + (firstDiagnosticLine(of: run.stderr).isEmpty ? "<no diagnostics>" : firstDiagnosticLine(of: run.stderr)))
            return
        }

        let parsed = parseSignatureDisplay(combinedStreams(of: run))
        report.signatureAuthorities = parsed.authorities
        report.teamIdentifier = parsed.teamIdentifier
        report.signedIdentifier = parsed.identifier
        report.executablePath = parsed.executablePath
        report.cdHash = parsed.cdHash
        report.timestamp = parsed.timestamp
        report.notarizationTicket = parsed.notarizationTicket
        report.hardenedRuntime = parsed.hardenedRuntime
        report.linkerSigned = parsed.linkerSigned
        report.isAdHoc = parsed.isAdHoc
        report.runtimeVersion = parsed.runtimeVersion
        if let total = parsed.totalSignatures, total > 1 {
            let chosen = parsed.chosenSignature.map(String.init) ?? "?"
            report.notes.append("codesign reports \(total) signatures; this panel parsed only the "
                + "chosen one (Chosen signature=\(chosen))")
        }
        if parsed.hardenedRuntime == nil {
            report.notes.append("no CodeDirectory flags field found in codesign display — "
                + "hardened-runtime verdict withheld (unknown)")
        }
    }

    // MARK: - Probe 2: codesign --verify --deep --strict

    private static func probeVerify(_ path: String, runner: SecProcessRunner, into report: inout SecReport) async {
        let run: SecProcessRunner.Run
        do {
            run = try await runner.run(launchPath: codesignPath, arguments: verifyArguments + [path])
        } catch {
            report.notes.append("codesign --verify could not be launched: \(error)")
            return
        }
        if run.succeeded {
            report.codesignValid = true
        } else {
            report.codesignValid = false
            let reason = firstDiagnosticLine(of: run.stderr)
            report.notes.append("codesign --verify --deep --strict failed (exit \(run.exitStatus)): "
                + (reason.isEmpty ? "<no diagnostics>" : reason))
        }
    }

    // MARK: - Probe 3: spctl -a -vv (Gatekeeper)

    private static func probeGatekeeper(_ path: String, runner: SecProcessRunner, into report: inout SecReport) async {
        let run: SecProcessRunner.Run
        do {
            run = try await runner.run(launchPath: spctlPath, arguments: gatekeeperArguments + [path])
        } catch {
            report.notes.append("spctl could not be launched: \(error)")
            return
        }
        let parsed = parseGatekeeper(exitStatus: run.exitStatus, combinedText: combinedStreams(of: run))
        report.gatekeeperAssessment = parsed.verdict
        report.gatekeeperSource = parsed.source
        report.gatekeeperOrigin = parsed.origin
        if parsed.verdict == .unknown, let note = parsed.unknownNote {
            report.notes.append(note)
        }
    }

    // MARK: - Probe 4: codesign -d --entitlements :- (entitlements)

    private static func probeEntitlements(_ path: String, runner: SecProcessRunner, into report: inout SecReport) async {
        let run: SecProcessRunner.Run
        do {
            run = try await runner.run(launchPath: codesignPath, arguments: entitlementsArguments + [path])
        } catch {
            report.notes.append("codesign --entitlements could not be launched: \(error)")
            return
        }

        if run.succeeded, let dict = embeddedPlistDict(in: run.stdout) {
            apply(entitlementDict: dict, fromStream: "stdout", into: &report)
            return
        }
        if run.succeeded, let dict = embeddedPlistDict(in: run.stderr) {
            apply(entitlementDict: dict, fromStream: "stderr", into: &report)
            report.notes.append("entitlements dict parsed from the codesign diagnostic stream "
                + "(stdout carried none)")
            return
        }
        guard run.succeeded else {
            report.notes.append("entitlements unreadable — codesign --entitlements failed "
                + "(exit \(run.exitStatus)): " + (firstDiagnosticLine(of: run.stderr).isEmpty
                    ? "<no diagnostics>" : firstDiagnosticLine(of: run.stderr)))
            return
        }

        // Primary `:-` form succeeded but no plist came out: DER-era output or
        // genuinely no entitlements. One fallback probe decides which.
        let fallback: SecProcessRunner.Run
        do {
            fallback = try await runner.run(launchPath: codesignPath, arguments: entitlementsFallbackArguments + [path])
        } catch {
            report.notes.append("entitlements unreadable — the ':-:xml' fallback probe could not be "
                + "launched after the primary ':-' form yielded no plist: \(error)")
            return
        }
        if fallback.succeeded, let dict = embeddedPlistDict(in: combinedStreams(of: fallback)) {
            apply(entitlementDict: dict, fromStream: "fallback-xml", into: &report)
            report.notes.append("primary ':-' entitlements form was not plist-readable; "
                + "the ':-:xml' fallback form parsed it")
            return
        }
        if fallback.succeeded {
            // Both forms silent ⇒ the bundle genuinely carries no entitlements.
            report.entitlementsPresent = false
            report.sandboxed = false
            report.entitlementKeys = []
            report.notes.append("codesign exited 0 but no entitlement dict was parseable from either "
                + "the ':-' or ':-:xml' form — bundle carries no entitlements")
        } else {
            report.notes.append("entitlements unreadable — the ':-:xml' fallback probe failed "
                + "(exit \(fallback.exitStatus)): " + (firstDiagnosticLine(of: fallback.stderr).isEmpty
                    ? "<no diagnostics>" : firstDiagnosticLine(of: fallback.stderr)))
        }
    }

    /// Fills the entitlement summary fields from a parsed dict.
    private static func apply(entitlementDict dict: [String: Any], fromStream stream: String, into report: inout SecReport) {
        let parsed = parseEntitlements(dict)
        report.entitlementsPresent = true
        report.entitlementKeys = parsed.keys
        report.sandboxed = parsed.sandboxed
        report.keychainAccessGroupsCount = parsed.keychainAccessGroupsCount
        if stream == "fallback-xml" { return } // its note is written by the caller
        if parsed.keychainAccessGroupsPresentButNotArray {
            report.notes.append("keychain-access-groups entitlement present but not an array — "
                + "count withheld (unknown)")
        }
    }

    // MARK: - Display parser (pure; fixture-tested with real outputs)

    struct ParsedDisplay: Equatable {
        var executablePath: String?
        var identifier: String?
        var authorities: [String] = []
        var teamIdentifier: String?
        var cdHash: String?
        var timestamp: String?
        var notarizationTicket: String?
        var hardenedRuntime: Bool?
        var linkerSigned: Bool?
        var isAdHoc: Bool?
        var runtimeVersion: String?
        var totalSignatures: Int?
        var chosenSignature: Int?
    }

    /// Parses `codesign -dv -vvvv` display text (Key=Value lines; hash-page
    /// dumps start with whitespace and are skipped). Runs over the combined
    /// stdout+stderr because codesign's stream routing differs across macOS
    /// versions (stderr on 27.2). The CodeDirectory line is matched by PREFIX
    /// because its first `=` belongs to `v=20400` inside the line itself.
    static func parseSignatureDisplay(_ text: String) -> ParsedDisplay {
        var parsed = ParsedDisplay()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("CodeDirectory ") {
                parseCodeDirectoryFlags(String(line.dropFirst("CodeDirectory ".count)), into: &parsed)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq])
            let value = String(line[line.index(after: eq)...])
            switch key {
            case "Executable":
                parsed.executablePath = value
            case "Identifier":
                parsed.identifier = value
            case "Authority":
                parsed.authorities.append(value)
            case "TeamIdentifier":
                parsed.teamIdentifier = value == "not set" ? nil : value
            case "CDHash":
                parsed.cdHash = value
            case "Timestamp", "Signed Time":
                // Modern spelling first; the older `Signed Time=` fills only
                // when no Timestamp was seen (a display never carries both).
                if parsed.timestamp == nil { parsed.timestamp = value }
            case "Notarization Ticket":
                parsed.notarizationTicket = value
            case "Runtime Version":
                parsed.runtimeVersion = value
            case "Signature" where value == "adhoc":
                parsed.isAdHoc = true
            case "Total signatures":
                parsed.totalSignatures = Int(value.trimmingCharacters(in: .whitespaces))
            case "Chosen signature":
                parsed.chosenSignature = Int(value.trimmingCharacters(in: .whitespaces))
            default:
                continue
            }
        }
        return parsed
    }

    /// Extracts the CodeDirectory flags word+hex: `… flags=0x10000(runtime) …`.
    /// The parenthetical can be absent on some outputs (`flags=0x10000`) — the
    /// numeric bits must still yield the verdict.
    private static func parseCodeDirectoryFlags(_ value: String, into parsed: inout ParsedDisplay) {
        guard let flagsRange = value.range(of: "flags=0x") else { return }
        let hexStart = flagsRange.upperBound
        var hexEnd = hexStart
        while hexEnd < value.endIndex, value[hexEnd].isHexDigit {
            hexEnd = value.index(after: hexEnd)
        }
        guard hexEnd != hexStart else { return }
        var words: [String] = []
        if hexEnd < value.endIndex, value[hexEnd] == "(" {
            var parenEnd = hexEnd
            while parenEnd < value.endIndex, value[parenEnd] != ")" {
                parenEnd = value.index(after: parenEnd)
            }
            if parenEnd < value.endIndex {
                // Observed separators differ by codesign version:
                // "adhoc|linker-signed" (older) and "adhoc,linker-signed"
                // (macOS 27.2) — accept both.
                words = value[value.index(after: hexEnd)..<parenEnd]
                    .split(whereSeparator: { $0 == "|" || $0 == "," })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        let flagBits = Int64(String(value[hexStart..<hexEnd]), radix: 16) ?? 0
        // Word-match is what codesign itself prints; the numeric bits are the
        // same flags expressed numerically (0x10000 runtime, 0x20000
        // linker-signed, 0x2 adhoc) — a version that drops the parenthetical
        // still gets a verdict.
        parsed.hardenedRuntime = words.contains("runtime") || (flagBits & 0x1_0000 != 0)
        parsed.linkerSigned = words.contains("linker-signed") || (flagBits & 0x2_0000 != 0)
        parsed.isAdHoc = words.contains("adhoc") || (flagBits & 0x2 != 0) || (parsed.isAdHoc == true)
    }

    // MARK: - Gatekeeper parser (pure)

    struct ParsedGatekeeper: Equatable {
        var verdict: SecReport.GatekeeperAssessment
        var source: String?
        var origin: String?
        /// Note text when the verdict is unknown (nil otherwise).
        var unknownNote: String?
    }

    /// Pairs the spctl exit code with the assessment WORD (spctl's contract:
    /// exit 0 accepted / exit 3 rejected; anything else is an error, and even
    /// a "matching" exit without its word is not trusted).
    static func parseGatekeeper(exitStatus: Int32, combinedText: String) -> ParsedGatekeeper {
        var source: String?
        var origin: String?
        for rawLine in combinedText.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("source=") { source = String(line.dropFirst("source=".count)) }
            if line.hasPrefix("origin=") { origin = String(line.dropFirst("origin=".count)) }
        }
        let firstLine = firstDiagnosticLine(of: combinedText)
        if exitStatus == 0, firstLine.hasSuffix(": accepted") || firstLine.hasSuffix(" accepted") {
            return ParsedGatekeeper(verdict: .accepted, source: source, origin: origin)
        }
        if exitStatus == 3, firstLine.hasSuffix(": rejected") || firstLine.hasSuffix(" rejected") {
            return ParsedGatekeeper(verdict: .rejected, source: source, origin: origin)
        }
        let note = "spctl -a -vv could not produce an assessment (exit \(exitStatus)): "
            + (firstLine.isEmpty ? "<no diagnostics>" : firstLine)
        return ParsedGatekeeper(verdict: .unknown, source: source, origin: origin, unknownNote: note)
    }

    // MARK: - Entitlements parsing (pure)

    struct ParsedEntitlements: Equatable {
        var keys: [String]
        var sandboxed: Bool
        var keychainAccessGroupsCount: Int?
        var keychainAccessGroupsPresentButNotArray: Bool
    }

    /// Summarizes an entitlement dict: sorted keys, app-sandbox claim presence,
    /// keychain-access-groups array count (nil when the key is absent — no
    /// such entitlement is not the same fact as zero groups).
    static func parseEntitlements(_ dict: [String: Any]) -> ParsedEntitlements {
        let keys = dict.keys.sorted()
        var count: Int?
        var presentButNotArray = false
        if let value = dict["keychain-access-groups"] {
            if let array = value as? [Any] {
                count = array.count
            } else {
                presentButNotArray = true
            }
        }
        return ParsedEntitlements(
            keys: keys,
            sandboxed: dict["com.apple.security.app-sandbox"] != nil,
            keychainAccessGroupsCount: count,
            keychainAccessGroupsPresentButNotArray: presentButNotArray)
    }

    /// Parses a plist dict out of `text`: direct parse first (clean XML or
    /// binary plist), then an `<?xml … </plist>` substring (the diagnostic
    /// stream can carry display lines around the plist).
    static func embeddedPlistDict(in text: String) -> [String: Any]? {
        if let direct = plistDictionary(from: text) { return direct }
        guard let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>"),
              start.lowerBound < end.lowerBound
        else { return nil }
        return plistDictionary(from: String(text[start.lowerBound..<end.upperBound]))
    }

    private static func plistDictionary(from text: String) -> [String: Any]? {
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let root = try? PropertyListSerialization.propertyList(
            from: Data(text.utf8), options: [], format: &format)
        else { return nil }
        return root as? [String: Any]
    }

    // MARK: - Text helpers

    /// stdout and stderr merged (codesign/spctl route their display across
    /// streams differently by macOS version; the parse works on the union).
    private static func combinedStreams(of run: SecProcessRunner.Run) -> String {
        let parts = [run.stdout, run.stderr].filter { !$0.isEmpty }
        return parts.joined(separator: "\n")
    }

    /// First non-empty line, trimmed — the bounded evidence a note carries
    /// (never a whole diagnostic dump).
    private static func firstDiagnosticLine(of text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }
}
