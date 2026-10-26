// CaskSource tests — hermetic (custom URLProtocol stub; NO network is touched).
// Swift Testing only: XCTest discovery is broken on this toolchain (Xcode 27 beta).
// Fixtures are trimmed but true-to-shape JSON derived from the live sample in
// docs/evidence/ff.json (api/cask/firefox.json, generated 2026-10-26); the
// sha256-object fixture exercises the legacy/alternate schema shape.

import Foundation
import Testing
@testable import AppUpdaterCore

// MARK: - Hermetic URL stub

/// Serves pre-registered fixture bodies per URL and records every request.
/// Unregistered URLs get a 404. Everything runs synchronously in startLoading.
final class StubURLProtocol: URLProtocol {
    struct StubResponse: Sendable {
        let status: Int
        let body: Data
    }

    struct RecordedRequest: Sendable {
        let url: URL
        let userAgent: String?
    }

    private static let stubBox = LockedBox<[String: StubResponse]>([:])
    private static let requestBox = LockedBox<[RecordedRequest]>([])

    static func reset() {
        stubBox.with { stubs in stubs = [:] }
        requestBox.with { requests in requests = [] }
    }

    static func stub(_ json: String, status: Int = 200, forToken token: String) {
        let key = "https://formulae.brew.sh/api/cask/\(token).json"
        stubBox.with { stubs in
            stubs[key] = StubResponse(status: status, body: Data(json.utf8))
        }
    }

    static var recordedRequests: [RecordedRequest] {
        requestBox.with { requests in requests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Synchronous stubs complete inside startLoading; CFNetwork still invokes
    /// stopLoading on teardown (e.g. `forgetProtocolClient`) and the abstract
    /// base throws NSInvalidArgumentException unless overridden. No-op on purpose.
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requestBox.with { requests in
            requests.append(RecordedRequest(url: url, userAgent: request.value(forHTTPHeaderField: "User-Agent")))
        }
        let stub = Self.stubBox.with { stubs in stubs[url.absoluteString] }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub?.status ?? 404,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
        guard let response, let client else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body = stub?.body { client.urlProtocol(self, didLoad: body) }
        client.urlProtocolDidFinishLoading(self)
    }
}

/// Tiny thread-safe box for stub state (Swift Testing runs suites in parallel;
/// the suite below opts out with .serialized, but the box keeps the state rules).
final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ initial: Value) { value = initial }

    func with<Result>(_ mutate: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return mutate(&value)
    }
}

// MARK: - Fixtures (trimmed real-shape JSON; see docs/evidence/ff.json)

private let firefoxJSON = """
{
  "token": "firefox",
  "full_token": "firefox",
  "old_tokens": [],
  "tap": "homebrew/cask",
  "name": ["Mozilla Firefox"],
  "desc": "Web browser",
  "homepage": "https://www.mozilla.org/firefox/",
  "url": "https://download-installer.cdn.mozilla.net/pub/firefox/releases/158.0.1/mac/en-US/Firefox%20158.0.1.dmg",
  "url_specs": {},
  "version": "158.0.1",
  "autobump": true,
  "no_autobump_message": null,
  "skip_livecheck": false,
  "installed": null,
  "installed_time": null,
  "bundle_version": "15726.10.5",
  "bundle_short_version": "157.0.1",
  "pinned": false,
  "outdated": false,
  "sha256": "1d7aa96b51fc9110185047de18228ac87238fba5e42bba53c9d696f88878cba6",
  "artifacts": [
    {"uninstall": [{"quit": "org.mozilla.firefox"}]},
    {"app": ["Firefox.app"], "target": "/Applications/Firefox.app"},
    {"zap": [{"trash": ["~/Library/Caches/Firefox"]}]}
  ],
  "caveats": null,
  "depends_on": {"macos": {}},
  "conflicts_with": {"cask": ["firefox@beta", "firefox@esr"]},
  "container": null,
  "rename": [],
  "auto_updates": true,
  "deprecated": false,
  "disabled": false,
  "tap_git_head": "70f02325ff15b873141cc2b0a4b481a87a47a8c7",
  "languages": ["en-US"],
  "ruby_source_path": "Casks/f/firefox.rb",
  "ruby_source_checksum": {"sha256": "e0d05d5a1a1e6a764dcb6e5c67d3d35f21e37b9e29b6ab36f9c71e7c47076e44"},
  "variations": {},
  "supported_platforms": ["darwin", "arm", "intel", "unix", "linux"],
  "generated_date": "2026-10-26"
}
"""

