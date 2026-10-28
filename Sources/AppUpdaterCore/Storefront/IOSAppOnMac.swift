// IOSAppOnMac.swift — iOS-apps-on-Mac classification, documented signal set
// (GAP #10).
//
// Contract (UPDATEST-FINDINGS.md §3.1 [confirmed] — mirrored EXACTLY):
//   "MAS receipt detection: reads Contents/_MASReceipt/receipt,
//   /INSTALL_RECEIPT.json and /.metadata/INSTALL_RECEIPT.json
//   (iOS-app-on-mac wrapper), Wrapper/iTunesMetadata.plist,
//   kMDItemAppStoreAdamID, and shells out to /usr/sbin/pkgutil; fields
//   trackId, purchaseDate, installedDate."
//   Plus §3.4 [confirmed]: iOS-apps-on-Mac update copy — "This iOS app can
//   only be updated through the Mac App Store" / "iOS apps must be updated
//   through the Mac App Store".
//
// Signal roles (as documented — nothing added, nothing guessed):
//   - Wrapper/iTunesMetadata.plist, INSTALL_RECEIPT.json and
//     .metadata/INSTALL_RECEIPT.json → iOS-app-on-Mac WRAPPER markers ⇒
//     verdict `.iosAppOnMac`; trackId / purchaseDate / installedDate are
//     extracted from these when present under their DOCUMENTED key names.
//   - Contents/_MASReceipt/receipt → MAC App Store receipt ⇒ `.macAppStoreApp`
//     (a macOS MAS app, not an iOS wrapper). Documented presence check only —
//     the receipt blob is not parsed; MacUpdater additionally validates the
//     receipt's team (76TX64X7HC), noted but not reimplemented here.
//   - kMDItemAppStoreAdamID → Spotlight fallback for the App Store track ID.
//     Documented as a MAS-detection signal, so ON ITS OWN it yields
//     `.unknown`-with-note (it cannot distinguish a MAS app from an iOS
//     wrapper); its value is surfaced as trackId with the mapping flagged.
//   - pkgutil → documented read-only shell-out. The teardown names the tool
//     but not the parsed line, so the mapping is minimal and flagged: the
//     `install-time:` epoch line (the only date its standard output carries)
//     maps to installedDate, surfaced in evidence, never silently.
//
// Verdict precedence is our composition of the documented signals and is
//   flagged in notes where it matters: wrapper markers beat _MASReceipt
//   (an iOS wrapper can also carry a MAS receipt; the wrapper markers are
//   the more specific documented signal). A marker that is PRESENT but
//   unreadable ⇒ `.unknown` with a note — unknown is a first-class verdict
//   (repo honesty discipline), never collapsed.
//
// READ-ONLY + NETWORK-FREE:
//   - File reads go through the injected IOSBundleFileReader (FileManager
//     default). Tests build real fixture bundles in their own temp dirs.
//   - The two external probes (Spotlight kMDItemAppStoreAdamID, pkgutil) go
//     through injected async closures; the `.live()` forms run /usr/bin/mdls
//     and /usr/sbin/pkgutil. The teardown documents the KEY and the
//     SHELL-OUT, not the exact invocation forms — ours are stated in the
//     probe notes. Tests stub both, so no process is ever spawned in tests.
//
// NOT wired into the scanner/engine/AppState/CLI — the coordinator owns that
//   glue. No MAS automation here (future assistant work): documented DATA
//   layer only.

import Foundation

// MARK: - Result type

/// Classification of one app bundle against the documented iOS-apps-on-Mac
/// signal set. Immutable; every field carries its provenance.
public struct IOSAppOnMacInfo: Equatable, Sendable {

    public enum Verdict: Equatable, Sendable {
        /// Documented iOS-app-on-Mac wrapper markers present (iTunesMetadata
        /// wrapper plist and/or INSTALL_RECEIPT.json receipts).
        case iosAppOnMac
        /// Only the Mac App Store receipt is present — a macOS MAS app,
        /// not an iOS-on-Mac wrapper.
        case macAppStoreApp
        /// Bundle is readable and NONE of the documented markers exist.
        case notIOSAppOnMac
        /// Bundle missing, marker present but unreadable, or only ambiguous
        /// signals (e.g. bare Spotlight adamID) — first-class honest unknown.
        case unknown
    }

    public let verdict: Verdict

