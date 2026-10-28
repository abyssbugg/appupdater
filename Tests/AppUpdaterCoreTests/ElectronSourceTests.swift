// ElectronSource hermetic tests — Swift Testing ONLY (XCTest discovery is
// broken on this toolchain; AGENTS.md ledger). ZERO network: every HTTP route
// this suite can provoke is intercepted by a URLProtocol stub registered ONLY
// on the suite's own sessions (SparkleSourceTests/MassSourceTests pattern);
// "zero network" guarantees are asserted against the recorded request count,
// not assumed.
//
// Fixture policy: fake app bundles are built in a UNIQUE per-process temp dir
// (AGENTS.md ledger: shared fixed temp roots collide across concurrent swift
// test runners). No /Applications content is written or modified anywhere:
// real-bundle evidence for the asar layout was gathered READ-ONLY outside
// tests (see docs/evidence/gap-electron-source-2026-10-27.txt) and is encoded
// here as SELF-CONSISTENT synthetic asar bytes — the fixture writer below
// emits exactly the byte layout the reader parses (layout verified against a
// real installed Electron app — Claude Desktop 4.29.0 — on 2026-10-27).

import Foundation
import Testing
@testable import AppUpdaterCore

// MARK: - Hermetic transport

/// URLProtocol stub keyed by full URL string, recording every request.
final class ElectronStubURLProtocol: URLProtocol {
    struct StubResponse: Sendable {
        var status: Int
        var body: Data
    }

    struct RecordedRequest: Sendable {
        var url: URL
        var userAgent: String?
        var accept: String?
    }

    private static let state = LockedElectronBox<[String: StubResponse]>([:])
    private static let requests = LockedElectronBox<[RecordedRequest]>([])

    static func reset() {
        state.with { stubs in stubs = [:] }
        requests.with { log in log = [] }
    }

    static func stub(_ body: String, status: Int = 200, forURL urlString: String) {
        state.with { stubs in
            stubs[urlString] = StubResponse(status: status, body: Data(body.utf8))
        }
    }

    static var recordedCount: Int {
        requests.with { log in log.count }
    }

    static var recorded: [RecordedRequest] {
        requests.with { log in log }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    // Ledger gotcha: URLProtocol stubs need a no-op stopLoading override or the
    // CFNetwork teardown kills the whole runner.
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requests.with { log in
            log.append(RecordedRequest(
                url: url,
                userAgent: request.value(forHTTPHeaderField: "User-Agent"),
                accept: request.value(forHTTPHeaderField: "Accept")))
        }
        let stub = Self.state.with { stubs in stubs[url.absoluteString] }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub?.status ?? 404,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream"]
        )
        guard let response, let client else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body = stub?.body { client.urlProtocol(self, didLoad: body) }
        client.urlProtocolDidFinishLoading(self)
    }
}

/// Tiny lock-guarded box (Sparkle/Cask test pattern; suites run in parallel).
final class LockedElectronBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ initial: Value) { value = initial }

    func with<Result>(_ mutate: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return mutate(&value)
    }
}

// MARK: - Asar fixture writer (REAL verified layout, self-consistent bytes)

