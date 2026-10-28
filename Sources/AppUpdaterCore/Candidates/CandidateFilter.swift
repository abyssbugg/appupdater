// CandidateFilter.swift — deep candidate filtering (GAP #14).
//
// Contract (docs/reverse/GAP-ANALYSIS.md #14 + MACUPDATER-FINDINGS.md §5 step 8):
//   MacUpdater's candidate selection — after unarchiving the update artifact —
//   recursively finds .app bundles and DROPS, with these documented signals:
//     • wrong-arch Electron payloads: Contents/MacOS/osx_x86_64 and
//       Contents/MacOS/osx_arm64 (its "wrongOCTag" check);
//     • installer-bundle apps, recognized BY NAME: installer.app,
//       installation.app, setup.app, install.app, install, click_to_install,
//       open_to_install, installer, update, updater, *.install — such bundles
//       are vendor installers or OS-installers, NOT app updates;
//     • InstallBuilder-style installers, recognized BY PATH PRESENCE:
//       Contents/MacOS/installbuilder.sh and Contents/Resources/installer.dat.
//   Those exact signals are what this module implements — nothing more, and
//   everything it cannot ground in that documentation becomes an explicit
//   unknown/notApplicable verdict with an honest note instead of a guess.
//
// RELATIONSHIP TO THE SECURITY FLOOR (LOCKED decision 6):
//   This filter NEVER overrides and NEVER replaces the security floor. The
//   floor lives in InstallPlanner/UpdateDownloader/InstallCoordinator and
//   stays in force regardless of any verdict produced here: HTTPS-only
//   download, SHA-256 verification against the source-declared digest,
//   artifact-magic re-verification over the staged bytes. This module is an
//   ADDITIONAL honesty/eligibility layer only — a candidate that passes it is
//   not thereby verified, and a candidate it rejects never reaches the swap
//   stage even if its checksums matched. `accept` here means "no documented
//   disqualifier was found on disk", never "safe".
//
// Honesty discipline (the repo's standing rule — unknown is a verdict, never a
// guess), encoded structurally:
//   • Every detector returns a typed CandidateVerdict carrying its evidence
//     notes. A probe that could not run (unreadable/missing path) is
//     `.unknown` with the verbatim failure in its notes — never a silent
//     omission, never a guessed default.
//   • InstallBuilder: the teardown documents ONLY the two marker paths — no
//     byte/offset/string markers. The detector checks exactly those two paths
//     and nothing else; no content sniffing is invented.
//   • macOS "Install macOS …app" (Apple InstallAssistant) bundles: the
//     teardown documents only that MacUpdater ignores the class ("Apple
//     InstallAssistant", §3.1) — NO plist keys or bundle shapes are
//     documented. No such keys are checked here; the documented name list is
//     the entire implemented installer-bundle signal, and anything beyond it
//     stays an honest gap (see `installAssistantUndocumentedNote`).
//   • Electron wrong-arch for .zip candidates: the documented flow unarchives
//     BEFORE candidate selection (§5 steps 7–8). No documented in-place zip
//     probing exists, so the detector does not open archives. It accepts an
//     explicit `innerBinaryPath` (an already-extracted payload) or reports
//     `.notApplicable` with that explanation.
//
// Pure by construction: read-only, user-space, no processes spawned, no
// network, no writes — the staged artifact is only read (and only its header
// bytes, on demand). Mach-O parsing is plain header arithmetic (thin and fat,
// magic 0xFEEDFACF/0xFEEDFACE/0xCAFEBABE/0xCAFEBABF and their byte-swapped
// variants, cputype classification) mirroring MacUpdater's documented
// BundleArchitectureHelper arch detection (§3.1, [C]).

import Foundation

// MARK: - Verdict types

/// The outcome of one deep-candidate-filter probe. `.unknown` is a
/// first-class result (probe could not decide — read the notes), never
/// collapsed into a boolean.
public enum CandidateFilterOutcome: String, Codable, Hashable, Sendable {
    /// No documented disqualifier found. Means "eligible so far", NOT "verified"
    /// — the security floor (HTTPS + sha256 + magic) is a separate, unchanged gate.
    case accept
    /// A documented disqualifier matched: this artifact is NOT an app update.
    /// `reason` says exactly which signal matched and where.
    case reject
    /// The probe could not decide (unreadable bytes, garbage header, name/arch
    /// conflict). Notes carry the evidence; the caller treats this as unproven.
    case unknown
    /// The documented signal does not apply to this artifact shape (e.g. an
    /// app bundle with no Electron arch payload, or a zip with no inner
    /// binary supplied). Notes say why the probe was not applicable.
    case notApplicable
}

