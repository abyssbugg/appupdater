// GithubSource tests — hermetic (custom URLProtocol stub; NO network is
// touched). Swift Testing only: XCTest discovery is broken on this toolchain
// (Xcode 27 beta). Fixtures are synthetic but true-to-shape GitHub release
// JSON (api.github.com /releases/latest): tag_name / published_at / body /
// assets[].{name, browser_download_url}.
//
// Every test owns a UNIQUE temp directory (never /Applications, never real
// Application Support) — no shared fixed temp roots, per the cross-process
// fixture-collision gotcha. Request counting and header inspection ride on
// the stub's recording; the ETag/304 and rate-limit tests prove the exact
// documented behaviors (304 → cached verbatim body; 403 + remaining "0" →
// the verbatim throw).

import Foundation
import Testing
@testable import AppUpdaterCore

// MARK: - Hermetic URL stub (per-URL fixtures WITH response headers)

/// Serves pre-registered fixture bodies per ABSOLUTE URL and records every
/// request with its headers. Unregistered URLs answer 404 empty. Synchronous
/// inside startLoading; `stopLoading` is overridden because CFNetwork calls
/// it on teardown and the abstract base throws (repo gotcha).
final class GithubStubURLProtocol: URLProtocol {
    struct StubResponse: Sendable {
        let status: Int
        let body: Data
        let headers: [String: String]
    }

    struct RecordedRequest: Sendable {
        let url: URL
        let headers: [String: String]
    }

    private static let stubBox = LockedBox<[String: StubResponse]>([:])
    private static let requestBox = LockedBox<[RecordedRequest]>([])

    static func reset() {
        stubBox.with { stubs in stubs = [:] }
        requestBox.with { requests in requests = [] }
    }

    static func stub(_ body: String, status: Int = 200, headers: [String: String] = [:], forURL urlString: String) {
        stubBox.with { stubs in
            stubs[urlString] = StubResponse(status: status, body: Data(body.utf8), headers: headers)
        }
    }

