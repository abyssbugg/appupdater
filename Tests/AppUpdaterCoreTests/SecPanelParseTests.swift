// SecPanelParseTests.swift — hermetic parser + seam tests for the security
// panel (Sources/AppUpdaterCore/SecurityPanel/).
//
// Swift Testing ONLY — XCTest discovery is broken on this toolchain (Xcode 27
// beta, see AGENTS.md gotcha ledger). Swift Testing does not re-export
// Foundation, so `import Foundation` is required here.
//
// Fixtures are VERBATIM outputs captured from the real tools on the macOS
// 27.2 build host (noted per fixture); stub runners feed them through the
// injected SecProcessRunner seam so `inspect()` is exercised end-to-end with
// zero tool invocations. Known-shape variants (a fixture with one numeric
// field changed, or a trimmed display) are labeled as such at each use.

import Testing
import Foundation
@testable import AppUpdaterCore

// MARK: - Verbatim real-tool fixtures (macOS 27.2 build host)

private enum Fixture {
    /// `codesign -dv -vvvv /Applications/Ghostty.app` (stderr), hash-page dump
    /// lines re-inserted verbatim (the display carries whitespace-prefixed
    /// `-7=…` lines; two real ones included).
    static let ghosttyDisplay = """
    Executable=/Applications/Ghostty.app/Contents/MacOS/ghostty
    Identifier=com.mitchellh.ghostty
    Format=app bundle with Mach-O universal (x86_64 arm64)
    CodeDirectory v=20500 size=43265 flags=0x10000(runtime) hashes=1341+7 location=embedded
    VersionPlatform=1
    VersionMin=851968
    VersionSDK=1769472
    Hash type=sha256 size=32
    CandidateCDHash sha256=b9bdc51aa395621c1a6de6d8cf9fb8d552f0e694
    CandidateCDHashFull sha256=b9bdc51aa395621c1a6de6d8cf9fb8d552f0e69416da6fbdeb348cbcfb3e8c82
    Hash choices=sha256
    CMSDigest=b9bdc51aa395621c1a6de6d8cf9fb8d552f0e69416da6fbdeb348cbcfb3e8c82
    CMSDigestType=2
    Executable Segment base=0
    Executable Segment limit=15941632
    Executable Segment flags=0x1
    Page size=16384
        -7=837a86721c3415b47c607f8ff2a8e9810fdc6a53fbc260c2aa245f0ea61287b0
        -6=0000000000000000000000000000000000000000000000000000000000000000
    CDHash=b9bdc51aa395621c1a6de6d8cf9fb8d552f0e694
    Signature size=9057
    Authority=Developer ID Application: Mitchell Hashimoto (24VZTF6M5V)
    Authority=Developer ID Certification Authority
    Authority=Apple Root CA
    Timestamp=Oct 27, 2026 at 10:39:46 PM
    Info.plist entries=50
    TeamIdentifier=24VZTF6M5V
    Runtime Version=27.0.0
    Sealed Resources version=2 rules=13 files=897
    Internal requirements count=1 size=184
    Total signatures=1
    Chosen signature=1
    """

    /// `codesign -dv -vvvv /Applications/Capy.app` (stderr), hash-page lines
    /// omitted. Carries the stapled Notarization Ticket + Timestamp shapes.
    static let capyDisplay = """
    Executable=/Applications/Capy.app/Contents/MacOS/Capy
    Identifier=ai.capy.desktop
    Format=app bundle with Mach-O thin (arm64)
    CodeDirectory v=20500 size=635 flags=0x10000(runtime) hashes=9+7 location=embedded
    VersionPlatform=1
    VersionMin=851968
    VersionSDK=1705216
    Hash type=sha256 size=32
    CandidateCDHash sha256=1cc690c544725be59665c4365164c67d17731463
    CandidateCDHashFull sha256=1cc690c544725be59665c4365164c67d17731463aaeab0b231f4679cce3ad88b
    Hash choices=sha256
    CMSDigest=1cc690c544725be59665c4365164c67d17731463aaeab0b231f4679cce3ad88b
    CMSDigestType=2
    Executable Segment base=0
    Executable Segment limit=16384
    Executable Segment flags=0x1
    Page size=4096
    CDHash=1cc690c544725be59665c4365164c67d17731463
    Signature size=8974
    Authority=Developer ID Application: Yingting Sun (9YWUN5FK23)
    Authority=Developer ID Certification Authority
    Authority=Apple Root CA
    Timestamp=Oct 27, 2026 at 3:27:14 PM
    Notarization Ticket=stapled
    Info.plist entries=39
    TeamIdentifier=9YWUN5FK23
    Runtime Version=26.5.0
    Sealed Resources version=2 rules=13 files=1576
    Internal requirements count=1 size=176
    Total signatures=1
    Chosen signature=1
    """