/// One typed verdict from a candidate-filter probe: outcome + evidence.
/// Codable + Hashable so the coordinator's future gate can record receipts
/// verbatim (and tests can compare field-for-field). Sendable value type.
public struct CandidateVerdict: Codable, Hashable, Sendable {
    public let outcome: CandidateFilterOutcome
    /// Non-nil ONLY for `.reject`: the documented disqualifier, self-sufficient
    /// for a receipt (which signal matched, on which artifact).
    public let reason: String?
    /// Evidence trail: which documented marker matched or was absent, doc
    /// citations, and — verbatim — anything that could not be probed.
    public let notes: [String]

    public init(outcome: CandidateFilterOutcome, reason: String?, notes: [String]) {
        self.outcome = outcome
        self.reason = reason
        self.notes = notes
    }

    public static func accept(_ notes: [String]) -> CandidateVerdict {
        CandidateVerdict(outcome: .accept, reason: nil, notes: notes)
    }

    public static func reject(_ reason: String, notes: [String]) -> CandidateVerdict {
        CandidateVerdict(outcome: .reject, reason: reason, notes: notes)
    }

    public static func unknown(_ notes: [String]) -> CandidateVerdict {
        CandidateVerdict(outcome: .unknown, reason: nil, notes: notes)
    }

    public static func notApplicable(_ notes: [String]) -> CandidateVerdict {
        CandidateVerdict(outcome: .notApplicable, reason: nil, notes: notes)
    }

    /// Strict ordering for combining verdicts (reject is the strongest claim):
    /// reject > unknown > accept > notApplicable. An `unknown` never hides a
    /// `reject`. A `notApplicable` never masks a checked `accept`: a
    /// not-applicable probe contributes NO evidence (its documented signal is
    /// simply absent from this artifact shape), while an accept is a real
    /// checked finding ("no documented disqualifier was found on disk") — so
    /// an accept outranks it and the per-detector receipts carry which signal
    /// did not apply.
    var precedence: Int {
        switch outcome {
        case .reject: return 3
        case .unknown: return 2
        case .accept: return 1
        case .notApplicable: return 0
        }
    }
}

// MARK: - Mach-O header parsing (pure)

/// Architectures a Mach-O header declares, reduced to the four cputypes that
/// matter on macOS today. Unknown cputypes are NOT mapped — they are reported
/// raw in `MachOArchReport.unknownCputypes` instead of guessed.
public enum MachOArchKind: String, Codable, Hashable, CaseIterable, Sendable {
    case x86
    // 'x86_64' is the canonical Mach-O architecture spelling (CPU_TYPE_X86_64,
    // mach-o/loader.h); swiftlint's identifier_name default regex rejects the
    // underscore-after-digit form, so the canonical name carries this one-line
    // exemption. The durable fix is `identifier_name.excluded: [x86_64]` in
    // .swiftlint.yml — which is not this lane's file, so the exemption lives
    // at the point of use until then.
    // swiftlint:disable:next identifier_name
    case x86_64
    case arm
    case arm64
}

/// Result of parsing one Mach-O (thin or fat) header. `isComplete == false`
/// means the parser saw a truncation/absurdity and the architecture set may
/// be INCOMPLETE — consumers must treat the report as unproven, never reject
/// on it. Codable + Hashable for verdict receipts.
public struct MachOArchReport: Codable, Hashable, Sendable {
    /// The first four bytes matched a known Mach-O (thin or fat) magic.
    public let isMachO: Bool
    /// True for fat/universal headers (0xCAFEBABE / 0xCAFEBABF family).
    public let isFat: Bool
    /// All slice architectures the header declares (empty when unknown/incomplete).
    public let architectures: Set<MachOArchKind>
    /// Cputype values present in the header that we deliberately do not map
    /// (raw, verbatim — never guessed into a named arch).
    public let unknownCputypes: [UInt32]
    /// False when the header was truncated, absurd, or otherwise partially
    /// read; the architecture set may be missing slices.
    public let isComplete: Bool
    /// Honest notes about anything unusual seen while parsing.
    public let notes: [String]

    init(isMachO: Bool, isFat: Bool, architectures: Set<MachOArchKind>,
         unknownCputypes: [UInt32], isComplete: Bool, notes: [String]) {
        self.isMachO = isMachO
        self.isFat = isFat
        self.architectures = architectures
        self.unknownCputypes = unknownCputypes
        self.isComplete = isComplete
        self.notes = notes
    }