    static var recordedRequests: [RecordedRequest] {
        requestBox.with { requests in requests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// No-op on purpose: synchronous stubs complete in startLoading, but
    /// CFNetwork still invokes stopLoading during session teardown.
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requestBox.with { requests in
            requests.append(RecordedRequest(url: url, headers: request.allHTTPHeaderFields ?? [:]))
        }
        let stub = Self.stubBox.with { stubs in stubs[url.absoluteString] }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub?.status ?? 404,
            httpVersion: "HTTP/1.1",
            headerFields: stub?.headers ?? [:]
        )
        guard let response, let client else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body = stub?.body { client.urlProtocol(self, didLoad: body) }
        client.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - Fixtures

/// Release JSON builder (true /releases/latest shape; omitted keys simulate
/// absent fields exactly as GitHub sends them — no null padding).
private func releaseJSON(
    tag: String? = "1.4.2",
    published: String? = "2026-10-01T10:00:00Z",
    body: String? = "Bug fixes and improvements",
    assets: [(name: String, url: String)] = [("App.dmg", "https://github.com/o/r/releases/download/v1.4.2/App.dmg")]
) -> String {
    func stringField(_ key: String, _ value: String?) -> String? {
        value.map { "\"\(key)\": \"\($0)\"" }
    }
    let assetItems = assets.map { item in
        "{\"name\": \"\(item.name)\", \"browser_download_url\": \"\(item.url)\"}"
    }
    let fields = [
        stringField("tag_name", tag),
        stringField("published_at", published),
        stringField("body", body),
        assetItems.isEmpty
            ? "\"assets\": []"
            : "\"assets\": [\(assetItems.joined(separator: ", "))]",
    ]
    .compactMap { $0 }
    return "{\(fields.joined(separator: ", "))}"
}

private func apiURL(owner: String = "o", repo: String = "r") -> String {
    "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
}

// MARK: - Tests

@Suite(.serialized)
struct GithubSourceTests {

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GithubStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("appupdater-githubsource-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeApp(feed: String? = nil) -> InstalledApp {
        InstalledApp(
            bundleIdentifier: "org.example.app",
            name: "Example App",
            path: "/Applications/Example.app",
            sparkleFeedURL: feed
        )
    }

    /// Non-crashing fixture constructor (force unwraps are lint ERRORS here).
    private func ref(_ owner: String, _ repo: String) throws -> RepoRef {
        try #require(RepoRef.validated(owner: owner, repo: repo))
    }

    // (1) RepoRef validation mirrors the brief's slug alphabet: alnum + - _ .
    @Test func repoRefValidationAndSlugKey() async throws {
        // Valid shapes, including every admitted punctuation char.
        let ok = try ref("Abc-1_x.Yz", "App.Name_9-z0")
        #expect(ok.owner == "Abc-1_x.Yz")
        #expect(ok.repo == "App.Name_9-z0")
        #expect(ok.slug == "Abc-1_x.Yz/App.Name_9-z0") // cache key form

        // Invalid: empty parts, whitespace, slash inside a part, non-ASCII.
        #expect(RepoRef.validated(owner: "", repo: "x") == nil)
        #expect(RepoRef.validated(owner: "o", repo: "") == nil)
        #expect(RepoRef.validated(owner: "o wner", repo: "r") == nil)
        #expect(RepoRef.validated(owner: "o", repo: "re po") == nil)
        #expect(RepoRef.validated(owner: "o", repo: "re/po") == nil)
        #expect(RepoRef.validated(owner: "ólaf", repo: "repo") == nil)
        #expect(RepoRef.validated(owner: "o", repo: "répo") == nil)
    }

    // (2) Sparkle-feed harvest: the brief's exact host list, .git stripping,
    // path-segment extraction, and the negatives (non-github, http, empty,
    // nil, single segment).
    @Test func sparkleFeedRefsPositivesAndNegatives() async throws {
        let one = try ref("MarmadileManteater", "FreeTubeCocoa")
        let two = try ref("rancher", "sparkle.app")
        let three = try ref("baseowner", "base.repo_1")
        let four = try ref("ownEr", "Repo")

        #expect(GithubSource.repoRefs(fromSparkleFeed: "https://github.com/ownEr/Repo.git") == [four]) // .git stripped
        #expect(GithubSource.repoRefs(fromSparkleFeed: "https://github.com/ownEr/Repo/releases/latest") == [four]) // deeper paths ignored

        #expect(GithubSource.repoRefs(fromSparkleFeed: "https://github.com/rancher/sparkle.app.git") == [two])
        #expect(GithubSource.repoRefs(fromSparkleFeed: "https://raw.githubusercontent.com/MarmadileManteater/FreeTubeCocoa/main/appcast.xml") == [one])
        #expect(GithubSource.repoRefs(fromSparkleFeed: "https://githubusercontent.com/baseowner/base.repo_1/anything") == [three])

        // Negatives — non-github hosts, non-https schemes, unusable shapes.
        #expect(GithubSource.repoRefs(fromSparkleFeed: "https://example.com/ownEr/Repo/appcast.xml") == [])
        #expect(GithubSource.repoRefs(fromSparkleFeed: "http://github.com/ownEr/Repo") == [])
        #expect(GithubSource.repoRefs(fromSparkleFeed: "https://objects.githubusercontent.com/ownEr/Repo/token") == [])
        #expect(GithubSource.repoRefs(fromSparkleFeed: "https://github.com/onlyowner") == [])
        #expect(GithubSource.repoRefs(fromSparkleFeed: "   ") == [])
        #expect(GithubSource.repoRefs(fromSparkleFeed: nil) == [])
    }

    // (3) End-to-end default harvest: an app whose own Sparkle feed points
    // at github.com produces a candidates list and a live claim, with ONLY
    // the derived repo contacted.
    @Test func sparkleHarvestEndToEnd() async throws {
        GithubStubURLProtocol.reset()
        let endpoint = apiURL(owner: "ownEr", repo: "Repo") // slug chars preserved in the URL
        GithubStubURLProtocol.stub(releaseJSON(), forURL: endpoint)

        let source = GithubSource(
            repoProvider: nil,
            directory: makeTempDirectory(),
            session: makeSession()
        )
        let app = makeApp(feed: "https://github.com/ownEr/Repo/releases/latest")
        let info = try await source.fetchUpdateInfo(for: app)

        #expect(info?.source == .github)
        #expect(info?.newestShortVersion == "1.4.2")
        let urls = GithubStubURLProtocol.recordedRequests.map { $0.url.absoluteString }
        #expect(urls == [endpoint])
    }

    // (4) A provider that returns nil means "decide yourself" → the default
    // sparkle-feed harvest runs.
    @Test func providerReturningNilFallsBackToHarvest() async throws {
        GithubStubURLProtocol.reset()
        let endpoint = apiURL(owner: "fed", repo: "repo")
        GithubStubURLProtocol.stub(releaseJSON(), forURL: endpoint)

        let nilProvider: (@Sendable (InstalledApp) async -> [RepoRef]?)? = { _ in nil }
        let source = GithubSource(
            repoProvider: nilProvider,
            directory: makeTempDirectory(),
            session: makeSession()
        )
        let info = try await source.fetchUpdateInfo(for: makeApp(feed: "https://github.com/fed/repo"))

        #expect(info?.newestShortVersion == "1.4.2")
        #expect(GithubStubURLProtocol.recordedRequests.map { $0.url.absoluteString } == [endpoint])
    }

    // (5) A provider returning [] is an ACTIVE "no candidates": the default
    // harvest must NOT run, even though the feed would have supplied one.
    @Test func providerReturningEmptySuppressesHarvest() async throws {
        GithubStubURLProtocol.reset()
        let emptyProvider: (@Sendable (InstalledApp) async -> [RepoRef]?)? = { _ in [] }
        let source = GithubSource(
            repoProvider: emptyProvider,
            directory: makeTempDirectory(),
            session: makeSession()
        )
        let info = try await source.fetchUpdateInfo(for: makeApp(feed: "https://github.com/fed/repo"))

        #expect(info == nil)
        #expect(GithubStubURLProtocol.recordedRequests.isEmpty) // zero net
    }

    // (6) Provider lists are capped to the first 2 UNIQUE refs (duplicates
    // collapse; the third unique ref never fetches). Nothing is registered
    // → every probe 404s → nil, but the REQUEST LOG pins the cap.
    @Test func providerListCappedToTwoUnique() async throws {
        GithubStubURLProtocol.reset()
        let a = try ref("alpha", "app.one")
        let b = try ref("beta", "app.two")
        let thirdRef = try ref("gamma", "app.three")
        let source = GithubSource(
            repoProvider: { _ in [a, b, a, thirdRef] },
            directory: makeTempDirectory(),
            session: makeSession()
        )
        let info = try await source.fetchUpdateInfo(for: makeApp())

        #expect(info == nil) // both candidates missed honestly
        #expect(GithubStubURLProtocol.recordedRequests.map { $0.url.absoluteString } == [
            apiURL(owner: "alpha", repo: "app.one"),
            apiURL(owner: "beta", repo: "app.two"),
        ])
    }