    /// App Store track ID when a documented source yielded it (receipt JSON,
    /// wrapper metadata plist, or the Spotlight adamID probe — mapping
    /// flagged in evidence).
    public let trackId: String?

    /// Documented field, extracted only from documented keys (plist-native
    /// date, ISO-8601 string, or numeric epoch — formats are NOT documented,
    /// unparseable values stay nil with a note).
    public let purchaseDate: Date?

    /// Documented field, extracted from documented keys or the flagged
    /// pkgutil `install-time` line.
    public let installedDate: Date?

    /// Documented-marker findings: which documented files/keys were found,
    /// which documented fields were extracted, each with its source.
    public let evidence: [String]

    /// Honest caveats: unreadable markers, undocumented-mechanism flags, the
    /// documented update-path copy for wrappers/MAS apps.
    public let note: String

    public init(
        verdict: Verdict,
        trackId: String?,
        purchaseDate: Date?,
        installedDate: Date?,
        evidence: [String],
        note: String)
    {
        self.verdict = verdict
        self.trackId = trackId
        self.purchaseDate = purchaseDate
        self.installedDate = installedDate
        self.evidence = evidence
        self.note = note
    }
}

// MARK: - File-reader seam

/// Injected file access for bundle contents. Tests can stub it, but the
/// default is plain FileManager over the caller's own fixture dirs — hermetic
/// either way (no /Applications or system paths are ever touched by tests).
public struct IOSBundleFileReader: Sendable {

    public typealias Read = @Sendable (_ path: String) throws -> Data
    public typealias Exists = @Sendable (_ path: String) -> Bool

    private let readData: Read
    private let existsCheck: Exists

    public init(read: @escaping Read, exists: @escaping Exists) {
        self.readData = read
        self.existsCheck = exists
    }

    public func data(atPath path: String) throws -> Data {
        try readData(path)
    }

    public func exists(atPath path: String) -> Bool {
        existsCheck(path)
    }

    public static func live() -> IOSBundleFileReader {
        IOSBundleFileReader(
            read: { try Data(contentsOf: URL(fileURLWithPath: $0)) },
            exists: { FileManager.default.fileExists(atPath: $0) })
    }
}

// MARK: - External probes (Spotlight adamID, pkgutil)

/// Injected async probes for the two documented external signals. Tests stub
/// both with canned/nil/throwing closures — nothing is ever executed in tests.
public struct IOSAppProbes: Sendable {

    /// Returns the raw Spotlight value of kMDItemAppStoreAdamID for the
    /// bundle, or nil when absent/unavailable. May throw (surfaced as a note).
    public typealias AdamID = @Sendable (_ bundlePath: String) async throws -> String?

    /// Returns the raw stdout of the documented pkgutil shell-out for the
    /// bundle identifier, or nil. May throw (surfaced as a note).
    public typealias Pkgutil = @Sendable (_ bundleID: String) async throws -> String?

    public let adamID: AdamID
    public let pkgutil: Pkgutil

    public init(adamID: @escaping AdamID, pkgutil: @escaping Pkgutil) {
        self.adamID = adamID
        self.pkgutil = pkgutil
    }

    /// Production probes (mechanisms OURS, flagged in the classifier's notes):
    ///   - adamID: `/usr/bin/mdls -raw -name kMDItemAppStoreAdamID <bundle>` —
    ///     the teardown documents the Spotlight KEY, not the query mechanism;
    ///     mdls is the read-only Spotlight CLI. mdls prints "(null)" for a
    ///     missing attribute, which is normalized to nil.
    ///   - pkgutil: `/usr/sbin/pkgutil --pkg-info <bundleID>` — the teardown
    ///     documents the /usr/sbin/pkgutil shell-out; the argument form is
    ///     the standard read-only --pkg-info form (flagged as ours).
    public static func live() -> IOSAppProbes {
        IOSAppProbes(
            adamID: { bundlePath in
                let run = try await runProbeProcess(launchPath: "/usr/bin/mdls", arguments: [
                    "-raw", "-name", "kMDItemAppStoreAdamID", bundlePath,
                ])
                guard run.exitStatus == 0 else { return nil }
                let value = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                return (value.isEmpty || value == "(null)") ? nil : value
            },
            pkgutil: { bundleID in
                let run = try await runProbeProcess(launchPath: "/usr/sbin/pkgutil", arguments: [
                    "--pkg-info", bundleID,
                ])
                guard run.exitStatus == 0 else { return nil }
                let value = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            })
    }
}

