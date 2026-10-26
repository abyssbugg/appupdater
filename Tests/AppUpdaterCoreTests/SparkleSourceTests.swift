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
        static let channels = "/v1/channels.xml"
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

    /// One default (channel-less) item plus three channel-tagged items (beta/delta/nightly),
    /// each newer than the previous — so any accidental channel admission surfaces as a win.
    private static let channelsAppcastXML = #"""
    <?xml version="1.0" standalone="yes"?>
    <rss xmlns:sparkle="http://www.sparkle-project.org/xml/sparkle/2008" version="2.0">
      <channel>
        <title>ChannelApp Updates</title>
        <item>
          <title>Version 1.0</title>
          <enclosure url="https://example.com/files/Channel-1.0.zip" sparkle:version="1.0.0" type="application/octet-stream" length="1000000"/>
        </item>
        <item>
          <title>Version 2.0 beta</title>
          <enclosure url="https://example.com/files/Channel-2.0b.zip" sparkle:version="2.0.0" sparkle:channel="beta" type="application/octet-stream" length="2000000"/>
        </item>
        <item>
          <title>Version 3.0 delta</title>
          <enclosure url="https://example.com/files/Channel-3.0d.zip" sparkle:version="3.0.0" sparkle:channel="delta" type="application/octet-stream" length="3000000"/>
        </item>
        <item>
          <title>Version 4.0 nightly</title>
          <enclosure url="https://example.com/files/Channel-4.0n.zip" sparkle:version="4.0.0" sparkle:channel="nightly" type="application/octet-stream" length="4000000"/>
        </item>
      </channel>
    </rss>
    """#

    private static let routes: [String: (status: Int, body: String)] = [
        RoutePath.main: (200, mainAppcastXML),
        RoutePath.fallback: (200, fallbackAppcastXML),
        RoutePath.older: (200, olderAppcastXML),
        RoutePath.channels: (200, channelsAppcastXML),
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
        bundleVersion: String? = nil,
        suDefaultChannel: String? = nil
    ) -> InstalledApp {
        InstalledApp(
            bundleIdentifier: "com.example.app",
            name: "Example App",
            path: "/Applications/Example.app",
            bundleVersion: bundleVersion,
            sparkleFeedURL: "https://appcast.stub.invalid" + path,
            suDefaultChannel: suDefaultChannel
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
    func selectionUsesVersionOracleComparator() {
        // Integration: the lane-local temporary comparator was replaced by VersionOracle.
        // The pinned MUST cases from the lane review now run against the real comparator.
        let oracle = VersionOracle()
        #expect(oracle.compare("1.10", "1.2") == .greater)   // numeric-aware, not lexical
        #expect(oracle.compare("1.2", "1.10") == .less)
        #expect(oracle.compare("1.2", "1.2") == .equal)      // equal strings equal
        #expect(oracle.compare("1.2", "1.2.0") == .equal)    // zero-padding tolerance
        #expect(oracle.compare("2.0.0", "1.2") == .greater)
        #expect(oracle.compare("1.2.3", "1.2.10") == .less)
        #expect(oracle.isUpdateAvailable(installed: "1.2.3", available: "1.10.0"))
        #expect(!oracle.isUpdateAvailable(installed: "9.8", available: "1.9.0"))
    }

    // MARK: - Declared channel policy (lane channels)

    @Test
    func noDeclaredChannelKeepsUnchangedDefaultChannelOnlyBehavior() async throws {
        let source = makeSource()

        // Baseline (unchanged by construction): with no declared channel the default item is the
        // ONLY admissible one and wins even though newer channel-tagged items exist in the feed.
        let info = try await source.fetchUpdateInfo(
            for: makeApp(path: RoutePath.channels, bundleVersion: "0.9.0"))
        let update = try #require(info)
        #expect(update.newestBundleVersion == "1.0.0")
        #expect(update.downloadURL?.absoluteString == "https://example.com/files/Channel-1.0.zip")
        #expect(update.sourceDetail?.contains("channel: default") == true)

        // Exclusion probe: installed 2.5.0 — the tagged items (2.0 beta, 3.0 delta, 4.0 nightly)
        // are all NEWER than the installed version. If any of them were admissible it would
        // emerge here; correct behavior is nil (the only admissible item, 1.0.0, is not newer).
        let admissibleProbe = try await source.fetchUpdateInfo(
            for: makeApp(path: RoutePath.channels, bundleVersion: "2.5.0"))
        #expect(admissibleProbe == nil)
    }

    @Test
    func declaredChannelAdmitsMatchingChannelAlongsideDefault() async throws {
        let source = makeSource()

        // App declares "delta": the delta item (3.0.0) is admissible and wins over the older
        // default item; beta (2.0.0, same-version-range as installed) and nightly (4.0.0, which
        // would otherwise be the winner) stay excluded.
        let info = try await source.fetchUpdateInfo(
            for: makeApp(
                path: RoutePath.channels,
                bundleVersion: "2.5.0",
                suDefaultChannel: "delta"
            ))
        let update = try #require(info)
        #expect(update.newestBundleVersion == "3.0.0")
        #expect(update.downloadURL?.absoluteString == "https://example.com/files/Channel-3.0d.zip")
        // The winner reports its TRUE channel, not the selection-internal re-tagged default.
        #expect(update.sourceDetail?.contains("channel: delta") == true)
        #expect(update.sourceDetail?.contains("channel: nightly") == false)
    }

    @Test
    func declaredChannelMatchIsExactCaseSensitiveLikeSparkle() throws {
        // Sparkle's own filtering admits an item when its channel is IN the allowed set
        // (`SUAppcastDriver.filterAppcast:forMacOSAndAllowedChannels:` → `NSSet containsObject:`,
        // case-sensitive NSString equality) and always keeps channel-less items. Pin our exact
        // mirror: a case-mismatched declaration must NOT admit the item ("Delta" ≠ "delta").
        let defaultItem = SparkleAppcastItem(
            sparkleVersion: "1.0.0", shortVersionString: "1.0", enclosureURL: nil,
            edSignature: nil, criticalUpdate: false, minimumSystemVersion: nil, channel: nil,
            pubDate: nil, releaseNotes: nil)
        let betaItem = SparkleAppcastItem(
            sparkleVersion: "2.0.0", shortVersionString: "2.0", enclosureURL: nil,
            edSignature: nil, criticalUpdate: false, minimumSystemVersion: nil, channel: "beta",
            pubDate: nil, releaseNotes: nil)
        let deltaItem = SparkleAppcastItem(
            sparkleVersion: "3.0.0", shortVersionString: "3.0", enclosureURL: nil,
            edSignature: nil, criticalUpdate: false, minimumSystemVersion: nil, channel: "delta",
            pubDate: nil, releaseNotes: nil)
        let nightlyItem = SparkleAppcastItem(
            sparkleVersion: "4.0.0", shortVersionString: "4.0", enclosureURL: nil,
            edSignature: nil, criticalUpdate: false, minimumSystemVersion: nil, channel: "nightly",
            pubDate: nil, releaseNotes: nil)
        let items = [defaultItem, betaItem, deltaItem, nightlyItem]

        // EXACT match: only the exactly-declared channel joins the default channel.
        let exact = try #require(SparkleSource.selectAdmissible(
            items, declaredChannel: "delta", installedBundleVersion: nil))
        #expect(exact.sparkleVersion == "3.0.0")       // delta admitted (would-be nightly winner excluded)
        #expect(exact.channel == "delta")              // true channel restored after selection

        // Case-mismatched declaration: "Delta" ≠ "delta" ⇒ the delta item stays excluded and the
        // default-item-only policy remains (documented Sparkle-semantics EXACT-match rule).
        let mismatched = try #require(SparkleSource.selectAdmissible(
            items, declaredChannel: "Delta", installedBundleVersion: nil))
        #expect(mismatched.sparkleVersion == "1.0.0")
        #expect(mismatched.channel == nil)

        // Empty declaration is defensively equivalent to none: unchanged default-channel behavior.
        let empty = try #require(SparkleSource.selectAdmissible(
            items, declaredChannel: "", installedBundleVersion: nil))
        #expect(empty.sparkleVersion == "1.0.0")
    }
}