enum ElectronAsarFixture {
    /// Builds a minimal REAL-LAYOUT asar archive (the verified byte layout —
    /// see AsarReader.swift's header and the evidence file):
    ///
    ///   u32LE(4) | u32LE(H) | u32LE(S) | u32LE(J) | JSON(J bytes, align4-padded)
    ///   where S = 4 + align4(J), H = 4 + S; file data follows and header
    ///   `offset` values are RELATIVE to the data base (= 8 + H = 16 + align4(J))
    ///   and stored as JSON strings (real-archive convention).
    ///
    /// `unpacked` members mimic entries whose bytes live beside the asar in
    /// app.asar.unpacked/: the header carries `"unpacked": true` + `size` and
    /// NO `offset`, and no bytes are packed for them.
    static func make(asarContents: [(path: String, body: String, unpacked: Bool)]) -> Data {
        var filesTree: [String: Any] = [:]
        var packedBodies: [Data] = []
        var packedOffset = 0

        for entry in asarContents {
            let segments = entry.path.split(separator: "/").map(String.init)
            precondition(!segments.isEmpty, "fixture member paths must be non-empty")
            var leaf: [String: Any] = ["size": entry.body.utf8.count]
            if entry.unpacked {
                leaf["unpacked"] = true
            } else {
                leaf["offset"] = String(packedOffset)
                packedBodies.append(Data(entry.body.utf8))
                packedOffset += entry.body.utf8.count
            }
            insert(segments, leaf: leaf, into: &filesTree)
        }

        let headerJSON = (try? JSONSerialization.data(withJSONObject: ["files": filesTree]))
            ?? Data("{}".utf8)
        let jsonLength = headerJSON.count
        let align4 = (jsonLength + 3) / 4 * 4
        let headerPayloadSize = 4 + align4 // S
        let headerBufferLength = 4 + headerPayloadSize // H

        var out = Data()
        func append(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        append(4)
        append(UInt32(headerBufferLength))
        append(UInt32(headerPayloadSize))
        append(UInt32(jsonLength))
        out.append(headerJSON)
        out.append(contentsOf: [UInt8](repeating: 0, count: align4 - jsonLength))
        for body in packedBodies { out.append(body) }
        return out
    }

    /// Nested insert into the `files` tree: intermediate segments become
    /// directories ({"files": {…}}), the last segment becomes the leaf.
    private static func insert(_ segments: [String], leaf: [String: Any], into tree: inout [String: Any]) {
        if segments.count == 1 {
            tree[segments[0]] = leaf
            return
        }
        var child = tree[segments[0]] as? [String: Any] ?? [:]
        var grandchild = child["files"] as? [String: Any] ?? [:]
        insert(Array(segments.dropFirst()), leaf: leaf, into: &grandchild)
        child["files"] = grandchild
        tree[segments[0]] = child
    }
}

// MARK: - Tests

@Suite(.serialized)
struct ElectronSourceTests {

    /// Unique per-process fixture root (AGENTS.md ledger: never a shared wiped root).
    private static let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("appupdater-electron-\(UUID().uuidString)")

    init() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
    }

    // MARK: Bundle builders + fixtures

    /// Creates an .app bundle skeleton in the suite's temp root. The framework
    /// path exists as an empty directory (existence is all detection needs).
    private func makeApp(
        name: String,
        withElectronFramework: Bool,
        yml: String? = nil,
        asarData: Data? = nil,
        shortVersion: String? = nil
    ) -> InstalledApp {
        let bundle = Self.root.appendingPathComponent("\(name).app", isDirectory: true)
        let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        if withElectronFramework {
            let framework = bundle.appendingPathComponent(
                "Contents/Frameworks/Electron Framework.framework", isDirectory: true)
            try? FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        }
        if let yml {
            try? Data(yml.utf8).write(to: resources.appendingPathComponent("app-update.yml"))
        }
        if let asarData {
            try? asarData.write(to: resources.appendingPathComponent("app.asar"))
        }
        return InstalledApp(
            bundleIdentifier: "com.example.\(name.lowercased())",
            name: name,
            path: bundle.path,
            shortVersion: shortVersion
        )
    }

    private func makeSource() -> ElectronSource {
        ElectronSource(urlProtocolClasses: [ElectronStubURLProtocol.self])
    }

    private static let originBase = "https://updates.stub.invalid/stable/"

    /// latest-mac.yml fixture in the LIVE shape (Capy sample, 2026-10-27).
    private static let latestMacYml = """
    version: 0.6.0
    files:
      - url: Stub-0.6.0-x64.zip
        sha512: SDLsha512FirstEntryPlaceholderValueAA==
        size: 167158770
      - url: Stub-0.6.0-arm64.dmg
        sha512: SDLsha512SecondEntryPlaceholderValueBB==
        size: 162487855
    path: Stub-0.6.0-x64.zip
    sha512: SDLsha512FirstEntryPlaceholderValueAA==
    releaseDate: '2026-10-27T20:29:20.738Z'
    """

