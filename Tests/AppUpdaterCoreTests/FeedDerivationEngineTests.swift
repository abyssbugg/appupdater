// FeedDerivationEngineTests — coordinator (feedderive integration): the engine's
// derived-feed path. Swift Testing only (XCTest discovery broken here). Hermetic:
// URLProtocol stub, no network. The derivation seam is canned — the pure module's
// own parsing is proven in FeedDerivationTests; this suite proves the ENGINE
// contract: derive-only-when-no-declared-feed, provenance annotation, attempt cap.

import Foundation
import Testing
import os
@testable import AppUpdaterCore

@Suite(.serialized)
struct FeedDerivationEngineTests {

    // MARK: - Hermetic transport (single route; mirrors house stub patterns)

    private enum RequestLog {
        static let state = OSAllocatedUnfairLock(initialState: [String]())
        static func record(_ url: String) { state.withLock { $0.append(url) } }
        static func read() -> [String] { state.withLock { $0 } }
        static func reset() { state.withLock { $0.removeAll() } }
    }

    private final class DerivedFeedStubURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool {
            // Claim EVERY request: undeclared hosts fail hermetically in
            // startLoading instead of escaping to the real network.
            if let url = request.url?.absoluteString { RequestLog.record(url) }
            return true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url, url.host == "derived.fixtures" else {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let body = Self.appcastXML.data(using: .utf8) ?? Data()
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/xml"]) ?? HTTPURLResponse()
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}

        private static let appcastXML = """
        <?xml version="1.0" standalone="yes"?>
        <rss xmlns:sparkle="http://www.sparkle-project.org/xml/sparkle/2008" version="2.0">
          <channel>
            <item>
              <enclosure url="https://derived.fixtures/Derived-2.0.zip" sparkle:version="2.0.0" \
        sparkle:shortVersionString="2.0" sparkle:edSignature="MEUCIQDDerivedSignatureValue==" \
        type="application/octet-stream" length="1234"/>
            </item>
          </channel>
        </rss>
        """
    }

    // MARK: - Fixtures

    private func makeApp(feedURL: String?) -> InstalledApp {
        InstalledApp(
            bundleIdentifier: "com.derived.example",
            name: "Derived Example",
            path: "/Applications/Derived Example.app",
            bundleVersion: "1",
            sparkleFeedURL: feedURL)
    }

    private func makeEngine(
        queries: LockedBox<[InstalledApp]>,
        candidates: [DerivedSparkleFeed]
    ) -> UpdateCheckEngine {
        UpdateCheckEngine(
            sources: [SparkleSource(urlProtocolClasses: [DerivedFeedStubURLProtocol.self])],
            feedDerivation: FeedDerivationResolver { app in
                queries.with { $0.append(app) }
                return candidates
            })
    }

    private let candidate = DerivedSparkleFeed(
        url: URL(string: "https://derived.fixtures/appcast.xml")!,
        framework: "AppCenter.framework",
        derivation: "test derivation")

    // MARK: - Tests

    @Test func noDeclaredFeedRunsSparkleAgainstDerivedCandidatesWithProvenance() async throws {
        RequestLog.reset()
        let queries = LockedBox<[InstalledApp]>([])
        let engine = makeEngine(queries: queries, candidates: [candidate])

        let check = await engine.check(app: makeApp(feedURL: nil))

        #expect(check.candidates.count == 1)
        let claim = try #require(check.candidates.first)
        #expect(claim.source == .sparkle)
        #expect(claim.newestBundleVersion == "2.0.0")
        let detail = try #require(claim.sourceDetail)
        #expect(detail.contains("feed derived from AppCenter.framework (test derivation)"))
        #expect(check.verdict == "update")
        #expect(queries.with { $0.count } == 1) // the ORIGINAL app was passed to the seam
        #expect(RequestLog.read().count == 1)
    }

    @Test func declaredFeedMeansDerivationIsNeverConsulted() async {
        RequestLog.reset()
        let queries = LockedBox<[InstalledApp]>([])
        let engine = makeEngine(queries: queries, candidates: [candidate])

        let check = await engine.check(app: makeApp(
            feedURL: "https://declared.fixtures/appcast.xml"))

        // The declared feed's host is not our stub → the sparkle attempt fails
        // hermetically (recorded as a failure) and the derivation seam was
        // NEVER queried — the core contract under test.
        #expect(queries.with { $0.isEmpty })
        #expect(RequestLog.read() == ["https://declared.fixtures/appcast.xml"])
        #expect(check.candidates.isEmpty)
        #expect(check.failures.count == 1)
    }

    @Test func nilSeamKeepsLegacyBehaviorExactly() async {
        RequestLog.reset()
        let engine = UpdateCheckEngine(
            sources: [SparkleSource(urlProtocolClasses: [DerivedFeedStubURLProtocol.self])])

        let check = await engine.check(app: makeApp(feedURL: nil))

        // SparkleSource returns nil instantly for a feed-less app (no network),
        // so the legacy shape is: zero claims, zero failures → "unknown".
        #expect(check.candidates.isEmpty)
        #expect(check.failures.isEmpty)
        #expect(check.verdict == "unknown")
        #expect(RequestLog.read().isEmpty)
    }

    @Test func derivedAttemptsAreCappedAtThree() async throws {
        RequestLog.reset()
        let queries = LockedBox<[InstalledApp]>([])
        var many: [DerivedSparkleFeed] = []
        for index in 0..<5 {
            many.append(DerivedSparkleFeed(
                url: try #require(URL(string: "https://derived.fixtures/appcast-\(index).xml")),
                framework: "AppCenter.framework",
                derivation: "candidate \(index)"))
        }
        let engine = makeEngine(queries: queries, candidates: many)

        let check = await engine.check(app: makeApp(feedURL: nil))

        #expect(check.candidates.count == UpdateCheckEngine.maxDerivedFeedAttempts)
        #expect(RequestLog.read().count == UpdateCheckEngine.maxDerivedFeedAttempts)
    }
}
