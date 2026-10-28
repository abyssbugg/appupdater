// CaskIndex tests — hermetic (custom URLProtocol stubs; NO network is touched, no
// /Applications or real Application Support is ever referenced). Swift Testing
// only: XCTest discovery is broken on this toolchain (Xcode 27 beta).
//
// Layout: TWO serialized suites, each with its OWN stub class and static state so
// the suites (and every other suite in this target) can run in parallel without
// touching each other's fixture tables — the cross-suite partition mirrors the
// per-lane file ownership. Whole-index fixtures are trimmed but true-to-shape
// (derived from the live sample shape in docs/evidence/ff.json); the ETag literal
// is the LIVE Updatest brew_api_etag.txt value quoted in docs/reverse/
// UPDATEST-FINDINGS.md §3.2 ("W/\"6ae11108-126336d\"") as shape provenance.
//
// Every test uses a UNIQUE UUID-named temp directory as the store's explicit
// persistence directory — the store's REQUIRED-directory design makes it
// impossible for a test to silently touch a real Application Support folder.

import Foundation
import Testing
@testable import AppUpdaterCore

// MARK: - Hermetic URL stub (whole-index endpoint)

/// Serves pre-registered fixture bodies per URL and records every request.
/// Unregistered URLs get a 404. Supports a hold gate used by the concurrency
/// dedupe test to pin all concurrent callers onto the single inflight task.
final class IndexStubURLProtocol: URLProtocol {
    struct StubResponse: Sendable {
        let status: Int
        let body: Data?
        let headers: [String: String]
        let fails: Bool

        static func success(_ body: Data?, status: Int, headers: [String: String]) -> StubResponse {
            StubResponse(status: status, body: body, headers: headers, fails: false)
        }
        static func networkFailure() -> StubResponse {
            StubResponse(status: 0, body: nil, headers: [:], fails: true)
        }
    }

    struct RecordedRequest: Sendable {
        let url: URL
        let userAgent: String?
        let ifNoneMatch: String?
    }

    private static let stubBox = StubBox<[String: StubResponse]>([:])
    private static let requestBox = StubBox<[RecordedRequest]>([])
    private static let holdBox = StubBox<Bool>(false)

    static func reset() {
        stubBox.with { stubs in stubs = [:] }
        Self.requestBox.with { requests in requests = [] }
        holdBox.with { hold in hold = false }
    }

    static func stub(_ json: String, status: Int = 200, headers: [String: String] = [:], forURLString url: String) {
        // Empty body (304 revalidation, blank-body probes) → no didLoad bytes.
        let body = json.isEmpty ? nil : Data(json.utf8)
        stubBox.with { stubs in
            stubs[url] = StubResponse.success(body, status: status, headers: headers)
        }
    }

    /// The request errors out instead of answering (transport failure).
    static func stubNetworkFailure(forURLString url: String) {
        stubBox.with { stubs in stubs[url] = StubResponse.networkFailure() }
    }

    static func holdResponses(_ on: Bool) {
        holdBox.with { hold in hold = on }
    }
    static func releaseHold() {
        holdResponses(false)
    }

    static var recordedRequests: [RecordedRequest] {
        Self.requestBox.with { requests in requests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Synchronous stubs complete inside startLoading; CFNetwork still invokes
    /// stopLoading on teardown and the abstract base throws unless overridden
    /// (cask lane gotcha, commit a350fde).
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let client else { return }
        Self.requestBox.with { requests in
            requests.append(RecordedRequest(
                url: url,
                userAgent: request.value(forHTTPHeaderField: "User-Agent"),
                ifNoneMatch: request.value(forHTTPHeaderField: "If-None-Match")))
        }
        let stub = Self.stubBox.with { stubs in stubs[url.absoluteString] }
        if let stub, stub.fails {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        // Concurrency-test gate: park here while callers pile onto the inflight task.
        while Self.holdBox.with({ hold in hold }) {
            Thread.sleep(forTimeInterval: 0.02)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub?.status ?? 404,
            httpVersion: "HTTP/1.1",
            headerFields: stub?.headers ?? ["Content-Type": "application/json"]
        )
        guard let response else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body = stub?.body { client.urlProtocol(self, didLoad: body) }
        client.urlProtocolDidFinishLoading(self)
    }
}

/// Tiny thread-safe box for stub state (independent copy from CaskSourceTests'
/// LockedBox so this lane's test file is self-contained against merge drift).
final class StubBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ initial: Value) { value = initial }

    func with<Result>(_ mutate: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return mutate(&value)
    }
}

/// Thread-safe box for the document-client suite's stub state.
final class DocStubBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ initial: Value) { value = initial }

    func with<Result>(_ mutate: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return mutate(&value)
    }
}

/// Serves pre-registered single-token documents (client-parity suite).
final class DocStubURLProtocol: URLProtocol {
    struct StubResponse: Sendable {
        let status: Int
        let body: Data?
    }

    private static let stubBox = DocStubBox<[String: StubResponse]>([:])
    private static let requestCount = DocStubBox<Int>(0)
    private static let lastUserAgent = DocStubBox<String?>(nil)

