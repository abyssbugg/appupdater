import Foundation
import Testing
import os
@testable import AppUpdaterCore

// Swift Testing only (XCTest session discovery is broken on this toolchain — see AGENTS.md ledger).
@Suite(.serialized)
struct SparkleSourceTests {

    // MARK: - Fixtures

    /// Verified epoch constants (macOS date -j -f cross-check), asserted as integer instants so the
    /// tests never depend on host locale/timezone.
    private enum RFC822Epochs {
        static let fri26Sep2025_1230z: Int = 1758889800      // Fri, 26 Sep 2025 12:30:00 +0000
        static let sun5Jan2025_0900plus1h: Int = 1736064000  // Sun, 5 Jan 2025 09:00:00 +0100
        static let tue9Sep2025_0915minus7h: Int = 1757434500 // Tue, 9 Sep 2025 09:15:00 -0700
    }

    private enum RoutePath {
        static let main = "/v1/main.xml"
        static let fallback = "/v1/fallback.xml"
        static let older = "/v1/older.xml"
    }

    private static let mainAppcastXML = #"""
    <?xml version="1.0" standalone="yes"?>
    <rss xmlns:sparkle="http://www.sparkle-project.org/xml/sparkle/2008" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
      <channel>
        <title>ExampleApp Updates</title>
        <link>https://example.com/appcast/example.xml</link>
        <description>Official ExampleApp release channel</description>
        <language>en</language>
        <item>
          <title>Version 1.9</title>
          <sparkle:releaseNotesLink>https://example.com/releasenotes/1.9.html</sparkle:releaseNotesLink>
          <pubDate>Tue, 9 Sep 2025 09:15:00 -0700</pubDate>
          <enclosure url="https://example.com/files/Example-1.9.zip" sparkle:version="1.9.0" sparkle:shortVersionString="1.9" type="application/octet-stream" length="4100000"/>
        </item>
        <item>
          <title>Version 1.10</title>
          <sparkle:releaseNotesLink>https://example.com/releasenotes/1.10.html</sparkle:releaseNotesLink>
          <pubDate>Fri, 26 Sep 2025 12:30:00 +0000</pubDate>
          <enclosure url="https://example.com/files/Example-1.10.zip" sparkle:version="1.10.0" sparkle:shortVersionString="1.10" sparkle:edSignature="MEUCIQDExampleSignedArtifactValue1234==" type="application/octet-stream" length="5300000"/>
          <sparkle:criticalUpdate></sparkle:criticalUpdate>
          <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
        </item>
        <item>
          <title>Version 1.12 (claims)</title>
          <sparkle:releaseNotesLink>https://example.com/releasenotes/1.12.html</sparkle:releaseNotesLink>
          <pubDate>Wed, 24 Sep 2025 10:00:00 +0200</pubDate>
          <enclosure url="https://example.com/files/Example-1.12.zip" sparkle:shortVersionString="1.12" type="application/octet-stream" length="4200000"/>
        </item>
        <item>
          <title>Version 2.9 beta</title>
          <sparkle:releaseNotesLink>https://example.com/releasenotes/2.9.html</sparkle:releaseNotesLink>
          <pubDate>Sat, 27 Sep 2025 08:00:00 +0000</pubDate>
          <enclosure url="https://example.com/files/Example-2.9b.zip" sparkle:version="2.9.0" sparkle:channel="beta" sparkle:edSignature="MEUCIQDBetaItemShallBeFiltered123==" type="application/octet-stream" length="5900000"/>
        </item>
      </channel>
    </rss>
    """#

    /// Single item: NO shortVersionString, NO edSignature, non-critical, single-digit-day pubDate,
    /// CDATA description, channel-level minimumSystemVersion fallback.
    private static let fallbackAppcastXML = #"""
    <?xml version="1.0" standalone="yes"?>
    <rss xmlns:sparkle="http://www.sparkle-project.org/xml/sparkle/2008" version="2.0">
      <channel>
        <title>DemoApp Updates</title>
        <sparkle:minimumSystemVersion>11.0</sparkle:minimumSystemVersion>
        <item>
          <title>Version 1.0</title>
          <pubDate>Sun, 5 Jan 2025 09:00:00 +0100</pubDate>
          <enclosure url="https://example.org/files/Demo-1.0.zip" sparkle:version="1.0.0" type="application/octet-stream" length="1200000"/>
          <description><![CDATA[<p>Initial release of <b>Demo</b>.</p>]]></description>
        </item>
      </channel>
    </rss>
    """#

    /// Only older-than-installed items: no update claim should come out.
    private static let olderAppcastXML = #"""
    <?xml version="1.0" standalone="yes"?>
    <rss xmlns:sparkle="http://www.sparkle-project.org/xml/sparkle/2008" version="2.0">
      <channel>
        <title>OldApp Updates</title>
        <item>
          <title>Version 1.9</title>
          <pubDate>Mon, 9 Sep 2024 09:15:00 -0700</pubDate>
          <enclosure url="https://old.example/files/Old-1.9.zip" sparkle:version="1.9.0" type="application/octet-stream" length="100"/>
        </item>
      </channel>
    </rss>
    """#

    private static let routes: [String: (status: Int, body: String)] = [
        RoutePath.main: (200, mainAppcastXML),
        RoutePath.fallback: (200, fallbackAppcastXML),
        RoutePath.older: (200, olderAppcastXML),
    ]

    // MARK: - Hermetic transport

    private enum RequestCounter {
        static let state = OSAllocatedUnfairLock(initialState: 0)
        static func increment() { state.withLock { $0 += 1 } }
        static func read() -> Int { state.withLock { $0 } }
    }

    private final class AppcastStubURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool {
            RequestCounter.increment()
            return route(for: request) != nil
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        private static func route(for request: URLRequest) -> (status: Int, body: String)? {
            guard let path = request.url?.path else { return nil }
            return routes[path]
        }

        override func startLoading() {
            guard let route = Self.route(for: request), let url = request.url,
                  let data = route.body.data(using: .utf8)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: route.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/xml"]
            ) ?? HTTPURLResponse()
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func makeSource() -> SparkleSource {
        SparkleSource(urlProtocolClasses: [AppcastStubURLProtocol.self])
    }

    private func makeApp(
        path: String,
        bundleVersion: String? = nil
    ) -> InstalledApp {
        InstalledApp(
            bundleIdentifier: "com.example.app",
            name: "Example App",
            path: "/Applications/Example.app",
            bundleVersion: bundleVersion,
            sparkleFeedURL: "https://appcast.stub.invalid" + path
        )
    }

    // MARK: - Tests

    @Test
    func newestItemChosenVersusInstalledOneTwoThree() async throws {
        let source = makeSource()
        let info = try await source.fetchUpdateInfo(
            for: makeApp(path: RoutePath.main, bundleVersion: "1.2.3")
        )

        #expect(info != nil)
        let update = try #require(info)
        // "1.10.0" numerically beats both "1.9.0" and installed "1.2.3" ("1.10" > "1.2");
        // the beta "2.9.0" item must be filtered by channel, not win.
        #expect(update.newestBundleVersion == "1.10.0")
        #expect(update.source == .sparkle)
        #expect(update.newestShortVersion == "1.10")  // shortVersionString preferred
        #expect(update.minimumSystemVersion == "12.0")
        #expect(update.releaseDate != nil)
        #expect(update.releaseDate!.timeIntervalSince1970 == Double(RFC822Epochs.fri26Sep2025_1230z))
    }

    @Test
    func shortVersionFallsBackToSparkleVersionWhenAbsent() async throws {
        let source = makeSource()
        let info = try await source.fetchUpdateInfo(
            for: makeApp(path: RoutePath.fallback, bundleVersion: "0.9")
        )

        let update = try #require(info)
        #expect(update.newestBundleVersion == "1.0.0")
        #expect(update.newestShortVersion == "1.0.0")  // sparkle:version fallback, no invented value
        // Channel-level sparkle:minimumSystemVersion applies as fallback.
        #expect(update.minimumSystemVersion == "11.0")
        // Release notes: <description> HTML kept as-given (CDATA content verbatim).
        #expect(update.releaseNotes == "<p>Initial release of <b>Demo</b>.</p>")
        // Single-digit-day RFC822 pubDate parsed.
        #expect(update.releaseDate!.timeIntervalSince1970 == Double(RFC822Epochs.sun5Jan2025_0900plus1h))
    }

    @Test
    func itemMissingSparkleVersionIsSkipped() async throws {
        let source = makeSource()
        let info = try await source.fetchUpdateInfo(
            for: makeApp(path: RoutePath.main, bundleVersion: "1.2.3")
        )

        let update = try #require(info)
        // The feed carries a "1.12" claim whose item has NO sparkle:version — untrusted, skipped.
        #expect(update.newestShortVersion != "1.12")
        #expect(update.newestBundleVersion == "1.10.0")
        #expect(update.downloadURL?.absoluteString != "https://example.com/files/Example-1.12.zip")
    }

    @Test
    func enclosureURLMapsToDownloadURL() async throws {
        let source = makeSource()
        let info = try await source.fetchUpdateInfo(
            for: makeApp(path: RoutePath.main, bundleVersion: "1.2.3")
        )

        let update = try #require(info)
        #expect(update.downloadURL?.absoluteString == "https://example.com/files/Example-1.10.zip")
    }

    @Test
    func criticalAndEdSignatureFlagsSurfaceInSourceDetail() async throws {
        let source = makeSource()
        let info = try await source.fetchUpdateInfo(
            for: makeApp(path: RoutePath.main, bundleVersion: "1.2.3")
        )

        let update = try #require(info)
        #expect(update.confidence == .high)
        let detail = try #require(update.sourceDetail)
        #expect(detail.contains("critical"))
        #expect(detail.contains("MEUCIQDExampleSignedArtifactValue1234=="))
        #expect(update.sha256Hex == nil)  // Sparkle authenticates with EdDSA, not sha256
    }

    @Test
    func absentSignatureMeansMediumConfidenceAndHonestDetail() async throws {
        let source = makeSource()
        let info = try await source.fetchUpdateInfo(
            for: makeApp(path: RoutePath.fallback, bundleVersion: "0.9")
        )

        let update = try #require(info)
        #expect(update.confidence == .medium)
        let detail = try #require(update.sourceDetail)
        #expect(detail.contains("no EdDSA signature"))
        #expect(!detail.contains("critical"))
    }

    @Test
    func noSparkleFeedURLReturnsNilWithoutNetworkHit() async throws {
        let source = makeSource()
        let before = RequestCounter.read()

        var app = makeApp(path: RoutePath.main)
        app.sparkleFeedURL = nil
        let info = try await source.fetchUpdateInfo(for: app)

        #expect(info == nil)
        #expect(RequestCounter.read() == before)  // zero requests issued
    }

    @Test
    func feedOlderThanInstalledReturnsNil() async throws {
        let source = makeSource()
        let info = try await source.fetchUpdateInfo(
            for: makeApp(path: RoutePath.older, bundleVersion: "2.0.1")
        )

        #expect(info == nil)  // installed 2.0.1 beats feed max 1.9.0 — no bogus claim
    }

    @Test
    func comparatorIsNumericAwareNotLexical() {
        #expect(SparkleVersionComparator.compare("1.10", "1.2") > 0)   // the MUST case
        #expect(SparkleVersionComparator.compare("1.2", "1.10") < 0)
        #expect(SparkleVersionComparator.compare("1.2", "1.2") == 0)   // equal strings equal
        #expect(SparkleVersionComparator.compare("1.2", "1.2.0") == 0) // zero-padding tolerance
        #expect(SparkleVersionComparator.compare("2.0.0", "1.2") > 0)
        #expect(SparkleVersionComparator.compare("1.2.3", "1.2.10") < 0)
        #expect(SparkleVersionComparator.isNewerVersion("1.10.0", than: "1.2.3"))
        #expect(!SparkleVersionComparator.isNewerVersion("1.9.0", than: "9.8"))
    }
}