    /// Not-a-Mach-O verdict for a byte sequence that matched no known magic.
    static func notMachO(_ notes: [String]) -> MachOArchReport {
        MachOArchReport(isMachO: false, isFat: false, architectures: [],
                        unknownCputypes: [], isComplete: true, notes: notes)
    }
}

/// Pure Mach-O header arithmetic: thin (32/64-bit) and fat (universal)
/// magics, both endiannesses, cputype classification. No file I/O here —
/// `archReport(binaryAt:)` is the bytes-on-demand disk front end.
public enum MachOArchParser {

    /// Mach-O thin magics as READ little-endian from the first four bytes.
    /// MH_MAGIC_64 (0xFEEDFACF) and MH_MAGIC (0xFEEDFACE) mean the header's
    /// fields are little-endian; their byteswaps (0xCFFAEDFE / 0xCEFAEDFE,
    /// the MH_CIGAM family) mean the file stores fields big-endian.
    static let thinMagics: [UInt32: (is64: Bool, bigEndianFields: Bool)] = [
        0xFEED_FACF: (true, false),
        0xCFFA_EDFE: (true, true),
        0xFEED_FACE: (false, false),
        0xCEFA_EDFE: (false, true),
    ]

    /// Fat (universal) magics as READ little-endian. Apple tools write fat
    /// headers BIG-endian (file bytes CA FE BA BE / CA FE BA BF, read LE as
    /// 0xBEBAFECA / 0xBFBAFECA, the FAT_CIGAM family); the byte-swapped
    /// spellings (read LE as 0xCAFEBABE / 0xCAFEBABF) mean fields are
    /// little-endian in the file.
    static let fatMagics: [UInt32: (is64: Bool, bigEndianFields: Bool)] = [
        0xBEBA_FECA: (false, true),
        0xCAFE_BABE: (false, false),
        0xBFBA_FECA: (true, true),
        0xCAFE_BABF: (true, false),
    ]

    /// Guard against absurd nfat_arch counts (malformed headers); beyond this
    /// the report stays incomplete with a note. A real universal binary has ≤ 4 slices.
    static let maxFatArchs = 128

    /// cputype → named architecture. Only these four are mapped; everything
    /// else lands in `unknownCputypes` verbatim.
    static func classify(_ cputype: UInt32) -> MachOArchKind? {
        switch cputype {
        case 7: return .x86
        case 0x0100_0007: return .x86_64
        case 12: return .arm
        case 0x0100_000C: return .arm64
        default: return nil
        }
    }

    /// Parse architectures from raw header bytes (the first bytes of a Mach-O
    /// file). Bounds-guarded throughout: short/garbage input produces honest
    /// notes, never a crash and never a guessed architecture.
    public static func parse(_ bytes: [UInt8]) -> MachOArchReport {
        guard bytes.count >= 4 else {
            return .notMachO(["header shorter than 4 bytes (\(bytes.count) read) — no magic to check"])
        }
        let magic = u32(bytes, 0, bigEndian: false) ?? 0
        if let thin = thinMagics[magic] {
            return parseThin(bytes, is64: thin.is64, bigEndianFields: thin.bigEndianFields)
        }
        if let fat = fatMagics[magic] {
            return parseFat(bytes, is64: fat.is64, bigEndianFields: fat.bigEndianFields)
        }
        return .notMachO(["magic \(hex(magic)) is not a known Mach-O thin/fat magic — not parseable as Mach-O"])
    }

    /// Bytes-on-demand disk front end: reads only the header bytes needed
    /// (8 for thin; 8 + nfat×stride for fat), never the whole binary.
    /// Never throws — an unreadable/missing/directory path becomes a
    /// `.notMachO`-shaped report whose notes carry the verbatim failure.
    public static func archReport(binaryAt url: URL) -> MachOArchReport {
        var headBytes: [UInt8]
        // Pre-classify the path BEFORE opening: directories are never Mach-O,
        // and reading them is left to this honest note instead of an I/O call
        // with platform-dependent behavior.
        var isDirectory: ObjCBool = false
        let pathExists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if !pathExists || isDirectory.boolValue {
            return .notMachO(["'\(url.path)' is not a readable regular file (exists: \(pathExists), directory: \(isDirectory.boolValue)) — header unreadable, unproven"])
        }
        do {
            headBytes = try Array(readPrefix(url, count: 8))
        } catch {
            return .notMachO(["could not read header bytes of '\(url.path)': \(error)"])
        }
        if headBytes.count >= 8 {
            let magic = u32(headBytes, 0, bigEndian: false) ?? 0
            if let fat = fatMagics[magic] {
                // Fat: need 8 + nfat×stride bytes — compute from the declared
                // count, re-read, and let the parser note truncation honestly.
                let stride = fat.is64 ? 32 : 20
                let nfat = Int(u32(headBytes, 4, bigEndian: fat.bigEndianFields) ?? 0)
                let wanted = min(nfat, maxFatArchs) * stride + 8
                if wanted > headBytes.count {
                    headBytes = (try? Array(readPrefix(url, count: wanted))) ?? headBytes
                }
            }
        }
        return parse(headBytes)
    }