/// Synthetic-but-shape-true document exercising the legacy {"string": …} sha256
/// object shape (both shapes occur across cask-schema versions).
private let chromeObjectSHAJSON = """
{
  "token": "google-chrome",
  "name": ["Google Chrome"],
  "desc": "Web browser",
  "homepage": "https://www.google.com/chrome/",
  "url": "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg",
  "version": "143.0.2689.3",
  "autobump": true,
  "sha256": {"string": "2f2c9c5e2d98e83428c5cf04309f6a9ea70355a1af69ea7015ee8b3f0e70c96a", "algorithm": "sha256"},
  "artifacts": [
    {"app": ["Google Chrome.app"], "target": "/Applications/Google Chrome.app"}
  ],
  "depends_on": {"macos": {}},
  "variations": {},
  "generated_date": "2026-10-26"
}
"""

/// Same app shape as firefoxJSON under a custom variant token, so the display
/// name diverges while the artifact's `.app` name stays Firefox.
private let firefoxVariantJSON = firefoxJSON.replacingOccurrences(of: "\"token\": \"firefox\",", with: "\"token\": \"firefox-nightly-custom\",")

/// Same app shape as firefoxJSON minus the `version` key (older-shape simulation).
private let firefoxMissingVersionJSON = firefoxJSON.replacingOccurrences(of: "\"version\": \"158.0.1\",\n  ", with: "")

// MARK: - Tests

@Suite(.serialized)
struct CaskSourceTests {

    private func makeSource() -> CaskSource {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return CaskSource(session: URLSession(configuration: configuration))
    }

    private func makeApp(name: String, path: String, bundleIdentifier: String) -> InstalledApp {
        InstalledApp(bundleIdentifier: bundleIdentifier, name: name, path: path)
    }

    // (1) Happy path — firefox-shaped cask decodes into the right UpdateInfo fields.
    @Test func happyPathExtractsFirefoxUpdateInfo() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub(firefoxJSON, forToken: "firefox")
        let source = makeSource()
        let app = makeApp(name: "Firefox", path: "/Applications/Firefox.app", bundleIdentifier: "org.mozilla.firefox")

        do {
            let info = try await source.fetchUpdateInfo(for: app)
            guard let info else {
                Issue.record("expected UpdateInfo, got nil")
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

            // Single-cask endpoint, exactly once, with the identifying User-Agent.
            let requests = StubURLProtocol.recordedRequests
            #expect(requests.count == 1)
            #expect(requests.first?.url.absoluteString == "https://formulae.brew.sh/api/cask/firefox.json")
            #expect(requests.first?.userAgent == "AppUpdater/0.1 (macOS)")
        } catch {
            Issue.record("fetchUpdateInfo threw unexpectedly: \(error)")
        }
    }

    // (2) Legacy {"string": …} sha256 object shape decodes tolerantly.
    @Test func sha256ObjectShapeDecodesTolerantly() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub(chromeObjectSHAJSON, forToken: "google-chrome")
        let source = makeSource()
        let app = makeApp(name: "Google Chrome", path: "/Applications/Google Chrome.app", bundleIdentifier: "com.google.Chrome")