    // (7) Pinned happy path: full honest decode + exact request shape.
    @Test func pinnedHappyPathDecodesAllFields() async throws {
        GithubStubURLProtocol.reset()
        GithubStubURLProtocol.stub(releaseJSON(), forURL: apiURL(owner: "o", repo: "r"))

        let source = GithubSource(pinnedOwner: "o", pinnedRepo: "r", directory: makeTempDirectory(), session: makeSession())
        let info = try await source.fetchUpdateInfo(for: makeApp())

        guard let info else {
            Issue.record("expected UpdateInfo, got nil")
            return
        }
        let expectedDate = ISO8601DateFormatter().date(from: "2026-10-01T10:00:00Z")
        #expect(info.source == .github)
        #expect(info.newestShortVersion == "1.4.2") // tag verbatim
        #expect(info.newestBundleVersion == nil)
        #expect(info.minimumSystemVersion == nil)
        #expect(info.releaseDate == expectedDate)
        #expect(info.releaseNotes == "Bug fixes and improvements")
        #expect(info.downloadURL == URL(string: "https://github.com/o/r/releases/download/v1.4.2/App.dmg"))
        #expect(info.sha256Hex == nil) // no sidecar in fixture
        #expect(info.confidence == .medium)
        #expect(info.sourceDetail == "github: o/r; release asset 'App.dmg'; sha256 self-attested upstream source (not verified)")

        let requests = GithubStubURLProtocol.recordedRequests
        #expect(requests.count == 1)
        #expect(requests.first?.url.absoluteString == apiURL(owner: "o", repo: "r"))
        #expect(requests.first?.headers["User-Agent"] == "AppUpdater/0.1 (macOS)")
        #expect(requests.first?.headers["Accept"] == "application/vnd.github.v3+json")
    }

