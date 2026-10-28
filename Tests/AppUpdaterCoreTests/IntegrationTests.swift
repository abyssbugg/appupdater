// Integration tests — cross-lane: scanner (lane A) → sources (lanes B/C/D) →
// VersionOracle resolution (lane E), through UpdateCheckEngine.
// Hermetic: custom URLProtocol stub, no network. Swift Testing only (XCTest broken here).

import Foundation
import Testing
@testable import AppUpdaterCore

// MARK: - Multi-source routing stub (pattern mirrors lane B's StubURLProtocol)

final class MultiSourceStubURLProtocol: URLProtocol {
    struct StubResponse: Sendable {
        let status: Int
        let body: Data
    }

    private static let box = LockedBox<[String: StubResponse]>([:])

    static func reset() {
        box.with { routes in routes = [:] }
    }

    static func stub(_ body: String, status: Int = 200, for absoluteURL: String) {
        box.with { routes in
            routes[absoluteURL] = StubResponse(status: status, body: Data(body.utf8))
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    // See gotcha ledger: CFNetwork teardown requires the no-op override.
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let stub = Self.box.with { routes in routes[url.absoluteString] }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub?.status ?? 404,  // unregistered ⇒ honest absence (404)
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
        guard let response, let client else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body = stub?.body { client.urlProtocol(self, didLoad: body) }
        client.urlProtocolDidFinishLoading(self)
    }
}

private func stubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MultiSourceStubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private let sparkleSessionClasses: [AnyClass] = [MultiSourceStubURLProtocol.self]

// MARK: - Fixture builders

private enum Fixture {
    /// Builds a physical .app bundle and returns its URL. Real files on disk so the
    /// scanner lane runs against genuine bytes, not against constructed structs.
    static func makeApp(
        in root: URL,
        name: String,
        bundleID: String,
        shortVersion: String?,
        bundleVersion: String?,
        sparkleFeed: String?,
        masReceipt: Bool
    ) throws -> URL {
        let appURL = root.appendingPathComponent("\(name).app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        if masReceipt {
            let receiptDir = appURL.appendingPathComponent("Contents/_MASReceipt", isDirectory: true)
            try FileManager.default.createDirectory(at: receiptDir, withIntermediateDirectories: true)
            try Data("receipt".utf8).write(to: receiptDir.appendingPathComponent("_MASReceipt"))
        }

        var plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key><string>\(name)</string>
            <key>CFBundleIdentifier</key><string>\(bundleID)</string>
        """
        if let shortVersion { plist += "\n    <key>CFBundleShortVersionString</key><string>\(shortVersion)</string>" }
        if let bundleVersion { plist += "\n    <key>CFBundleVersion</key><string>\(bundleVersion)</string>" }
        if let sparkleFeed { plist += "\n    <key>SUFeedURL</key><string>\(sparkleFeed)</string>" }
        plist += "\n</dict>\n</plist>\n"

        try plist.write(
            to: appURL.appendingPathComponent("Contents/Info.plist"),
            atomically: true,
            encoding: .utf8
        )
        return appURL
    }
}

private let firefoxAppcast = """
<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:sparkle="http://www.sparkle-project.org/xml/sparkle/2008" version="2.0">
  <channel>
    <title>Firefox</title>
    <item>
      <title>Firefox 139.0</title>
      <pubDate>Wed, 09 Oct 2024 10:00:00 +0000</pubDate>
      <enclosure url="https://download.mozilla.org/139.dmg" sparkle:version="139.0" sparkle:shortVersionString="139.0" sparkle:edSignature="AAABBBCCCDDDEEEFFFGGGHHHIIJJJZZZ=" type="application/octet-stream"/>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
"""

private let itchAppcast = """
<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:sparkle="http://www.sparkle-project.org/xml/sparkle/2008" version="2.0">
  <channel>
    <title>itch</title>
    <item>
      <title>itch 2.2</title>
      <pubDate>Fri, 11 Oct 2024 12:00:00 +0000</pubDate>
      <enclosure url="https://dl.itch.local/2.2.zip" sparkle:version="2.2" sparkle:shortVersionString="2.2" sparkle:edSignature="KEYKEYKEYKEYKEYKEYKEYKEY12345678=" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
"""

private let firefoxCaskJSON = """
{
  "token": "firefox",
  "name": "Firefox",
  "desc": "Fast and open-source browser",
  "homepage": "https://www.mozilla.org/firefox/",
  "url": "https://download.mozilla.org/Firefox.dmg",
  "version": "140.0",
  "sha256": "9f8f1c0f7b3a4d5e6f7089f2a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0",
  "artifacts": [{"app": ["Firefox.app"]}]
}
"""

private struct ItunesEnvelope: Encodable {
    let resultCount: Int
    let results: [Result]
    struct Result: Encodable {
        let bundleId: String
        let trackName: String
        let version: String
        let minimumOsVersion: String
        let trackId: Int64
        let currentVersionReleaseDate: String
        let releaseNotes: String
        let trackViewUrl: String
    }
}

private let caskBase = "https://formulae.brew.sh/api/cask/"

@Suite(.serialized)
struct IntegrationTests {
    /// Workspace is wiped at each init, so garbage from a previous run never
    /// leaks into assertions (no deinit — structs can't have one here). The
    /// NAME is unique per PROCESS (static = computed once): concurrent
    /// `swift test` runners each own their directory, so one runner's init
    /// wipe can never delete another's live fixtures — fixed shared roots
    /// used to do exactly that (the Phase-4 cross-process flake; see
    /// AGENTS.md gotcha ledger).
    private static let sharedRoot: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("appupdater-integration-\(UUID().uuidString)", isDirectory: true)
    private var root: URL = Self.sharedRoot

    init() {
        // Stub-owned state is suite-shared; .serialized keeps tests deterministic.
        MultiSourceStubURLProtocol.reset()
        try? FileManager.default.removeItem(at: Self.sharedRoot)
        try? FileManager.default.createDirectory(at: Self.sharedRoot, withIntermediateDirectories: true)
        root = Self.sharedRoot
    }

    // MARK: Engine source ordering

    @Test func engineSortsSourcesIntoLockedPrecedence() {
        let engine = UpdateCheckEngine(sources: [
            MASSource(session: stubbedSession()),
            SparkleSource(urlProtocolClasses: sparkleSessionClasses),
            CaskSource(session: stubbedSession()),
        ])
        #expect(engine.sortedSources.map { $0.kindValue } == [.cask, .sparkle, .mas])
    }

    // MARK: End-to-end candidates + resolution

    @Test func firefoxFlowCaskBeatsSparkleByPrecedence() async throws {
        MultiSourceStubURLProtocol.stub(firefoxCaskJSON, for: caskBase + "firefox.json")
        MultiSourceStubURLProtocol.stub(firefoxAppcast, for: "https://fixtures.local/sparkle/appcast.xml")
        MultiSourceStubURLProtocol.stub(
            #"{"resultCount":0,"results":[]}"#,
            for: "https://itunes.apple.com/lookup?bundleId=org.mozilla.firefox&country=us"
        )

        _ = try Fixture.makeApp(
            in: root,
            name: "Firefox",
            bundleID: "org.mozilla.firefox",
            shortVersion: "1.0",
            bundleVersion: "10",
            sparkleFeed: "https://fixtures.local/sparkle/appcast.xml",
            masReceipt: false
        )

        let apps = try await ProductionAppScanner().scan(directoryURLs: [root])
        #expect(apps.count == 1)
        let app = try #require(apps.first)
        #expect(app.bundleIdentifier == "org.mozilla.firefox")
        #expect(app.isMacAppStore == false)

        // LANE CONTRACT: Sparkle selectNewest compares sparkle:version against the
        // INSTALLER-facing bundleVersion ("10"), so 139.0 is a genuine newer claim;
        // the resolver then compares short versions ("1.0" vs candidates).
        let engine = UpdateCheckEngine(sources: [
            CaskSource(session: stubbedSession()),
            SparkleSource(urlProtocolClasses: sparkleSessionClasses),
            MASSource(session: stubbedSession()),
        ])
        let check = await engine.check(app: app)

        #expect(check.candidates.map { $0.source } == [.cask, .sparkle])
        let resolved = try #require(check.resolved)
        #expect(resolved.source == .cask)                  // strongest source's verdict wins
        #expect(resolved.newestShortVersion == "140.0")    // NOT overridden by sparkle 139.0
        #expect(resolved.sha256Hex?.count == 64)           // cask sha256 surfaced
        #expect(check.verdict == "update")
    }

    @Test func sparkOnlyAppResolvesFromFeed() async throws {
        MultiSourceStubURLProtocol.stub(
            itchAppcast,
            for: "https://fixtures.local/sparkle/itchappcast.xml"
        )
        // cask route for "itch" intentionally UNregistered → 404 → honest nil claim.

        _ = try Fixture.makeApp(
            in: root,
            name: "Itch",
            bundleID: "io.itch.test",
            shortVersion: nil,
            bundleVersion: nil,
            sparkleFeed: "https://fixtures.local/sparkle/itchappcast.xml",
            masReceipt: false
        )
        let apps = try await ProductionAppScanner().scan(directoryURLs: [root])
        let app = try #require(apps.first)

        let engine = UpdateCheckEngine(sources: [
            CaskSource(session: stubbedSession()),
            SparkleSource(urlProtocolClasses: sparkleSessionClasses),
            MASSource(session: stubbedSession()),
        ])
        let check = await engine.check(app: app)

        let resolved = try #require(check.resolved)
        #expect(resolved.source == .sparkle)
        #expect(resolved.newestShortVersion == "2.2")
        #expect(resolved.downloadURL == URL(string: "https://dl.itch.local/2.2.zip"))
        #expect(resolved.confidence == .high)  // plausible EdDSA signature shape on the item
        #expect(check.verdict == "update")
    }

    @Test func masAppResolvesFromITunesLookup() async throws {
        let lookup = ItunesEnvelope(
            resultCount: 1,
            results: [
                .init(
                    bundleId: "com.fake.masapp",
                    trackName: "MasApp",
                    version: "6.2",
                    minimumOsVersion: "15.0",
                    trackId: 1_234_567,
                    currentVersionReleaseDate: "2024-10-01T00:00:00Z",
                    releaseNotes: "Fixes and improvements.",
                    trackViewUrl: "https://apps.apple.com/us/app/id1234567"
                )
            ]
        )
        let data = try JSONEncoder().encode(lookup)
        MultiSourceStubURLProtocol.stub(
            String(decoding: data, as: UTF8.self),
            for: "https://itunes.apple.com/lookup?bundleId=com.fake.masapp&country=us"
        )

        _ = try Fixture.makeApp(
            in: root,
            name: "MasApp",
            bundleID: "com.fake.masapp",
            shortVersion: "6.1",
            bundleVersion: "61",
            sparkleFeed: nil,
            masReceipt: true
        )
        let apps = try await ProductionAppScanner().scan(directoryURLs: [root])
        let app = try #require(apps.first)
        #expect(app.isMacAppStore)  // scanner detected the receipt — cross-lane contract

        let engine = UpdateCheckEngine(sources: [
            CaskSource(session: stubbedSession()),
            SparkleSource(urlProtocolClasses: sparkleSessionClasses),
            MASSource(session: stubbedSession()),
        ])
        let check = await engine.check(app: app)

        let resolved = try #require(check.resolved)
        #expect(resolved.source == .mas)
        #expect(resolved.confidence == .high)  // first-party Apple data
        #expect(resolved.downloadURL == nil)   // no legit direct download from lookup
        #expect(resolved.sourceDetail?.contains("trackId") == true)
        #expect(check.verdict == "update")
    }

    @Test func fullyUnknownAppIsHonest() async throws {
        MultiSourceStubURLProtocol.stub(
            #"{"resultCount":0,"results":[]}"#,
            for: "https://itunes.apple.com/lookup?bundleId=org.fake.nocando&country=us"
        )
        _ = try Fixture.makeApp(
            in: root,
            name: "Nocando",
            bundleID: "org.fake.nocando",
            shortVersion: "1.0",
            bundleVersion: "1",
            sparkleFeed: nil,
            masReceipt: false
        )
        let apps = try await ProductionAppScanner().scan(directoryURLs: [root])
        let app = try #require(apps.first)

        let engine = UpdateCheckEngine(sources: [
            CaskSource(session: stubbedSession()),
            SparkleSource(urlProtocolClasses: sparkleSessionClasses),
            MASSource(session: stubbedSession()),
        ])
        let check = await engine.check(app: app)

        #expect(check.resolved == nil)
        #expect(check.candidates.isEmpty)
        #expect(check.failures.isEmpty)
        #expect(check.verdict == "unknown")  // truthfully "nothing is known" — never faked
    }

    @Test func verdictFieldIsHonestAndEncoded() throws {
        let app = InstalledApp(bundleIdentifier: "io.test.verdict", name: "Verdict App", path: "/tmp/Verdict.app")

        func verdictFor(resolved: UpdateInfo?, candidates: [UpdateInfo], failures: [CheckSourceFailure] = []) throws -> String {
            let updateCheck = UpdateCheck(app: app, candidates: candidates, failures: failures, resolved: resolved)
            // Verdict must survive the JSON round-trip — gate reports are consumed by machines.
            let roundTrip = try JSONDecoder().decode(UpdateCheck.self, from: try JSONEncoder().encode(updateCheck))
            #expect(roundTrip.verdict == updateCheck.verdict)
            return updateCheck.verdict
        }

        let info = UpdateInfo(source: .cask, newestShortVersion: "2.0")
        let thrown = CheckSourceFailure(kind: .mas, message: "boom")

        #expect(try verdictFor(resolved: info, candidates: [info], failures: []) == "update")
        #expect(try verdictFor(resolved: nil, candidates: [info], failures: []) == "current")
        #expect(try verdictFor(resolved: nil, candidates: [], failures: []) == "unknown")
        #expect(try verdictFor(resolved: nil, candidates: [], failures: [thrown]) == "failed")
    }

    @Test func throwingSourceIsRecordedOthersCarryOn() async throws {
        MultiSourceStubURLProtocol.stub(firefoxCaskJSON, for: caskBase + "firefox.json")
        MultiSourceStubURLProtocol.stub(
            #"{"resultCount":0,"results":[]}"#,
            for: "https://itunes.apple.com/lookup?bundleId=org.mozilla.firefox&country=us"
        )
        _ = try Fixture.makeApp(
            in: root,
            name: "Firefox",
            bundleID: "org.mozilla.firefox",
            shortVersion: "1.0",
            bundleVersion: "10",
            sparkleFeed: nil,   // no sparkle claim path — isolates the throw behavior
            masReceipt: false
        )
        let apps = try await ProductionAppScanner().scan(directoryURLs: [root])
        let app = try #require(apps.first)

        struct AlwaysThrowing: UpdateSource {
            static var kind: SourceKind { .github }
            func fetchUpdateInfo(for app: InstalledApp) async throws -> UpdateInfo? {
                throw URLError(.timedOut)
            }
        }

        let engine = UpdateCheckEngine(sources: [
            CaskSource(session: stubbedSession()),
            AlwaysThrowing(),
            MASSource(session: stubbedSession()),
        ])
        let check = await engine.check(app: app)

        #expect(check.failures.count == 1)
        #expect(check.failures.first?.kind == .github)
        #expect(check.candidates.map { $0.source } == [.cask])  // cask still delivered its claim
        #expect(check.resolved?.source == .cask)
        #expect(check.verdict == "update")
    }

    // MARK: Manual-source pin seam (manual-over-builtin, gap sprint)

    /// Hit counter shared with the fake sources (probe sematics only).
    private actor ManualPinProbeCounter {
        var hits = 0
        func hit() { hits += 1 }
        func value() -> Int { hits }
    }

    /// Fake built-in (.cask) with a claim the pin must NOT compete against.
    private struct ManualPinBuiltinSource: UpdateSource {
        static var kind: SourceKind { .cask }
        var counter: ManualPinProbeCounter
        var claim: UpdateInfo?
        func fetchUpdateInfo(for app: InstalledApp) async throws -> UpdateInfo? {
            await counter.hit()
            return claim
        }
    }

    /// Fake pinned source (.github) — inserts a claim or throws.
    private struct ManualPinStubSource: UpdateSource {
        static var kind: SourceKind { .github }
        var counter: ManualPinProbeCounter
        var claim: UpdateInfo?
        func fetchUpdateInfo(for app: InstalledApp) async throws -> UpdateInfo? {
            await counter.hit()
            return claim
        }
    }

    /// Fake pinned source that throws verbatim.
    private struct ManualPinThrowSource: UpdateSource {
        static var kind: SourceKind { .github }
        var counter: ManualPinProbeCounter
        func fetchUpdateInfo(for app: InstalledApp) async throws -> UpdateInfo? {
            await counter.hit()
            throw URLError(.timedOut)
        }
    }

    @Test func manualPinSuppressesBuiltinsAndWinsVerdict() async {
        let builtin = ManualPinProbeCounter()
        let pinned = ManualPinProbeCounter()
        let engine = UpdateCheckEngine(
            sources: [ManualPinBuiltinSource(counter: builtin, claim: UpdateInfo(source: .cask, newestShortVersion: "9.9"))],
            manualSource: ManualSourceResolver { _ in
                ManualPinStubSource(counter: pinned, claim: UpdateInfo(source: .github, newestShortVersion: "2.0"))
            }
        )
        let app = InstalledApp(bundleIdentifier: "io.test.pin", name: "ManualApp", path: "/tmp/ManualPin.app", shortVersion: "1.0")
        let check = await engine.check(app: app)

        // The builtin's 9.9 claim would beat 2.0 on any consulted path — the
        // fact that `.github`/2.0 wins proves the builtin was never queried.
        #expect(check.resolved?.source == .github)
        #expect(check.resolved?.newestShortVersion == "2.0")
        #expect(check.candidates.map { $0.source } == [.github])
        #expect(await pinned.value() == 1)
        #expect(await builtin.value() == 0)
        #expect(check.verdict == "update")
    }

    @Test func manualPinEqualVersionIsCurrentNotUpdate() async {
        let pinned = ManualPinProbeCounter()
        let engine = UpdateCheckEngine(
            sources: [],
            manualSource: ManualSourceResolver { _ in
                ManualPinStubSource(counter: pinned, claim: UpdateInfo(source: .github, newestShortVersion: "1.0"))
            }
        )
        let app = InstalledApp(bundleIdentifier: "io.test.pin.eq", name: "ManualApp", path: "/tmp/ManualPin.app", shortVersion: "1.0")
        let check = await engine.check(app: app)

        // A pin never manufactures an update the installed version refutes:
        // strictly-greater gate still applies at resolve time.
        #expect(check.resolved == nil)
        #expect(check.candidates.count == 1)
        #expect(check.failures.isEmpty)
        #expect(check.verdict == "current")
    }

    @Test func manualPinAbsentYieldsBuiltinsUnchanged() async {
        let builtin = ManualPinProbeCounter()
        let engine = UpdateCheckEngine(
            sources: [ManualPinBuiltinSource(counter: builtin, claim: UpdateInfo(source: .cask, newestShortVersion: "2.0"))],
            manualSource: ManualSourceResolver { _ in nil }
        )
        let app = InstalledApp(bundleIdentifier: "io.test.pin.nil", name: "ManualApp", path: "/tmp/ManualPin.app", shortVersion: "1.0")
        let check = await engine.check(app: app)

        #expect(check.resolved?.source == .cask)
        #expect(await builtin.value() == 1)
        #expect(check.verdict == "update")
    }

    @Test func manualPinThrowIsVerbatimFailureWithNoBuiltinFallback() async {
        let builtin = ManualPinProbeCounter()
        let pinned = ManualPinProbeCounter()
        let engine = UpdateCheckEngine(
            sources: [ManualPinBuiltinSource(counter: builtin, claim: UpdateInfo(source: .cask, newestShortVersion: "9.9"))],
            manualSource: ManualSourceResolver { _ in ManualPinThrowSource(counter: pinned) }
        )
        let app = InstalledApp(bundleIdentifier: "io.test.pin.throw", name: "ManualApp", path: "/tmp/ManualPin.app", shortVersion: "1.0")
        let check = await engine.check(app: app)

        // Honesty: the pin failed loudly and the engine does NOT silently fall
        // back to built-ins for a pinned app (the owner's attestation stands).
        #expect(check.failures.count == 1)
        #expect(check.failures.first?.kind == .github)
        #expect(check.candidates.isEmpty)
        #expect(await pinned.value() == 1)
        #expect(await builtin.value() == 0)
        #expect(check.verdict == "failed")
    }
}
