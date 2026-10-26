// MASSource hermetic tests — Swift Testing ONLY (XCTest test discovery is broken on this
// toolchain: Xcode 27 beta / Swift 6.4, see AGENTS.md gotcha ledger). Zero network: a custom
// URLProtocol stub intercepts every lookup request this suite's sessions make and records
// them, so "no request" guarantees are assertable, not assumed.
// Swift Testing does not re-export Foundation — explicit `import Foundation` below.

import Testing
import Foundation
@testable import AppUpdaterCore

// MARK: - Request stub

/// Token for one canned reply enqueued by a test.
/// Lock-guarded because URLSession's internal queues touch it concurrently with the test thread.
/// (Internal, not private: MassTestStubState's member signatures reference it. Test-file only.)
struct StubReply: Sendable {
    let statusCode: Int
    let payload: Data
}

final class MassTestStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var canned: StubReply?
    private var recorded: [URLRequest] = []

    var requestCount: Int { lock.withLock { recorded.count } }
    var requests: [URLRequest] { lock.withLock { recorded } }

    func reset() {
        lock.withLock { canned = nil; recorded.removeAll() }
    }

    func enqueue(_ reply: StubReply) {
        lock.withLock { canned = reply }
    }

    /// Records `request` and returns the canned reply (nil when nothing is enqueued).
    func serve(request: URLRequest) -> StubReply? {
        lock.withLock {
            recorded.append(request)
            return canned
        }
    }
}

/// URLProtocol that serves whatever `MassTestStubState` has enqueued. It is registered ONLY
/// on this suite's own ephemeral URLSession configurations; system/default sessions are never
/// touched, so nothing here can leak network behavior into any other lane or suite.
private final class MassStubURLProtocol: URLProtocol {
    static let state = MassTestStubState()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let canned = Self.state.serve(request: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: canned.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: canned.payload)
            // macOS 27 SDK: the completion integration point is URLProtocolDidFinishLoading:
            // (the legacy didCompleteWith form no longer exists in NSURLProtocolClient here).
            client?.urlProtocolDidFinishLoading(self)
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        }
    }
}

// MARK: - Fixtures (real iTunes-lookup-shaped JSON, Swift multiline literals)

/// Serialized once per suite: .serialized keeps the lock-protected stub state unshared
/// between concurrently running tests.
@Suite(.serialized)
private struct MASSourceTests {
    /// resultCount 1 + a full result object (extra unmapped keys included on purpose to prove
    /// tolerant decoding ignores them).
    private static let fullResultJSON = """
    {
      "resultCount": 1,
      "results": [
        {
          "trackId": 5123456789,
          "bundleId": "com.example.kitchen",
          "trackName": "Kitchen Timer",
          "version": "2.4.1",
          "bundleVersion": "2451",
          "minimumOsVersion": "15.0",
          "currentVersionReleaseDate": "2026-03-14T09:41:33Z",
          "releaseNotes": "Adds a titanium mode. Fixes espresso jitter.",
          "trackViewUrl": "https://apps.apple.com/us/app/kitchen-timer/id5123456789",
          "artistName": "Example Softworks",
          "price": 0,
          "averageUserRating": 4.3,
          "userRatingCount": 4212,
          "fileSizeBytes": "17014015"
        }
      ]
    }
    """

    /// Real lookup shape for a bundle id Apple doesn't know.
    private static let emptyResultJSON = """
    {"resultCount":0,"results":[]}
    """

    /// Happy shape minus the optional keys Apple omits freely.
    private static let missingOptionalsJSON = """
    {
      "resultCount": 1,
      "results": [
        {
          "trackId": 5123456789,
          "bundleId": "com.example.kitchen",
          "trackName": "Kitchen Timer",
          "version": "2.4.2",
          "currentVersionReleaseDate": "2026-03-14T09:41:33Z",
          "trackViewUrl": "https://apps.apple.com/us/app/kitchen-timer/id5123456789"
        }
      ]
    }
    """

    /// Error-page bytes a lookup can plausibly return — clearly not JSON.
    private static let malformedJSON = "<html><body>503 Service Unavailable</body></html>"

    /// Legacy RFC-822-ish release date render Apple has historically shipped.
    private static let rfc822ResultJSON = """
    {
      "resultCount": 1,
      "results": [
        {
          "bundleId": "com.example.kitchen",
          "version": "2.4.0",
          "currentVersionReleaseDate": "Thu, 05 Mar 2026 09:41:33 GMT"
        }
      ]
    }
    """

    // MARK: Helpers

    private func makeSession(enqueued: StubReply) -> URLSession {
        let state = MassStubURLProtocol.state
        state.reset()
        state.enqueue(enqueued)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MassStubURLProtocol.self]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    private func masApp(bundleID: String = "com.example.kitchen") -> InstalledApp {
        InstalledApp(
            bundleIdentifier: bundleID,
            name: "Kitchen Timer",
            path: "/Applications/Kitchen Timer.app",
            shortVersion: "2.3.9",
            bundleVersion: "2390",
            isMacAppStore: true
        )
    }

    // MARK: Tests