/// Internal single-shot process runner — same mechanics as the SecurityPanel
/// lane's SecProcessRunner (Process + pipes drained to EOF before
/// waitUntilExit, inside a dispatch closure so no non-Sendable state crosses
/// the Swift 6 boundary). Kept private to this lane: read-only queries only.
private func runProbeProcess(launchPath: String, arguments: [String]) async throws
    -> (stdout: String, stderr: String, exitStatus: Int32)
{
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
        (stdout: String, stderr: String, exitStatus: Int32), Error>) in
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
            continuation.resume(returning: (
                stdout: String(decoding: stdoutData, as: UTF8.self),
                stderr: String(decoding: stderrData, as: UTF8.self),
                exitStatus: process.terminationStatus))
        }
    }
}

// MARK: - Classifier

public enum IOSAppOnMac {

    // Documented marker paths (bundle-relative), verbatim from §3.1.
    public static let wrapperMetadataPath = "Wrapper/iTunesMetadata.plist"
    public static let installReceiptPath = "INSTALL_RECEIPT.json"
    public static let metadataInstallReceiptPath = ".metadata/INSTALL_RECEIPT.json"
    public static let macReceiptPath = "Contents/_MASReceipt/receipt"
    public static let infoPlistPath = "Contents/Info.plist"

    /// Documented Spotlight key (§3.1).
    public static let spotlightAdamIDKey = "kMDItemAppStoreAdamID"

    /// Documented update-path copy (§3.4), surfaced verbatim for wrappers.
    public static let documentedWrapperUpdateCopy =
        "This iOS app can only be updated through the Mac App Store — "
            + "iOS apps must be updated through the Mac App Store"

    /// Documented MAS update-path default (§3.4), surfaced for MAS receipts.
    public static let documentedMASUpdateCopy =
        "documented MAS update path (Updatest §3.4): open the App Store"

    /// Local accumulator threading the documented findings (the three
    /// documented fields, evidence, unreadable markers, parsed-marker count)
    /// through the parse helpers — keeps their parameter counts small and the
    /// data flow explicit.
    private struct MarkerFindings {
        var trackId: String?
        var purchaseDate: Date?
        var installedDate: Date?
        var evidence: [String] = []
        var unreadable: [String] = []
        var parsedMarkerCount = 0
    }

