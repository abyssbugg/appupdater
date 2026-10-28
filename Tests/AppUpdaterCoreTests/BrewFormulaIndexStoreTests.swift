// BrewFormulaIndexStore tests — the ETag-cached formula whole-index store.
// Hermetic (custom URLProtocol stubs; NO network is touched, no real
// Application Support is ever referenced — every test uses a UNIQUE UUID-named
// temp directory as the store's explicitly-required persistence directory, the
// CaskIndexTests discipline). Swift Testing only: XCTest discovery is broken
// on this toolchain (Xcode 27 beta).
//
// Layout: ONE serialized suite with its OWN stub class + static state so the
// suites in this target can run in parallel without touching each other's
// fixture tables. Fixtures are trimmed but true-to-shape formula.json records
// (modern `versions.stable` map, legacy top-level `version` string, and a
// versionless record — never a synthesized version).

import Foundation
import Testing
@testable import AppUpdaterCore

// MARK: - Hermetic URL stub (formula whole-index endpoint)

/// Serves pre-registered fixture bodies per URL and records every request.
/// Unregistered URLs get a 404. Supports a hold gate used by the concurrency
/// dedupe test to pin all concurrent callers onto the single inflight task.
final class FormulaStubURLProtocol: URLProtocol {
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

    private static let stubBox = FormulaStubBox<[String: StubResponse]>([:])
    private static let requestBox = FormulaStubBox<[RecordedRequest]>([])
    private static let holdBox = FormulaStubBox<Bool>(false)

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

/// Tiny thread-safe box for stub state (an independent copy so this file is
/// self-contained against merge drift).
final class FormulaStubBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ initial: Value) { value = initial }

    func with<Result>(_ mutate: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return mutate(&value)
    }
}

// MARK: - Fixtures (trimmed real-shape JSON; whole index = array of formula docs)

private let formulaIndexEndpointURL = "https://formulae.brew.sh/api/formula.json"
private let formulaCacheFileName = "formula.json"
private let formulaEtagFileName = "formula.json.etag"
private let formulaUserAgent = "AppUpdater/0.1 (macOS)"
private let formulaLiveETag = "W/\"0f4d2a1b-2f4a9e\""

/// Four-record whole index exercising: the MODERN `versions` map (wget, with
/// `head` + boolean `bottle` keys that decode-lite must ignore), the modern
/// map with `"bottle": false` (node@20 — a BOOL in the versions object), the
/// LEGACY top-level `version` string (gnupg), and a VERSIONLESS record (jq —
/// version decodes nil, never synthesized).
private let formulaIndexFixtureJSON = """
[
  {
    "name": "wget",
    "full_name": "homebrew/core/wget",
    "tap": "homebrew/core",
    "oldname": null,
    "aliases": [],
    "versioned_formulae": [],
    "desc": "Internet file retriever",
    "homepage": "https://www.gnu.org/software/wget/",
    "versions": {
      "stable": "1.25.0",
      "head": "HEAD-58c4a7e",
      "bottle": true
    },
    "urls": {
      "stable": {
        "url": "https://ftp.gnu.org/gnu/wget/wget-1.25.0.tar.gz",
        "tag": null,
        "revision": null
      }
    },
    "revision": 0,
    "keg_only": false,
    "outdated": false,
    "pinned": false,
    "deprecated": false,
    "disabled": false
  },
  {
    "name": "node@20",
    "full_name": "homebrew/core/node@20",
    "tap": "homebrew/core",
    "desc": "Platform built on V8 to build network applications",
    "homepage": "https://nodejs.org/",
    "versions": {
      "stable": "20.18.1",
      "head": null,
      "bottle": false
    },
    "keg_only": true,
    "outdated": false,
    "pinned": false,
    "deprecated": false,
    "disabled": false
  },
  {
    "name": "gnupg",
    "full_name": "homebrew/core/gnupg",
    "tap": "homebrew/core",
    "desc": "GNU Pretty Good Privacy (PGP) package",
    "homepage": "https://gnupg.org",
    "version": "2.4.7",
    "outdated": false,
    "pinned": false,
    "deprecated": false,
    "disabled": false
  },
  {
    "name": "jq",
    "full_name": "homebrew/core/jq",
    "tap": "homebrew/core",
    "desc": "Lightweight and flexible command-line JSON processor",
    "homepage": "https://jqlang.github.io/jq/",
    "outdated": false,
    "pinned": false,
    "deprecated": false,
    "disabled": false
  }
]
"""

/// Same index with only wget's stable version advanced — proves a 200 refresh
/// REPLACES the in-memory records (the earlier disk bytes are retired).
private let updatedFormulaIndexFixtureJSON = formulaIndexFixtureJSON
    .replacingOccurrences(of: "\"stable\": \"1.25.0\"", with: "\"stable\": \"1.26.0\"")