        do {
            let info = try await source.fetchUpdateInfo(for: app)
            guard let info else {
                Issue.record("expected UpdateInfo for object-shape sha256 cask, got nil")
                return
            }
            #expect(info.newestShortVersion == "143.0.2689.3")
            #expect(info.sha256Hex == "2f2c9c5e2d98e83428c5cf04309f6a9ea70355a1af69ea7015ee8b3f0e70c96a")
        } catch {
            Issue.record("fetchUpdateInfo threw unexpectedly: \(error)")
        }
    }

    // (3a) Unknown token → 404 → nil.
    @Test func notFoundTokenReturnsNil() async {
        StubURLProtocol.reset() // nothing registered → all requests 404
        let source = makeSource()
        let app = makeApp(name: "No Such App", path: "/Applications/No-such.app", bundleIdentifier: "org.example.missing")

        do {
            let info = try await source.fetchUpdateInfo(for: app)
            #expect(info == nil)
        } catch {
            Issue.record("fetchUpdateInfo threw unexpectedly: \(error)")
        }
    }

    // (3b) Empty body with 200 → nil (proxy/gateway answers a blank body).
    @Test func emptyBodyReturnsNil() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub("", forToken: "firefox")
        let source = makeSource()
        let app = makeApp(name: "Firefox", path: "/Applications/Firefox.app", bundleIdentifier: "org.mozilla.firefox")

        do {
            let info = try await source.fetchUpdateInfo(for: app)
            #expect(info == nil)
        } catch {
            Issue.record("fetchUpdateInfo threw unexpectedly: \(error)")
        }
    }

    // (4) Artifact mismatch → nil: endpoint returns a document whose app artifact
    // belongs to a different app (simulates stale/redirected content). The honest
    // boundary says return nil — never attribute another app's update.
    @Test func artifactMismatchReturnsNil() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub(firefoxJSON, forToken: "sparkle") // wrong body under this token
        let source = makeSource()
        let app = makeApp(name: "Sparkle", path: "/Applications/Sparkle.app", bundleIdentifier: "org.sparkle-project.SparkleTest")

        do {
            let info = try await source.fetchUpdateInfo(for: app)
            #expect(info == nil)
        } catch {
            Issue.record("fetchUpdateInfo threw unexpectedly: \(error)")
        }
    }

    // (5) Malformed JSON → nil (documented design; UpdateSource.throws is the
    // frozen contract but this source treats undecodable data as "no info").
    @Test func malformedJSONReturnsNil() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub("{\"token\": \"firefox\", \"versio", forToken: "firefox")
        let source = makeSource()
        let app = makeApp(name: "Firefox", path: "/Applications/Firefox.app", bundleIdentifier: "org.mozilla.firefox")

        do {
            let info = try await source.fetchUpdateInfo(for: app)
            #expect(info == nil)
        } catch {
            Issue.record("fetchUpdateInfo threw unexpectedly: \(error)")
        }
    }

    // (6) Document without a usable `version` → nil; never synthesize a version.
    @Test func missingVersionReturnsNil() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub(firefoxMissingVersionJSON, forToken: "firefox")
        let source = makeSource()
        let app = makeApp(name: "Firefox", path: "/Applications/Firefox.app", bundleIdentifier: "org.mozilla.firefox")

        do {
            let info = try await source.fetchUpdateInfo(for: app)
            #expect(info == nil)
        } catch {
            Issue.record("fetchUpdateInfo threw unexpectedly: \(error)")
        }
    }

    // (7) Validation is case-insensitive on display name.
    @Test func artifactMatchIsCaseInsensitive() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub(firefoxJSON, forToken: "firefox")
        let source = makeSource()
        let app = makeApp(name: "FIREFOX", path: "/Applications/Unknown.app", bundleIdentifier: "org.mozilla.firefox")

        do {
            let info = try await source.fetchUpdateInfo(for: app)
            #expect(info?.newestShortVersion == "158.0.1")
        } catch {
            Issue.record("fetchUpdateInfo threw unexpectedly: \(error)")
        }
    }

    // (8) The bundle-path basename alone validates the cask when the display
    // name diverges: token slug still comes from the app NAME (stub is
    // registered under that slug), but the match fires via /path/Firefox.app.
    @Test func pathBasenameValidatesCask() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub(firefoxVariantJSON, forToken: "firefox-nightly-custom")
        let source = makeSource()
        let app = makeApp(name: "Firefox Nightly Custom", path: "/Applications/Firefox.app", bundleIdentifier: "org.mozilla.firefox")

        do {
            let info = try await source.fetchUpdateInfo(for: app)
            #expect(info?.newestShortVersion == "158.0.1")
        } catch {
            Issue.record("fetchUpdateInfo threw unexpectedly: \(error)")
        }
    }

    // (9) Token slug generation follows Homebrew conventions.
    @Test func candidateTokenFollowsSlugRules() {
        #expect(CaskMatching.candidateToken(from: "Firefox") == "firefox")
        #expect(CaskMatching.candidateToken(from: "Google Chrome") == "google-chrome")
        #expect(CaskMatching.candidateToken(from: "Fantastical 2") == "fantastical-2")
        #expect(CaskMatching.candidateToken(from: "1Password 7") == "1password-7")
        #expect(CaskMatching.candidateToken(from: "  Firefox  ") == "firefox")
        #expect(CaskMatching.candidateToken(from: "(Platypus) Extra") == "platypus-extra")
        #expect(CaskMatching.candidateToken(from: "") == nil)
        #expect(CaskMatching.candidateToken(from: "!!!") == nil)
    }

    // MARK: - Cask token alias fallback (lane caskalias, 2026-10-26)
    //
    // CaskSource consults CaskAliases.table ONCE after the derived token
    // provably 404s. All behavior under test here is hermetic: the stub
    // answers 404 for any unregistered token, 200 + body for registered ones.
    // The LIVE verification of every alias TABLE entry happened separately
    // in the worktree session (single-cask fetches, see CaskAliases header);
    // nothing here touches the network.
    //
    // Fixtures below are trimmed but true-to-shape, taken from the LIVE docs
    // fetched 2026-10-26: /tmp/lanecask_verify/chrome_google-chrome.json and
    // /tmp/lanecask_verify/code_visual-studio-code.json (values like
    // google-chrome's sha256 "no_check" are the real live values).

    private let chromeAliasJSON = """
    {
      "token": "google-chrome",
      "name": ["Google Chrome"],
      "desc": "Web browser",
      "homepage": "https://www.google.com/chrome/",
      "url": "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg",
      "version": "156.0.8078.48",
      "sha256": "no_check",
      "artifacts": [
        {"app": ["Google Chrome.app"], "target": "/Applications/Google Chrome.app"}
      ],
      "depends_on": {"macos": {}},
      "variations": {},
      "generated_date": "2026-10-26"
    }
    """

    private let vscodeAliasJSON = """
    {
      "token": "visual-studio-code",
      "name": ["Microsoft Visual Studio Code", "VS Code"],
      "desc": "Open-source code editor",
      "homepage": "https://code.visualstudio.com/",
      "url": "https://update.code.visualstudio.com/1.143.1/darwin-arm64/stable",
      "version": "1.143.1",
      "sha256": "65ced7020e995c296e121881b10cd7ba46638cebc5dde0cb921bc82de13cd772",
      "artifacts": [
        {"app": ["Visual Studio Code.app"], "target": "/Applications/Visual Studio Code.app"}
      ],
      "depends_on": {"macos": {}},
      "generated_date": "2026-10-26"
    }
    """

    // Test-side copy of the declared table — used by the freeze test so any
    // value/entry drift in the source literal fails loudly.
    private let aliasTableDeclared: [String: String] = [
        "chrome": "google-chrome",
        "code": "visual-studio-code",
        "brave": "brave-browser",
        "ollama": "ollama-app",
        "github-copilot": "github-copilot-app",
        "signal-beta": "signal@beta",
        "cline": "cline-app",
        "t3-code-nightly": "t3-code@nightly",
        "manus-studio": "manus",
        "amp": "amp-app",
        "cue": "manus-cue",
        "hermes": "hermes-desktop",
        "devin": "devin-desktop",
        "cleanmymac-5-cli": "cleanmymac-cli",
    ]

    // (10) 404 on the derived token + alias table hit → the aliased token is
    // fetched second, in order, and the resolved claim comes from THE ALIASED
    // token's document (version/sha256/url are google-chrome's).
    @Test func aliasFallbackRetriesAliasedTokenOn404() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub(chromeAliasJSON, forToken: "google-chrome") // "chrome" stays unregistered → 404
        let source = makeSource()
        let app = makeApp(name: "Chrome", path: "/Applications/Google Chrome.app", bundleIdentifier: "com.google.Chrome")

        do {
            let info = try await source.fetchUpdateInfo(for: app)
            guard let info else {
                Issue.record("expected aliased UpdateInfo, got nil")
                return
            }
            #expect(info.source == .cask)
            #expect(info.newestShortVersion == "156.0.8078.48")
            #expect(info.sha256Hex == "no_check")
            #expect(info.downloadURL?.absoluteString == "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg")

            // Request log: primary miss FIRST, aliased retry SECOND — one retry only.
            let requests = StubURLProtocol.recordedRequests
            #expect(requests.count == 2)
            #expect(requests.map { $0.url.absoluteString } == [
                "https://formulae.brew.sh/api/cask/chrome.json",
                "https://formulae.brew.sh/api/cask/google-chrome.json",
            ])
            // The identifying User-Agent travels on both attempt families.
            #expect(requests.allSatisfy { $0.userAgent == "AppUpdater/0.1 (macOS)" })
        } catch {
            Issue.record("fetchUpdateInfo threw unexpectedly: \(error)")
        }
    }

    // (11) Second verified pair: the claim genuinely rides on the aliased
    // document (version/sha/url are visual-studio-code's — different values
    // than any chrome-family document could supply).
    @Test func aliasResolvesVisualStudioCodeClaim() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub(vscodeAliasJSON, forToken: "visual-studio-code") // "code" → 404
        let source = makeSource()
        let app = makeApp(name: "Code", path: "/Applications/Visual Studio Code.app", bundleIdentifier: "com.microsoft.VSCode")

        do {
            let info = try await source.fetchUpdateInfo(for: app)
            guard let info else {
                Issue.record("expected aliased UpdateInfo for VS Code, got nil")
                return
            }
            #expect(info.newestShortVersion == "1.143.1")
            #expect(info.sha256Hex == "65ced7020e995c296e121881b10cd7ba46638cebc5dde0cb921bc82de13cd772")
            #expect(info.downloadURL?.absoluteString == "https://update.code.visualstudio.com/1.143.1/darwin-arm64/stable")
            #expect(info.releaseNotes == "https://code.visualstudio.com/")

            let requests = StubURLProtocol.recordedRequests
            #expect(requests.count == 2)
            #expect(requests.map { $0.url.absoluteString } == [
                "https://formulae.brew.sh/api/cask/code.json",
                "https://formulae.brew.sh/api/cask/visual-studio-code.json",
            ])
        } catch {
            Issue.record("fetchUpdateInfo threw unexpectedly: \(error)")
        }
    }

    // (12) A derived token that is NOT in the alias table gets NO retry: one
    // request, honest nil, verdict unchanged.
    @Test func tokenNotInAliasTableGetsNoRetry() async {
        StubURLProtocol.reset() // nothing registered → 404 everywhere
        let source = makeSource()
        let app = makeApp(name: "No Such App", path: "/Applications/No-such.app", bundleIdentifier: "org.example.missing")

        do {
            let info = try await source.fetchUpdateInfo(for: app)
            #expect(info == nil) // honest failure verdict unchanged
            let requests = StubURLProtocol.recordedRequests
            #expect(requests.count == 1) // primary only; no second fetch
            #expect(requests.first?.url.absoluteString == "https://formulae.brew.sh/api/cask/no-such-app.json")
        } catch {
            Issue.record("fetchUpdateInfo threw unexpectedly: \(error)")
        }
    }

    // (13) The fallback is failure-DRIVEN: when the primary derived token
    // itself succeeds, the table entry must not preempt it — exactly one
    // fetch, no aliased request, no substitution.
    @Test func aliasDoesNotFireWhenPrimaryTokenSucceeds() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub(chromeAliasJSON, forToken: "chrome") // derived token EXISTS here
        let source = makeSource()
        let app = makeApp(name: "Chrome", path: "/Applications/Google Chrome.app", bundleIdentifier: "com.google.Chrome")

        do {
            let info = try await source.fetchUpdateInfo(for: app)
            #expect(info?.newestShortVersion == "156.0.8078.48") // the primary document's claim
            let requests = StubURLProtocol.recordedRequests
            #expect(requests.count == 1) // no aliased second fetch
            #expect(requests.first?.url.absoluteString == "https://formulae.brew.sh/api/cask/chrome.json")
        } catch {
            Issue.record("fetchUpdateInfo threw unexpectedly: \(error)")
        }
    }

    // (14) An alias can never defeat validation: google-chrome's document is
    // served under the aliased token, but its app artifact is for a DIFFERENT
    // app → both attempts conclude nil. Verdict unchanged, no misattribution.
    @Test func aliasedDocumentThatDoesNotValidateStaysNil() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub(firefoxJSON, forToken: "google-chrome") // wrong app's body under the aliased token
        let source = makeSource()
        let app = makeApp(name: "Chrome", path: "/Applications/Google Chrome.app", bundleIdentifier: "com.google.Chrome")

        do {
            let info = try await source.fetchUpdateInfo(for: app)
            #expect(info == nil)
            // Both the primary and the aliased fetch happened before the verdict.
            let requests = StubURLProtocol.recordedRequests
            #expect(requests.count == 2)
        } catch {
            Issue.record("fetchUpdateInfo threw unexpectedly: \(error)")
        }
    }

    // (15) Table freeze: the REQUIRED entry exists; the table matches the
    // declared pairings exactly. Duplicate keys in a dictionary literal
    // collapse SILENTLY (verified live: Swift emits only a warning, keeping
    // the last value — `swiftc` check, 2026-10-26), so the exact-content pin
    // is the loud guard against future copy-paste dupes.
    @Test func aliasTableFreeze() {
        // Documented required entry for this lane.
        #expect(CaskAliases.table["chrome"] == "google-chrome")

        // Exact content (count + every pairing as declared).
        #expect(CaskAliases.table == aliasTableDeclared)
        #expect(CaskAliases.table.count == 14)

        // Meta sanity per entry: an alias always maps a token to a DIFFERENT
        // token, and every target builds a fetchable single-cask URL
        // (exercises the "@" tokens, e.g. signal@beta / t3-code@nightly).
        for (derived, target) in CaskAliases.table {
            #expect(derived != target)
            #expect(URL(string: "https://formulae.brew.sh/api/cask/\(target).json") != nil)
        }
    }
}