    static func reset() {
        stubBox.with { stubs in stubs = [:] }
        requestCount.with { count in count = 0 }
        lastUserAgent.with { agent in agent = nil }
    }

    static func stub(_ json: String, status: Int = 200, forToken token: String) {
        let key = "https://formulae.brew.sh/api/cask/\(token).json"
        stubBox.with { stubs in stubs[key] = StubResponse(status: status, body: Data(json.utf8)) }
    }

    static var requests: Int {
        requestCount.with { count in count }
    }
    static var lastRecordedUserAgent: String? {
        lastUserAgent.with { agent in agent }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let client else { return }
        Self.requestCount.with { count in count += 1 }
        Self.lastUserAgent.with { agent in agent = request.value(forHTTPHeaderField: "User-Agent") }
        let stub = Self.stubBox.with { stubs in stubs[url.absoluteString] }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub?.status ?? 404,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
        guard let response else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body = stub?.body { client.urlProtocol(self, didLoad: body) }
        client.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - Fixtures (trimmed real-shape JSON; whole index = array of cask documents)

private let indexEndpointURL = "https://formulae.brew.sh/api/cask.json"
private let liveETag = "W/\"6ae11108-126336d\"" // Updatest's live brew_api_etag.txt value (§3.2 shape provenance)
private let cacheFileName = "cask.json"
private let etagFileName = "cask.json.etag"
private let userAgent = "AppUpdater/0.1 (macOS)"

/// Four-record whole index exercising: array-name/string-sha decoding (firefox),
/// object-sha decoding (google-chrome), legacy string-name + bare-string app
/// artifact value (tor-browser), and the ALIAS-KILLER decoy — a record under the
/// derived token "chrome" whose artifacts do NOT match installed app "Chrome"
/// (artifact "Chrome Remote Desktop.app"), the case that forces the scan path.
private let indexFixtureJSON = """
[
  {
    "token": "firefox",
    "name": ["Mozilla Firefox"],
    "desc": "Web browser",
    "homepage": "https://www.mozilla.org/firefox/",
    "url": "https://download-installer.cdn.mozilla.net/pub/firefox/releases/158.0.1/mac/en-US/Firefox 158.0.1.dmg",
    "version": "158.0.1",
    "sha256": "1d7aa96b51fc9110185047de18228ac87238fba5e42bba53c9d696f88878cba6",
    "artifacts": [
      {"app": ["Firefox.app"], "target": "/Applications/Firefox.app"}
    ]
  },
  {
    "token": "google-chrome",
    "name": ["Google Chrome"],
    "desc": "Web browser",
    "homepage": "https://www.google.com/chrome/",
    "url": "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg",
    "version": "156.0.8078.48",
    "sha256": {"string": "2f2c9c5e2d98e83428c5cf04309f6a9ea70355a1af69ea7015ee8b3f0e70c96a", "algorithm": "sha256"},
    "artifacts": [
      {"app": ["Google Chrome.app"]}
    ]
  },
  {
    "token": "tor-browser",
    "name": "Tor Browser",
    "desc": "Privacy browser",
    "homepage": "https://www.torproject.org/",
    "url": "https://dist.torproject.org/torbrowser/14.0.6/Tor Browser.dmg",
    "version": "14.0.6",
    "sha256": "9396f43b01a7a5c0330ad3f3b554e83fd8e35a4d1a25d4b6b80f9b09cb19f7bb",
    "artifacts": [
      {"app": "Tor Browser.app"}
    ]
  },
  {
    "token": "chrome",
    "name": ["Chrome Remote Desktop"],
    "desc": "Remote access helper",
    "homepage": "https://remotedesktop.google.com/",
    "url": "https://dl.google.com/chrome-remote-desktop/remotedesktop.dmg",
    "version": "159.0.0.1",
    "sha256": "5d5d7f39d7893a3d2a4f03d6a301d7a2e5e93b5f6b6c0f0f1c2a4d5e6f708091",
    "artifacts": [
      {"app": ["Chrome Remote Desktop.app"]}
    ]
  }
]
"""

/// Same index with only firefox's version key advanced — proves a 200 refresh
/// REPLACES the in-memory records (the earlier disk bytes are retired).
private let updatedIndexFixtureJSON = indexFixtureJSON
    .replacingOccurrences(of: "\"version\": \"158.0.1\"", with: "\"version\": \"159.0\"")

/// Two records whose app artifacts BOTH validate app "Diff Viewer"; the second
/// record's displayName is the exact (case-insensitive) app name, proving
/// displayName preference beats array order.
private let tiedExactNameFixtureJSON = """
[
  {
    "token": "diffviewer-first",
    "name": ["Diff Viewer Pro"],
    "homepage": "https://example.com/first",
    "url": "https://example.com/first.dmg",
    "version": "1.0",
    "sha256": "aaaaaa96b51fc9110185047de18228ac87238fba5e42bba53c9d696f88878cba6",
    "artifacts": [{"app": ["Diff Viewer.app"]}]
  },
  {
    "token": "diffviewer-second",
    "name": ["Diff Viewer"],
    "homepage": "https://example.com/second",
    "url": "https://example.com/second.dmg",
    "version": "2.0",
    "sha256": "bbbbbb51fc9110185047de18228ac87238fba5e42bba53c9d696f88878cba6",
    "artifacts": [{"app": ["Diff Viewer.app"]}]
  }
]
"""

/// Several matches without a displayName tiebreak — the FIRST record in index
/// order is kept (documented tiebreak of last resort).
private let severalEqualNameFixtureJSON = """
[
  {
    "token": "diffviewer-alpha",
    "name": ["Diff Viewer"],
    "homepage": "https://example.com/alpha",
    "url": "https://example.com/alpha.dmg",
    "version": "1.0",
    "sha256": "cccccc51fc9110185047de18228ac87238fba5e42bba53c9d696f88878cba6",
    "artifacts": [{"app": ["Diff Viewer.app"]}]
  },
  {
    "token": "diffviewer-beta",
    "name": ["Diff Viewer"],
    "homepage": "https://example.com/beta",
    "url": "https://example.com/beta.dmg",
    "version": "2.0",
    "sha256": "dddddd51fc9110185047de18228ac87238fba5e42bba53c9d696f88878cba6",
    "artifacts": [{"app": ["Diff Viewer.app"]}]
  }
]
"""

/// A loaded record with a blank version must never surface a synthesized claim.
private let blankVersionIndexFixtureJSON = """
[
  {
    "token": "firefox",
    "name": ["Mozilla Firefox"],
    "version": "",
    "url": "https://example.com/firefox.dmg",
    "artifacts": [{"app": ["Firefox.app"]}]
  }
]
"""

// Single-document fixtures for CaskDocumentClient parity (CaskSource-shaped).

private let firefoxDocumentJSON = """
{
  "token": "firefox",
  "name": ["Mozilla Firefox"],
  "desc": "Web browser",
  "homepage": "https://www.mozilla.org/firefox/",
  "url": "https://download-installer.cdn.mozilla.net/pub/firefox/releases/158.0.1/mac/en-US/Firefox 158.0.1.dmg",
  "version": "158.0.1",
  "sha256": "1d7aa96b51fc9110185047de18228ac87238fba5e42bba53c9d696f88878cba6",
  "artifacts": [
    {"app": ["Firefox.app"], "target": "/Applications/Firefox.app"}
  ]
}
"""

/// Legacy shapes in one document: `name` STRING, `sha256` OBJECT, app artifact
/// rendered as a bare string — all occur across cask-schema versions.
private let torLegacyShapesJSON = """
{
  "token": "tor-browser",
  "name": "Tor Browser",
  "homepage": "https://www.torproject.org/",
  "url": "https://dist.torproject.org/torbrowser/14.0.6/Tor Browser.dmg",
  "version": "14.0.6",
  "sha256": {"string": "9396f43b01a7a5c0330ad3f3b554e83fd8e35a4d1a25d4b6b80f9b09cb19f7bb", "algorithm": "sha256"},
  "artifacts": [{"app": "Tor Browser.app"}]
}
"""

/// Document with the `version` KEY ABSENT (older-shape simulation) — never
/// synthesize a version.
private let versionlessDocumentJSON = """
{
  "token": "firefox",
  "name": ["Mozilla Firefox"],
  "homepage": "https://www.mozilla.org/firefox/",
  "url": "https://example.com/firefox.dmg",
  "sha256": "1d7aa96b51fc9110185047de18228ac87238fba5e42bba53c9d696f88878cba6",
  "artifacts": [{"app": ["Firefox.app"]}]
}
"""

/// Loop until the predicate holds (stub request arrival is asynchronous but
/// immediate; this keeps the concurrency test deterministic without flaky sleeps).
private func waitUntil(timeout: TimeInterval = 5.0, _ predicate: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000) // 20 ms
    }
    return predicate()
}