    /// (1) Honesty-first: a non-MAS install must NOT generate even one network request.
    @Test func nonMasAppReturnsNilWithoutAnyNetworkRequest() async throws {
        let session = makeSession(enqueued: StubReply(statusCode: 200, payload: Data(Self.fullResultJSON.utf8)))
        defer { session.finishTasksAndInvalidate() }
        let source = MASSource(session: session)
        var app = masApp()
        app.isMacAppStore = false

        let fetched = try await source.fetchUpdateInfo(for: app)

        #expect(fetched == nil)
        #expect(MassStubURLProtocol.state.requestCount == 0)
    }

    /// (2) Happy path: every field maps into UpdateInfo exactly as the lookup documents.
    @Test func happyPathMapsEveryLookupFieldIntoUpdateInfo() async throws {
        let session = makeSession(enqueued: StubReply(statusCode: 200, payload: Data(Self.fullResultJSON.utf8)))
        defer { session.finishTasksAndInvalidate() }
        // Ground-truth epoch for 2026-03-14T09:41:33Z, computed independently of any formatter.
        let expectedReleaseDate: Double = 1_773_481_293
        let source = MASSource(session: session)

        let fetched = try await source.fetchUpdateInfo(for: masApp())
        let info = try #require(fetched)

        #expect(info.source == .mas)
        #expect(info.newestShortVersion == "2.4.1")
        #expect(info.newestBundleVersion == nil)  // lookup carries no separate bundle version
        #expect(info.downloadURL == nil)          // MAS has no legitimate direct download
        #expect(info.sha256Hex == nil)
        #expect(info.minimumSystemVersion == "15.0")
        #expect(info.releaseDate?.timeIntervalSince1970 == expectedReleaseDate)
        #expect(info.releaseNotes == "Adds a titanium mode. Fixes espresso jitter.")
        #expect(info.confidence == .high)
        #expect(info.sourceDetail == "Apple iTunes lookup (first-party data), trackId 5123456789")

        // Request evidence: exactly one call, to the pinned endpoint with the pinned UA.
        let requests = MassStubURLProtocol.state.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://itunes.apple.com/lookup?bundleId=com.example.kitchen&country=us")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "AppUpdater/0.1 (macOS)")
    }

    /// (3) resultCount 0 → quiet nil ("unknown to the storefront"), not an error.
    @Test func zeroResultLookupReturnsNil() async throws {
        let session = makeSession(enqueued: StubReply(statusCode: 200, payload: Data(Self.emptyResultJSON.utf8)))
        defer { session.finishTasksAndInvalidate() }
        let source = MASSource(session: session)

        let fetched = try await source.fetchUpdateInfo(for: masApp())

        #expect(fetched == nil)
        // The request legitimately happened and was honestly answered with a nil claim.
        #expect(MassStubURLProtocol.state.requestCount == 1)
    }

    /// (4) Malformed payload (e.g. an HTML error page) → throws, per the documented contract;
    /// never a fabricated update claim.
    @Test func malformedLookupPayloadThrowsInsteadOfGuessing() async throws {
        let session = makeSession(enqueued: StubReply(statusCode: 200, payload: Data(Self.malformedJSON.utf8)))
        defer { session.finishTasksAndInvalidate() }
        let source = MASSource(session: session)

        do {
            _ = try await source.fetchUpdateInfo(for: masApp())
            Issue.record("Malformed payload must throw, not return a fabricated claim")
        } catch {
            // Expected — decode failure propagates (documented on MASSource).
        }
    }

    /// (5) Tolerant decode: Apple omitting minimumOsVersion/releaseNotes still succeeds → nils.
    @Test func missingOptionalFieldsDecodeTolerantlyToNil() async throws {
        let session = makeSession(enqueued: StubReply(statusCode: 200, payload: Data(Self.missingOptionalsJSON.utf8)))
        defer { session.finishTasksAndInvalidate() }
        // Same ground-truth epoch as the happy path — the one date key present still parses.
        let expectedReleaseDate: Double = 1_773_481_293
        let source = MASSource(session: session)

        let fetched = try await source.fetchUpdateInfo(for: masApp())
        let info = try #require(fetched)

        #expect(info.newestShortVersion == "2.4.2")
        #expect(info.minimumSystemVersion == nil)
        #expect(info.releaseNotes == nil)
        #expect(info.releaseDate?.timeIntervalSince1970 == expectedReleaseDate)
        #expect(info.confidence == .high)
        #expect(MassStubURLProtocol.state.requestCount == 1)
    }

    /// Tolerant date fallback: a legacy RFC-822-style release date still parses.
    /// Ground truth epoch 1772703693 == 2026-03-05T09:41:33Z, verified independently.
    @Test func rfc822StyleReleaseDateStillParses() async throws {
        let session = makeSession(enqueued: StubReply(statusCode: 200, payload: Data(Self.rfc822ResultJSON.utf8)))
        defer { session.finishTasksAndInvalidate() }
        let source = MASSource(session: session)

        let fetched = try await source.fetchUpdateInfo(for: masApp())
        let info = try #require(fetched)

        #expect(info.releaseDate?.timeIntervalSince1970 == 1_772_703_693)
    }
}