    // MARK: - Thin parsing

    private static func parseThin(_ bytes: [UInt8], is64: Bool, bigEndianFields: Bool) -> MachOArchReport {
        var notes = ["thin Mach-O (64-bit: \(is64), \(bigEndianFields ? "big" : "little")-endian fields)"]
        guard let cputype = u32(bytes, 4, bigEndian: bigEndianFields) else {
            notes.append("header too short for cputype (only \(bytes.count) bytes readable) — architecture unknown")
            return MachOArchReport(isMachO: true, isFat: false, architectures: [],
                                   unknownCputypes: [], isComplete: false, notes: notes)
        }
        if let arch = classify(cputype) {
            notes.append("cputype \(hex(cputype)) → \(arch.rawValue)")
            return MachOArchReport(isMachO: true, isFat: false, architectures: [arch],
                                   unknownCputypes: [], isComplete: true, notes: notes)
        }
        notes.append("cputype \(hex(cputype)) is not a mapped macOS architecture — recorded raw, not guessed")
        return MachOArchReport(isMachO: true, isFat: false, architectures: [],
                               unknownCputypes: [cputype], isComplete: true, notes: notes)
    }

    // MARK: - Fat parsing

    private static func parseFat(_ bytes: [UInt8], is64: Bool, bigEndianFields: Bool) -> MachOArchReport {
        var notes = ["fat Mach-O (64-bit header: \(is64), \(bigEndianFields ? "big" : "little")-endian fields)"]
        guard let nfatRaw = u32(bytes, 4, bigEndian: bigEndianFields) else {
            notes.append("fat header too short for nfat_arch — architecture set unknown")
            return MachOArchReport(isMachO: true, isFat: true, architectures: [],
                                   unknownCputypes: [], isComplete: false, notes: notes)
        }
        var nfat = Int(nfatRaw)
        var complete = true
        if nfat > maxFatArchs {
            notes.append("nfat_arch \(nfatRaw) exceeds the sane cap \(maxFatArchs) — parsing the first \(maxFatArchs), report incomplete")
            nfat = maxFatArchs
            complete = false
        }
        if nfat == 0 {
            notes.append("fat header declares ZERO architectures — nothing runnable is documented by this header")
            return MachOArchReport(isMachO: true, isFat: true, architectures: [],
                                   unknownCputypes: [], isComplete: complete, notes: notes)
        }
        let stride = is64 ? 32 : 20
        var archs = Set<MachOArchKind>()
        var unknowns: [UInt32] = []
        for entry in 0..<nfat {
            let offset = 8 + entry * stride
            guard let cputype = u32(bytes, offset, bigEndian: bigEndianFields) else {
                notes.append("fat entry table truncated (declared \(nfatRaw) arch entries, \(entry) fully readable) — set may be incomplete")
                complete = false
                break
            }
            if let arch = classify(cputype) {
                archs.insert(arch)
            } else {
                unknowns.append(cputype)
            }
        }
        var archNotes = archs.sorted { $0.rawValue < $1.rawValue }.map { $0.rawValue }
        if !unknowns.isEmpty {
            archNotes.append("unmapped cputypes: " + unknowns.map { hex($0) }.joined(separator: ", "))
        }
        notes.append("fat slices: " + (archNotes.isEmpty ? "(none readable)" : archNotes.joined(separator: ", ")))
        return MachOArchReport(isMachO: true, isFat: true, architectures: archs,
                               unknownCputypes: unknowns, isComplete: complete, notes: notes)
    }

    // MARK: - Byte helpers (bounds-guarded, no force indexing)

    private static func u32(_ bytes: [UInt8], _ offset: Int, bigEndian: Bool) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        let raw = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        return bigEndian ? raw.byteSwapped : raw
    }

    private static func hex(_ value: UInt32) -> String {
        "0x" + String(value, radix: 16).uppercased()
    }

    private static func readPrefix(_ url: URL, count: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // ofLength reads AT MOST count bytes (fewer at EOF) — exactly the
        // bytes-on-demand contract for header reads. This SDK exposes the
        // legacy non-throwing signature; the open() above is where errors
        // surface (and callers note them verbatim).
        return handle.readData(ofLength: count)
    }
}