// MARK: - Store + source tests

@Suite(.serialized)
struct CaskIndexStoreTests {

    /// Unique temp directory per test (never real Application Support); the store
    /// is REQUIRED to take it explicitly.
    private func makeStore() async -> (store: CaskIndexStore, directory: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cask-index-\(UUID().uuidString)", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IndexStubURLProtocol.self]
        let store = CaskIndexStore(directory: dir, session: URLSession(configuration: configuration))
        return (store, dir)
    }

    private func makeApp(name: String, path: String, bundleIdentifier: String) -> InstalledApp {
        InstalledApp(bundleIdentifier: bundleIdentifier, name: name, path: path)
    }

    private func writeFixture(_ text: String, name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: nil)
        try Data(text.utf8).write(to: directory.appendingPathComponent(name))
    }

    private let firefoxApp = InstalledApp(
        bundleIdentifier: "org.mozilla.firefox",
        name: "Firefox",
        path: "/Applications/Firefox.app")
    private let chromeApp = InstalledApp(
        bundleIdentifier: "com.google.Chrome",
        name: "Chrome",
        path: "/Applications/Google Chrome.app")

    // (1) Disk cache decodes from the explicit directory; the conditional GET is
    // sent with the persisted ETag and a 304 revalidates the loaded records with
    // exactly ONE network request (no byte refetch).
    @Test func diskCacheDecodeAnd304Revalidation() async throws {
        IndexStubURLProtocol.reset()
        IndexStubURLProtocol.stub("", status: 304, forURLString: indexEndpointURL) // no body on revalidation
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeFixture(indexFixtureJSON, name: cacheFileName, in: dir)
        try writeFixture(liveETag, name: etagFileName, in: dir)

        let loaded = await store.ensureLoaded()
        #expect(loaded == true)
        #expect(await store.isLoaded == true)
        #expect(await store.cachedRecordCount == 4)
        #expect(await store.lastError == nil)

        let requests = IndexStubURLProtocol.recordedRequests
        #expect(requests.count == 1)
        #expect(requests.first?.url.absoluteString == indexEndpointURL)
        #expect(requests.first?.userAgent == userAgent)
        #expect(requests.first?.ifNoneMatch == liveETag)

        // Records loaded from DISK are immediately matchable.
        let torRecord = try #require(await store.record(withToken: "tor-browser"))
        #expect(torRecord.token == "tor-browser")
    }

    // (2) A changed ETag → the server answers 200: records are REPLACED by the new
    // body and the new ETag overwrites the persisted etag file.
    @Test func revalidation200ReplacesRecordsAndPersistsETag() async throws {
        IndexStubURLProtocol.reset()
        IndexStubURLProtocol.stub(updatedIndexFixtureJSON, headers: ["ETag": "W/new-etag"], forURLString: indexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeFixture(indexFixtureJSON, name: cacheFileName, in: dir)
        try writeFixture("W/old-etag", name: etagFileName, in: dir)

        #expect(await store.ensureLoaded() == true)
        let refreshed = try #require(await store.record(withToken: "firefox"))
        #expect(refreshed.version == "159.0") // the NEW document's claim, not disk's 158.0.1
        #expect(await store.cachedRecordCount == 4)

        let requests = IndexStubURLProtocol.recordedRequests
        #expect(requests.count == 1)
        #expect(requests.first?.ifNoneMatch == "W/old-etag") // conditional request carried the persisted etag

        let persistedETag = try #require(try? String(
            contentsOf: dir.appendingPathComponent(etagFileName), encoding: .utf8))
        #expect(persistedETag == "W/new-etag")
    }

    // (3) Fresh store (no cache files): the index is downloaded whole, persisted
    // with its ETag, and the NEXT cycle sends If-None-Match from the persisted
    // file (the persisted etag is the one source of truth).
    @Test func freshLoad200PersistsBytesAndETagForNextCycle() async throws {
        IndexStubURLProtocol.reset()
        IndexStubURLProtocol.stub(indexFixtureJSON, headers: ["ETag": liveETag], forURLString: indexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        #expect(await store.cachedRecordCount == 4)

        let cacheURL = dir.appendingPathComponent(cacheFileName)
        let persistedBytes = try #require(try? Data(contentsOf: cacheURL))
        #expect(persistedBytes == Data(indexFixtureJSON.utf8)) // RAW body persisted, not re-encoded
        let persistedETag = try #require(try? String(
            contentsOf: dir.appendingPathComponent(etagFileName), encoding: .utf8))
        #expect(persistedETag == liveETag)

        // Second cycle: revalidates from the persisted state (no full refetch).
        IndexStubURLProtocol.stub("", status: 304, forURLString: indexEndpointURL)
        #expect(await store.ensureLoaded() == true)
        #expect(await store.cachedRecordCount == 4)
        let requests = IndexStubURLProtocol.recordedRequests
        #expect(requests.count == 2)
        #expect(requests[0].ifNoneMatch == nil) // fresh load is unconditional
        #expect(requests[1].ifNoneMatch == liveETag) // persisted etag drives the conditional GET
    }

    // (4) Non-200 status → the verbatim status lands in lastError and nothing is
    // loaded (honest failure, no partial state).
    @Test func serverErrorRecordsVerbatimLastError() async throws {
        IndexStubURLProtocol.reset()
        IndexStubURLProtocol.stub("{\"message\": \"unexpected gatekeeper\"}", status: 500, forURLString: indexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let loaded = await store.ensureLoaded()
        #expect(loaded == false)
        #expect(await store.lastError == "HTTP 500")
        #expect(await store.isLoaded == false)
        #expect(await store.cachedRecordCount == 0)
        let requests = IndexStubURLProtocol.recordedRequests
        #expect(requests.count == 1)
        #expect(requests.first?.ifNoneMatch == nil) // nothing usable → no conditional request
    }

    // (5) Transport failure → the thrown URLError is recorded verbatim.
    @Test func networkFailureRecordsVerbatimError() async throws {
        IndexStubURLProtocol.reset()
        IndexStubURLProtocol.stubNetworkFailure(forURLString: indexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let loaded = await store.ensureLoaded()
        #expect(loaded == false)
        let lastError = await store.lastError
        #expect(lastError?.contains("NSURLErrorDomain") == true) // String(describing:) of the thrown error
        #expect(await store.cachedRecordCount == 0)
    }

    // (6) Poisoned disk cache: the disk decode fails, so the cycle deliberately
    // sends NO If-None-Match (a cache it cannot decode never claims its ETag) and
    // the network retry replaces the poison with valid bytes + etag.
    @Test func poisonedDiskCacheSkipsIfNoneMatchAndRefetches() async throws {
        IndexStubURLProtocol.reset()
        IndexStubURLProtocol.stub(indexFixtureJSON, headers: ["ETag": "W/fresh-etag"], forURLString: indexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeFixture("{ this is not json }", name: cacheFileName, in: dir)
        try writeFixture(liveETag, name: etagFileName, in: dir)

        #expect(await store.ensureLoaded() == true)
        #expect(await store.cachedRecordCount == 4)

        let requests = IndexStubURLProtocol.recordedRequests
        #expect(requests.count == 1)
        #expect(requests.first?.ifNoneMatch == nil) // decode failure → unconditional GET

        let persistedBytes = try #require(try? Data(
            contentsOf: dir.appendingPathComponent(cacheFileName)))
        #expect(persistedBytes == Data(indexFixtureJSON.utf8)) // poison replaced
        let persistedETag = try #require(try? String(
            contentsOf: dir.appendingPathComponent(etagFileName), encoding: .utf8))
        #expect(persistedETag == "W/fresh-etag")
    }

    // (7) Stale-serve: a failed revalidation leaves the previously loaded records
    // usable for matching — stale-but-verifiable data beats an empty verdict, and
    // lastError carries the honest revalidation failure.
    @Test func staleServeAfterFailedRevalidation() async throws {
        IndexStubURLProtocol.reset()
        IndexStubURLProtocol.stubNetworkFailure(forURLString: indexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeFixture(indexFixtureJSON, name: cacheFileName, in: dir)
        try writeFixture(liveETag, name: etagFileName, in: dir)

        #expect(await store.ensureLoaded() == false) // the CYCLE failed
        #expect(await store.lastError?.contains("NSURLErrorDomain") == true)
        // …but the loaded records remain verifiably usable.
        #expect(await store.isLoaded == true)
        #expect(await store.cachedRecordCount == 4)
        #expect(await store.record(withToken: "firefox") != nil)
    }

    // (8) A 304 with NO usable cached records is a protocol absurdity: recorded
    // verbatim, returns false, and the persisted ETag is dropped so the next
    // cycle goes unconditional (self-heal).
    @Test func noUsableCache304RecordsAbsurdityAndDropsEtag() async throws {
        IndexStubURLProtocol.reset()
        IndexStubURLProtocol.stub("", status: 304, forURLString: indexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeFixture(liveETag, name: etagFileName, in: dir) // etag WITHOUT a cache file

        #expect(await store.ensureLoaded() == false)
        #expect(await store.lastError == "HTTP 304 without a usable cached cask.json")
        #expect(await store.isLoaded == false)

        let requests = IndexStubURLProtocol.recordedRequests
        #expect(requests.first?.ifNoneMatch == nil) // no usable records → no conditional claim
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(etagFileName).path) == false) // self-heal
    }

    // (9) Exact-token record lookup: hit returns the record, miss returns nil.
    @Test func recordTokenHitAndMiss() async throws {
        IndexStubURLProtocol.reset()
        IndexStubURLProtocol.stub(indexFixtureJSON, forURLString: indexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        let hit = try #require(await store.record(withToken: "google-chrome"))
        #expect(hit.token == "google-chrome")
        #expect(hit.version == "156.0.8078.48")
        #expect(await store.record(withToken: "does-not-exist") == nil)
    }

    // (10) Token-direct match still REQUIRES artifact validation: app "Firefox"
    // → derived token "firefox" → the token path wins with artifact evidence.
    @Test func tokenDirectMatchValidatesArtifacts() async throws {
        IndexStubURLProtocol.reset()
        IndexStubURLProtocol.stub(indexFixtureJSON, forURLString: indexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        let match = try #require(await store.resolvedMatch(for: firefoxApp))
        guard case .token(let token, let record) = match else {
            Issue.record("expected the token path, got \(match)")
            return
        }
        #expect(token == "firefox")
        #expect(record.token == "firefox")
        #expect((try #require(await store.bestMatch(for: firefoxApp)).token) == "firefox")
    }

    // (11) THE ALIAS-KILLER: derived token "chrome" HAS a record but its
    // artifacts do NOT match app "Chrome" → the artifact-name scan finds the
    // correct record under a DIFFERENT token (google-chrome) — zero extra fetches,
    // zero alias-table maintenance.
    @Test func aliasKillerScanFindsRecordUnderDifferentToken() async throws {
        IndexStubURLProtocol.reset()
        IndexStubURLProtocol.stub(indexFixtureJSON, forURLString: indexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        let match = try #require(await store.resolvedMatch(for: chromeApp))
        guard case .artifactName(let record, let artifact) = match else {
            Issue.record("expected the artifact-name scan path, got \(match)")
            return
        }
        #expect(record.token == "google-chrome")
        #expect(artifact == "Google Chrome.app")
        #expect((try #require(await store.bestMatch(for: chromeApp)).token) == "google-chrome")
    }

    // (12) Nothing validates → nil (honest miss; never a weaker guess).
    @Test func noMatchReturnsNil() async throws {
        IndexStubURLProtocol.reset()
        IndexStubURLProtocol.stub(indexFixtureJSON, forURLString: indexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        let stranger = makeApp(name: "No Such App", path: "/Applications/No-such.app", bundleIdentifier: "org.example.missing")
        let match = await store.resolvedMatch(for: stranger)
        #expect(match == nil) // optional-vs-nil comparison, no Equatable requirement
        #expect(await store.bestMatch(for: stranger) == nil)
    }

    // (13) Multiple artifact matches → prefer the record whose displayName equals
    // the app name case-insensitively, even though it is LATER in index order.
    @Test func displayNameTiebreakPrefersExactName() async throws {
        IndexStubURLProtocol.reset()
        IndexStubURLProtocol.stub(tiedExactNameFixtureJSON, forURLString: indexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        let viewer = makeApp(name: "Diff Viewer", path: "/Applications/Diff Viewer.app", bundleIdentifier: "com.example.diffviewer")
        let chosen = try #require(await store.bestMatch(for: viewer))
        #expect(chosen.token == "diffviewer-second") // exact name beats array order
    }

    // (14) Several matches WITHOUT a displayName tiebreak → the first record in
    // index order is kept (documented rule, logged when it fires).
    @Test func severalMatchesKeepFirstInArrayOrder() async throws {
        IndexStubURLProtocol.reset()
        IndexStubURLProtocol.stub(severalEqualNameFixtureJSON, forURLString: indexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        let viewer = makeApp(name: "DIFF VIEWER", path: "/Applications/Diff Viewer.app", bundleIdentifier: "com.example.diffviewer")
        let chosen = try #require(await store.bestMatch(for: viewer))
        #expect(chosen.token == "diffviewer-alpha") // first in array order
    }

    // (15) Concurrent ensureLoaded calls share ONE inflight task: exactly one
    // network request, every caller receives the same TRUE verdict. The stub's
    // hold gate parks the first caller; the remaining nine then dedupe onto it.
    @Test func dedupesConcurrentEnsureLoads() async throws {
        IndexStubURLProtocol.reset()
        IndexStubURLProtocol.stub(indexFixtureJSON, headers: ["ETag": liveETag], forURLString: indexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        IndexStubURLProtocol.holdResponses(true)
        defer { IndexStubURLProtocol.releaseHold() }

        let tasks = (0..<10).map { _ in Task { await store.ensureLoaded() } }
        #expect(await waitUntil { IndexStubURLProtocol.recordedRequests.count == 1 } == true)
        try? await Task.sleep(nanoseconds: 200_000_000) // let all entrants pile onto the inflight task
        IndexStubURLProtocol.releaseHold()

        for task in tasks {
            #expect(await task.value == true)
        }
        #expect(IndexStubURLProtocol.recordedRequests.count == 1) // single fetch for ten callers
    }

    // (16) dropCache wipes files AND memory; the store is semantically "never
    // loaded" afterwards (lastError included).
    @Test func dropCacheWipesState() async throws {
        IndexStubURLProtocol.reset()
        IndexStubURLProtocol.stub(indexFixtureJSON, headers: ["ETag": liveETag], forURLString: indexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(cacheFileName).path) == true)

        await store.dropCache()
        #expect(await store.isLoaded == false)
        #expect(await store.cachedRecordCount == 0)
        #expect(await store.lastError == nil)
        #expect(await store.record(withToken: "firefox") == nil)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(cacheFileName).path) == false)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(etagFileName).path) == false)

        // A cycle after dropping works again, from a genuinely fresh state.
        IndexStubURLProtocol.stub("{\"message\": \"down\"}", status: 503, forURLString: indexEndpointURL)
        #expect(await store.ensureLoaded() == false) // stub now answers 503
        #expect(await store.lastError == "HTTP 503")
    }

    // (17) CaskIndexSource over the loaded index — token path: UpdateInfo is the
    // exact `.info` mapping of CaskSource.lookup (trim/nil/space-encode fallback
    // unchanged) and sourceDetail names the token basis honestly.
    @Test func sourceTokenPathBuildsExactInfo() async throws {
        IndexStubURLProtocol.reset()
        IndexStubURLProtocol.stub(indexFixtureJSON, forURLString: indexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        let source = CaskIndexSource(store: store)
        let info = try #require(try await source.fetchUpdateInfo(for: firefoxApp))

        #expect(info.source == .cask)
        #expect(info.newestShortVersion == "158.0.1")
        #expect(info.newestBundleVersion == nil)
        #expect(info.downloadURL?.absoluteString == "https://download-installer.cdn.mozilla.net/pub/firefox/releases/158.0.1/mac/en-US/Firefox%20158.0.1.dmg")
        #expect(info.sha256Hex == "1d7aa96b51fc9110185047de18228ac87238fba5e42bba53c9d696f88878cba6")
        #expect(info.minimumSystemVersion == nil)
        #expect(info.releaseNotes == "https://www.mozilla.org/firefox/") // homepage ?? desc
        #expect(info.confidence == .medium)
        #expect(info.sourceDetail == "Homebrew cask whole-index; matched by token 'firefox'; self-attested (sha256 lives in the same unsigned JSON).")
    }

    // (18) CaskIndexSource artifact-name basis + object-shape sha256 flows
    // through, verbatim sourceDetail for the alias-killer path.
    @Test func sourceArtifactBasisViaAliasKiller() async throws {
        IndexStubURLProtocol.reset()
        IndexStubURLProtocol.stub(indexFixtureJSON, forURLString: indexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        let source = CaskIndexSource(store: store)
        let info = try #require(try await source.fetchUpdateInfo(for: chromeApp))

        #expect(info.newestShortVersion == "156.0.8078.48")
        #expect(info.sha256Hex == "2f2c9c5e2d98e83428c5cf04309f6a9ea70355a1af69ea7015ee8b3f0e70c96a") // object-shape sha256
        let expectedDetail = "Homebrew cask whole-index; matched by artifact-name 'Google Chrome.app'; self-attested (sha256 lives in the same unsigned JSON)."
        #expect(info.sourceDetail == expectedDetail)
    }

    // (19) Honest nil when nothing in the loaded index validates.
    @Test func sourceReturnsNilWhenIndexHasNothingUsable() async throws {
        IndexStubURLProtocol.reset()
        IndexStubURLProtocol.stub(indexFixtureJSON, forURLString: indexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        let source = CaskIndexSource(store: store)
        let stranger = makeApp(name: "No Such App", path: "/Applications/No-such.app", bundleIdentifier: "org.example.missing")
        #expect(try await source.fetchUpdateInfo(for: stranger) == nil)
    }

    // (20) Blank version → nil, never synthesized (both the blank string and the
    // absent-key shapes).
    @Test func sourceNeverSynthesizesBlankOrMissingVersion() async throws {
        IndexStubURLProtocol.reset()
        IndexStubURLProtocol.stub(blankVersionIndexFixtureJSON, forURLString: indexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        let source = CaskIndexSource(store: store)
        #expect(try await source.fetchUpdateInfo(for: firefoxApp) == nil) // blank "version": ""
    }

    // (21) Literal spaces in cask urls go through the same percent-encoding
    // fallback as the single-cask source (tor-browser's URL has a raw space).
    @Test func sourceEncodesLiteralSpaceURL() async throws {
        IndexStubURLProtocol.reset()
        IndexStubURLProtocol.stub(indexFixtureJSON, forURLString: indexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        let source = CaskIndexSource(store: store)
        let torApp = makeApp(name: "Tor Browser", path: "/Applications/Tor Browser.app", bundleIdentifier: "org.torproject.torbrowser")
        let info = try #require(try await source.fetchUpdateInfo(for: torApp))
        #expect(info.downloadURL?.absoluteString == "https://dist.torproject.org/torbrowser/14.0.6/Tor%20Browser.dmg")
    }
}

// MARK: - CaskDocumentClient parity tests (single-token pipeline)

@Suite(.serialized)
struct CaskDocumentClientTests {

    private func makeClient() -> CaskDocumentClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DocStubURLProtocol.self]
        return CaskDocumentClient(session: URLSession(configuration: configuration))
    }

    private let firefoxApp = InstalledApp(
        bundleIdentifier: "org.mozilla.firefox",
        name: "Firefox",
        path: "/Applications/Firefox.app")
    private let torApp = InstalledApp(
        bundleIdentifier: "org.torproject.torbrowser",
        name: "Tor Browser",
        path: "/Applications/Tor Browser.app")

    // (22) Parity happy path: 200 + artifact-valid document → .info with the
    // exact CaskSource.fetchUpdateInfo field mapping, one request, identifying
    // User-Agent.
    @Test func clientParityHappyPath() async throws {
        DocStubURLProtocol.reset()
        DocStubURLProtocol.stub(firefoxDocumentJSON, forToken: "firefox")
        let client = makeClient()

        let outcome = try await client.lookup(token: "firefox", for: firefoxApp)
        guard case .info(let info) = outcome else {
            Issue.record("expected .info, got \(outcome)")
            return
        }
        #expect(info.source == .cask)
        #expect(info.newestShortVersion == "158.0.1")
        #expect(info.newestBundleVersion == nil)
        #expect(info.downloadURL?.absoluteString == "https://download-installer.cdn.mozilla.net/pub/firefox/releases/158.0.1/mac/en-US/Firefox%20158.0.1.dmg")
        #expect(info.sha256Hex == "1d7aa96b51fc9110185047de18228ac87238fba5e42bba53c9d696f88878cba6")
        #expect(info.releaseNotes == "https://www.mozilla.org/firefox/")
        #expect(info.confidence == .medium)
        #expect(info.sourceDetail == "Homebrew cask metadata is public but self-attested (sha256 lives in the same unsigned JSON).")

        #expect(DocStubURLProtocol.requests == 1)
        #expect(DocStubURLProtocol.lastRecordedUserAgent == userAgent)
    }

    // (23) Parity: unknown token → HTTP 404 → .notFound (the alias-retry trigger,
    // for whoever swaps this client into CaskSource internals).
    @Test func clientNotFound404() async throws {
        DocStubURLProtocol.reset() // nothing registered → 404 everywhere
        let client = makeClient()

        let outcome = try await client.lookup(token: "no-such-token", for: firefoxApp)
        guard case .notFound = outcome else {
            Issue.record("expected .notFound, got \(outcome)")
            return
        }
    }

    // (24) Parity: artifact mismatch (the document is for a different app) →
    // .noResult, never a misattributed claim.
    @Test func clientArtifactMismatchNoResult() async throws {
        DocStubURLProtocol.reset()
        DocStubURLProtocol.stub(firefoxDocumentJSON, forToken: "misattributed")
        let client = makeClient()

        let sparkleApp = InstalledApp(
            bundleIdentifier: "org.sparkle-project.SparkleTest",
            name: "Sparkle",
            path: "/Applications/Sparkle.app")
        let outcome = try await client.lookup(token: "misattributed", for: sparkleApp)
        guard case .noResult = outcome else {
            Issue.record("expected .noResult for artifact mismatch, got \(outcome)")
            return
        }
    }

    // (25) Parity: document WITHOUT a `version` key → .noResult, never synthesize.
    @Test func clientNoVersionNoResult() async throws {
        DocStubURLProtocol.reset()
        DocStubURLProtocol.stub(versionlessDocumentJSON, forToken: "firefox")
        let client = makeClient()

        let outcome = try await client.lookup(token: "firefox", for: firefoxApp)
        guard case .noResult = outcome else {
            Issue.record("expected .noResult for missing version, got \(outcome)")
            return
        }
    }

    // (26) Parity: empty body with 200 (proxy/gateway answer) → .noResult.
    @Test func clientEmptyBodyNoResult() async throws {
        DocStubURLProtocol.reset()
        DocStubURLProtocol.stub("", forToken: "firefox")
        let client = makeClient()

        let outcome = try await client.lookup(token: "firefox", for: firefoxApp)
        guard case .noResult = outcome else {
            Issue.record("expected .noResult for empty body, got \(outcome)")
            return
        }
    }

    // (27) Parity: malformed JSON → .noResult (honest nil; the frozen `throws` is
    // never violated).
    @Test func clientMalformedJSONNoResult() async throws {
        DocStubURLProtocol.reset()
        DocStubURLProtocol.stub("{\"token\": \"firefox\", \"versio", forToken: "firefox")
        let client = makeClient()

        let outcome = try await client.lookup(token: "firefox", for: firefoxApp)
        guard case .noResult = outcome else {
            Issue.record("expected .noResult for malformed JSON, got \(outcome)")
            return
        }
    }

    // (28) Parity: non-404 server error → .noResult (stays an honest nil).
    @Test func clientServerErrorNoResult() async throws {
        DocStubURLProtocol.reset()
        DocStubURLProtocol.stub("{\"message\": \"down\"}", status: 500, forToken: "firefox")
        let client = makeClient()

        let outcome = try await client.lookup(token: "firefox", for: firefoxApp)
        guard case .noResult = outcome else {
            Issue.record("expected .noResult for HTTP 500, got \(outcome)")
            return
        }
    }

    // (29) Parity: the documented shape variants decode tolerantly — `name` as a
    // STRING, `sha256` as a {"string": …} OBJECT, and the app artifact as a bare
    // string — plus the literal-space URL fallback rides along.
    @Test func clientTolerantShapesInfo() async throws {
        DocStubURLProtocol.reset()
        DocStubURLProtocol.stub(torLegacyShapesJSON, forToken: "tor-browser")
        let client = makeClient()

        let outcome = try await client.lookup(token: "tor-browser", for: torApp)
        guard case .info(let info) = outcome else {
            Issue.record("expected .info for tolerant shapes, got \(outcome)")
            return
        }
        #expect(info.newestShortVersion == "14.0.6")
        #expect(info.sha256Hex == "9396f43b01a7a5c0330ad3f3b554e83fd8e35a4d1a25d4b6b80f9b09cb19f7bb") // object shape
        #expect(info.downloadURL?.absoluteString == "https://dist.torproject.org/torbrowser/14.0.6/Tor%20Browser.dmg") // space fallback
        #expect(info.releaseNotes == "https://www.torproject.org/")
    }
}