    // (8) The pinned repo WINS as the only candidate: the default sparkle-feed
    // harvest does not even run — an app whose OWN feed points at another
    // GitHub repo is never contacted; requests go to the pinned repo only.
    // (The pinned init takes no provider parameter by design; this proves the
    // "pinned wins as the ONLY candidate" semantics end to end.)
    @Test func pinnedWinsAsOnlyCandidateNoHarvestFallback() async throws {
        GithubStubURLProtocol.reset()
        let pinnedURL = apiURL(owner: "pinned", repo: "repo")
        GithubStubURLProtocol.stub(releaseJSON(tag: "0.9.0"), forURL: pinnedURL)

        let app = makeApp(feed: "https://github.com/harvest/other/releases/latest")
        let source = GithubSource(pinnedOwner: "pinned", pinnedRepo: "repo", directory: makeTempDirectory(), session: makeSession())
        let info = try await source.fetchUpdateInfo(for: app)

        #expect(info?.newestShortVersion == "0.9.0") // pinned document's claim
        #expect(GithubStubURLProtocol.recordedRequests.map { $0.url.absoluteString } == [pinnedURL]) // harvest repo never contacted
    }

    // (9) An invalid pin yields the honest nil with ZERO requests (and never
    // a silent fallback to the sparkle-feed harvest).
    @Test func invalidPinnedHonestNilZeroRequests() async throws {
        GithubStubURLProtocol.reset()
        let source = GithubSource(pinnedOwner: "o wner", pinnedRepo: "re.po", directory: makeTempDirectory(), session: makeSession())
        let app = makeApp(feed: "https://github.com/nevershould/harvest")
        let info = try await source.fetchUpdateInfo(for: app)

        #expect(info == nil)
        #expect(GithubStubURLProtocol.recordedRequests.isEmpty)
    }

    // (10) Release without a usable tag_name → skip; NEVER synthesize a
    // version. Honest nil, one request only.
    @Test func missingTagNameHonestNil() async throws {
        GithubStubURLProtocol.reset()
        GithubStubURLProtocol.stub(releaseJSON(tag: nil), forURL: apiURL())

        let source = GithubSource(pinnedOwner: "o", pinnedRepo: "r", directory: makeTempDirectory(), session: makeSession())
        let info = try await source.fetchUpdateInfo(for: makeApp())

        #expect(info == nil)
        #expect(GithubStubURLProtocol.recordedRequests.count == 1)
    }

    // (11) Malformed release JSON → honest nil (parse gap, no throw).
    @Test func unparseableReleaseJSONHonestNil() async throws {
        GithubStubURLProtocol.reset()
        GithubStubURLProtocol.stub("{\"tag_name\": \"1.4.2\", \" publi", forURL: apiURL())

        let source = GithubSource(pinnedOwner: "o", pinnedRepo: "r", directory: makeTempDirectory(), session: makeSession())
        let info = try await source.fetchUpdateInfo(for: makeApp())

        #expect(info == nil)
        #expect(GithubStubURLProtocol.recordedRequests.count == 1)
    }