    /// Classifies one bundle. NEVER throws; every probe failure becomes an
    /// explicit note with the honest verdict.
    public static func classify(
        bundlePath: String,
        reader: IOSBundleFileReader = .live(),
        probes: IOSAppProbes = .live()
    ) async -> IOSAppOnMacInfo {
        guard reader.exists(atPath: bundlePath) else {
            return IOSAppOnMacInfo(
                verdict: .unknown,
                trackId: nil, purchaseDate: nil, installedDate: nil,
                evidence: [],
                note: "bundle path not found — no probes run: \(bundlePath)")
        }

        var notes: [String] = []
        var findings = MarkerFindings()

        // 1. Documented iOS-app-on-Mac wrapper markers.
        parseWrapperMetadata(bundlePath: bundlePath, reader: reader, into: &findings)
        parseInstallReceipt(
            relativePath: installReceiptPath, bundlePath: bundlePath, reader: reader,
            into: &findings)
        parseInstallReceipt(
            relativePath: metadataInstallReceiptPath, bundlePath: bundlePath, reader: reader,
            into: &findings)

        var trackId = findings.trackId
        var purchaseDate = findings.purchaseDate
        var installedDate = findings.installedDate
        var evidence = findings.evidence
        let wrapperMarkerCount = findings.parsedMarkerCount

        for marker in findings.unreadable {
            notes.append("documented marker present but unreadable: \(marker)")
        }

        // 2. Verdict from wrapper markers; else the documented MAS receipt.
        //     An UNREADABLE documented wrapper marker cannot assert membership
        //     (and, being the more specific signal, also blocks the MAS-receipt
        //     verdict it would otherwise outrank) — with no successfully parsed
        //     marker the verdict is withheld: honest unknown, never a guess.
        if wrapperMarkerCount > 0 {
            notes.append(documentedWrapperUpdateCopy
                + " (UPDATEST-FINDINGS §3.4; wrapper markers beat a possible _MASReceipt — "
                + "our precedence composition of the documented signals)")
            notes.append(documentedMASUpdateCopy)
            return IOSAppOnMacInfo(
                verdict: .iosAppOnMac,
                trackId: trackId, purchaseDate: purchaseDate, installedDate: installedDate,
                evidence: evidence,
                note: notes.joined(separator: " · "))
        }

        if !findings.unreadable.isEmpty {
            notes.append("a documented wrapper marker is present but unreadable — the wrapper "
                + "verdict cannot be asserted and it outranks the MAS receipt, so the verdict "
                + "is withheld (unknown)")
            return IOSAppOnMacInfo(
                verdict: .unknown,
                trackId: trackId, purchaseDate: purchaseDate, installedDate: installedDate,
                evidence: evidence,
                note: notes.joined(separator: " · "))
        }

        let macReceipt = bundlePath + "/" + macReceiptPath
        if reader.exists(atPath: macReceipt) {
            evidence.append("Contents/_MASReceipt/receipt present (documented MAS receipt)")
            notes.append("Mac App Store receipt present — macOS MAS app, not an iOS-on-Mac wrapper")
            notes.append("MacUpdater additionally validates the receipt's team (76TX64X7HC) — "
                + "the receipt blob is not parsed here")
            notes.append(documentedMASUpdateCopy)
            return IOSAppOnMacInfo(
                verdict: .macAppStoreApp,
                trackId: trackId, purchaseDate: purchaseDate, installedDate: installedDate,
                evidence: evidence,
                note: notes.joined(separator: " · "))
        }

        // 3. No wrapper, no MAS receipt: the two remaining documented signals.
        //     Both are documented MAS-DETECTION signals, so on their own they
        //     cannot say iOS-on-Mac — each yields the honest unknown, never a
        //     guess. A THROWN probe means the documented signal set could not
        //     be completed → unknown as well (honesty discipline).
        let adamIDOutcome = await probeAdamID(
            bundlePath: bundlePath, probes: probes, into: &trackId,
            evidence: &evidence, notes: &notes)
        let pkgutilOutcome = await probePkgutil(
            bundlePath: bundlePath, reader: reader, probes: probes,
            into: &installedDate, evidence: &evidence, notes: &notes)

        if adamIDOutcome.found || pkgutilOutcome.found {
            if adamIDOutcome.found {
                notes.append("the Spotlight \(spotlightAdamIDKey) signal is present "
                    + "(documented MAS-detection signal) — cannot distinguish a MAS app from an "
                    + "iOS-on-Mac wrapper without the documented wrapper markers")
            }
            if pkgutilOutcome.found {
                notes.append("a pkgutil receipt exists for this bundle (documented MAS-detection "
                    + "shell-out) — same ambiguity, verdict stays unknown")
            }
            return IOSAppOnMacInfo(
                verdict: .unknown,
                trackId: trackId, purchaseDate: purchaseDate, installedDate: installedDate,
                evidence: evidence,
                note: notes.joined(separator: " · "))
        }

        if adamIDOutcome.failed || pkgutilOutcome.failed {
            notes.append("a documented external probe failed — the documented signal set is "
                + "incomplete, verdict withheld (unknown)")
            return IOSAppOnMacInfo(
                verdict: .unknown,
                trackId: trackId, purchaseDate: purchaseDate, installedDate: installedDate,
                evidence: evidence,
                note: notes.joined(separator: " · "))
        }

        evidence.append("none of the documented markers found: \(wrapperMetadataPath), "
            + "\(installReceiptPath), \(metadataInstallReceiptPath), \(macReceiptPath), "
            + "Spotlight \(spotlightAdamIDKey), pkgutil receipt")
        notes.append("bundle is readable and carries no documented iOS-app-on-Mac or MAS marker")
        return IOSAppOnMacInfo(
            verdict: .notIOSAppOnMac,
            trackId: nil, purchaseDate: nil, installedDate: nil,
            evidence: evidence,
            note: notes.joined(separator: " · "))
    }

    // MARK: - Wrapper metadata plist (Wrapper/iTunesMetadata.plist)