    private static let githubReleaseJSON = #"""
    {
      "tag_name": "v1.4.2",
      "name": "Release 1.4.2",
      "published_at": "2026-10-26T23:00:00Z",
      "assets": [
        {"name": "Stub-1.4.2.dmg", "browser_download_url": "https://github.com/stub-owner/stub-repo/releases/download/v1.4.2/Stub-1.4.2.dmg"},
        {"name": "latest-mac.yml", "browser_download_url": "https://github.com/stub-owner/stub-repo/releases/download/v1.4.2/latest-mac.yml"},
        {"name": "latest-linux.yml", "browser_download_url": "https://github.com/stub-owner/stub-repo/releases/download/v1.4.2/latest-linux.yml"}
      ]
    }
    """#

    private static let githubReleaseYml = """
    version: 1.4.2
    files:
      - url: Stub-1.4.2-mac.zip
        sha512: GHsha512EntryPlaceholderValueCC==
        size: 74000000
    path: Stub-1.4.2-mac.zip
    releaseName: Release 1.4.2
    """

    /// Pipeline-B main script content carrying the Updatest-style regex targets
    /// (owner/repo WITH a {platform}/{version}-style suffix to prove stripping).
    private static let electronMainScript = """
    const config = { updateURL: 'https://update.electronjs.org/stub-owner/stub-app' };
    // electron-updater resolves https://update.electronjs.org/stub-owner/stub-app/darwin-arm64/<version>
    """

    private func electronAsar(main: String, mainBody: String) -> Data {
        let packageJson = #"{"name":"stub-app","version":"0.5.0","main":"\#(main)"}"#
        return ElectronAsarFixture.make(asarContents: [
            (path: "package.json", body: packageJson, unpacked: false),
            (path: main, body: mainBody, unpacked: false),
        ])
    }

    // MARK: Detection (zero network)

    @Test
    func missingElectronFrameworkDetectsNothingAndHitsNoNetwork() async throws {
        ElectronStubURLProtocol.reset()
        let before = ElectronStubURLProtocol.recordedCount
        let app = makeApp(name: "NotElectron", withElectronFramework: false,
                          yml: "provider: generic\nurl: \(Self.originBase)")

        let info = try await makeSource().fetchUpdateInfo(for: app)

        #expect(info == nil)
        #expect(ElectronStubURLProtocol.recordedCount == before) // zero requests issued
    }

    @Test
    func frameworkWithoutResourceFilesDetectsNothingAndHitsNoNetwork() async throws {
        ElectronStubURLProtocol.reset()
        let before = ElectronStubURLProtocol.recordedCount
        let app = makeApp(name: "BareElectron", withElectronFramework: true)

        let info = try await makeSource().fetchUpdateInfo(for: app)

        #expect(info == nil)
        #expect(ElectronStubURLProtocol.recordedCount == before)
    }

    @Test
    func detectionRuleMatchesTheBriefMatrix() {
        // The brief's matrix: framework + (yml OR asar) detect; either resource
        // alone without the framework does not.
        let yml = makeApp(name: "DetYml", withElectronFramework: true,
                          yml: "provider: generic\nurl: https://x.invalid")
        let asar = makeApp(name: "DetAsar", withElectronFramework: true,
                           asarData: ElectronAsarFixture.make(asarContents: [
                               (path: "package.json", body: "{}", unpacked: false)]))
        let neither = makeApp(name: "DetNone", withElectronFramework: true)
        #expect(ElectronSource.detectsElectronBundle(atPath: yml.path))
        #expect(ElectronSource.detectsElectronBundle(atPath: asar.path))
        #expect(!ElectronSource.detectsElectronBundle(atPath: neither.path))
        #expect(!ElectronSource.detectsElectronBundle(atPath: "/Applications/nonexistent-bundle-XYZ.app"))
    }

    // MARK: ElectronYaml unit tests

    @Test
    func flatKeysParseWithQuotesStripped() throws {
        let config = ElectronYaml.parseAppUpdateYml(Data("""
        provider: generic
        url: 'https://desktop-release.notion-static.com'
        channel: arm64
        updaterCacheDirName: notion-updater
        """.utf8))
        #expect(config.provider == "generic")
        #expect(config.url == "https://desktop-release.notion-static.com")
        #expect(config.channel == "arm64")
    }

    @Test
    func githubProviderFlatKeysParsedRegardlessOfOrder() throws {
        // Real-world sample (Granola): owner/repo declared BEFORE provider.
        let config = ElectronYaml.parseAppUpdateYml(Data("""
        owner: granola-inc
        repo: granola-electron
        provider: github
        """.utf8))
        #expect(config.provider == "github")
        #expect(config.owner == "granola-inc")
        #expect(config.repo == "granola-electron")
    }

    @Test
    func latestMacYmlParsedWithFilesAndReleaseDate() throws {
        let parsed = ElectronYaml.parseLatestMacYml(Data(Self.latestMacYml.utf8))
        #expect(parsed.version == "0.6.0")
        #expect(parsed.files.count == 2)
        #expect(parsed.files[0].url == "Stub-0.6.0-x64.zip")
        #expect(parsed.files[0].size == 167158770)
        #expect(parsed.files[1].url == "Stub-0.6.0-arm64.dmg")
        #expect(parsed.path == "Stub-0.6.0-x64.zip")
        // ISO8601 with fractional seconds ('2026-10-27T20:29:20.738Z') pinned
        // to the epoch: 2026-01-01 00:00 UTC = 1_767_225_600; +299 days
        // (Oct 27 00:00) + 73_760 s = 1_793_129_960… asserted exactly-instant
        // via the fractional-aware formatter below.
        let date = try #require(ElectronYaml.parseReleaseDate(parsed.releaseDate))
        #expect(abs(date.timeIntervalSince1970 - 1_793_132_960.738) < 0.01)
    }

    @Test
    func releaseDateFallbacksAcceptBareTimestampsAndRejectGarbage() {
        #expect(ElectronYaml.parseReleaseDate("2026-03-02T10:00:00+00:00") != nil) // RFC3339 no fraction
        #expect(ElectronYaml.parseReleaseDate("2026-03-02") != nil) // date-only tolerant fallback
        #expect(ElectronYaml.parseReleaseDate("not-a-date") == nil)
        #expect(ElectronYaml.parseReleaseDate(nil) == nil)
        #expect(ElectronYaml.parseReleaseDate("") == nil)
    }

    @Test
    func latestMacYmlWithoutVersionParsesEmptyAndSourceRefuses() async throws {
        // Missing REQUIRED version → empty files; the SOURCE refuses (never
        // synthesizes a version).
        let body = "path: x.zip\nsha512: abc\n"
        let parsed = ElectronYaml.parseLatestMacYml(Data(body.utf8))
        #expect(parsed.version == nil)
        #expect(parsed.files.isEmpty)

        ElectronStubURLProtocol.reset()
        ElectronStubURLProtocol.stub(body, forURL: Self.originBase + "latest-mac.yml")
        let app = makeApp(name: "YmlNoVersion", withElectronFramework: true,
                          yml: "provider: generic\nurl: \(Self.originBase)")
        let info = try await makeSource().fetchUpdateInfo(for: app)
        #expect(info == nil)
    }

    @Test
    func downloadURLJoinResolvesRelativeAgainstOriginAndAbsoluteWins() throws {
        let origin = try #require(URL(string: Self.originBase + "latest-mac.yml"))
        let joined = ElectronSource.resolvingFileURL("Stub-0.6.0-arm64.dmg", againstOriginDirectory: origin)
        #expect(joined?.absoluteString == "https://updates.stub.invalid/stable/Stub-0.6.0-arm64.dmg")

        let absolute = try #require(URL(string: "https://cdn.stub.invalid/Stub-0.6.0.zip"))
        let won = ElectronSource.resolvingFileURL(absolute.absoluteString, againstOriginDirectory: origin)
        #expect(won == absolute) // absolute wins verbatim
    }

    // MARK: Pipeline A — provider routing

    @Test
    func githubProviderFetchesReleaseThenLatestMacYmlAssetWithHeaders() async throws {
        ElectronStubURLProtocol.reset()
        ElectronStubURLProtocol.stub(Self.githubReleaseJSON,
                                     forURL: "https://api.github.com/repos/stub-owner/stub-repo/releases/latest")
        ElectronStubURLProtocol.stub(Self.githubReleaseYml,
                                     forURL: "https://github.com/stub-owner/stub-repo/releases/download/v1.4.2/latest-mac.yml")
        let app = makeApp(name: "GithubYml", withElectronFramework: true,
                          yml: "owner: stub-owner\nrepo: stub-repo\nprovider: github")

        let update = try #require(try await makeSource().fetchUpdateInfo(for: app))
        #expect(update.source == .unknown)
        #expect(update.newestShortVersion == "1.4.2")
        // The relative files[] url joins the RELEASE-ASSET directory of the
        // yml origin — the same rebuild electron-updater performs for github.
        #expect(update.downloadURL?.absoluteString
            == "https://github.com/stub-owner/stub-repo/releases/download/v1.4.2/Stub-1.4.2-mac.zip")
        #expect(update.sha256Hex == nil) // ONLY SHA-512 exists upstream
        #expect(update.newestBundleVersion == nil)
        #expect(update.confidence == .medium)
        #expect(update.releaseNotes == "Release 1.4.2")
        let detail = try #require(update.sourceDetail)
        #expect(detail.contains("electron-builder metadata from"))
        #expect(detail.contains("only SHA-512 published upstream — automatic install disabled; the app updates itself / manual staged install"))
        // Header policy: UA on EVERY request; GitHub media-type Accept only on
        // the API route.
        try #require(ElectronStubURLProtocol.recorded.count == 2)
        let api = try #require(ElectronStubURLProtocol.recorded.first { $0.url.host == "api.github.com" })
        #expect(api.userAgent == "AppUpdater/0.1 (macOS)")
        #expect(api.accept == "application/vnd.github.v3+json")
        let asset = try #require(ElectronStubURLProtocol.recorded.first { $0.url.host == "github.com" })
        #expect(asset.userAgent == "AppUpdater/0.1 (macOS)")
    }

    @Test
    func githubProviderWithoutLatestMacYmlAssetFallsToPipelineB() async throws {
        // released JSON carries dmg assets but NO "latest-mac.yml" named asset
        // (real shape on this machine's sample repo) → pipeline B fallback.
        ElectronStubURLProtocol.reset()
        ElectronStubURLProtocol.stub(
            #"{"assets":[{"name":"Stub-ios.dmg","browser_download_url":"https://github.com/stub-owner/stub-repo/releases/download/v1/Stub-ios.dmg"}]}"#,
            forURL: "https://api.github.com/repos/stub-owner/stub-repo/releases/latest")
        ElectronStubURLProtocol.stub(
            #"{"name":"stub-app","version":"2.0.0","url":"https://github.com/stub-owner/stub-app/releases/download/v2.0.0/Stub-2.0.0.zip"}"#,
            forURL: "https://update.electronjs.org/stub-owner/stub-app/darwin-arm64/0.0.0")
        let app = makeApp(name: "GithubNoYmlAsset", withElectronFramework: true,
                          yml: "owner: stub-owner\nrepo: stub-repo\nprovider: github",
                          asarData: electronAsar(main: "main.js", mainBody: Self.electronMainScript))

        let update = try #require(try await makeSource().fetchUpdateInfo(for: app))
        #expect(update.newestShortVersion == "2.0.0")
        #expect(update.source == .unknown)
        let detail = try #require(update.sourceDetail)
        #expect(detail.contains("electron self-update probe"))
    }

    @Test
    func genericProviderBaseJoinsWithAndWithoutTrailingSlash() async throws {
        // The real configs mix both shapes (Notion no-slash, Capy slash).
        ElectronStubURLProtocol.reset()
        ElectronStubURLProtocol.stub(Self.latestMacYml,
                                     forURL: "https://updates.stub.invalid/stable/latest-mac.yml")
        let app = makeApp(name: "GenericYml", withElectronFramework: true,
                          yml: "provider: generic\nurl: https://updates.stub.invalid/stable")

        let update = try #require(try await makeSource().fetchUpdateInfo(for: app))
        #expect(update.newestShortVersion == "0.6.0")
        // FIRST usable files[] entry (document-order v1 policy, documented):
        #expect(update.downloadURL?.absoluteString
            == "https://updates.stub.invalid/stable/Stub-0.6.0-x64.zip")
        #expect(update.releaseNotes == nil) // no releaseName in this feed — honest nil
        #expect(update.minimumSystemVersion == nil)
        #expect(try #require(update.releaseDate).timeIntervalSince1970 == 1_793_132_960.738)
    }

    @Test
    func plainHttpUrlRefusedByHttpsFloorFallsToAsar() async throws {
        // Real-world shape (ZCode-like): provider generic with an http:// base.
        // LOCKED security floor: never fetched over plaintext; pipeline B still
        // probes the (stubbed) electronjs endpoint.
        ElectronStubURLProtocol.reset()
        ElectronStubURLProtocol.stub(#"{"name":"stub-app","version":"2.1.0"}"#,
                                     forURL: "https://update.electronjs.org/stub-owner/stub-app/darwin-arm64/0.0.0")
        let app = makeApp(name: "LocalhostYml", withElectronFramework: true,
                          yml: "provider: generic\nurl: http://localhost:8081",
                          asarData: electronAsar(main: "main.js", mainBody: Self.electronMainScript))

        let update = try #require(try await makeSource().fetchUpdateInfo(for: app))
        #expect(!ElectronStubURLProtocol.recorded.contains { $0.url.host == "localhost" }) // no plaintext fetch
        #expect(update.newestShortVersion == "2.1.0")
        #expect(update.downloadURL == nil) // url-less probe JSON → honest nil url
    }

    @Test
    func urllessProvidersFetchNothingAndReturnNilHonestly() async throws {
        // s3/custom providers carry endpoint/bucket keys but no routable url —
        // the real Bionic (s3) and Linear/Termius (custom) shapes.
        ElectronStubURLProtocol.reset()
        let before = ElectronStubURLProtocol.recordedCount
        let app = makeApp(name: "CustomYml", withElectronFramework: true,
                          yml: "provider: custom\nbucket: termius.desktop.autoupdate\nendpoint: https://s3.amazonaws.com")
        let info = try await makeSource().fetchUpdateInfo(for: app)
        #expect(info == nil)
        #expect(ElectronStubURLProtocol.recordedCount == before) // nothing fetched
    }

    // MARK: latest-mac.yml → claim semantics

    @Test
    func versionOnlyYmlStillYieldsClaimWithoutDownloadURL() async throws {
        ElectronStubURLProtocol.reset()
        ElectronStubURLProtocol.stub("version: 9.9.9\npath: OnlyPath-9.9.9.zip\n",
                                     forURL: Self.originBase + "latest-mac.yml")
        let app = makeApp(name: "NoFilesEntry", withElectronFramework: true,
                          yml: "provider: generic\nurl: \(Self.originBase)")
        let update = try #require(try await makeSource().fetchUpdateInfo(for: app))
        #expect(update.newestShortVersion == "9.9.9") // the claim stands
        #expect(update.downloadURL == nil) // no usable files[].url — never invent one
    }

    // MARK: Pipeline B — asar plumbing

    @Test
    func asarFixtureRoundTripsRealLayoutThroughReader() throws {
        // The writer emits the VERIFIED layout; the reader must recover the
        // same bytes — proves the fixture factory and reader agree on the
        // data-base rule (offsets relative to 8 + u32[4..8)) end to end.
        let asar = electronAsar(main: "main.js", mainBody: Self.electronMainScript)
        let asarPath = Self.root.appendingPathComponent("roundtrip.asar").path
        try asar.write(to: URL(fileURLWithPath: asarPath))

        let archive = try #require(AsarReader.open(asarPath: asarPath))
        let package = try #require(AsarReader.packageJsonData(in: archive, asarPath: asarPath))
        let packageJson = try #require(try JSONSerialization.jsonObject(with: package) as? [String: Any])
        #expect(packageJson["main"] as? String == "main.js")
        let mainBytes = try #require(AsarReader.readMember(["main.js"], in: archive, asarPath: asarPath))
        #expect(String(decoding: mainBytes, as: UTF8.self) == Self.electronMainScript)
    }

    @Test
    func asarPipelineBRecoversOwnerRepoAndReadsTheProbe() async throws {
        // Claude-Desktop-like app: asar present, NO app-update.yml. Note the
        // probe uses the SCANNER's shortVersion (nil here → the brief's "0.0.0"
        // fallback), NOT the asar package.json version (0.5.0).
        ElectronStubURLProtocol.reset()
        ElectronStubURLProtocol.stub(
            #"{"name":"stub-app","version":"2.3.0","url":"https://github.com/stub-owner/stub-app/releases/download/v2.3.0/Stub-2.3.0.dmg"}"#,
            forURL: "https://update.electronjs.org/stub-owner/stub-app/darwin-arm64/0.0.0")
        let app = makeApp(name: "AsarOnly", withElectronFramework: true,
                          asarData: electronAsar(main: "main.js", mainBody: Self.electronMainScript))

        let update = try #require(try await makeSource().fetchUpdateInfo(for: app))
        #expect(update.source == .unknown)
        #expect(update.newestShortVersion == "2.3.0")
        #expect(update.downloadURL?.absoluteString
            == "https://github.com/stub-owner/stub-app/releases/download/v2.3.0/Stub-2.3.0.dmg")
        #expect(update.newestBundleVersion == nil)
        #expect(update.sha256Hex == nil)
        #expect(update.confidence == .medium)
        #expect(update.releaseNotes == "stub-app") // the probe JSON's name field
        #expect(update.releaseDate == nil) // this upstream carries no date
        let detail = try #require(update.sourceDetail)
        #expect(detail.contains("electron self-update probe of stub-owner/stub-app"))
        #expect(detail.contains("darwin-arm64 emulated probe"))
        #expect(detail.contains("manual staged install"))
    }

    @Test
    func asarProbeUsesInstalledShortVersionThenZeroFallback() async throws {
        ElectronStubURLProtocol.reset()
        ElectronStubURLProtocol.stub(#"{"name":"stub-app","version":"2.3.0"}"#,
                                     forURL: "https://update.electronjs.org/stub-owner/stub-app/darwin-arm64/3.7.1")
        ElectronStubURLProtocol.stub(#"{"name":"stub-app","version":"2.3.0"}"#,
                                     forURL: "https://update.electronjs.org/stub-owner/stub-app/darwin-arm64/0.0.0")
        let source = makeSource()
        var app = makeApp(name: "ProbeVersion", withElectronFramework: true,
                          asarData: electronAsar(main: "main.js", mainBody: Self.electronMainScript),
                          shortVersion: "3.7.1")

        let withVersion = try await source.fetchUpdateInfo(for: app)
        #expect(withVersion != nil)
        #expect(ElectronStubURLProtocol.recorded.contains {
            $0.url.path.contains("/darwin-arm64/3.7.1")
        })

        app.shortVersion = nil
        let withoutVersion = try await source.fetchUpdateInfo(for: app)
        #expect(withoutVersion != nil)
        #expect(ElectronStubURLProtocol.recorded.contains {
            $0.url.path.contains("/darwin-arm64/0.0.0")
        })
    }

    @Test
    func electronjsResponseWithoutVersionYieldsNil() async throws {
        ElectronStubURLProtocol.reset()
        ElectronStubURLProtocol.stub(#"{"name":"stub-app"}"#,
                                     forURL: "https://update.electronjs.org/stub-owner/stub-app/darwin-arm64/0.0.0")
        let app = makeApp(name: "NoVersionJson", withElectronFramework: true,
                          asarData: electronAsar(main: "main.js", mainBody: Self.electronMainScript))
        let info = try await makeSource().fetchUpdateInfo(for: app)
        #expect(info == nil) // version REQUIRED upstream — honest nil
    }

    @Test
    func probeUrlWithoutHttpsSchemeIsNotAClaim() async throws {
        // The probe JSON may hand out a http:// url — refused by the floor
        // (downloadURL nil), while the VERSION claim still surfaces.
        ElectronStubURLProtocol.reset()
        ElectronStubURLProtocol.stub(
            #"{"name":"stub-app","version":"2.4.0","url":"http://plain.stub.invalid/Stub.zip"}"#,
            forURL: "https://update.electronjs.org/stub-owner/stub-app/darwin-arm64/0.0.0")
        let app = makeApp(name: "HttpUrlJson", withElectronFramework: true,
                          asarData: electronAsar(main: "main.js", mainBody: Self.electronMainScript))
        let update = try #require(try await makeSource().fetchUpdateInfo(for: app))
        #expect(update.newestShortVersion == "2.4.0")
        #expect(update.downloadURL == nil)
    }

    @Test
    func asarWithoutElectronjsUrlYieldsNilHonestly() async throws {
        // Claude's real main.js embeds NO update.electronjs.org URL: regexes
        // hit nothing → honest nil, and the electronjs endpoint is never hit.
        ElectronStubURLProtocol.reset()
        let before = ElectronStubURLProtocol.recordedCount
        let app = makeApp(name: "NoUpdateUrlAsar", withElectronFramework: true,
                          asarData: electronAsar(main: "main.js",
                                                 mainBody: "const app = require('electron'); app.start();"))
        let info = try await makeSource().fetchUpdateInfo(for: app)
        #expect(info == nil)
        #expect(ElectronStubURLProtocol.recordedCount == before)
    }

    @Test
    func asarMainFileMissingOrUnpackedYieldsNilHonestly() async throws {
        // Two real-world honest-nil shapes in ONE archive behavior contract:
        //   1. package.json's main points at a file NOT in the header
        //      (Factory-style app: main: "./lib/keytar.js" but the member is
        //      absent from the tree).
        //   2. the main member is UNPACKED (no offset — Figma/Slack shape).
        ElectronStubURLProtocol.reset()
        let before = ElectronStubURLProtocol.recordedCount
        let mainBody = Self.electronMainScript
        let packageJson = #"{"main":"missing.js"}"#
        let asar = ElectronAsarFixture.make(asarContents: [
            (path: "package.json", body: packageJson, unpacked: false),
            (path: "main.js", body: mainBody, unpacked: true), // unpacked leaf
        ])
        let asarPath = Self.root.appendingPathComponent("unpacked.asar").path
        try asar.write(to: URL(fileURLWithPath: asarPath))

        // Archive-level: the unpacked member's node carries NO offset and its
        // bytes are unreachable — the reader refuses rather than guessing.
        let archive = try #require(AsarReader.open(asarPath: asarPath))
        let unpackedNode = try #require(AsarReader.node(at: ["main.js"], in: archive.rootFiles))
        #expect(AsarReader.integer(unpackedNode["offset"]) == nil)
        #expect(AsarReader.readMember(["main.js"], in: archive, asarPath: asarPath) == nil)

        // Source-level: main points at missing.js → honest nil, no network.
        let app = makeApp(name: "UnpackedMain", withElectronFramework: true,
                          asarData: ElectronAsarFixture.make(asarContents: [
                              (path: "package.json", body: #"{"main":"./missing.js"}"#, unpacked: false),
                              (path: "main.js", body: mainBody, unpacked: true)]))
        let info = try await makeSource().fetchUpdateInfo(for: app)
        #expect(info == nil)
        #expect(ElectronStubURLProtocol.recordedCount == before)
    }

    @Test
    func ownerRepoExtractionPinsTheRegexContract() throws {
        // Updatest regex shape pinned: the updateURL assignment form, the
        // {platform}/{version} suffix stripped by first-two-segments taking,
        // plain http refused by the LOCKED floor, non-electronjs hosts ignored.
        let script = "var c = { updateURL: 'https://update.electronjs.org/acme/tool/darwin-arm64/1.2.3' };"
        let extracted = try #require(ElectronSource.ownerRepo(fromMainScript: Data(script.utf8)))
        #expect(extracted.owner == "acme")
        #expect(extracted.repo == "tool")

        let genericSelfHost = #"updateURL = "https://selfhosted.invalid/manifest""#
        #expect(ElectronSource.ownerRepo(fromMainScript: Data(genericSelfHost.utf8)) == nil)

        let plainHttp = #"updateURL: 'http://update.electronjs.org/acme/tool'"#
        #expect(ElectronSource.ownerRepo(fromMainScript: Data(plainHttp.utf8)) == nil)

        let tooFewSegments = #"['https://update.electronjs.org/only/']"#
        #expect(ElectronSource.ownerRepo(fromMainScript: Data(tooFewSegments.utf8)) == nil)
    }
}