    // (12) No eligible asset (excluded types only) → info-only claim:
    // downloadURL nil, honest detail, still a valid UpdateInfo.
    @Test func excludedAssetsInfoOnlyClaim() async throws {
        GithubStubURLProtocol.reset()
        let assets: [(name: String, url: String)] = [
            ("App.exe", "https://github.com/o/r/releases/download/v1.4.2/App.exe"),
            ("App.deb", "https://github.com/o/r/releases/download/v1.4.2/App.deb"),
            ("App.rpm", "https://github.com/o/r/releases/download/v1.4.2/App.rpm"),
            ("App.apk", "https://github.com/o/r/releases/download/v1.4.2/App.apk"),
            ("App.AppImage", "https://github.com/o/r/releases/download/v1.4.2/App.AppImage"),
            ("App.pkg", "https://github.com/o/r/releases/download/v1.4.2/App.pkg"),
        ]
        GithubStubURLProtocol.stub(releaseJSON(assets: assets), forURL: apiURL())

        let source = GithubSource(pinnedOwner: "o", pinnedRepo: "r", directory: makeTempDirectory(), session: makeSession())
        let info = try await source.fetchUpdateInfo(for: makeApp())

        #expect(info?.downloadURL == nil) // info-only claim
        #expect(info?.newestShortVersion == "1.4.2")
        #expect(info?.sourceDetail == "github: o/r; no matching macOS release asset — info-only claim; sha256 self-attested upstream source (not verified)")
    }

    // (13) Extension tier first: a .zip listed BEFORE a .dmg still loses.
    @Test func dmgBeatsZipRegardlessOfOrder() async throws {
        GithubStubURLProtocol.reset()
        let assets: [(name: String, url: String)] = [
            ("App.zip", "https://github.com/o/r/releases/download/v1.4.2/App.zip"),
            ("App.dmg", "https://github.com/o/r/releases/download/v1.4.2/App.dmg"),
        ]
        GithubStubURLProtocol.stub(releaseJSON(assets: assets), forURL: apiURL())

        let source = GithubSource(pinnedOwner: "o", pinnedRepo: "r", directory: makeTempDirectory(), session: makeSession())
        let info = try await source.fetchUpdateInfo(for: makeApp())

        #expect(info?.downloadURL?.lastPathComponent == "App.dmg")
    }

    // (14) Tie-break order is extension tier BEFORE arch labels: an arm64
    // .zip does NOT beat an x86_64 .dmg.
    @Test func extensionTierBeatsArchLabels() async throws {
        GithubStubURLProtocol.reset()
        let assets: [(name: String, url: String)] = [
            ("App-x86_64.dmg", "https://github.com/o/r/releases/download/v1.4.2/App-x86_64.dmg"),
            ("App-arm64.zip", "https://github.com/o/r/releases/download/v1.4.2/App-arm64.zip"),
        ]
        GithubStubURLProtocol.stub(releaseJSON(assets: assets), forURL: apiURL())

        let source = GithubSource(pinnedOwner: "o", pinnedRepo: "r", directory: makeTempDirectory(), session: makeSession())
        let info = try await source.fetchUpdateInfo(for: makeApp())

        #expect(info?.downloadURL?.lastPathComponent == "App-x86_64.dmg")
    }

    // (15) Within one tier, the arm64/aarch64 label wins even when it comes
    // later and the earlier sibling carries the x86_64 label.
    @Test func arm64BeatsX64WithinTier() async throws {
        GithubStubURLProtocol.reset()
        let assets: [(name: String, url: String)] = [
            ("App-x86_64.zip", "https://github.com/o/r/releases/download/v1.4.2/App-x86_64.zip"),
            ("App-aarch64.zip", "https://github.com/o/r/releases/download/v1.4.2/App-aarch64.zip"),
        ]
        GithubStubURLProtocol.stub(releaseJSON(assets: assets), forURL: apiURL())

        let source = GithubSource(pinnedOwner: "o", pinnedRepo: "r", directory: makeTempDirectory(), session: makeSession())
        let info = try await source.fetchUpdateInfo(for: makeApp())

        #expect(info?.downloadURL?.lastPathComponent == "App-aarch64.zip")
    }

    // (16) No arch labels → first-match wins in asset array order.
    @Test func firstMatchWhenNoArchLabels() async throws {
        GithubStubURLProtocol.reset()
        let assets: [(name: String, url: String)] = [
            ("Alpha.dmg", "https://github.com/o/r/releases/download/v1.4.2/Alpha.dmg"),
            ("Beta.dmg", "https://github.com/o/r/releases/download/v1.4.2/Beta.dmg"),
        ]
        GithubStubURLProtocol.stub(releaseJSON(assets: assets), forURL: apiURL())

        let source = GithubSource(pinnedOwner: "o", pinnedRepo: "r", directory: makeTempDirectory(), session: makeSession())
        let info = try await source.fetchUpdateInfo(for: makeApp())

        #expect(info?.downloadURL?.lastPathComponent == "Alpha.dmg")
    }