    private static func parseWrapperMetadata(
        bundlePath: String,
        reader: IOSBundleFileReader,
        into findings: inout MarkerFindings)
    {
        let path = bundlePath + "/" + wrapperMetadataPath
        guard reader.exists(atPath: path) else { return }
        findings.evidence.append("Wrapper/iTunesMetadata.plist present (documented iOS-app-on-Mac "
            + "wrapper marker, UPDATEST-FINDINGS §3.1)")
        let data: Data
        do {
            data = try reader.data(atPath: path)
        } catch {
            findings.unreadable.append("\(wrapperMetadataPath): read failed — \(error)")
            return
        }
        guard
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
            let dict = plist as? [String: Any]
        else {
            findings.unreadable.append("\(wrapperMetadataPath): not a parseable plist")
            return
        }
        // Counted ONLY on a successful parse: an unreadable documented marker
        // cannot prove wrapper membership (honesty discipline — see header).
        findings.parsedMarkerCount += 1
        extractDocumentedFields(from: dict, source: wrapperMetadataPath, into: &findings)
    }

    // MARK: - INSTALL_RECEIPT.json (root and .metadata/ forms)

    private static func parseInstallReceipt(
        relativePath: String,
        bundlePath: String,
        reader: IOSBundleFileReader,
        into findings: inout MarkerFindings)
    {
        let path = bundlePath + "/" + relativePath
        guard reader.exists(atPath: path) else { return }
        findings.evidence.append("\(relativePath) present (documented iOS-app-on-Mac wrapper receipt, "
            + "UPDATEST-FINDINGS §3.1)")
        let data: Data
        do {
            data = try reader.data(atPath: path)
        } catch {
            findings.unreadable.append("\(relativePath): read failed — \(error)")
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data),
            let dict = json as? [String: Any]
        else {
            findings.unreadable.append("\(relativePath): not a parseable JSON object")
            return
        }
        // Counted ONLY on a successful parse: an unreadable documented marker
        // cannot prove wrapper membership (honesty discipline — see header).
        findings.parsedMarkerCount += 1
        extractDocumentedFields(from: dict, source: relativePath, into: &findings)
    }

    // MARK: - Documented field extraction (trackId / purchaseDate / installedDate)

    /// Extracts ONLY the three documented field names. Value formats are NOT
    /// documented in the teardown, so attempts are limited and flagged:
    /// plist-native Date/NSNumber, ISO-8601 strings, numeric epoch. Anything
    /// else stays nil with an explicit note.
    private static func extractDocumentedFields(
        from dict: [String: Any],
        source: String,
        into findings: inout MarkerFindings)
    {
        if findings.trackId == nil, let raw = dict["trackId"] {
            if let value = trackIDValue(raw) {
                findings.trackId = value
                findings.evidence.append(
                    "trackId \(value) extracted from \(source) (documented field)")
            } else {
                findings.evidence.append("trackId present in \(source) but unparseable (value format not "
                    + "documented in teardown) — left unknown")
            }
        }
        if findings.purchaseDate == nil, let raw = dict["purchaseDate"] {
            if let value = documentedDateValue(raw) {
                findings.purchaseDate = value
                findings.evidence.append(
                    "purchaseDate extracted from \(source) (documented field)")
            } else {
                findings.evidence.append("purchaseDate present in \(source) but unparseable (value format "
                    + "not documented in teardown) — left unknown")
            }
        }
        if findings.installedDate == nil, let raw = dict["installedDate"] {
            if let value = documentedDateValue(raw) {
                findings.installedDate = value
                findings.evidence.append(
                    "installedDate extracted from \(source) (documented field)")
            } else {
                findings.evidence.append("installedDate present in \(source) but unparseable (value format "
                    + "not documented in teardown) — left unknown")
            }
        }
    }

    /// NSNumber (plist/JSON numbers) or String → normalized track ID string.
    private static func trackIDValue(_ raw: Any) -> String? {
        if let number = raw as? NSNumber { return number.stringValue }
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// Limited, honest date attempts: plist-native Date, ISO-8601 (with and
    /// without fractional seconds), numeric epoch (seconds). Nil otherwise —
    /// never guessed. Formatters are built per call (non-Sendable class —
    /// no shared static state).
    private static func documentedDateValue(_ raw: Any) -> Date? {
        if let date = raw as? Date { return date }
        if let number = raw as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            let plain = ISO8601DateFormatter()
            if let date = plain.date(from: trimmed) { return date }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions.insert(.withFractionalSeconds)
            if let date = fractional.date(from: trimmed) { return date }
        }
        return nil
    }