// MARK: - Candidate filter (the documented detectors)

/// One deep-filter run over a staged candidate: per-detector verdicts plus the
/// combined overall verdict. Codable + Hashable for gate receipts.
public struct CandidateFilterReport: Codable, Hashable, Sendable {
    /// The candidate path as inspected (verbatim from the caller).
    public let candidatePath: String
    /// Worst verdict across the detectors (reject > unknown > accept >
    /// notApplicable); `reason` carries the strongest rejection when there is
    /// one. A not-applicable detector contributes no evidence — WHICH signal
    /// did not apply stays visible in that detector's own receipt below.
    public let overall: CandidateVerdict
    /// Documented installer-bundle NAME check.
    public let installerBundle: CandidateVerdict
    /// Documented InstallBuilder marker-path check.
    public let installBuilder: CandidateVerdict
    /// Documented Electron wrong-arch (wrongOCTag) check.
    public let electronWrongArch: CandidateVerdict
}

public enum CandidateFilter {

    /// Where every implemented signal is documented (verbatim teardown line,
    /// confirmed evidence).
    public static let documentedSource = "docs/reverse/MACUPDATER-FINDINGS.md §5 step 8 (candidate selection)"

    /// The documented installer-bundle app names — installed verbatim from the
    /// teardown. Bundles matching these are vendor installers or OS installers,
    /// NOT app updates.
    public static let installerBundleNames: [String] = [
        "installer.app", "installation.app", "setup.app", "install.app", "install",
        "click_to_install", "open_to_install", "installer", "update", "updater",
    ]

    /// The documented `*.install` glob (the one wildcard in the list).
    public static let installerBundleGlobSuffix = ".install"

    /// Documented InstallBuilder markers — the ONLY documented signals (no
    /// byte/offset/string markers exist in the teardown; none are invented here).
    public static let installBuilderMarkerRelativePaths: [String] = [
        "Contents/MacOS/installbuilder.sh",
        "Contents/Resources/installer.dat",
    ]

    /// Documented Electron arch-payload shapes (the "wrongOCTag" check).
    public static let electronPayloadRelativePaths: [(path: String, arch: MachOArchKind)] = [
        ("Contents/MacOS/osx_x86_64", .x86_64),
        ("Contents/MacOS/osx_arm64", .arm64),
    ]

    /// Honest gap, kept public so reports/tests can cite it: the teardown
    /// documents NO plist keys or bundle shapes for Apple InstallAssistant
    /// ("Install macOS …app") bundles — only that MacUpdater ignores the class
    /// (§3.1). We deliberately do not invent keys or shapes to check.
    public static let installAssistantUndocumentedNote =
        "InstallAssistant-style detection beyond the documented name list is NOT implemented: "
            + "no plist keys or bundle shapes for 'Install macOS …app' bundles are documented in the teardown — "
            + "inventing them would be a guess, and unknown beats a guess"

    /// The architecture of the RUNNING AppUpdater slice, as a compiled
    /// constant (no ProcessInfo, no environment reads). This is the runnable-
    /// arch proxy: what a payload must contain to execute on this machine.
    /// Under Rosetta an x86_64 build compares as x86_64, correctly accepting an
    /// x86_64 payload it can translate; the teardown documents native-arch
    /// detection only (BundleArchitectureHelper, hasIntel/hasARM), so this
    /// refinement is ours and is noted in verdicts.
    public static var runningMachineArch: MachOArchKind? {
        #if arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        return .x86_64
        #else
        return nil
        #endif
    }

    /// Detector 1 — documented installer-bundle NAME check (§5 step 8).
    /// Matches the candidate's last path component, case-insensitively, against
    /// the documented name list and the `*.install` glob; a trailing ".app" is
    /// also stripped before the bare-name pass so e.g. "click_to_install.app"
    /// hits the documented bare name "click_to_install". Case-insensitive
    /// matching is a deliberate conservative superset of the (lowercase)
    /// documented list: for an eligibility gate, missing an installer is the
    /// worse error, and this direction is recorded in the notes.
    public static func installerBundleVerdict(at candidateURL: URL) -> CandidateVerdict {
        let name = candidateURL.lastPathComponent.lowercased()
        var citations = ["documented installer-bundle name check — " + documentedSource]
        let nameFinding = Self.installerBundleNameFinding(for: name)
        let nameNote = String(describing: nameFinding)
        guard candidateExists(candidateURL) else {
            return .unknown(["candidate path not found/unreadable: '\(candidateURL.path)' — nothing verifiable on disk"]
                + [nameNote] + citations)
        }
        if let matched = nameFinding.matched {
            return .reject(
                "documented installer-bundle name '\(matched)' matched candidate '\(candidateURL.lastPathComponent)' "
                    + "(\(nameFinding.glob ? "*.install glob" : "exact") match) — such artifacts are NOT app updates",
                notes: [nameNote] + citations)
        }
        citations.append("last path component '\(candidateURL.lastPathComponent)' matches none of "
            + installerBundleNames.map { "'\($0)'" }.joined(separator: ", ")
            + " nor '\(installerBundleGlobSuffix)' suffix — negative finding")
        return .accept(citations)
    }