    /// `codesign -dv -vvvv` of an ad-hoc-signed test fixture bundle (stderr).
    static let binAdHocDisplay = """
    Executable=/tmp/secpanel-exp/Bin.app/Contents/MacOS/Bin
    Identifier=com.example.bin
    Format=bundle with Mach-O thin (arm64)
    CodeDirectory v=20400 size=296 flags=0x2(adhoc) hashes=3+3 location=embedded
    VersionPlatform=1
    VersionMin=1769984
    VersionSDK=1769472
    Hash type=sha256 size=32
    CandidateCDHash sha256=2e9dbd7c8fbfdb3e5e9470d719b375468cae158e
    CandidateCDHashFull sha256=2e9dbd7c8fbfdb3e5e9470d719b375468cae158eb2925d3548e7a742f4cba25f
    Hash choices=sha256
    CMSDigest=2e9dbd7c8fbfdb3e5e9470d719b375468cae158eb2925d3548e7a742f4cba25f
    CMSDigestType=2
    Executable Segment base=0
    Executable Segment limit=16384
    Executable Segment flags=0x1
    Page size=16384
    CDHash=2e9dbd7c8fbfdb3e5e9470d719b375468cae158e
    Signature=adhoc
    Info.plist=not bound
    TeamIdentifier=not set
    Sealed Resources version=2 rules=13 files=0
    Internal requirements count=0 size=12
    Total signatures=1
    Chosen signature=1
    """

    /// `codesign -dv -vvvv` of a fresh `cc`-linked binary (real lines, subset):
    /// the flags parenthetical is COMMA-separated on macOS 27.2 —
    /// `adhoc,linker-signed` — the shape that must not defeat the word parse.
    static let linkerSignedDisplay = """
    Identifier=l-bin
    Format=Mach-O thin (arm64)
    CodeDirectory v=20400 size=254 flags=0x20002(adhoc,linker-signed) hashes=5+0 location=embedded
    Executable Segment flags=0x1
    Signature=adhoc
    TeamIdentifier=not set
    """

    /// `codesign -dv -vvvv` of an unsigned fixture bundle (whole stderr).
    static let unsignedDisplay = "Bar.app: code object is not signed at all\n"

    /// `spctl -a -vv /Applications/Capy.app` (stderr; everything on stderr on
    /// 27.2), exit 0 — the canonical Notarized-Developer-ID acceptance.
    static let capySpctlAccepted = """
    /Applications/Capy.app: accepted
    source=Notarized Developer ID
    origin=Developer ID Application: Yingting Sun (9YWUN5FK23)
    """

    /// `spctl -a -vv` of an ad-hoc-signed fixture, exit 3 (no source line).
    static let binSpctlRejected = "Bin.app: rejected\n"

    /// `spctl -a -vv` of an unsigned fixture, exit 3.
    static let barSpctlRejectedUnsigned = "Bar.app: rejected\nsource=no usable signature\n"

    /// `spctl -a -vv` error shapes, exit 1 (an ERROR, not an assessment).
    static let malformedSpctl = "Foo.app: a required plist file or resource is malformed\n"
    static let tamperedSpctl = "Tam.app: code has no resources but signature indicates they must be present\n"

    /// `codesign --verify --deep --strict` failure diagnostics (stderr), exit 1.
    static let infoPlistTamperVerify = "Bin.app: invalid Info.plist (plist or signature have been modified)\n"
    static let resourceTamperVerify = "Tam.app: code has no resources but signature indicates they must be present\n"