/// Blank stable version — never surfaces as a synthesized version.
private let blankVersionFormulaIndexFixtureJSON = """
[
  {
    "name": "wget",
    "desc": "Internet file retriever",
    "homepage": "https://www.gnu.org/software/wget/",
    "versions": { "stable": "", "head": null, "bottle": true }
  }
]
"""

/// Loop until the predicate holds (stub request arrival is asynchronous but
/// immediate; this keeps the concurrency test deterministic without flaky
/// sleeps).
private func formulaWaitUntil(timeout: TimeInterval = 5.0, _ predicate: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000) // 20 ms
    }
    return predicate()
}

// MARK: - Store tests

@Suite(.serialized)
struct BrewFormulaIndexStoreTests {

    /// Unique temp directory per test (never real Application Support); the
    /// store is REQUIRED to take it explicitly.
    private func makeStore() -> (store: BrewFormulaIndexStore, directory: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("formula-index-\(UUID().uuidString)", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FormulaStubURLProtocol.self]
        let store = BrewFormulaIndexStore(directory: dir, session: URLSession(configuration: configuration))
        return (store, dir)
    }

    private func writeFixture(_ text: String, name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: nil)
        try Data(text.utf8).write(to: directory.appendingPathComponent(name))
    }

    // (1) Fresh store: the index is downloaded whole, decoded, persisted RAW
    // with its ETag; the NEXT cycle sends If-None-Match from the persisted
    // file and a 304 revalidates with no byte refetch.
    @Test func freshLoad200PersistsBytesAndETagThen304Revalidates() async throws {
        FormulaStubURLProtocol.reset()
        FormulaStubURLProtocol.stub(
            formulaIndexFixtureJSON, headers: ["ETag": formulaLiveETag], forURLString: formulaIndexEndpointURL)
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        #expect(await store.isLoaded == true)
        #expect(await store.cachedRecordCount == 4)
        #expect(await store.lastError == nil)

        let persistedBytes = try #require(try? Data(
            contentsOf: dir.appendingPathComponent(formulaCacheFileName)))
        #expect(persistedBytes == Data(formulaIndexFixtureJSON.utf8)) // RAW body persisted, not re-encoded
        let persistedETag = try #require(try? String(
            contentsOf: dir.appendingPathComponent(formulaEtagFileName), encoding: .utf8))
        #expect(persistedETag == formulaLiveETag)

        // Second cycle: revalidates from the persisted state (no full refetch).
        FormulaStubURLProtocol.stub("", status: 304, forURLString: formulaIndexEndpointURL)
        #expect(await store.ensureLoaded() == true)
        #expect(await store.cachedRecordCount == 4)

        let requests = FormulaStubURLProtocol.recordedRequests
        #expect(requests.count == 2)
        #expect(requests[0].ifNoneMatch == nil) // fresh load is unconditional
        #expect(requests[1].ifNoneMatch == formulaLiveETag) // persisted etag drives the conditional GET
        #expect(requests[0].userAgent == formulaUserAgent)
        #expect(requests[1].userAgent == formulaUserAgent)
    }

    // (2) A changed ETag → the server answers 200: records are REPLACED by the
    // new body and the new ETag overwrites the persisted etag file.
    @Test func revalidation200ReplacesRecordsAndPersistsETag() async throws {
        FormulaStubURLProtocol.reset()
        FormulaStubURLProtocol.stub(
            updatedFormulaIndexFixtureJSON, headers: ["ETag": "W/new-formula-etag"],
            forURLString: formulaIndexEndpointURL)
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeFixture(formulaIndexFixtureJSON, name: formulaCacheFileName, in: dir)
        try writeFixture("W/old-formula-etag", name: formulaEtagFileName, in: dir)

        #expect(await store.ensureLoaded() == true)
        let refreshed = try #require(await store.record(named: "wget"))
        #expect(refreshed.version == "1.26.0") // the NEW document's claim, not disk's 1.25.0
        #expect(await store.cachedRecordCount == 4)

        let requests = FormulaStubURLProtocol.recordedRequests
        #expect(requests.count == 1)
        #expect(requests.first?.ifNoneMatch == "W/old-formula-etag") // conditional request carried the persisted etag

        let persistedETag = try #require(try? String(
            contentsOf: dir.appendingPathComponent(formulaEtagFileName), encoding: .utf8))
        #expect(persistedETag == "W/new-formula-etag")
    }

    // (3) STALE-SERVE: a failed revalidation over a decodable disk cache
    // leaves the previously loaded records USABLE — stale-but-verifiable beats
    // an empty verdict — and lastError carries the honest revalidation failure.
    @Test func staleServeAfterFailedRevalidation() async throws {
        FormulaStubURLProtocol.reset()
        FormulaStubURLProtocol.stubNetworkFailure(forURLString: formulaIndexEndpointURL)
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeFixture(formulaIndexFixtureJSON, name: formulaCacheFileName, in: dir)
        try writeFixture(formulaLiveETag, name: formulaEtagFileName, in: dir)

        #expect(await store.ensureLoaded() == false) // the CYCLE failed
        #expect(await store.lastError?.contains("NSURLErrorDomain") == true)
        // …but the loaded records remain verifiably usable.
        #expect(await store.isLoaded == true)
        #expect(await store.cachedRecordCount == 4)
        #expect(await store.record(named: "gnupg")?.version == "2.4.7")
    }

    // (4) Malformed body with NO cache → honest empty: the cycle fails with
    // the verbatim decode error, nothing is persisted, no ETag recorded.
    @Test func malformedBodyHonestEmpty() async throws {
        FormulaStubURLProtocol.reset()
        FormulaStubURLProtocol.stub("{ this is not a formula index", forURLString: formulaIndexEndpointURL)
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == false)
        #expect(await store.isLoaded == false)
        #expect(await store.cachedRecordCount == 0)
        #expect(await store.lastError?.isEmpty == false) // verbatim String(describing:) of the decode error
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(formulaCacheFileName).path) == false)
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(formulaEtagFileName).path) == false)
    }

    // (5) Undecodable NETWORK body over a GOOD disk cache: decode-before-
    // persist means the previous records AND disk bytes stand untouched, the
    // cycle fails honestly, and the records remain usable (stale-serve).
    @Test func undecodableNetworkBodyNeverClobbersGoodCache() async throws {
        FormulaStubURLProtocol.reset()
        FormulaStubURLProtocol.stub("\"forty-two strings, no objects\"", forURLString: formulaIndexEndpointURL)
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeFixture(formulaIndexFixtureJSON, name: formulaCacheFileName, in: dir)
        try writeFixture(formulaLiveETag, name: formulaEtagFileName, in: dir)

        #expect(await store.ensureLoaded() == false)
        #expect(await store.isLoaded == true) // the disk-decoded records stand
        #expect(await store.cachedRecordCount == 4)
        #expect(await store.record(named: "jq")?.version == nil) // versionless record: honest nil
        let diskBytes = try #require(try? Data(
            contentsOf: dir.appendingPathComponent(formulaCacheFileName)))
        #expect(diskBytes == Data(formulaIndexFixtureJSON.utf8)) // poison never persisted
    }

    // (6) Poisoned disk cache: the disk decode fails, so the cycle deliberately
    // sends NO If-None-Match and the network retry replaces the poison with
    // valid bytes + etag.
    @Test func poisonedDiskCacheSkipsIfNoneMatchAndRefetches() async throws {
        FormulaStubURLProtocol.reset()
        FormulaStubURLProtocol.stub(
            formulaIndexFixtureJSON, headers: ["ETag": "W/fresh-formula-etag"],
            forURLString: formulaIndexEndpointURL)
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeFixture("{ poison }", name: formulaCacheFileName, in: dir)
        try writeFixture(formulaLiveETag, name: formulaEtagFileName, in: dir)

        #expect(await store.ensureLoaded() == true)
        #expect(await store.cachedRecordCount == 4)

        let requests = FormulaStubURLProtocol.recordedRequests
        #expect(requests.count == 1)
        #expect(requests.first?.ifNoneMatch == nil) // decode failure → unconditional GET

        let persistedBytes = try #require(try? Data(
            contentsOf: dir.appendingPathComponent(formulaCacheFileName)))
        #expect(persistedBytes == Data(formulaIndexFixtureJSON.utf8)) // poison replaced
        let persistedETag = try #require(try? String(
            contentsOf: dir.appendingPathComponent(formulaEtagFileName), encoding: .utf8))
        #expect(persistedETag == "W/fresh-formula-etag")
    }

    // (7) A 304 with NO usable cached records is a protocol absurdity: recorded
    // verbatim, returns false, and the persisted ETag is dropped so the next
    // cycle goes unconditional (self-heal).
    @Test func noUsableCache304RecordsAbsurdityAndDropsEtag() async throws {
        FormulaStubURLProtocol.reset()
        FormulaStubURLProtocol.stub("", status: 304, forURLString: formulaIndexEndpointURL)
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try writeFixture(formulaLiveETag, name: formulaEtagFileName, in: dir) // etag WITHOUT a cache file

        #expect(await store.ensureLoaded() == false)
        #expect(await store.lastError == "HTTP 304 without a usable cached formula.json")
        #expect(await store.isLoaded == false)

        let requests = FormulaStubURLProtocol.recordedRequests
        #expect(requests.first?.ifNoneMatch == nil) // no usable records → no conditional claim
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(formulaEtagFileName).path) == false) // self-heal
    }

    // (8) Server error → the verbatim status lands in lastError and nothing is
    // loaded (honest failure, no partial state).
    @Test func serverErrorRecordsVerbatimLastError() async throws {
        FormulaStubURLProtocol.reset()
        FormulaStubURLProtocol.stub("{\"message\": \"down\"}", status: 503, forURLString: formulaIndexEndpointURL)
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == false)
        #expect(await store.lastError == "HTTP 503")
        #expect(await store.isLoaded == false)
        #expect(await store.cachedRecordCount == 0)
    }

    // (9) DECODE-LITE shapes pinned: modern versions.stable wins; legacy
    // top-level version is the fallback; blank → nil; versionless → nil;
    // unknown top-level keys (urls, keg_only, pinned, …) are ignored on the
    // floor; homepage/desc ride through.
    @Test func decodeLiteShapes() async throws {
        FormulaStubURLProtocol.reset()
        FormulaStubURLProtocol.stub(formulaIndexFixtureJSON, forURLString: formulaIndexEndpointURL)
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)

        let wget = try #require(await store.record(named: "wget"))
        #expect(wget.version == "1.25.0") // versions.stable (head ignored)
        #expect(wget.homepage == "https://www.gnu.org/software/wget/")
        #expect(wget.desc == "Internet file retriever")

        let node = try #require(await store.record(named: "node@20"))
        #expect(node.version == "20.18.1") // versions map with "bottle": false decodes fine

        let gnupg = try #require(await store.record(named: "gnupg"))
        #expect(gnupg.version == "2.4.7") // legacy top-level version fallback

        let jq = try #require(await store.record(named: "jq"))
        #expect(jq.version == nil) // versionless: never synthesized
        #expect(jq.homepage == "https://jqlang.github.io/jq/")
    }

    // (10) Blank stable version → nil (the blank-to-nil rule, never a "" claim).
    @Test func blankVersionDecodesNil() async throws {
        FormulaStubURLProtocol.reset()
        FormulaStubURLProtocol.stub(blankVersionFormulaIndexFixtureJSON, forURLString: formulaIndexEndpointURL)
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        let wget = try #require(await store.record(named: "wget"))
        #expect(wget.version == nil)
    }

    // (11) Exact-name lookup: hit returns the record, miss returns nil.
    @Test func recordNamedHitAndMiss() async throws {
        FormulaStubURLProtocol.reset()
        FormulaStubURLProtocol.stub(formulaIndexFixtureJSON, forURLString: formulaIndexEndpointURL)
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        let hit = try #require(await store.record(named: "node@20"))
        #expect(hit.name == "node@20")
        #expect(await store.record(named: "does-not-exist") == nil)
    }

    // (12) Concurrent ensureLoaded calls share ONE inflight task: exactly one
    // network request, every caller receives the same TRUE verdict (the
    // CaskIndexStore dedupe discipline, mirrored by construction).
    @Test func dedupesConcurrentEnsureLoads() async throws {
        FormulaStubURLProtocol.reset()
        FormulaStubURLProtocol.stub(
            formulaIndexFixtureJSON, headers: ["ETag": formulaLiveETag], forURLString: formulaIndexEndpointURL)
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        FormulaStubURLProtocol.holdResponses(true)
        defer { FormulaStubURLProtocol.releaseHold() }

        let tasks = (0..<10).map { _ in Task { await store.ensureLoaded() } }
        #expect(await formulaWaitUntil { FormulaStubURLProtocol.recordedRequests.count == 1 } == true)
        try? await Task.sleep(nanoseconds: 200_000_000) // let all entrants pile onto the inflight task
        FormulaStubURLProtocol.releaseHold()

        for task in tasks {
            #expect(await task.value == true)
        }
        #expect(FormulaStubURLProtocol.recordedRequests.count == 1) // single fetch for ten callers
    }

    // (13) dropCache wipes files AND memory; the store is semantically "never
    // loaded" afterwards (lastError included).
    @Test func dropCacheWipesState() async throws {
        FormulaStubURLProtocol.reset()
        FormulaStubURLProtocol.stub(
            formulaIndexFixtureJSON, headers: ["ETag": formulaLiveETag], forURLString: formulaIndexEndpointURL)
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(formulaCacheFileName).path) == true)

        await store.dropCache()
        #expect(await store.isLoaded == false)
        #expect(await store.cachedRecordCount == 0)
        #expect(await store.lastError == nil)
        #expect(await store.record(named: "wget") == nil)
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(formulaCacheFileName).path) == false)
        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(formulaEtagFileName).path) == false)
    }
}
