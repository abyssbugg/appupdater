// GlueWireJSONTests.swift — glue-wiring lane: wire-shape pins for the JSON
// and dictionary contracts the NEW glue surfaces render (the app's
// security/brew/proxy panels and the CLI's security/brew-pins/brew-doctor/
// proxy-show modes). The glue itself lives in the app/CLI targets, which the
// package's single test target cannot link (Package.swift is frozen) — these
// pins hold the Core-level CONTRACTS that glue renders, so a wire change
// fails here instead of silently re-shaping a shipped report.
//
// Swift Testing only (XCTest discovery broken here). Hermetic: a temp
// directory for the candidate-filter probe, no network, no keychain, no
// system-state mutation (the proxy dictionary assertions are pure value
// checks; the keychain pins are static-string namespace checks only).

import Foundation
import Testing
@testable import AppUpdaterCore

@Suite("Glue wiring — wire shapes")
struct GlueWireJSONTests {

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Top-level JSON keys of `data` (empty on any parse failure — the
    /// #expect against an expected set then fails with the reason visible).
    private static func topLevelKeys(_ data: Data) -> Set<String> {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            .map { Set($0.keys) } ?? []
    }

    // MARK: SecReport (the security panel's per-app report)

    /// The security card and `security` mode render the full SecReport field
    /// set — the wire shape is pinned key-for-key so no field can silently
    /// vanish from the surfaces (and the round trip proves what was rendered
    /// is what was inspected).
    @Test func secReportJSONCarriesTheFullWireFieldSet() throws {
        var report = SecReport(appPath: "/Applications/Fixture.app")
        report.signaturePresent = true
        report.codesignValid = true
        report.gatekeeperAssessment = .accepted
        report.gatekeeperSource = "Notarized Developer ID"
        report.gatekeeperOrigin = "Origin Label"
        report.signatureAuthorities = ["Developer ID Application: Fixture (TEAM1234)"]
        report.teamIdentifier = "TEAM1234"
        report.signedIdentifier = "com.example.fixture"
        report.executablePath = "/Applications/Fixture.app/Contents/MacOS/Fixture"
        report.cdHash = "abcd-1234"
        report.timestamp = "2026-01-01 00:00:00 +0000"
        report.notarizationTicket = "stapled"
        report.hardenedRuntime = true
        report.linkerSigned = false
        report.isAdHoc = false
        report.runtimeVersion = "14.0"
        report.entitlementKeys = ["com.apple.security.app-sandbox"]
        report.entitlementsPresent = true
        report.sandboxed = true
        report.keychainAccessGroupsCount = 2
        report.notes = ["probe note one", "probe note two"]

        let data = try Self.encoder.encode(report)
        let expected: Set<String> = [
            "appPath", "signaturePresent", "codesignValid", "gatekeeperAssessment",
            "gatekeeperSource", "gatekeeperOrigin", "signatureAuthorities", "teamIdentifier",
            "signedIdentifier", "executablePath", "cdHash", "timestamp", "notarizationTicket",
            "hardenedRuntime", "linkerSigned", "isAdHoc", "runtimeVersion", "entitlementKeys",
            "entitlementsPresent", "sandboxed", "keychainAccessGroupsCount", "notes",
        ]
        #expect(Self.topLevelKeys(data) == expected)
        #expect(try Self.decoder.decode(SecReport.self, from: data) == report)
    }

    // MARK: CandidateFilterReport (the candidates lane's receipts)

    /// Per-detector receipts + the combined overall verdict, over a real
    /// (hermetic temp) path: the documented negative case for all three
    /// detectors on an empty directory — installer-bundle name miss,
    /// InstallBuilder markers absent, no Electron payload shapes — and the
    /// wire keys exactly.
    @Test func candidateFilterReportJSONCarriesPerDetectorReceipts() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glue-wire-candidate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let report = CandidateFilter.filter(candidateURL: dir)
        #expect(report.installerBundle.outcome == .accept)
        #expect(report.installBuilder.outcome == .accept)
        #expect(report.electronWrongArch.outcome == .notApplicable)
        #expect(report.overall.outcome == .accept)

        let data = try Self.encoder.encode(report)
        #expect(
            Self.topLevelKeys(data)
                == ["candidatePath", "overall", "installerBundle", "installBuilder", "electronWrongArch"])

        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let overall = try #require(object["overall"] as? [String: Any])
        // Accept verdicts carry a nil reason — and synthesized Codable omits
        // nil optionals from the wire (`encodeIfPresent`), so "reason" is
        // absent here. Its presence is pinned by the reject case below.
        #expect(Set(overall.keys) == ["outcome", "notes"])
        #expect(overall["outcome"] as? String == "accept")
        #expect(report.candidatePath == dir.path)
    }

    /// A documented REJECT (installer-bundle name match) rides through the
    /// wire with its reason — the receipt the install reports carry.
    @Test func candidateFilterRejectCarriesReasonThroughJSON() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("installer", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let report = CandidateFilter.filter(candidateURL: dir)
        #expect(report.overall.outcome == .reject)
        #expect(report.overall.reason?.contains("documented installer-bundle name") == true)

        let data = try Self.encoder.encode(report)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let overall = try #require(object["overall"] as? [String: Any])
        #expect(overall["outcome"] as? String == "reject")
        let reason = try #require(overall["reason"] as? String)
        #expect(reason.contains("documented installer-bundle name"))
    }

    // MARK: SystemProxySnapshot (the read-only system picture)

    /// The snapshot's Codable wire shape (the proxy sheet and `proxy show`
    /// render it as-is) + the documented display phrasings.
    @Test func systemProxySnapshotJSONWireShape() throws {
        let snapshot = SystemProxySnapshot(
            http: SystemProxyEntry(host: "127.0.0.1", port: 8080),
            https: nil, socks5: nil,
            exclusions: ["*.local"], pacURL: nil, notes: [])
        let data = try Self.encoder.encode(snapshot)
        // Synthesized Codable omits nil optionals: only the non-nil http
        // entry survives on the wire alongside the always-present arrays.
        #expect(Self.topLevelKeys(data) == ["http", "exclusions", "notes"])
        #expect(snapshot.detectedDescription == "Proxy detected: http 127.0.0.1:8080")
        #expect(SystemProxySnapshot().detectedDescription == "No system proxy detected")

        let decoded = try Self.decoder.decode(SystemProxySnapshot.self, from: data)
        #expect(decoded == snapshot)
    }

    // MARK: ProxySettings (the persisted settings contract)

    /// The settings JSON carries exactly the documented five keys, mode
    /// rawValues are wire-stable, and the decode tolerance decodes a
    /// key-poor file to honest defaults (never fails the whole file).
    @Test func proxySettingsJSONWireShapeAndDecodeTolerance() throws {
        let settings = ProxySettings(
            mode: .manual,
            http: ProxyProtocolEntry(host: "proxy.local", port: 8080, authRequired: true),
            https: nil, socks5: nil, pacURL: nil)
        let data = try Self.encoder.encode(settings)
        // Synthesized encode omits nil optionals (`encodeIfPresent`): the
        // wire carries only mode + the configured http entry here. (The
        // decode side tolerates all keys missing — pinned below.)
        #expect(Self.topLevelKeys(data) == ["mode", "http"])
        #expect(try Self.decoder.decode(ProxySettings.self, from: data) == settings)

        let partial = Data("{\"mode\":\"none\"}".utf8)
        let decoded = try Self.decoder.decode(ProxySettings.self, from: partial)
        #expect(decoded == ProxySettings(mode: .none))

        #expect(ProxyMode.system.rawValue == "system")
        #expect(ProxyMode.manual.rawValue == "manual")
        #expect(ProxyMode.none.rawValue == "none")
    }

    // MARK: ProxyConfiguration (the session adoption contract)

    /// The documented mode → dictionary semantics the ProxySessionController
    /// adopts verbatim: .system → nil, .none → empty dictionary, .manual →
    /// exactly the configured protocol's three documented keys.
    @Test func connectionProxyDictionaryModeSemantics() throws {
        #expect(try ProxyConfiguration.connectionProxyDictionary(for: ProxySettings()) == nil)
        #expect(
            try ProxyConfiguration.connectionProxyDictionary(for: ProxySettings(mode: .none))?
                .isEmpty == true)

        let manual = ProxySettings(
            mode: .manual,
            http: ProxyProtocolEntry(host: "proxy.local", port: 8080),
            https: nil, socks5: nil, pacURL: nil)
        let dictionary = try #require(
            ProxyConfiguration.connectionProxyDictionary(for: manual) as [AnyHashable: Any]?)
        #expect(
            Set(dictionary.keys)
                == Set([
                    SystemProxyParser.Keys.httpEnable,
                    SystemProxyParser.Keys.httpHost,
                    SystemProxyParser.Keys.httpPort,
                ]))
        #expect(dictionary[SystemProxyParser.Keys.httpHost] as? String == "proxy.local")
        #expect(dictionary[SystemProxyParser.Keys.httpPort] as? Int == 8080)
    }

    /// Invalid settings THROW with the documented "Invalid proxy
    /// configuration" text — never a half dictionary (the app's session
    /// adoption surfaces this verbatim and applies nothing).
    @Test func invalidSettingsThrowTheDocumentedReason() {
        let invalid = ProxySettings(
            mode: .manual,
            http: ProxyProtocolEntry(host: "", port: 8080),
            https: nil, socks5: nil, pacURL: nil)
        do {
            _ = try ProxyConfiguration.connectionProxyDictionary(for: invalid)
            Issue.record("expected a throw for invalid settings")
        } catch let error as ProxyConfigurationError {
            #expect(error.reason.hasPrefix("Invalid proxy configuration"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    /// The PAC honesty note the adoption surfaces in .system mode (verbatim).
    @Test func pacLimitationNoteIsSurfacedVerbatim() {
        #expect(
            ProxyConfiguration.pacLimitationNote
                == "PAC evaluation not performed (not implemented); system-level URLSession "
                    + "falls back to system PAC handling")
    }

    // MARK: Verdict-enum rawValues (the glue surfaces' rendered words)

    /// The verdict words the glue surfaces render verbatim are wire-stable:
    /// GatekeeperAssessment rides the `security` JSON through SecReport's
    /// synthesized Codable, and CandidateFilterOutcome rides the
    /// `install --apply` JSON through CandidateFilterReport's — both also
    /// appear as rendered `.rawValue` strings on the app's inspector card.
    /// A rename here would silently re-shape every glue surface.
    @Test func verdictEnumRawValuesAreWireStable() {
        #expect(SecReport.GatekeeperAssessment.accepted.rawValue == "accepted")
        #expect(SecReport.GatekeeperAssessment.rejected.rawValue == "rejected")
        #expect(SecReport.GatekeeperAssessment.unknown.rawValue == "unknown")

        #expect(CandidateFilterOutcome.accept.rawValue == "accept")
        #expect(CandidateFilterOutcome.reject.rawValue == "reject")
        #expect(CandidateFilterOutcome.unknown.rawValue == "unknown")
        #expect(CandidateFilterOutcome.notApplicable.rawValue == "notApplicable")
    }

    // MARK: ProxyKeychain namespace (the credential seam's wire stability)

    /// Static-string pins only — no keychain access. The account namespace
    /// and service name are the documented contract the Proxy sheet's
    /// credential rows (and nothing else) depend on.
    @Test func proxyKeychainNamespaceIsWireStable() {
        #expect(ProxyKeychain.service == "io.appupdater.AppUpdater.proxy")
        #expect(ProxyKeychain.account(for: .http) == "proxy.http")
        #expect(ProxyKeychain.account(for: .https) == "proxy.https")
        #expect(ProxyKeychain.account(for: .socks5) == "proxy.socks5")
    }
}