    /// `codesign -d --entitlements :- /System/Applications/Calculator.app`
    /// (stdout), exit 0. Real system entitlements — the captured single-line
    /// XML with newlines inserted between elements for line length (plist XML
    /// is whitespace-insensitive between tags).
    static let calculatorEntitlementsXML = """
    <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
    <key>com.apple.private.coreservices.canmaplsdatabase</key><true/>
    <key>com.apple.private.hid.client.event-dispatch.internal</key><true/>
    <key>com.apple.runningboard.terminateprocess</key><true/>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.exception.shared-preference.read-only</key><array><string>com.apple.calculator</string></array>
    <key>com.apple.security.exception.shared-preference.read-write</key><array><string>com.apple.internal.testplatform</string></array>
    <key>com.apple.security.files.user-selected.read-write</key><true/>
    <key>com.apple.security.network.client</key><true/>
    <key>com.apple.security.print</key><true/>
    <key>com.apple.security.temporary-exception.files.absolute-path.read-only</key><array><string>/Library/Managed Preferences/</string></array>
    <key>com.apple.security.temporary-exception.mach-lookup.global-name</key><array>
    <string>com.apple.managedconfiguration.profiled</string><string>com.apple.ManagedSettingsAgent</string>
    <string>com.apple.internal.xctestinternalangel.sessions</string>
    </array>
    <key>file-read-data</key><true/>
    <key>file-write-data</key><true/>
    <key>user-preference-read</key><true/>
    <key>user-preference-write</key><true/>
    </dict></plist>
    """

    /// The XML an ad-hoc `codesign -s - --entitlements ent.plist` fixture
    /// round-trips back through `codesign -d --entitlements :-` (stdout, exit 0;
    /// newlines inserted between elements for line length).
    static let sandboxedEntitlementsXML = """
    <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.network.client</key><true/>
    <key>keychain-access-groups</key><array><string>groupA</string><string>groupB</string></array>
    </dict></plist>
    """

    /// Same sandbox dict but with `keychain-access-groups` malformed into a
    /// string — the "present but not an array" honesty case.
    static let keychainNonArrayEntitlementsXML = """
    <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>keychain-access-groups</key><string>not-an-array</string>
    </dict></plist>
    """
}

// MARK: - Stub seam helpers

private struct ProbeStubMiss: Error {
    let launchPath: String
}

private func canned(_ stdout: String = "", stderr: String = "", exit: Int32 = 0) -> SecProcessRunner.Run {
    SecProcessRunner.Run(stdout: stdout, stderr: stderr, exitStatus: exit)
}

/// A runner that answers each probe kind from a canned run; a probe with no
/// canned run THROWS (which exercises the inspector's spawn-failure notes).
private func stubRunner(
    display: SecProcessRunner.Run? = nil,
    verify: SecProcessRunner.Run? = nil,
    gatekeeper: SecProcessRunner.Run? = nil,
    entitlements: SecProcessRunner.Run? = nil,
    entitlementsFallback: SecProcessRunner.Run? = nil
) -> SecProcessRunner {
    SecProcessRunner { launchPath, arguments in
        if launchPath == SecInspector.codesignPath {
            if arguments.contains("--entitlements") {
                if arguments.contains(":-:xml") {
                    guard let run = entitlementsFallback else { throw ProbeStubMiss(launchPath: launchPath) }
                    return run
                }
                guard let run = entitlements else { throw ProbeStubMiss(launchPath: launchPath) }
                return run
            }
            if arguments.contains("--verify") {
                guard let run = verify else { throw ProbeStubMiss(launchPath: launchPath) }
                return run
            }
            if arguments.contains("-dv") {
                guard let run = display else { throw ProbeStubMiss(launchPath: launchPath) }
                return run
            }
        }
        if launchPath == SecInspector.spctlPath {
            guard let run = gatekeeper else { throw ProbeStubMiss(launchPath: launchPath) }
            return run
        }
        throw ProbeStubMiss(launchPath: launchPath)
    }
}