    // MARK: - Spotlight kMDItemAppStoreAdamID probe

    /// Spotlight kMDItemAppStoreAdamID probe. `found` = the signal exists
    /// (value folded into `trackId` with flagged mapping); `failed` = the
    /// probe threw (documented signal set incomplete).
    private static func probeAdamID(
        bundlePath: String,
        probes: IOSAppProbes,
        into trackId: inout String?,
        evidence: inout [String],
        notes: inout [String]) async -> (found: Bool, failed: Bool)
    {
        do {
            guard let raw = try await probes.adamID(bundlePath) else { return (false, false) }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return (false, false) }
            if trackId == nil { trackId = trimmed }
            evidence.append("Spotlight \(spotlightAdamIDKey) = \(trimmed) (documented signal; "
                + "surfaced as trackId — mapping flagged as our reading; query mechanism ours: "
                + "/usr/bin/mdls, the teardown documents only the key)")
            return (true, false)
        } catch {
            notes.append("Spotlight \(spotlightAdamIDKey) probe threw: \(error)")
            return (false, true)
        }
    }

    // MARK: - pkgutil probe (documented /usr/sbin/pkgutil shell-out)

    /// pkgutil probe. `found` = a receipt exists for the bundle identifier
    /// (documented MAS-detection shell-out); `failed` = the probe threw.
    private static func probePkgutil(
        bundlePath: String,
        reader: IOSBundleFileReader,
        probes: IOSAppProbes,
        into installedDate: inout Date?,
        evidence: inout [String],
        notes: inout [String]) async -> (found: Bool, failed: Bool)
    {
        let bundleID = readBundleIdentifier(bundlePath: bundlePath, reader: reader,
            evidence: &evidence, notes: &notes)
        guard let bundleID else {
            notes.append("pkgutil probe skipped (documented /usr/sbin/pkgutil shell-out needs a "
                + "bundle identifier; \(infoPlistPath) has none)")
            return (false, false)
        }
        do {
            guard let output = try await probes.pkgutil(bundleID) else {
                notes.append("pkgutil returned nothing for \(bundleID) (probe exit treated as no "
                    + "receipt)")
                return (false, false)
            }
            evidence.append("pkgutil --pkg-info \(bundleID) succeeded (documented shell-out; "
                + "argument form ours)")
            if installedDate == nil, let line = installTimeLine(of: output) {
                installedDate = line.date
                evidence.append("installedDate from pkgutil install-time \(line.rawValue) — mapping "
                    + "FLAGGED as our reading (teardown names the tool and the installedDate "
                    + "field, not the parsed line)")
            } else if installedDate == nil {
                notes.append("pkgutil output carried no install-time line — installedDate left "
                    + "unknown (no undocumented field is parsed)")
            }
            return (true, false)
        } catch {
            notes.append("pkgutil probe threw: \(error)")
            return (false, true)
        }
    }

    /// Reads CFBundleIdentifier from Contents/Info.plist (Updatest §3.1
    /// documents reading "Contents/Info.plist"). Nil + note when unreadable.
    private static func readBundleIdentifier(
        bundlePath: String,
        reader: IOSBundleFileReader,
        evidence: inout [String],
        notes: inout [String]) -> String?
    {
        let path = bundlePath + "/" + infoPlistPath
        guard reader.exists(atPath: path) else { return nil }
        guard
            let data = try? reader.data(atPath: path),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dict = plist as? [String: Any],
            let bundleID = dict["CFBundleIdentifier"] as? String,
            !bundleID.isEmpty
        else {
            notes.append("\(infoPlistPath) present but CFBundleIdentifier unreadable")
            return nil
        }
        evidence.append("bundle identifier \(bundleID) from \(infoPlistPath) (documented read)")
        return bundleID
    }

    /// Parses the `install-time:` epoch line from pkgutil output (the only
    /// date field its standard read-only output carries).
    private static func installTimeLine(of output: String) -> (date: Date, rawValue: String)? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("install-time:") else { continue }
            let value = trimmed.dropFirst("install-time:".count)
                .trimmingCharacters(in: .whitespaces)
            guard let seconds = Double(value), seconds > 0 else { return nil }
            return (Date(timeIntervalSince1970: seconds), value)
        }
        return nil
    }
}
