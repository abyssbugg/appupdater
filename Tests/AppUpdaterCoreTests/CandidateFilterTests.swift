// CandidateFilterTests.swift — hermetic tests for the deep candidate filter
// (Sources/AppUpdaterCore/Candidates/CandidateFilter.swift, GAP #14).
//
// Swift Testing ONLY — XCTest discovery is broken on this toolchain (AGENTS.md
// gotcha ledger). Swift Testing does not re-export Foundation, so
// `import Foundation` is required here.
//
// Hermeticity: every test builds its fixtures in a fresh UUID temp root; the
// detectors are pure file readers, so nothing else is touched. Mach-O fixtures
// are constructed BYTE-BY-BYTE (no compiler, no lipo, no subprocesses):
// thin 32/64-bit headers in both endiannesses, fat32/fat64 universal headers
// with both cputypes, truncated/absurd/zero-entry fat tables, and garbage —
// the parser must classify each and stay honest on the rest.
//
// Arch-dependent expectations (Electron wrong-arch verdicts flip with the
// host's compiled arch) are computed from CandidateFilter.runningMachineArch —
// the exact constant the detector compares against — so the suite is green on
// either arm64 or x86_64 test hosts by construction. No force unwraps
// anywhere (the lint gate treats force_unwrapping as an error, tests included).

import Foundation
import Testing
@testable import AppUpdaterCore

@Suite
struct CandidateFilterTests {

    // MARK: - Fixture helpers

    private let fm = FileManager.default