/// An existing empty directory — stubbed `inspect()` tests need a path that
/// EXISTS so the probes actually run (a missing path short-circuits with the
/// not-found note by design; that behavior has its own dedicated tests).
private func makeProbeDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("appupdater-secpanel-parse-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Tests

@Suite struct SecPanelParseTests {

    // MARK: parseSignatureDisplay

    @Test func devIDDisplayParsesFully() {
        let parsed = SecInspector.parseSignatureDisplay(Fixture.ghosttyDisplay)
        #expect(parsed.executablePath == "/Applications/Ghostty.app/Contents/MacOS/ghostty")
        #expect(parsed.identifier == "com.mitchellh.ghostty")
        #expect(parsed.authorities == [
            "Developer ID Application: Mitchell Hashimoto (24VZTF6M5V)",
            "Developer ID Certification Authority",
            "Apple Root CA",
        ])
        #expect(parsed.teamIdentifier == "24VZTF6M5V")
        #expect(parsed.cdHash == "b9bdc51aa395621c1a6de6d8cf9fb8d552f0e694")
        #expect(parsed.timestamp == "Oct 27, 2026 at 10:39:46 PM")
        #expect(parsed.notarizationTicket == nil)
        #expect(parsed.hardenedRuntime == true)
        #expect(parsed.linkerSigned == false)
        #expect(parsed.isAdHoc == false)
        #expect(parsed.runtimeVersion == "27.0.0")
        #expect(parsed.totalSignatures == 1)
        #expect(parsed.chosenSignature == 1)
    }

    @Test func stapledTicketAndTimestampParse() {
        let parsed = SecInspector.parseSignatureDisplay(Fixture.capyDisplay)
        #expect(parsed.notarizationTicket == "stapled")
        #expect(parsed.timestamp == "Oct 27, 2026 at 3:27:14 PM")
        #expect(parsed.teamIdentifier == "9YWUN5FK23")
        #expect(parsed.hardenedRuntime == true)
        #expect(parsed.identifier == "ai.capy.desktop")
    }

    @Test func adHocDisplayParses() {
        let parsed = SecInspector.parseSignatureDisplay(Fixture.binAdHocDisplay)
        #expect(parsed.authorities.isEmpty)
        #expect(parsed.teamIdentifier == nil) // "not set" is honest absence
        #expect(parsed.isAdHoc == true)
        #expect(parsed.hardenedRuntime == false)
        #expect(parsed.linkerSigned == false)
        #expect(parsed.cdHash == "2e9dbd7c8fbfdb3e5e9470d719b375468cae158e")
        #expect(parsed.identifier == "com.example.bin")
        #expect(parsed.timestamp == nil)
    }

    @Test func commaSeparatedLinkerSignedFlagsParse() {
        let parsed = SecInspector.parseSignatureDisplay(Fixture.linkerSignedDisplay)
        #expect(parsed.linkerSigned == true)
        #expect(parsed.isAdHoc == true)
        #expect(parsed.hardenedRuntime == false)
        #expect(parsed.teamIdentifier == nil)
    }

    @Test func unsignedDiagnosticsParseToAllNil() {
        let parsed = SecInspector.parseSignatureDisplay(Fixture.unsignedDisplay)
        #expect(parsed == SecInspector.ParsedDisplay()) // no Key= lines at all
    }

    @Test func runtimeBitAloneYieldsHardened() {
        // Realistic variant: same CodeDirectory wording with the parenthetical
        // dropped — the numeric 0x10000 bit must still yield the verdict.
        let text = Fixture.ghosttyDisplay.replacingOccurrences(
            of: "flags=0x10000(runtime)", with: "flags=0x10000")
        let parsed = SecInspector.parseSignatureDisplay(text)
        #expect(parsed.hardenedRuntime == true)
    }

    // MARK: parseGatekeeper

    @Test func acceptedAssessmentParses() {
        let parsed = SecInspector.parseGatekeeper(exitStatus: 0, combinedText: Fixture.capySpctlAccepted)
        #expect(parsed.verdict == .accepted)
        #expect(parsed.source == "Notarized Developer ID")
        #expect(parsed.origin == "Developer ID Application: Yingting Sun (9YWUN5FK23)")
        #expect(parsed.unknownNote == nil)
    }

    @Test func adHocRejectionParses() {
        let parsed = SecInspector.parseGatekeeper(exitStatus: 3, combinedText: Fixture.binSpctlRejected)
        #expect(parsed.verdict == .rejected)
        #expect(parsed.source == nil)
        #expect(parsed.origin == nil)
    }

    @Test func unsignedRejectionCarriesSource() {
        let parsed = SecInspector.parseGatekeeper(exitStatus: 3, combinedText: Fixture.barSpctlRejectedUnsigned)
        #expect(parsed.verdict == .rejected)
        #expect(parsed.source == "no usable signature")
    }

    @Test func malformedErrorIsUnknownWithVerbatimNote() {
        let parsed = SecInspector.parseGatekeeper(exitStatus: 1, combinedText: Fixture.malformedSpctl)
        #expect(parsed.verdict == .unknown)
        #expect(parsed.unknownNote?.contains("exit 1") == true)
        #expect(parsed.unknownNote?.contains("a required plist file or resource is malformed") == true)
    }

    @Test func tamperedSpctlErrorIsUnknown() {
        let parsed = SecInspector.parseGatekeeper(exitStatus: 1, combinedText: Fixture.tamperedSpctl)
        #expect(parsed.verdict == .unknown)
        #expect(parsed.unknownNote?.contains("code has no resources") == true)
    }

    @Test func acceptedWordWithoutProbeFailureNote() {
        // exit 0 but the word never arrived — unknown, never guessed-accepted.
        let parsed = SecInspector.parseGatekeeper(exitStatus: 0, combinedText: "unparseable noise\n")
        #expect(parsed.verdict == .unknown)
        #expect(parsed.unknownNote?.contains("unparseable noise") == true)
    }

    @Test func rejectedWordWithWrongExitIsUnknown() {
        // The word says rejected but the exit code is not spctl's 3: refuse to
        // trust either signal alone.
        let parsed = SecInspector.parseGatekeeper(exitStatus: 0, combinedText: "X.app: rejected\n")
        #expect(parsed.verdict == .unknown)
    }

    @Test func emptyOutputExit3IsUnknown() {
        let parsed = SecInspector.parseGatekeeper(exitStatus: 3, combinedText: "")
        #expect(parsed.verdict == .unknown)
        #expect(parsed.unknownNote?.contains("<no diagnostics>") == true)
    }

    // MARK: entitlements parsing

    @Test func calculatorEntitlementsSummarize() throws {
        let dict = try #require(SecInspector.embeddedPlistDict(in: Fixture.calculatorEntitlementsXML))
        let parsed = SecInspector.parseEntitlements(dict)
        #expect(parsed.keys.count == 15)
        #expect(parsed.keys.first == "com.apple.private.coreservices.canmaplsdatabase")
        #expect(parsed.keys.last == "user-preference-write")
        #expect(parsed.sandboxed == true)
        #expect(parsed.keychainAccessGroupsCount == nil) // key absent ≠ zero groups
        #expect(parsed.keychainAccessGroupsPresentButNotArray == false)
    }

    @Test func sandboxedFixtureEntitlementsSummarize() throws {
        let dict = try #require(SecInspector.embeddedPlistDict(in: Fixture.sandboxedEntitlementsXML))
        let parsed = SecInspector.parseEntitlements(dict)
        #expect(parsed.keys == [
            "com.apple.security.app-sandbox",
            "com.apple.security.network.client",
            "keychain-access-groups",
        ])
        #expect(parsed.sandboxed == true)
        #expect(parsed.keychainAccessGroupsCount == 2)
    }

    @Test func keychainNonArrayWithholdsCount() throws {
        let dict = try #require(SecInspector.embeddedPlistDict(in: Fixture.keychainNonArrayEntitlementsXML))
        let parsed = SecInspector.parseEntitlements(dict)
        #expect(parsed.sandboxed == true)
        #expect(parsed.keychainAccessGroupsCount == nil)
        #expect(parsed.keychainAccessGroupsPresentButNotArray == true)
    }

    @Test func sandboxKeyAbsentIsNotSandboxed() throws {
        let dict = try #require(SecInspector.embeddedPlistDict(in: """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.security.network.client</key><true/></dict></plist>
        """))
        let parsed = SecInspector.parseEntitlements(dict)
        #expect(parsed.sandboxed == false)
        #expect(parsed.keychainAccessGroupsCount == nil)
    }

    @Test func embeddedPlistSurvivesDiagnosticNoise() throws {
        // The entitlements XML mirrors onto the codesign diagnostic stream
        // (macOS 27.2 shape): display line + deprecation warning + plist.
        let noisy = """
        Executable=/System/Applications/Calculator.app/Contents/MacOS/Calculator
        warning: Specifying ':' in the path is deprecated and will not work in a future release
        \(Fixture.calculatorEntitlementsXML)
        """
        let dict = try #require(SecInspector.embeddedPlistDict(in: noisy))
        #expect(dict["com.apple.security.app-sandbox"] != nil)
    }

    @Test func embeddedPlistRejectsGarbage() {
        #expect(SecInspector.embeddedPlistDict(in: "") == nil)
        #expect(SecInspector.embeddedPlistDict(in: "totally not a plist") == nil)
        #expect(SecInspector.embeddedPlistDict(in: "<?xml unclosed") == nil)
    }

    // MARK: inspect() end-to-end through the stubbed seam

    @Test func fullySignedHappyPathReport() async throws {
        let runner = stubRunner(
            display: canned(stderr: Fixture.ghosttyDisplay),
            verify: canned(),
            gatekeeper: canned(stderr: Fixture.capySpctlAccepted),
            entitlements: canned(Fixture.calculatorEntitlementsXML))
        let report = await SecInspector.inspect(appAt: URL(fileURLWithPath: "/Applications/Ghostty.app"), using: runner)
        #expect(report.appPath == "/Applications/Ghostty.app")
        #expect(report.signaturePresent == true)
        #expect(report.codesignValid == true)
        #expect(report.gatekeeperAssessment == .accepted)
        #expect(report.gatekeeperSource == "Notarized Developer ID")
        #expect(report.gatekeeperOrigin == "Developer ID Application: Yingting Sun (9YWUN5FK23)")
        #expect(report.signatureAuthorities.count == 3)
        #expect(report.teamIdentifier == "24VZTF6M5V")
        #expect(report.signedIdentifier == "com.mitchellh.ghostty")
        #expect(report.cdHash == "b9bdc51aa395621c1a6de6d8cf9fb8d552f0e694")
        #expect(report.timestamp == "Oct 27, 2026 at 10:39:46 PM")
        #expect(report.notarizationTicket == nil)
        #expect(report.hardenedRuntime == true)
        #expect(report.linkerSigned == false)
        #expect(report.isAdHoc == false)
        #expect(report.runtimeVersion == "27.0.0")
        #expect(report.entitlementsPresent == true)
        #expect(report.sandboxed == true)
        #expect(report.keychainAccessGroupsCount == nil)
        #expect(report.entitlementKeys.count == 15)
        #expect(report.notes.isEmpty) // a fully successful panel is silent
    }

    @Test func tamperedBundleReport() async throws {
        let runner = stubRunner(
            display: canned(stderr: Fixture.binAdHocDisplay),
            verify: canned(stderr: Fixture.resourceTamperVerify, exit: 1),
            gatekeeper: canned(stderr: Fixture.tamperedSpctl, exit: 1),
            entitlements: canned(),
            entitlementsFallback: canned())
        let probeDir = try makeProbeDir()
        defer { try? FileManager.default.removeItem(at: probeDir) }
        let report = await SecInspector.inspect(appAt: probeDir, using: runner)
        #expect(report.signaturePresent == true) // display still exits 0 when tampered
        #expect(report.codesignValid == false)
        #expect(report.notes.contains { $0.contains("--deep --strict failed (exit 1)")
            && $0.contains("code has no resources but signature indicates they must be present") })
        #expect(report.gatekeeperAssessment == .unknown) // exit 1 is an error, not a rejection
        #expect(report.notes.contains { $0.contains("could not produce an assessment (exit 1)") })
        #expect(report.isAdHoc == true)
        #expect(report.sandboxed == false) // exit 0, nothing parseable, no entitlements
    }

    @Test func unsignedBundleReport() async throws {
        let runner = stubRunner(
            display: canned(stderr: Fixture.unsignedDisplay, exit: 1),
            verify: canned(stderr: Fixture.unsignedDisplay, exit: 1),
            gatekeeper: canned(stderr: Fixture.barSpctlRejectedUnsigned, exit: 3),
            entitlements: canned(stderr: Fixture.unsignedDisplay, exit: 1))
        let probeDir = try makeProbeDir()
        defer { try? FileManager.default.removeItem(at: probeDir) }
        let report = await SecInspector.inspect(appAt: probeDir, using: runner)
        #expect(report.signaturePresent == false)
        #expect(report.notes.contains { $0.contains("the bundle is not signed (exit 1)")
            && $0.contains("code object is not signed at all") })
        #expect(report.codesignValid == false)
        #expect(report.gatekeeperAssessment == .rejected)
        #expect(report.gatekeeperSource == "no usable signature")
        #expect(report.teamIdentifier == nil)
        #expect(report.signatureAuthorities.isEmpty)
        #expect(report.entitlementsPresent == nil) // unreadable, not absent
        #expect(report.sandboxed == nil)
        #expect(report.notes.contains { $0.contains("entitlements unreadable") })
    }

    @Test func entitlementsDERFallbackPath() async throws {
        // Realistic variant of the pre-macOS-12.3 behavior: the `:-` form
        // emits DER (unparseable text here), the `:-:xml` fallback decodes.
        let runner = stubRunner(
            display: canned(stderr: Fixture.capyDisplay),
            verify: canned(),
            gatekeeper: canned(stderr: Fixture.capySpctlAccepted),
            entitlements: canned("\u{30}\u{82}der-ish-bytes\n"),
            entitlementsFallback: canned(Fixture.sandboxedEntitlementsXML))
        let report = await SecInspector.inspect(appAt: URL(fileURLWithPath: "/Applications/Capy.app"), using: runner)
        #expect(report.entitlementsPresent == true)
        #expect(report.sandboxed == true)
        #expect(report.keychainAccessGroupsCount == 2)
        #expect(report.notes.contains { $0.contains("':-:xml' fallback") })
    }

    @Test func entitlementsAbsentWhenBothFormsSilent() async throws {
        let runner = stubRunner(
            display: canned(stderr: Fixture.binAdHocDisplay),
            verify: canned(),
            gatekeeper: canned(stderr: Fixture.binSpctlRejected, exit: 3),
            entitlements: canned(),
            entitlementsFallback: canned())
        let probeDir = try makeProbeDir()
        defer { try? FileManager.default.removeItem(at: probeDir) }
        let report = await SecInspector.inspect(appAt: probeDir, using: runner)
        #expect(report.entitlementsPresent == false)
        #expect(report.sandboxed == false)
        #expect(report.entitlementKeys.isEmpty)
        #expect(report.keychainAccessGroupsCount == nil)
        #expect(report.notes.contains { $0.contains("bundle carries no entitlements") })
    }

    @Test func entitlementsFallbackLaunchFailureIsUnreadable() async throws {
        // The primary form yields no plist and the fallback cannot spawn: the
        // verdict stays unreadable (nil), never a guessed absence.
        let runner = stubRunner(
            display: canned(stderr: Fixture.capyDisplay),
            verify: canned(),
            gatekeeper: canned(stderr: Fixture.capySpctlAccepted),
            entitlements: canned("\u{30}\u{82}der-ish-bytes\n"))
        let report = await SecInspector.inspect(appAt: URL(fileURLWithPath: "/Applications/Capy.app"), using: runner)
        #expect(report.entitlementsPresent == nil)
        #expect(report.sandboxed == nil)
        #expect(report.notes.contains { $0.contains("fallback probe could not be launched") })
    }

    @Test func keychainNonArrayNoteSurfaces() async throws {
        let runner = stubRunner(
            display: canned(stderr: Fixture.binAdHocDisplay),
            verify: canned(),
            gatekeeper: canned(stderr: Fixture.binSpctlRejected, exit: 3),
            entitlements: canned(Fixture.keychainNonArrayEntitlementsXML))
        let probeDir = try makeProbeDir()
        defer { try? FileManager.default.removeItem(at: probeDir) }
        let report = await SecInspector.inspect(appAt: probeDir, using: runner)
        #expect(report.entitlementsPresent == true)
        #expect(report.sandboxed == true)
        #expect(report.keychainAccessGroupsCount == nil)
        #expect(report.notes.contains { $0.contains("keychain-access-groups entitlement present but not an array") })
    }

    @Test func multiSignatureDisplayAddsNote() async throws {
        // Realistic variant (codesign prints Total signatures=2 for universal
        // binaries' chosen display): the note must say only the chosen one
        // was parsed.
        let display = Fixture.binAdHocDisplay
            .replacingOccurrences(of: "Total signatures=1", with: "Total signatures=2")
        let runner = stubRunner(
            display: canned(stderr: display),
            verify: canned(),
            gatekeeper: canned(stderr: Fixture.binSpctlRejected, exit: 3),
            entitlements: canned(),
            entitlementsFallback: canned())
        let probeDir = try makeProbeDir()
        defer { try? FileManager.default.removeItem(at: probeDir) }
        let report = await SecInspector.inspect(appAt: probeDir, using: runner)
        #expect(report.notes.contains {
            $0.contains("2 signatures") && $0.contains("Chosen signature=1")
        })
    }

    @Test func missingFlagsFieldWithholdsHardened() async throws {
        // Trimmed-real variant: a display with no CodeDirectory line at all.
        let trimmed = Fixture.binAdHocDisplay
            .split(separator: "\n")
            .filter { !$0.contains("CodeDirectory") }
            .joined(separator: "\n")
        let runner = stubRunner(
            display: canned(stderr: trimmed),
            verify: canned(),
            gatekeeper: canned(stderr: Fixture.binSpctlRejected, exit: 3),
            entitlements: canned(),
            entitlementsFallback: canned())
        let probeDir = try makeProbeDir()
        defer { try? FileManager.default.removeItem(at: probeDir) }
        let report = await SecInspector.inspect(appAt: probeDir, using: runner)
        #expect(report.hardenedRuntime == nil)
        #expect(report.notes.contains { $0.contains("hardened-runtime verdict withheld") })
    }

    @Test func everyProbeThrowingBecomesFourNotes() async throws {
        let probeDir = try makeProbeDir()
        defer { try? FileManager.default.removeItem(at: probeDir) }
        let report = await SecInspector.inspect(
            appAt: probeDir,
            using: stubRunner()) // every probe throws ProbeStubMiss
        #expect(report.signaturePresent == nil)
        #expect(report.codesignValid == nil)
        #expect(report.gatekeeperAssessment == .unknown)
        #expect(report.entitlementsPresent == nil)
        #expect(report.sandboxed == nil)
        #expect(report.notes.count == 4)
        #expect(report.notes.contains { $0.contains("codesign -dv could not be launched") })
        #expect(report.notes.contains { $0.contains("codesign --verify could not be launched") })
        #expect(report.notes.contains { $0.contains("spctl could not be launched") })
        #expect(report.notes.contains { $0.contains("codesign --entitlements could not be launched") })
    }

    @Test func missingBundleRunsNoProbes() async throws {
        let counter = InvokeCounter()
        let runner = SecProcessRunner { _, _ in
            counter.bump()
            return canned()
        }
        let missing = URL(fileURLWithPath: "/tmp/appupdater-secpanel-does-not-exist-\(UUID().uuidString).app")
        let report = await SecInspector.inspect(appAt: missing, using: runner)
        #expect(counter.isUntouched) // short-circuit before any probe
        #expect(report.notes == ["app bundle not found — no probes run: \(missing.path)"])
        #expect(report.signaturePresent == nil)
        #expect(report.codesignValid == nil)
        #expect(report.gatekeeperAssessment == .unknown)
    }

    @Test func plainFileAppRunsNoProbes() async throws {
        let counter = InvokeCounter()
        let runner = SecProcessRunner { _, _ in
            counter.bump()
            return canned()
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appupdater-secpanel-parse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Fake.app")
        try Data("junk".utf8).write(to: fileURL)
        let report = await SecInspector.inspect(appAt: fileURL, using: runner)
        #expect(counter.isUntouched)
        #expect(report.notes.count == 1)
        #expect(report.notes[0].contains("not a bundle directory"))
    }

    // MARK: SecReport shape

    @Test func secReportCodableRoundTrip() async throws {
        let runner = stubRunner(
            display: canned(stderr: Fixture.capyDisplay),
            verify: canned(),
            gatekeeper: canned(stderr: Fixture.capySpctlAccepted),
            entitlements: canned(Fixture.sandboxedEntitlementsXML))
        let report = await SecInspector.inspect(appAt: URL(fileURLWithPath: "/Applications/Capy.app"), using: runner)
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(SecReport.self, from: data)
        #expect(decoded == report) // Codable + Hashable: field-for-field equal
    }

    @Test func secReportEqualityDistinguishesFields() async throws {
        var a = SecReport(appPath: "/Applications/X.app")
        var b = a
        #expect(a == b)
        b.codesignValid = true
        #expect(a != b)
        a.codesignValid = true
        #expect(a == b)
        a.notes.append("codesign --verify --deep --strict failed (exit 1): tampered")
        #expect(a != b) // notes are part of identity
    }
}

// MARK: - Sendable invoke counter

/// Counts seam invocations from concurrent probes without data races.
/// `@unchecked` because NSLock guards the one mutable field.
private final class InvokeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var countValue = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return countValue
    }

    /// True when nothing was invoked — reads clearer than `count == 0` (and
    /// keeps the empty_count lint honest about what this is).
    var isUntouched: Bool {
        count == 0
    }

    func bump() {
        lock.lock()
        defer { lock.unlock() }
        countValue += 1
    }
}