    // (17) HTTPS floor: a non-https asset URL is skipped from the pick, so a
    // plain-http .dmg loses to an https .zip.
    @Test func nonHTTPSAssetSkippedFromPick() async throws {
        GithubStubURLProtocol.reset()
        let assets: [(name: String, url: String)] = [
            ("App.dmg", "http://insecure.example/App.dmg"),
            ("App.zip", "https://github.com/o/r/releases/download/v1.4.2/App.zip"),
        ]
        GithubStubURLProtocol.stub(releaseJSON(assets: assets), forURL: apiURL())

        let source = GithubSource(pinnedOwner: "o", pinnedRepo: "r", directory: makeTempDirectory(), session: makeSession())
        let info = try await source.fetchUpdateInfo(for: makeApp())

        #expect(info?.downloadURL?.lastPathComponent == "App.zip")
    }

    // (18) Sidecar present with valid content → sha256Hex accepted (upper-
    // case hex normalized to lowercase, first whitespace token taken),
    // confidence .high, detail names the sidecar; exactly one extra request.
    @Test func sidecarVerifiedHighConfidence() async throws {
        GithubStubURLProtocol.reset()
        let sidecarURL = "https://github.com/o/r/releases/download/v1.4.2/App.dmg.sha256"
        let assets: [(name: String, url: String)] = [
            ("App.dmg", "https://github.com/o/r/releases/download/v1.4.2/App.dmg"),
            ("App.dmg.sha256", sidecarURL),
        ]
        GithubStubURLProtocol.stub(releaseJSON(assets: assets), forURL: apiURL())
        GithubStubURLProtocol.stub("ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789  App.dmg\n", forURL: sidecarURL)

        let source = GithubSource(pinnedOwner: "o", pinnedRepo: "r", directory: makeTempDirectory(), session: makeSession())
        let info = try await source.fetchUpdateInfo(for: makeApp())

        #expect(info?.sha256Hex == "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789")
        #expect(info?.confidence == .high)
        #expect(info?.sourceDetail == "github: o/r; release asset 'App.dmg'; sha256 verified via sidecar 'App.dmg.sha256'")
        let urls = GithubStubURLProtocol.recordedRequests.map { $0.url.absoluteString }
        #expect(urls == [apiURL(), sidecarURL]) // one extra request, bounded
    }

    // (19) Sidecar present but MALFORMED content → honestly unverified:
    // sha256Hex nil, confidence .medium, self-attested detail. The fetch
    // itself still happened (bounded honesty, not silence).
    @Test func sidecarMalformedHonestlyNil() async throws {
        GithubStubURLProtocol.reset()
        let sidecarURL = "https://github.com/o/r/releases/download/v1.4.2/App.dmg.sha256"
        let assets: [(name: String, url: String)] = [
            ("App.dmg", "https://github.com/o/r/releases/download/v1.4.2/App.dmg"),
            ("App.dmg.sha256", sidecarURL),
        ]
        GithubStubURLProtocol.stub(releaseJSON(assets: assets), forURL: apiURL())
        GithubStubURLProtocol.stub("not-a-checksum  App.dmg\n", forURL: sidecarURL)

        let source = GithubSource(pinnedOwner: "o", pinnedRepo: "r", directory: makeTempDirectory(), session: makeSession())
        let info = try await source.fetchUpdateInfo(for: makeApp())

        #expect(info?.sha256Hex == nil)
        #expect(info?.confidence == .medium)
        #expect(info?.sourceDetail == "github: o/r; release asset 'App.dmg'; sha256 self-attested upstream source (not verified)")
        #expect(GithubStubURLProtocol.recordedRequests.count == 2)
    }