    /// Detector 2 — documented InstallBuilder marker check (§5 step 8).
    /// Path presence of the two documented markers, exactly as documented; the
    /// teardown gives no byte/offset/string markers, so no content is sniffed
    /// and none is invented. Absent markers = negative finding (documented
    /// scope), recorded as accept-with-note, never as proof of anything more.
    public static func installBuilderVerdict(at candidateURL: URL) -> CandidateVerdict {
        var notes = ["documented InstallBuilder marker check (path presence only; the teardown documents no byte/offset/string markers) — " + documentedSource]
        guard candidateExists(candidateURL) else {
            return .unknown(["candidate path not found/unreadable: '\(candidateURL.path)' — markers unverifiable"] + notes)
        }
        for relativePath in installBuilderMarkerRelativePaths {
            let markerURL = candidateURL.appendingPathComponent(relativePath)
            if markerURL.exists {
                notes.append("marker present: '\(relativePath)'")
                return .reject(
                    "documented InstallBuilder marker found at '\(relativePath)' in candidate "
                        + "'\(candidateURL.lastPathComponent)' — InstallBuilder-style installer, not an app update",
                    notes: notes)
            }
            notes.append("marker absent: '\(relativePath)'")
        }
        return .accept(notes)
    }

    /// Detector 3 — documented Electron wrong-arch check (§5 step 8, the
    /// "wrongOCTag" drop). Two shapes are understood:
    ///
    ///  • an extracted bundle directory containing Contents/MacOS/osx_x86_64
    ///    and/or Contents/MacOS/osx_arm64 — each payload's Mach-O header is
    ///    parsed and compared against `runningMachineArch`. If ANY payload
    ///    definitively parses to a runnable architecture, the candidate is
    ///    accepted (a sibling payload that will not parse is carried as a
    ///    warning note, never silently dropped). Otherwise, if a definitive
    ///    payload exists but none is runnable, the verdict is reject with the
    ///    documented wrongOCTag reason. A payload whose header will not
    ///    parse, or whose parsed architecture contradicts its documented
    ///    name, is honest unknown — it can never turn into a guess.
    ///  • a non-extracted artifact (e.g. a staged .zip): NO documented
    ///    in-place probing exists — the documented flow unarchives first (§5
    ///    steps 7–8). Supply an already-extracted payload via
    ///    `innerBinaryPath` for a real verdict, or receive `.notApplicable`
    ///    with that explanation. No deep zip guessing is performed.
    public static func electronWrongArchVerdict(
        at candidateURL: URL,
        innerBinaryPath: URL? = nil
    ) -> CandidateVerdict {
        var notes = ["documented Electron wrong-arch check (Contents/MacOS/osx_x86_64 / osx_arm64, 'wrongOCTag') — " + documentedSource]
        guard let machineArch = runningMachineArch else {
            notes.append("running-machine architecture unknown for this build (no arm64/x86_64 compile-time arch) — cannot compare")
            return .unknown(notes)
        }
        notes.append("running machine arch: \(machineArch.rawValue)")

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: candidateURL.path, isDirectory: &isDirectory)
        guard exists else {
            return .unknown(["candidate path not found/unreadable: '\(candidateURL.path)' — payloads unverifiable"] + notes)
        }
        if !isDirectory.boolValue {
            return innerBinaryVerdict(innerBinaryPath, machineArch: machineArch, baseNotes: notes, candidateName: candidateURL.lastPathComponent)
        }
        if let inner = innerBinaryPath {
            notes.append("explicit innerBinaryPath '\(inner.path)' supplied for a bundle directory; the documented in-bundle payload shapes take precedence and this path is noted but not used")
        }