    private func newRoot() throws -> URL {
        let url = fm.temporaryDirectory
            .appendingPathComponent("candfilter-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeDir(_ name: String, in root: URL, intermediate: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: intermediate)
        return url
    }

    private func makeFile(_ name: String, bytes: [UInt8], in root: URL, intermediate: Bool = false) throws -> URL {
        if intermediate {
            let dir = root.appendingPathComponent((name as NSString).deletingLastPathComponent, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let url = root.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: Mach-O byte construction (explicit, endian-independent)

    /// One UInt32 as 4 bytes, in the given file endianness (explicit shifts —
    /// no host-endian assumptions, no unsafe buffers).
    private func bytes32(_ value: UInt32, bigEndian: Bool) -> [UInt8] {
        let v = bigEndian ? value.bigEndian : value
        return [
            UInt8(truncatingIfNeeded: v),
            UInt8(truncatingIfNeeded: v >> 8),
            UInt8(truncatingIfNeeded: v >> 16),
            UInt8(truncatingIfNeeded: v >> 24),
        ]
    }

    private func bytes64(_ value: UInt64, bigEndian: Bool) -> [UInt8] {
        let v = bigEndian ? value.bigEndian : value
        return (0..<8).map { UInt8(truncatingIfNeeded: v >> UInt64($0 * 8)) }
    }

    /// Minimal thin Mach-O header (32 B for 64-bit, 28 B for 32-bit): magic,
    /// cputype, cpusubtype, filetype=MH_EXECUTE, zeroed tail. `bigEndianFields`
    /// selects the MH_CIGAM (byte-swapped) spelling.
    private func thinHeader(is64: Bool, cputype: UInt32, bigEndianFields: Bool) -> [UInt8] {
        let magic: UInt32 = is64 ? 0xFEED_FACF : 0xFEED_FACE
        var bytes = bytes32(magic, bigEndian: bigEndianFields)
        bytes += bytes32(cputype, bigEndian: bigEndianFields)
        bytes += bytes32(3, bigEndian: bigEndianFields) // cpusubtype (unused by the parser)
        bytes += bytes32(2, bigEndian: bigEndianFields) // filetype MH_EXECUTE
        bytes += bytes32(0, bigEndian: bigEndianFields) // ncmds
        bytes += bytes32(0, bigEndian: bigEndianFields) // sizeofcmds
        bytes += bytes32(0, bigEndian: bigEndianFields) // flags
        if is64 {
            bytes += bytes32(0, bigEndian: bigEndianFields) // reserved
        }
        return bytes
    }

    /// Minimal fat header. `slices` = the cputypes actually present; pass more
    /// cputypes per slice to exercise each entry. `declaredCount` overrides
    /// nfat_arch (for truncated/absurd fixtures). A fat_arch entry is 20 bytes
    /// and a fat_arch_64 entry is 32 bytes (its trailing `reserved` field is
    /// part of the real struct — omitting it shifts every later entry out of
    /// the parser's stride, which is exactly the fixture bug this field fixes).
    private func fatHeader(
        is64: Bool,
        bigEndianFields: Bool,
        slices: [UInt32],
        declaredCount: UInt32? = nil,
        cputypeOverrides: [UInt32]? = nil
    ) -> [UInt8] {
        let magic: UInt32 = is64 ? 0xCAFE_BABF : 0xCAFE_BABE
        var bytes = bytes32(magic, bigEndian: bigEndianFields)
        bytes += bytes32(declaredCount ?? UInt32(slices.count), bigEndian: bigEndianFields)
        for (index, cputype) in (cputypeOverrides ?? slices).enumerated() {
            bytes += bytes32(cputype, bigEndian: bigEndianFields) // cputype
            bytes += bytes32(3, bigEndian: bigEndianFields) // cpusubtype
            if is64 {
                bytes += bytes64(UInt64(index * 0x1000), bigEndian: bigEndianFields) // offset
                bytes += bytes64(0x1000, bigEndian: bigEndianFields) // size
                bytes += bytes32(12, bigEndian: bigEndianFields) // align
                bytes += bytes32(0, bigEndian: bigEndianFields) // reserved (fat_arch_64 stride = 32)
            } else {
                bytes += bytes32(UInt32(index * 0x1000), bigEndian: bigEndianFields) // offset
                bytes += bytes32(0x1000, bigEndian: bigEndianFields) // size
                bytes += bytes32(12, bigEndian: bigEndianFields) // align
            }
        }
        return bytes
    }

    private let arm64Cputype: UInt32 = 0x0100_000C
    private let x8664Cputype: UInt32 = 0x0100_0007

    /// Host-dependent expectation for a single-arch Electron payload.
    private func payloadOutcome(payloadArch: MachOArchKind) -> CandidateFilterOutcome {
        guard let host = CandidateFilter.runningMachineArch else { return .unknown }
        return payloadArch == host ? .accept : .reject
    }

    // MARK: - Installer-bundle name detector (documented name list)

    @Test func documentedExactNamesAreRejected() throws {
        let root = try newRoot()
        for name in CandidateFilter.installerBundleNames {
            let candidate = name.hasSuffix(".app")
                ? try makeDir(name, in: root, intermediate: true)
                : try makeDir(name, in: root)
            let verdict = CandidateFilter.installerBundleVerdict(at: candidate)
            #expect(verdict.outcome == .reject, "expected reject for documented name '\(name)'")
            let reason = try #require(verdict.reason)
            #expect(reason.contains("'\(name)'"), "reason must cite the matched documented name")
            #expect(!verdict.notes.isEmpty)
        }
    }

    @Test func installGlobSuffixIsRejected() throws {
        let root = try newRoot()
        let dir = try makeDir("Foo.install", in: root)
        let file = try makeFile("bar.install", bytes: [0x00], in: root)
        for candidate in [dir, file] {
            let verdict = CandidateFilter.installerBundleVerdict(at: candidate)
            #expect(verdict.outcome == .reject)
            let reason = try #require(verdict.reason)
            #expect(reason.contains("glob"), "glob matches must be labeled as glob in the reason")
            #expect(reason.contains(CandidateFilter.installerBundleGlobSuffix))
        }
    }

    @Test func caseInsensitivityAndAppStrippedBareNamesAreRejected() throws {
        let root = try newRoot()
        // The documented list is lowercase; our gate matches case-insensitively
        // (conservative superset, noted in the verdict) and also tries the
        // ".app"-stripped form so documented BARE names match bundles.
        for name in ["Install.app", "SETUP.app", "updater.app", "click_to_install.app", "Open_To_Install.APP"] {
            let candidate = try makeDir(name, in: root, intermediate: true)
            let verdict = CandidateFilter.installerBundleVerdict(at: candidate)
            #expect(verdict.outcome == .reject, "expected reject for '\(name)'")
        }
    }

    @Test func nonInstallerNamesAcceptWithNegativeFinding() throws {
        let root = try newRoot()
        for name in ["TextEdit.app", "InstallS.app", "myUpdaterPro.app", "installerpro"] {
            let candidate = try makeDir(name, in: root, intermediate: true)
            let verdict = CandidateFilter.installerBundleVerdict(at: candidate)
            #expect(verdict.outcome == .accept, "='\(name)' is not in the documented list — must not reject")
            #expect(verdict.notes.contains { $0.contains("negative finding") })
        }
    }

    @Test func missingCandidateRootIsUnknown() throws {
        let root = try newRoot()
        let ghost = root.appendingPathComponent("Ghost.app", isDirectory: true)
        let verdict = CandidateFilter.installerBundleVerdict(at: ghost)
        #expect(verdict.outcome == .unknown)
        #expect(verdict.notes.contains { $0.contains("not found/unreadable") })
    }

    @Test func installerBundleVerdictCitesDocumentation() throws {
        let root = try newRoot()
        let reject = CandidateFilter.installerBundleVerdict(at: try makeDir("setup.app", in: root, intermediate: true))
        let plain = CandidateFilter.installerBundleVerdict(at: try makeDir("TextEdit.app", in: root, intermediate: true))
        let unknown = CandidateFilter.installerBundleVerdict(at: root.appendingPathComponent("gone.app"))
        for verdict in [reject, plain, unknown] {
            #expect(verdict.notes.contains { $0.contains("MACUPDATER-FINDINGS.md") })
        }
    }

    // MARK: - InstallBuilder marker detector (documented paths only)

    @Test func installBuilderScriptMarkerRejects() throws {
        let root = try newRoot()
        let bundle = try makeDir("Tool.app", in: root, intermediate: true)
        try makeDir("Tool.app/Contents/MacOS", in: root, intermediate: true)
        try makeFile("Tool.app/Contents/MacOS/installbuilder.sh", bytes: Array("#!/bin/sh".utf8), in: root)
        let verdict = CandidateFilter.installBuilderVerdict(at: bundle)
        #expect(verdict.outcome == .reject)
        let reason = try #require(verdict.reason)
        #expect(reason.contains("Contents/MacOS/installbuilder.sh"))
    }

    @Test func installBuilderDataMarkerRejects() throws {
        let root = try newRoot()
        let bundle = try makeDir("Tool.app", in: root, intermediate: true)
        try makeDir("Tool.app/Contents/Resources", in: root, intermediate: true)
        try makeFile("Tool.app/Contents/Resources/installer.dat", bytes: [0x00], in: root)
        let verdict = CandidateFilter.installBuilderVerdict(at: bundle)
        #expect(verdict.outcome == .reject)
        let reason = try #require(verdict.reason)
        #expect(reason.contains("Contents/Resources/installer.dat"))
    }

    @Test func installBuilderAbsentMarkersAcceptWithDocumentedScopeNote() throws {
        let root = try newRoot()
        let bundle = try makeDir("App.app", in: root, intermediate: true)
        try makeDir("App.app/Contents/MacOS", in: root, intermediate: true)
        let verdict = CandidateFilter.installBuilderVerdict(at: bundle)
        #expect(verdict.outcome == .accept)
        #expect(verdict.notes.contains { $0.contains("marker absent: 'Contents/MacOS/installbuilder.sh'") })
        #expect(verdict.notes.contains { $0.contains("marker absent: 'Contents/Resources/installer.dat'") })
        #expect(verdict.notes.contains { $0.contains("no byte/offset/string markers") },
                "the honest scope note (no byte markers documented, none invented) must ride along")
    }

    @Test func installBuilderMissingRootIsUnknown() throws {
        let root = try newRoot()
        let verdict = CandidateFilter.installBuilderVerdict(at: root.appendingPathComponent("Nope.app", isDirectory: true))
        #expect(verdict.outcome == .unknown)
        #expect(verdict.notes.contains { $0.contains("markers unverifiable") })
    }

    // MARK: - Mach-O header parser (byte-by-byte fixtures)

    @Test func thinHeadersParseToTheirCputype() {
        for (header, expected) in [
            (thinHeader(is64: true, cputype: arm64Cputype, bigEndianFields: false), MachOArchKind.arm64),
            (thinHeader(is64: true, cputype: x8664Cputype, bigEndianFields: false), MachOArchKind.x86_64),
            (thinHeader(is64: false, cputype: 7, bigEndianFields: false), MachOArchKind.x86),
            (thinHeader(is64: false, cputype: 12, bigEndianFields: false), MachOArchKind.arm),
        ] {
            let report = MachOArchParser.parse(header)
            #expect(report.isMachO)
            #expect(!report.isFat)
            #expect(report.architectures == Set([expected]), "cputype \(expected.rawValue) must classify")
            #expect(report.isComplete)
            #expect(report.unknownCputypes.isEmpty)
        }
    }

    @Test func byteSwappedThinHeaderParsesBigEndianFields() {
        // MH_CIGAM_64 spelling: magic stored big-endian (FE ED FA CF on disk),
        // fields big-endian — the parser must read both back correctly.
        let report = MachOArchParser.parse(thinHeader(is64: true, cputype: arm64Cputype, bigEndianFields: true))
        #expect(report.isMachO)
        #expect(report.architectures == Set([.arm64]))
        #expect(report.notes.contains { $0.contains("big-endian fields") })
    }

    @Test func fat32BothEndiannessesParseAllSlices() {
        for bigEndianFields in [false, true] {
            let report = MachOArchParser.parse(
                fatHeader(is64: false, bigEndianFields: bigEndianFields, slices: [x8664Cputype, arm64Cputype]))
            #expect(report.isMachO)
            #expect(report.isFat)
            #expect(report.architectures == Set([.x86_64, .arm64]))
            #expect(report.isComplete)
        }
    }

    @Test func fat64BothEndiannessesParseAllSlices() {
        for bigEndianFields in [false, true] {
            let report = MachOArchParser.parse(
                fatHeader(is64: true, bigEndianFields: bigEndianFields, slices: [x8664Cputype, arm64Cputype]))
            #expect(report.isMachO)
            #expect(report.isFat)
            #expect(report.architectures == Set([.x86_64, .arm64]))
            #expect(report.isComplete)
        }
    }

    @Test func garbageBytesAreNotMachO() {
        for garbage in [Array("definitely not a mach-o binary".utf8), [UInt8](repeating: 0xFF, count: 64), []] {
            let report = MachOArchParser.parse(garbage)
            #expect(!report.isMachO)
            #expect(report.architectures.isEmpty)
            #expect(!report.notes.isEmpty, "honest note required")
        }
    }

    @Test func truncatedFatTableReportsIncomplete() {
        // Declares 3 slices, ships only 1 — the parser must flag the report as
        // incomplete, not silently accept the missing two.
        let report = MachOArchParser.parse(
            fatHeader(is64: false, bigEndianFields: true, slices: [x8664Cputype], declaredCount: 3))
        #expect(report.isMachO)
        #expect(report.architectures == Set([.x86_64]))
        #expect(!report.isComplete)
        #expect(report.notes.contains { $0.contains("truncated") })
    }

    @Test func absurdNfatArchCountIsCapped() {
        let report = MachOArchParser.parse(
            fatHeader(is64: false, bigEndianFields: false, slices: [arm64Cputype], declaredCount: 0xFFFF_FFFF))
        #expect(report.isMachO)
        #expect(!report.isComplete)
        #expect(report.notes.contains { $0.contains("exceeds the sane cap") })
    }

    @Test func zeroArchFatIsANoteNotAGuess() {
        let report = MachOArchParser.parse(
            fatHeader(is64: false, bigEndianFields: true, slices: [], declaredCount: 0))
        #expect(report.isMachO)
        #expect(report.architectures.isEmpty)
        #expect(report.isComplete)
        #expect(report.notes.contains { $0.contains("ZERO architectures") })
    }

    @Test func unknownCputypeIsRecordedRawNotMapped() {
        // cputype 18 (0x12) is not one of the four mapped macOS archs — it
        // must land verbatim in unknownCputypes, never translated into a name.
        let report = MachOArchParser.parse(thinHeader(is64: false, cputype: 18, bigEndianFields: false))
        #expect(report.isMachO)
        #expect(report.architectures.isEmpty)
        #expect(report.unknownCputypes == [18])
        #expect(report.notes.contains { $0.contains("not a mapped") })
    }

    @Test func archReportReadsFromDiskHonestOnUnreadables() throws {
        let root = try newRoot()
        let thinFile = try makeFile("thin", bytes: thinHeader(is64: true, cputype: x8664Cputype, bigEndianFields: false), in: root)
        let diskReport = MachOArchParser.archReport(binaryAt: thinFile)
        #expect(diskReport.architectures == Set([.x86_64]))

        let ghost = root.appendingPathComponent("missing")
        let ghostReport = MachOArchParser.archReport(binaryAt: ghost)
        #expect(!ghostReport.isMachO)
        #expect(ghostReport.notes.contains { $0.contains("not a readable regular file") })

        let dirReport = MachOArchParser.archReport(binaryAt: root)
        #expect(!dirReport.isMachO)
        #expect(dirReport.notes.contains { $0.contains("directory: true") })

        let shortFile = try makeFile("short", bytes: [0xCF, 0xFA], in: root)
        let shortReport = MachOArchParser.archReport(binaryAt: shortFile)
        #expect(!shortReport.isMachO)
        #expect(shortReport.notes.contains { $0.contains("shorter than 4 bytes") })
    }

    // MARK: - Electron wrong-arch detector (documented wrongOCTag shapes)

    @Test func x86OnlyPayloadJudgedAgainstHostArch() throws {
        let root = try newRoot()
        let bundle = try makeDir("Elec.app", in: root, intermediate: true)
        try makeDir("Elec.app/Contents/MacOS", in: root, intermediate: true)
        try makeFile("Elec.app/Contents/MacOS/osx_x86_64",
                     bytes: thinHeader(is64: true, cputype: x8664Cputype, bigEndianFields: false), in: root)
        let verdict = CandidateFilter.electronWrongArchVerdict(at: bundle)
        #expect(verdict.outcome == payloadOutcome(payloadArch: .x86_64))
        if verdict.outcome == .reject {
            let reason = try #require(verdict.reason)
            #expect(reason.contains("wrong-arch") || reason.contains("no slice"))
        }
    }

    @Test func arm64OnlyPayloadJudgedAgainstHostArch() throws {
        let root = try newRoot()
        let bundle = try makeDir("Elec.app", in: root, intermediate: true)
        try makeDir("Elec.app/Contents/MacOS", in: root, intermediate: true)
        try makeFile("Elec.app/Contents/MacOS/osx_arm64",
                     bytes: thinHeader(is64: true, cputype: arm64Cputype, bigEndianFields: false), in: root)
        let verdict = CandidateFilter.electronWrongArchVerdict(at: bundle)
        #expect(verdict.outcome == payloadOutcome(payloadArch: .arm64))
    }

    @Test func bothPayloadsAcceptOnAnyHost() throws {
        let root = try newRoot()
        let bundle = try makeDir("Elec.app", in: root, intermediate: true)
        try makeDir("Elec.app/Contents/MacOS", in: root, intermediate: true)
        try makeFile("Elec.app/Contents/MacOS/osx_x86_64",
                     bytes: thinHeader(is64: true, cputype: x8664Cputype, bigEndianFields: false), in: root)
        try makeFile("Elec.app/Contents/MacOS/osx_arm64",
                     bytes: thinHeader(is64: true, cputype: arm64Cputype, bigEndianFields: false), in: root)
        let verdict = CandidateFilter.electronWrongArchVerdict(at: bundle)
        #expect(verdict.outcome == .accept)
        #expect(verdict.notes.contains { $0.contains("runnable payload") })
    }

    @Test func universalFatPayloadAcceptsOnAnyHost() throws {
        let root = try newRoot()
        let bundle = try makeDir("Elec.app", in: root, intermediate: true)
        try makeDir("Elec.app/Contents/MacOS", in: root, intermediate: true)
        try makeFile("Elec.app/Contents/MacOS/osx_x86_64",
                     bytes: fatHeader(is64: false, bigEndianFields: true, slices: [x8664Cputype, arm64Cputype]), in: root)
        let verdict = CandidateFilter.electronWrongArchVerdict(at: bundle)
        #expect(verdict.outcome == .accept)
    }

    @Test func garbagePayloadHeaderIsUnknownNeverGuessed() throws {
        let root = try newRoot()
        let bundle = try makeDir("Elec.app", in: root, intermediate: true)
        try makeDir("Elec.app/Contents/MacOS", in: root, intermediate: true)
        try makeFile("Elec.app/Contents/MacOS/osx_x86_64", bytes: Array("garbage bytes".utf8), in: root)
        let verdict = CandidateFilter.electronWrongArchVerdict(at: bundle)
        #expect(verdict.outcome == .unknown)
        #expect(verdict.notes.contains { $0.contains("does not parse as Mach-O") })
    }

    @Test func nameContentConflictIsUnknownNotReject() throws {
        // A file named osx_arm64 whose header says x86_64 contradicts its
        // documented shape — honest unknown even when the content would run.
        let root = try newRoot()
        let bundle = try makeDir("Elec.app", in: root, intermediate: true)
        try makeDir("Elec.app/Contents/MacOS", in: root, intermediate: true)
        try makeFile("Elec.app/Contents/MacOS/osx_arm64",
                     bytes: thinHeader(is64: true, cputype: x8664Cputype, bigEndianFields: false), in: root)
        let verdict = CandidateFilter.electronWrongArchVerdict(at: bundle)
        #expect(verdict.outcome == .unknown)
        #expect(verdict.notes.contains { $0.contains("NAME/CONTENT CONFLICT") })
    }

    @Test func bundleWithoutPayloadsIsNotApplicable() throws {
        let root = try newRoot()
        let bundle = try makeDir("Plain.app", in: root, intermediate: true)
        try makeDir("Plain.app/Contents/MacOS", in: root, intermediate: true)
        try makeFile("Plain.app/Contents/MacOS/main", bytes: Array("#!/bin/sh".utf8), in: root)
        let verdict = CandidateFilter.electronWrongArchVerdict(at: bundle)
        #expect(verdict.outcome == .notApplicable)
        #expect(verdict.notes.contains { $0.contains("osx_x86_64") })
    }

    @Test func zipWithoutInnerBinaryIsNotApplicableWithHonestNote() throws {
        let root = try newRoot()
        let zip = try makeFile("Elec.zip", bytes: [0x50, 0x4B, 0x03, 0x04], in: root)
        let verdict = CandidateFilter.electronWrongArchVerdict(at: zip)
        #expect(verdict.outcome == .notApplicable)
        #expect(verdict.notes.contains { $0.contains("no deep zip guessing") })
        #expect(verdict.notes.contains { $0.contains("innerBinaryPath") })
    }

    @Test func zipWithExplicitInnerBinaryIsJudged() throws {
        let root = try newRoot()
        let zip = try makeFile("Elec.zip", bytes: [0x50, 0x4B, 0x03, 0x04], in: root)
        let inner = try makeFile("extracted-payload",
                                 bytes: thinHeader(is64: true, cputype: arm64Cputype, bigEndianFields: false), in: root)
        let verdict = CandidateFilter.electronWrongArchVerdict(at: zip, innerBinaryPath: inner)
        #expect(verdict.outcome == payloadOutcome(payloadArch: .arm64))
        #expect(verdict.notes.contains { $0.contains("explicitly supplied inner binary") })
    }

    @Test func missingOrDirectoryInnerBinaryIsUnknown() throws {
        let root = try newRoot()
        let zip = try makeFile("Elec.zip", bytes: [0x50, 0x4B, 0x03, 0x04], in: root)
        let ghost = CandidateFilter.electronWrongArchVerdict(at: zip, innerBinaryPath: root.appendingPathComponent("nope"))
        #expect(ghost.outcome == .unknown)
        #expect(ghost.notes.contains { $0.contains("not found / not a regular file") })

        let dirPayload = CandidateFilter.electronWrongArchVerdict(at: zip, innerBinaryPath: root)
        #expect(dirPayload.outcome == .unknown)
    }

    // MARK: - Combined gate (per-detector receipts + overall precedence)

    @Test func overallRejectWinsAndCarriesReceipts() throws {
        let root = try newRoot()
        let bundle = try makeDir("setup.app", in: root, intermediate: true)
        try makeDir("setup.app/Contents/MacOS", in: root, intermediate: true)
        try makeFile("setup.app/Contents/MacOS/osx_x86_64", bytes: Array("junk".utf8), in: root)
        let report = CandidateFilter.filter(candidateURL: bundle)
        #expect(report.overall.outcome == .reject, "reject outranks the unknown payload")
        let reason = try #require(report.overall.reason)
        #expect(reason.contains("installer-bundle name"))
        #expect(report.installerBundle.outcome == .reject)
        #expect(report.installBuilder.outcome == .accept)
        #expect(report.electronWrongArch.outcome == .unknown)
        #expect(report.overall.notes.contains { $0.contains("security floor") },
                "the never-overrides-the-floor statement must be part of the receipt")
    }

    @Test func overallUnknownWhenNothingRejects() throws {
        let root = try newRoot()
        let bundle = try makeDir("Vague.app", in: root, intermediate: true)
        try makeDir("Vague.app/Contents/MacOS", in: root, intermediate: true)
        try makeFile("Vague.app/Contents/MacOS/osx_arm64", bytes: [0x00, 0x01, 0x02], in: root)
        let report = CandidateFilter.filter(candidateURL: bundle)
        #expect(report.overall.outcome == .unknown)
        #expect(report.overall.reason == nil)
    }

    @Test func plainAppBundleIsOverallAccept() throws {
        let root = try newRoot()
        let bundle = try makeDir("TextEdit.app", in: root, intermediate: true)
        try makeDir("TextEdit.app/Contents/MacOS", in: root, intermediate: true)
        try makeFile("TextEdit.app/Contents/MacOS/TextEdit", bytes: [0x00], in: root)
        let report = CandidateFilter.filter(candidateURL: bundle)
        #expect(report.overall.outcome == .accept)
        #expect(report.installerBundle.outcome == .accept)
        #expect(report.installBuilder.outcome == .accept)
        #expect(report.electronWrongArch.outcome == .notApplicable)
        #expect(report.candidatePath == bundle.path)
    }

    @Test func stagedZipOverallIsAcceptWithDeepSignalNotApplicable() throws {
        let root = try newRoot()
        let zip = try makeFile("Regular.zip", bytes: [0x50, 0x4B, 0x03, 0x04], in: root)
        let report = CandidateFilter.filter(candidateURL: zip)
        // Shallow documented checks ran over the staged file name and found
        // nothing; the deep Electron signal is notApplicable for an
        // unextracted artifact — and a not-applicable probe contributes NO
        // evidence, so the overall is the checked accept. Which signal did
        // not apply stays visible in the per-detector receipt (that receipt
        // is what tells a coordinator to unarchive and re-run the deep check
        // on the extracted bundle).
        #expect(report.installerBundle.outcome == .accept)
        #expect(report.installBuilder.outcome == .accept)
        #expect(report.electronWrongArch.outcome == .notApplicable)
        #expect(report.overall.outcome == .accept)
        #expect(report.overall.reason == nil)
    }

    // MARK: - Verdict type contract (Codable + Hashable receipts)

    @Test func verdictsRoundTripThroughJSONAndHash() throws {
        let verdicts: [CandidateVerdict] = [
            .accept(["negative finding", "citation"]),
            .reject("documented installer-bundle name 'setup.app' matched", notes: ["evidence"]),
            .unknown(["header unparseable"]),
            .notApplicable(["no documented shape applies"]),
        ]
        for verdict in verdicts {
            let data = try JSONEncoder().encode(verdict)
            let decoded = try JSONDecoder().decode(CandidateVerdict.self, from: data)
            #expect(decoded == verdict)
            #expect(decoded.outcome.rawValue == verdict.outcome.rawValue)
        }
        let set = Set(verdicts + [verdicts[0], verdicts[1]])
        #expect(set.count == 4, "Hashable receipts must dedupe by value")
    }

    @Test func reportRoundTripsThroughJSON() throws {
        let root = try newRoot()
        let bundle = try makeDir("setup.app", in: root, intermediate: true)
        let report = CandidateFilter.filter(candidateURL: bundle)
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(CandidateFilterReport.self, from: data)
        #expect(decoded == report)
    }

    // MARK: - Precedence arithmetic (reject > unknown > accept > notApplicable)

    @Test func verdictPrecedenceOrdering() {
        let accept = CandidateVerdict.accept([])
        let na = CandidateVerdict.notApplicable([])
        let unknown = CandidateVerdict.unknown([])
        let reject = CandidateVerdict.reject("r", notes: [])
        // A not-applicable probe contributes no evidence; a checked accept
        // (real finding: no documented disqualifier on disk) outranks it.
        #expect(na.precedence < accept.precedence)
        #expect(accept.precedence < unknown.precedence)
        #expect(unknown.precedence < reject.precedence)
    }

    // MARK: - Inner-binary branch (no documented name contract — content only)

    @Test func zipWithExplicitInnerBinaryWrongArchIsRejectedWithReframedReason() throws {
        let root = try newRoot()
        let zip = try makeFile("Elec.zip", bytes: [0x50, 0x4B, 0x03, 0x04], in: root)
        let inner = try makeFile("extracted-payload",
                                 bytes: thinHeader(is64: true, cputype: x8664Cputype, bigEndianFields: false), in: root)
        let verdict = CandidateFilter.electronWrongArchVerdict(at: zip, innerBinaryPath: inner)
        // An inner binary has NO documented name contract, so an x86_64
        // payload must be judged on content alone: on an arm64 host this is
        // the honest wrong-arch reject (never swallowed by a name/content
        // conflict it never agreed to); on an x86_64 host it is runnable.
        #expect(verdict.outcome == payloadOutcome(payloadArch: .x86_64))
        if verdict.outcome == .reject {
            let reason = try #require(verdict.reason)
            #expect(reason.contains("explicit inner binary"), "the no-contract re-frame must relabel the rejection")
            #expect(reason.contains("wrong-arch"))
        }
    }

    @Test func zipWithUniversalInnerBinaryAcceptsOnAnyHost() throws {
        let root = try newRoot()
        let zip = try makeFile("Elec.zip", bytes: [0x50, 0x4B, 0x03, 0x04], in: root)
        let inner = try makeFile("extracted-payload",
                                 bytes: fatHeader(is64: false, bigEndianFields: true, slices: [x8664Cputype, arm64Cputype]), in: root)
        let verdict = CandidateFilter.electronWrongArchVerdict(at: zip, innerBinaryPath: inner)
        #expect(verdict.outcome == .accept)
        #expect(verdict.notes.contains { $0.contains("runnable on this machine") })
    }

    @Test func filterCarriesInnerBinaryOverall() throws {
        let root = try newRoot()
        let zip = try makeFile("Elec.zip", bytes: [0x50, 0x4B, 0x03, 0x04], in: root)
        let inner = try makeFile("extracted-payload",
                                 bytes: thinHeader(is64: true, cputype: x8664Cputype, bigEndianFields: false), in: root)
        let report = CandidateFilter.filter(candidateURL: zip, innerBinaryPath: inner)
        #expect(report.overall.outcome == payloadOutcome(payloadArch: .x86_64))
        #expect(report.electronWrongArch.notes.contains { $0.contains("explicitly supplied inner binary") })
    }

    // MARK: - Honesty paths at the payload level (unproven beats guessed)

    @Test func truncatedThinPayloadIsUnknown() throws {
        // A valid MH_MAGIC_64 truncated before cputype: the header exists but
        // the architecture is unreadable — honest unknown, never a guess.
        let root = try newRoot()
        let bundle = try makeDir("Elec.app", in: root, intermediate: true)
        try makeDir("Elec.app/Contents/MacOS", in: root, intermediate: true)
        try makeFile("Elec.app/Contents/MacOS/osx_arm64", bytes: [0xCF, 0xFA, 0xED, 0xFE], in: root)
        let verdict = CandidateFilter.electronWrongArchVerdict(at: bundle)
        #expect(verdict.outcome == .unknown)
        #expect(verdict.notes.contains { $0.contains("header incomplete/truncated") })
    }

    @Test func unmappedCputypePayloadIsUnknown() throws {
        let root = try newRoot()
        let bundle = try makeDir("Elec.app", in: root, intermediate: true)
        try makeDir("Elec.app/Contents/MacOS", in: root, intermediate: true)
        try makeFile("Elec.app/Contents/MacOS/osx_x86_64",
                     bytes: thinHeader(is64: false, cputype: 18, bigEndianFields: false), in: root)
        let verdict = CandidateFilter.electronWrongArchVerdict(at: bundle)
        #expect(verdict.outcome == .unknown)
        #expect(verdict.notes.contains { $0.contains("unmapped cputype(s) present") })
    }

    @Test func runnablePayloadWinsOverUnparseableSiblingWithWarningNotes() throws {
        let root = try newRoot()
        let bundle = try makeDir("Elec.app", in: root, intermediate: true)
        try makeDir("Elec.app/Contents/MacOS", in: root, intermediate: true)
        try makeFile("Elec.app/Contents/MacOS/osx_x86_64", bytes: Array("junk".utf8), in: root)
        try makeFile("Elec.app/Contents/MacOS/osx_arm64",
                     bytes: fatHeader(is64: false, bigEndianFields: true, slices: [x8664Cputype, arm64Cputype]), in: root)
        let verdict = CandidateFilter.electronWrongArchVerdict(at: bundle)
        // The universal payload runs on any host; the unparseable sibling must
        // ride along as a warning note, never be silently dropped.
        #expect(verdict.outcome == .accept)
        #expect(verdict.notes.contains { $0.contains("runnable payload documented and present: 'Contents/MacOS/osx_arm64'") })
        #expect(verdict.notes.contains { $0.contains("does not parse as Mach-O") })
    }

    @Test func bundlePayloadsTakePrecedenceOverSuppliedInnerBinary() throws {
        let root = try newRoot()
        let bundle = try makeDir("Elec.app", in: root, intermediate: true)
        try makeDir("Elec.app/Contents/MacOS", in: root, intermediate: true)
        try makeFile("Elec.app/Contents/MacOS/osx_arm64", bytes: [0x00], in: root) // unparseable payload
        let runnableElsewhere = try makeFile(
            "elsewhere-binary",
            bytes: fatHeader(is64: false, bigEndianFields: true, slices: [x8664Cputype, arm64Cputype]), in: root)
        // The documented in-bundle shapes take precedence: a runnable binary
        // supplied from outside the bundle must NOT rescue an unparseable
        // in-bundle payload.
        let verdict = CandidateFilter.electronWrongArchVerdict(at: bundle, innerBinaryPath: runnableElsewhere)
        #expect(verdict.outcome == .unknown)
        #expect(verdict.notes.contains { $0.contains("noted but not used") })
    }
}