    // (20) Sidecar present but fetched over plain HTTP → skipped (https
    // floor on derived URLs), unverified: .medium, sha nil.
    @Test func sidecarNonHTTPSSkippedHonestUnverified() async throws {
        GithubStubURLProtocol.reset()
        let assets: [(name: String, url: String)] = [
            ("App.dmg", "https://github.com/o/r/releases/download/v1.4.2/App.dmg"),
            ("App.dmg.sha256", "http://insecure.example/App.dmg.sha256"),
        ]
        GithubStubURLProtocol.stub(releaseJSON(assets: assets), forURL: apiURL())

        let source = GithubSource(pinnedOwner: "o", pinnedRepo: "r", directory: makeTempDirectory(), session: makeSession())
        let info = try await source.fetchUpdateInfo(for: makeApp())

        #expect(info?.sha256Hex == nil)
        #expect(info?.confidence == .medium)
        #expect(info?.downloadURL?.lastPathComponent == "App.dmg")
        #expect(GithubStubURLProtocol.recordedRequests.count == 1) // sidecar never fetched
    }

    // (21) No sidecar asset → self-attested medium; detail exact.
    @Test func sidecarAbsentSelfAttestedMedium() async throws {
        GithubStubURLProtocol.reset()
        GithubStubURLProtocol.stub(releaseJSON(), forURL: apiURL())

        let source = GithubSource(pinnedOwner: "o", pinnedRepo: "r", directory: makeTempDirectory(), session: makeSession())
        let info = try await source.fetchUpdateInfo(for: makeApp())

        #expect(info?.sha256Hex == nil)
        #expect(info?.confidence == .medium)
        #expect(info?.sourceDetail == "github: o/r; release asset 'App.dmg'; sha256 self-attested upstream source (not verified)")
    }

    // (22) ETag flow, run 2: 200 (etag+body persist) then 304 → the CACHED
    // verbatim body is reused (request counter proves no refetch; run 2's
    // body would be unavailable anyway). If-None-Match travels on run 2.
    @Test func etag304ReusesCachedBody() async throws {
        GithubStubURLProtocol.reset()
        let endpoint = apiURL()
        GithubStubURLProtocol.stub(releaseJSON(tag: "1.0.1"), status: 200, headers: ["ETag": "\"sha-1abc\""], forURL: endpoint)

        let directory = makeTempDirectory()
        let source = GithubSource(pinnedOwner: "o", pinnedRepo: "r", directory: directory, session: makeSession())
        let first = try await source.fetchUpdateInfo(for: makeApp())
        #expect(first?.newestShortVersion == "1.0.1")

        // Run 2 hits the SAME directory's cache; the stub now answers 304
        // (no body would exist to refetch).
        GithubStubURLProtocol.reset()
        GithubStubURLProtocol.stub("", status: 304, headers: [:], forURL: endpoint)
        let second = try await source.fetchUpdateInfo(for: makeApp())

        #expect(second?.newestShortVersion == "1.0.1") // came from the cached body
        let releaseRequests = GithubStubURLProtocol.recordedRequests.filter { $0.url.absoluteString == endpoint }
        #expect(releaseRequests.count == 1) // run 2: exactly one conditional request
        #expect(releaseRequests.first?.headers["If-None-Match"] == "\"sha-1abc\"")
        #expect(releaseRequests.first?.headers["Accept"] == "application/vnd.github.v3+json")
    }

    // (23) Cache persistence across instances: an INDEPENDENTLY constructed
    // store reads the same file the first source persisted; and a second
    // SOURCE over the same directory reuses the cache through 304.
    @Test func etagCachePersistsAcrossStoreInstances() async throws {
        GithubStubURLProtocol.reset()
        let endpoint = apiURL()
        GithubStubURLProtocol.stub(releaseJSON(tag: "1.0.2"), status: 200, headers: ["ETag": "\"etag200\""], forURL: endpoint)

        let directory = makeTempDirectory()
        let sourceA = GithubSource(pinnedOwner: "o", pinnedRepo: "r", directory: directory, session: makeSession())
        _ = try await sourceA.fetchUpdateInfo(for: makeApp())

        let readback = try #require(GithubEtagStore(directory: directory).load())
        #expect(readback.etags["o/r"] == "\"etag200\"") // raw etag, verbatim
        #expect(readback.responses["o/r"]?.contains("1.0.2") == true) // verbatim body

        GithubStubURLProtocol.reset()
        GithubStubURLProtocol.stub("", status: 304, headers: [:], forURL: endpoint)
        let sourceB = GithubSource(pinnedOwner: "o", pinnedRepo: "r", directory: directory, session: makeSession())
        let second = try await sourceB.fetchUpdateInfo(for: makeApp())

        #expect(second?.newestShortVersion == "1.0.2") // through sourceB's store read
        #expect(GithubStubURLProtocol.recordedRequests.count == 1)
    }