        // In-bundle payloads, exactly at the documented shapes.
        let payloadReports: [(payload: String, expected: MachOArchKind?, verdict: CandidateVerdict)] =
            electronPayloadRelativePaths.compactMap { shape in
                let payloadURL = candidateURL.appendingPathComponent(shape.path)
                guard payloadURL.exists else { return nil }
                return (shape.path, shape.arch, payloadVerdict(payloadURL, nameContract: shape.arch, machineArch: machineArch))
            }
        if payloadReports.isEmpty {
            notes.append("no Electron arch payload at \(electronPayloadRelativePaths.map { "'\($0.path)'" }.joined(separator: " or ")) "
                + "— the documented wrongOCTag shapes are absent; nothing to judge here")
            return .notApplicable(notes)
        }
        let allNotes = payloadReports.flatMap { $0.verdict.notes } + notes
        let definitive = payloadReports.filter { $0.verdict.outcome == .accept || $0.verdict.outcome == .reject }
        let runnable = definitive.filter { $0.verdict.outcome == .accept }
        if let runnablePayload = runnable.first {
            let acceptNotes = ["runnable payload documented and present: '\(runnablePayload.payload)'"]
                + payloadReports.filter { $0.verdict.outcome != .accept }.flatMap { $0.verdict.notes }
                + notes
            return .accept(acceptNotes)
        }
        if !definitive.isEmpty {
            let reasons = definitive.map { "'\($0.payload)': \($0.verdict.reason ?? "")" }.joined(separator: "; ")
            return .reject(
                "Electron wrong-arch payload (documented 'wrongOCTag'): \(candidateURL.lastPathComponent) carries "
                    + "arch payloads none of which run on this \(machineArch.rawValue) machine — \(reasons)",
                notes: allNotes)
        }
        return .unknown(["no payload could be definitively judged (unparseable/conflicting headers) — honest unknown"] + allNotes)
    }

    /// The combined gate the coordinator's future eligibility check calls:
    /// all three documented detectors over one candidate, with the overall
    /// verdict = strongest per-detector outcome (reject > unknown > accept >
    /// notApplicable — a not-applicable probe contributes no evidence, so a
    /// checked accept outranks it). Read-only end to end.
    public static func filter(
        candidateURL: URL,
        innerBinaryPath: URL? = nil
    ) -> CandidateFilterReport {
        let installer = installerBundleVerdict(at: candidateURL)
        let builder = installBuilderVerdict(at: candidateURL)
        let electron = electronWrongArchVerdict(at: candidateURL, innerBinaryPath: innerBinaryPath)
        let perDetector: [(String, CandidateVerdict)] = [
            ("installerBundle", installer), ("installBuilder", builder), ("electronWrongArch", electron),
        ]
        let strongest = perDetector.map { $0.1 }.max { $0.precedence < $1.precedence } ?? .unknown(["no detectors ran"])
        let overallReason = perDetector
            .filter { $0.1.outcome == .reject }
            .map { $0.1.reason ?? "" }
            .first
        var combinedNotes = perDetector.flatMap { $0.1.notes }
        combinedNotes.insert("overall = strongest per-detector verdict (reject > unknown > accept > notApplicable; "
            + "a not-applicable probe contributes no evidence and its receipt below says which signal did not apply); "
            + "the security floor (HTTPS + sha256 + artifact magic) is a separate, unchanged gate — this filter never overrides it", at: 0)
        let overall = CandidateVerdict(
            outcome: strongest.outcome,
            reason: overallReason,
            notes: combinedNotes)
        return CandidateFilterReport(
            candidatePath: candidateURL.path,
            overall: overall,
            installerBundle: installer,
            installBuilder: builder,
            electronWrongArch: electron)
    }

    // MARK: - Internals (shared by the detectors)

    /// One Electron payload file's verdict: Mach-O parse + optional name
    /// contract + runnability, all as explicit notes. `.accept` = parses
    /// cleanly AND is runnable on this machine — and, when a documented name
    /// contract applies, the header honors it. `nameContract == nil` (explicit
    /// inner binaries: no documented name exists for an arbitrary extracted
    /// payload) skips the name check entirely — content-vs-machine is the only
    /// judge, so a wrong-arch inner binary reaches the honest reject instead
    /// of being swallowed by a name/content conflict it never agreed to.
    private static func payloadVerdict(
        _ payloadURL: URL,
        nameContract: MachOArchKind?,
        machineArch: MachOArchKind
    ) -> CandidateVerdict {
        let report = MachOArchParser.archReport(binaryAt: payloadURL)
        let label = nameContract?.rawValue ?? payloadURL.lastPathComponent
        var notes = ["payload '\(label)' at '\(payloadURL.path)': " + report.notes.joined(separator: "; ")]
        guard report.isMachO else {
            notes.append("does not parse as Mach-O — honest unknown, no guess")
            return .unknown(notes)
        }
        guard report.isComplete else {
            notes.append("header incomplete/truncated — architecture set may be missing slices; unproven")
            return .unknown(notes)
        }
        guard !report.architectures.isEmpty, report.unknownCputypes.isEmpty else {
            notes.append(report.unknownCputypes.isEmpty
                ? "no mapped architecture in header — unproven"
                : "unmapped cputype(s) present — unproven")
            return .unknown(notes)
        }
        if let contract = nameContract, !report.architectures.contains(contract) {
            notes.append("NAME/CONTENT CONFLICT: documented name says \(contract.rawValue) but the header declares "
                + report.architectures.map { $0.rawValue }.sorted().joined(separator: "+")
                + " — the payload does not honor its documented shape; unproven")
            return .unknown(notes)
        }
        if report.architectures.contains(machineArch) {
            notes.append("contains a \(machineArch.rawValue) slice — runnable on this machine")
            return .accept(notes)
        }
        notes.append("declares " + report.architectures.map { $0.rawValue }.sorted().joined(separator: "+")
            + " — no \(machineArch.rawValue) slice: not runnable on this machine")
        return .reject(
            "payload '\(label)' at '\(payloadURL.path)' declares no \(machineArch.rawValue) slice "
                + "(declares: " + report.architectures.map { $0.rawValue }.sorted().joined(separator: "+") + ")",
            notes: notes)
    }

    /// The explicit inner-binary branch (zip candidates, etc.): judge the
    /// caller-extracted payload, or report the honest notApplicable.
    private static func innerBinaryVerdict(
        _ innerBinaryPath: URL?,
        machineArch: MachOArchKind,
        baseNotes: [String],
        candidateName: String
    ) -> CandidateVerdict {
        var notes = baseNotes
        guard let inner = innerBinaryPath else {
            notes.append("staged artifact '\(candidateName)' is not an extracted bundle; the documented flow unarchives BEFORE "
                + "candidate selection (MACUPDATER-FINDINGS.md §5 steps 7–8) and no in-place archive probing is documented")
            notes.append("no innerBinaryPath supplied — no deep zip guessing performed; supply an already-extracted payload path for a real verdict")
            return .notApplicable(notes)
        }
        notes.append("judging explicitly supplied inner binary '\(inner.path)'")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inner.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            notes.append("inner binary not found / not a regular file at '\(inner.path)' — unproven")
            return .unknown(notes)
        }
        // No documented name contract exists for an arbitrary inner binary,
        // so none is enforced (nameContract: nil): content-vs-machine is the
        // only judge, and a rejection is re-framed cleanly for the receipt.
        let verdict = payloadVerdict(inner, nameContract: nil, machineArch: machineArch)
        if verdict.outcome == .reject, let reason = verdict.reason, reason.contains("declares no") {
            return .reject(
                "explicit inner binary '\(inner.path)' declares no \(machineArch.rawValue) slice — wrong-arch for this machine",
                notes: verdict.notes + notes)
        }
        return CandidateVerdict(outcome: verdict.outcome, reason: verdict.reason, notes: verdict.notes + notes)
    }

    /// Name-vs-list finding for the installer-bundle detector, kept as a
    /// structured intermediate so missing-path and matched paths share it.
    struct InstallerNameFinding: CustomStringConvertible {
        let glob: Bool
        let matched: String?

        var description: String {
            matched.map { "last path component matches documented installer-bundle name '\($0)' (\(glob ? "*.install glob" : "exact"))" }
                ?? "last path component matches no documented installer-bundle name"
        }
    }

    static func installerBundleNameFinding(for name: String) -> InstallerNameFinding {
        // Names to test: the raw component, plus its ".app"-stripped form so a
        // bundle named e.g. "click_to_install.app" also hits the documented
        // bare name. Both passes are case-insensitive (see method docs).
        var names = [name]
        if name.hasSuffix(".app"), name.count > 4 {
            names.append(String(name.dropLast(4)))
        }
        for candidate in names {
            for documented in installerBundleNames where candidate == documented {
                return InstallerNameFinding(glob: false, matched: documented)
            }
            if candidate.hasSuffix(installerBundleGlobSuffix) {
                return InstallerNameFinding(glob: true, matched: "*\(installerBundleGlobSuffix)")
            }
        }
        return InstallerNameFinding(glob: false, matched: nil)
    }

    /// Read-only existence probe; existence is all the detectors need (they
    /// never read directory contents beyond named paths).
    static func candidateExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

extension URL {
    /// Read-only existence check local to this module (avoids repeating
    /// FileManager noise in three detectors).
    fileprivate var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