    // (24) 404 on candidate one → continue to candidate two; the claim comes
    // from the SECOND repo's document. Request order preserved.
    @Test func notFoundContinuesToNextCandidate() async throws {
        GithubStubURLProtocol.reset()
        let expired = apiURL(owner: "gone", repo: "missing") // unregistered → 404
        let live = apiURL(owner: "here", repo: "present")
        GithubStubURLProtocol.stub(releaseJSON(tag: "2.0.0"), forURL: live)

        let first = try ref("gone", "missing")
        let secondRef = try ref("here", "present")
        let source = GithubSource(
            repoProvider: { _ in [first, secondRef] },
            directory: makeTempDirectory(),
            session: makeSession()
        )
        let info = try await source.fetchUpdateInfo(for: makeApp())

        #expect(info?.newestShortVersion == "2.0.0")
        #expect(GithubStubURLProtocol.recordedRequests.map { $0.url.absoluteString } == [expired, live])
    }

    // (25) 404 on the only (pinned) candidate → honest nil, single request.
    @Test func pinnedNotFoundHonestNil() async throws {
        GithubStubURLProtocol.reset() // nothing registered → pinned URL 404s

        let source = GithubSource(pinnedOwner: "o", pinnedRepo: "r", directory: makeTempDirectory(), session: makeSession())
        let info = try await source.fetchUpdateInfo(for: makeApp())

        #expect(info == nil)
        #expect(GithubStubURLProtocol.recordedRequests.map { $0.url.absoluteString } == [apiURL()])
    }

    // (26) 403 + X-RateLimit-Remaining "0" → the verbatim honest throw, so
    // UpdateCheckEngine.failures surfaces it ("May be rate limited.").
    @Test func rateLimitThrowsVerbatimMessage() async throws {
        GithubStubURLProtocol.reset()
        GithubStubURLProtocol.stub("", status: 403, headers: ["X-RateLimit-Remaining": "0"], forURL: apiURL())

        let source = GithubSource(pinnedOwner: "o", pinnedRepo: "r", directory: makeTempDirectory(), session: makeSession())
        do {
            let info = try await source.fetchUpdateInfo(for: makeApp())
            Issue.record("expected a rate-limit throw, got \(String(describing: info))")
        } catch {
            #expect(
                String(describing: error)
                    == "GitHub API rate limit exhausted (403) — releases/latest for 'o/r'"
            )
        }
    }

    // (27) 403 with remaining NOT "0" (or header absent) stays an honest
    // nil — only the exhausted-limit case throws.
    @Test func rateLimitNonZeroRemainingHonestNil() async throws {
        GithubStubURLProtocol.reset()
        GithubStubURLProtocol.stub("", status: 403, headers: ["X-RateLimit-Remaining": "999"], forURL: apiURL())

        let source = GithubSource(pinnedOwner: "o", pinnedRepo: "r", directory: makeTempDirectory(), session: makeSession())
        let info = try await source.fetchUpdateInfo(for: makeApp())

        #expect(info == nil) // honest miss, no throw
        #expect(GithubStubURLProtocol.recordedRequests.count == 1)
    }

    // (28) published_at tolerance: plain Z form, fractional-seconds form,
    // and missing/garbage → nil (never guessed).
    @Test func releaseDateTolerantParsing() async {
        let plain = GithubSource.releaseDate(from: "2026-10-01T10:00:00Z")
        let fractional = GithubSource.releaseDate(from: "2026-10-01T10:00:00.750Z")
        #expect(plain != nil)
        #expect(fractional != nil)
        #expect(GithubSource.releaseDate(from: nil) == nil)
        #expect(GithubSource.releaseDate(from: "") == nil)
        #expect(GithubSource.releaseDate(from: "not a date") == nil)
    }
}
