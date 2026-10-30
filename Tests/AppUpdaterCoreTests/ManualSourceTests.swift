// ManualSourceTests.swift — gap #2 lane (manual per-app source pins): hermetic
// Swift Testing coverage of Manual/ManualSourceStore.swift and
// Manual/ManualSourceResolver.swift's documented contract — disk round-trips
// across independent store instances, add-refusal textbook texts (duplicates,
// invalid slugs, whitespace tokens), remove honesty, the corrupt-file clean
// rethrow with byte-identical bytes, resolver nil-paths with ZERO asserted
// requests, github/cask pins end-to-end through the RETURNED sources, and the
// wave's centerpiece: the coordinator-authored engine seam driven by the REAL
// service + REAL store (pinned app → pinned claim with built-ins suppressed;
// other app → built-ins consulted normally; no-pin engine identical to a
// plain one).
//
// XCTest discovery is broken on this toolchain (gotcha ledger) → Swift Testing
// only, with the explicit Foundation import (it does not re-export).
// Unique temp root per TEST; never /Applications, never the real Application
// Support tree, no network (per-file URLProtocol stub class; unregistered
// URLs answer 404).

import Foundation
import Testing
@testable import AppUpdaterCore

// MARK: - Hermetic URL stub (per-URL fixtures WITH response headers)

/// Serves pre-registered fixture bodies per ABSOLUTE URL and records every
/// request with its headers — one registry covering BOTH pin kinds
/// (api.github.com and formulae.brew.sh). Unregistered URLs answer 404
/// empty. Synchronous inside startLoading; `stopLoading` is overridden
/// because CFNetwork calls it on teardown (repo gotcha).
final class ManualStubURLProtocol: URLProtocol {
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

/// True-to-shape /releases/latest JSON (tag verbatim → newestShortVersion).
private func manualReleaseJSON(tag: String? = "1.4.2") -> String {
    let tagField = tag.map { "\"tag_name\": \"\($0)\"" }
    let fields = [
        tagField,
        "\"published_at\": \"2026-10-01T10:00:00Z\"",
        "\"body\": \"Bug fixes and improvements\"",
        "\"assets\": [{\"name\": \"App.dmg\", \"browser_download_url\": \"https://github.com/o/r/releases/download/v1.4.2/App.dmg\"}]",
    ].compactMap { $0 }
    return "{\(fields.joined(separator: ", "))}"
}

/// Trimmed but true-to-shape single-cask document (api/cask/<token>.json):
/// tolerant-decodable fields PLUS an app artifact installing "Firefox.app",
/// which satisfies CaskMatching's artifact validation against the fixture
/// app below (mirrors the trimmed live-shape fixture in CaskSourceTests).
private let manualCaskJSON = """
{
  "token": "firefox",
  "name": ["Mozilla Firefox"],
  "desc": "Web browser",
  "homepage": "https://www.mozilla.org/firefox/",
  "url": "https://download-installer.cdn.mozilla.net/pub/firefox/releases/158.0.1/mac/en-US/Firefox%20158.0.1.dmg",
  "version": "158.0.1",
  "sha256": "1d7aa96b51fc9110185047de18228ac87238fba5e42bba53c9d696f88878cba6",
  "artifacts": [{"app": ["Firefox.app"], "target": "/Applications/Firefox.app"}]
}
"""

/// The fixture cask matcher app: name and path both normalize to "firefox",
/// so the firefox document's artifact validates (match-by-display-name OR
/// bundle-basename is the matching contract CaskDocumentClient enforces on
/// its way out — replicated through it, never bypassed).
private func makeFirefoxFixtureApp() -> InstalledApp {
    InstalledApp(
        bundleIdentifier: "org.mozilla.firefox",
        name: "Firefox",
        path: "/Applications/Firefox.app",
        shortVersion: "1.0"
    )
}

// MARK: - Seam doubles (mirror IntegrationTests' fakes exactly)

/// Hit counter shared with the fake sources (probe semantics only).
private actor ManualProbeCounter {
    var hits = 0
    func hit() { hits += 1 }
    func value() -> Int { hits }
}

/// Fake built-in (.cask) with a claim the pin must NOT compete against.
private struct ManualFakeBuiltinSource: UpdateSource {
    static var kind: SourceKind { .cask }
    var counter: ManualProbeCounter
    var claim: UpdateInfo?
    func fetchUpdateInfo(for app: InstalledApp) async throws -> UpdateInfo? {
        await counter.hit()
        return claim
    }
}

// MARK: - Tests

@Suite(.serialized)
struct ManualSourceTests {

    /// Unique temp root per TEST call, UUID-scoped so concurrent runners
    /// never share roots (cross-process fixture-collision gotcha).
    private func makeRoot(_ leaf: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appupdater-manual-\(leaf)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManualStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    // MARK: (1) Store — persistence, ordering, lazy creation

    @Test func pinsRoundTripAcrossIndependentStoreInstancesLazyCreation() throws {
        let root = try makeRoot("roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeDir = root.appendingPathComponent("Store", isDirectory: true)
        let store = ManualSourceStore(directory: storeDir)

        // Lazy honesty: reading a virgin store creates NOTHING on disk.
        #expect(try store.pins().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: storeDir.path(percentEncoded: false)))

        try store.add(caskPin: "google-chrome", bundleID: "com.google.Chrome")
        try store.add(githubPin: "microsoft", repo: "vscode", bundleID: "com.microsoft.VSCode")

        // The persisted file answers the frozen shape contract.
        let fileURL = storeDir.appendingPathComponent("manual_sources.json")
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        #expect(persisted?["schemaVersion"] as? Int == 1)
        #expect((persisted?["pins"] as? [[String: Any]])?.count == 2)

        // An INDEPENDENT store instance over the same directory reads the
        // same records, still sorted (bundleID → kind → createdAt).
        let reopened = ManualSourceStore(directory: storeDir)
        let pins = try reopened.pins()
        #expect(pins.map(\.bundleID) == ["com.google.Chrome", "com.microsoft.VSCode"])
        #expect(pins.map(\.kind) == [.cask, .github])
        #expect(pins[0].token == "google-chrome")
        #expect(pins[0].targetDescription == "google-chrome")
        #expect(pins[0].owner == nil)
        #expect(pins[0].repo == nil)
        #expect(pins[1].owner == "microsoft")
        #expect(pins[1].repo == "vscode")
        #expect(pins[1].targetDescription == "microsoft/vscode")
        #expect(pins[1].token == nil)
        #expect(pins.allSatisfy { !$0.id.isEmpty })
    }

    // (2) Canonical sort ladder incl. the createdAt tie-break for same
    // bundleID+kind (only reachable through a decode-side, schema-valid
    // hand-written file — the add-refusal keeps real stores unique).
    @Test func pinsReadSortedBundleIDKindCreatedAtHandcraftedFile() throws {
        let root = try makeRoot("sort")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeDir = root.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let json = """
        {"schemaVersion": 1, "pins": [
          {"id": "p3", "bundleID": "org.b", "kind": "github", "owner": "b", "repo": "repo", "createdAt": 800000000.0},
          {"id": "p1", "bundleID": "org.a", "kind": "cask", "token": "aa", "createdAt": 1.0},
          {"id": "p2", "bundleID": "org.a", "kind": "github", "owner": "a2", "repo": "repo2", "createdAt": 2.0},
          {"id": "p0", "bundleID": "org.a", "kind": "cask", "token": "ab", "createdAt": 999.0}
        ]}
        """
        try Data(json.utf8).write(to: storeDir.appendingPathComponent("manual_sources.json"))

        let pins = try ManualSourceStore(directory: storeDir).pins()
        #expect(pins.map(\.id) == ["p1", "p0", "p2", "p3"])
        #expect(pins[0].bundleID == "org.a" && pins[1].bundleID == "org.a")
        #expect(pins[0].createdAt < pins[1].createdAt) // same bundleID + kind → createdAt decides
        #expect(pins[2].kind == .github)               // same bundleID → kind "cask" < "github"
        #expect(pins[3].bundleID == "org.b")
    }

    // MARK: (3) Add refusals — verbatim honest texts, disk never touched

    @Test func duplicateSameKindRefusedNamesBundleIDAndTargetPinUntouched() throws {
        let root = try makeRoot("dup")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManualSourceStore(directory: root.appendingPathComponent("Store", isDirectory: true))
        try store.add(githubPin: "syncthing", repo: "syncthing", bundleID: "io.a")

        do {
            try store.add(githubPin: "other", repo: "fork", bundleID: "io.a")
            Issue.record("same bundleID + same kind must be refused")
        } catch let thrown as ManualSourceError {
            #expect(thrown.reason.contains("io.a"))
            #expect(thrown.reason.contains("GitHub release pin"))
            #expect(thrown.reason.contains("syncthing/syncthing")) // the EXISTING pin named
            #expect(thrown.reason.contains("one pin per kind per app"))
        }
        #expect(try store.pins().count == 1) // refusal changed nothing
        let afterRefusal = try JSONSerialization.jsonObject(with: Data(
            contentsOf: root.appendingPathComponent("Store/manual_sources.json"))) as? [String: Any]
        #expect((afterRefusal?["pins"] as? [[String: Any]])?.count == 1)

        // Cask duplicate: same rule, its own kind label.
        try store.add(caskPin: "google-chrome", bundleID: "io.a")
        do {
            try store.add(caskPin: "other-token", bundleID: "io.a")
            Issue.record("duplicate cask pin must be refused")
        } catch let thrown as ManualSourceError {
            #expect(thrown.reason.contains("Homebrew cask pin"))
            #expect(thrown.reason.contains("google-chrome"))
        }
        #expect(try store.pins().count == 2)
    }

    // (4) One pin per KIND — but a bundle id may carry BOTH kinds at once
    // (documented store choice; the resolver's first-in-sort rule stays
    // deterministic — cask sorts before github).
    @Test func sameBundleIDDifferentKindsAllowed() throws {
        let root = try makeRoot("bothkinds")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManualSourceStore(directory: root.appendingPathComponent("Store", isDirectory: true))

        try store.add(githubPin: "a", repo: "app", bundleID: "io.both")
        try store.add(caskPin: "app", bundleID: "io.both")

        let pins = try store.pins()
        #expect(pins.count == 2)
        #expect(pins.map(\.kind) == [.cask, .github]) // store sort order
        #expect(pins.allSatisfy { $0.bundleID == "io.both" })
    }

    @Test func invalidGithubSlugRefusedHonestText() throws {
        let root = try makeRoot("slug")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManualSourceStore(directory: root.appendingPathComponent("Store", isDirectory: true))

        for (owner, repo) in [("o wner", "re.po"), ("o", "re po"), ("o", "re/po"), ("", "r"), ("o", "")] {
            do {
                try store.add(githubPin: owner, repo: repo, bundleID: "io.x")
                Issue.record("\"\(owner)/\(repo)\" must be refused (same alphabet RepoRef admits)")
            } catch let thrown as ManualSourceError {
                #expect(thrown.reason.contains("not a valid GitHub repository"))
            }
        }
        #expect(try store.pins().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Store", isDirectory: true).path(percentEncoded: false)))
    }

    @Test func caskTokenWhitespaceRefusedTrimmedAccepted() throws {
        let root = try makeRoot("token")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManualSourceStore(directory: root.appendingPathComponent("Store", isDirectory: true))

        // Internal whitespace and all-whitespace are refused VERBATIM.
        for token in ["fire fox", "   ", "\tgoogle-chrome\tgoogle-chrome"] {
            do {
                try store.add(caskPin: token, bundleID: "io.x")
                Issue.record("\"\(token)\" must be refused")
            } catch let thrown as ManualSourceError {
                #expect(thrown.reason.contains("cask tokens are single words"))
            }
        }
        // Trimmed-but-real tokens ARE accepted (normalization contract).
        try store.add(caskPin: "  google-chrome  ", bundleID: "io.trimmed")
        #expect(try store.pins().first?.token == "google-chrome")
    }

    @Test func emptyBundleIDRefusedAndTargetLessPinLawful() throws {
        let root = try makeRoot("bundleid")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManualSourceStore(directory: root.appendingPathComponent("Store", isDirectory: true))

        for bid in ["", "   "] {
            do {
                try store.add(caskPin: "firefox", bundleID: bid)
                Issue.record("empty bundle id must be refused")
            } catch let thrown as ManualSourceError {
                #expect(thrown.reason.contains("the app's bundle identifier is empty"))
            }
            do {
                try store.add(githubPin: "a", repo: "b", bundleID: bid)
                Issue.record("empty bundle id must be refused (github verb too)")
            } catch let thrown as ManualSourceError {
                #expect(thrown.reason.contains("the app's bundle identifier is empty"))
            }
        }

        // A pin for a bundle id that is NOT any installed app is lawful —
        // the store validates TEXT, never the scan set (honesty in UI).
        try store.add(githubPin: "ghost", repo: "future", bundleID: "com.not.installed.yet")
        #expect(try store.pins().first?.bundleID == "com.not.installed.yet")
    }

    // MARK: (4) Remove — honest unknown-id error, real removal unblocks re-add

    @Test func removeUnknownIdHonestErrorThenRealRemovalReadd() throws {
        let root = try makeRoot("remove")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ManualSourceStore(directory: root.appendingPathComponent("Store", isDirectory: true))
        try store.add(caskPin: "firefox", bundleID: "io.r")

        do {
            try store.remove(id: "does-not-exist")
            Issue.record("unknown id must throw")
        } catch let thrown as ManualSourceError {
            #expect(thrown.reason.contains("does-not-exist"))
            #expect(thrown.reason.contains("no pin with id"))
        }

        let pinned = try #require(try store.pins().first)
        try store.remove(id: pinned.id)
        #expect(try store.pins().isEmpty)

        // After removal the same bundleID+kind adds again (refusal was only
        // about coexistence, never about history).
        try store.add(caskPin: "firefox", bundleID: "io.r")
        #expect(try store.pins().count == 1)
    }

    // MARK: (5) Corrupt / unsupported store → clean rethrow, bytes untouched

    @Test func corruptStoreCleanRethrowBytesUntouchedRemoveAlsoThrows() throws {
        let root = try makeRoot("corrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeDir = root.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let fileURL = storeDir.appendingPathComponent("manual_sources.json")
        let garbage = "not json {{{"
        try Data(garbage.utf8).write(to: fileURL)

        let store = ManualSourceStore(directory: storeDir)
        do {
            _ = try store.pins()
            Issue.record("corrupt manual_sources.json must throw clean")
        } catch let thrown as ManualSourceError {
            #expect(thrown.reason.contains("manual_sources.json could not be read from"))
            #expect(thrown.reason.contains(storeDir.path(percentEncoded: false)))
            #expect(thrown.reason.contains("has not been modified or deleted"))
        }

        // Mutation verbs hit the SAME corruption and throw — never
        // auto-delete, never repair.
        do {
            try store.add(caskPin: "firefox", bundleID: "io.c")
            Issue.record("add over a corrupt file must throw, not repair")
        } catch let thrown as ManualSourceError {
            #expect(thrown.reason.contains("could not be read from"))
        }
        #expect(try Data(contentsOf: fileURL) == Data(garbage.utf8)) // bytes byte-identical
    }

    @Test func unsupportedSchemaVersionCleanTextNeverAutoDelete() throws {
        let root = try makeRoot("schema")
        defer { try? FileManager.default.removeItem(at: root) }
        let storeDir = root.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let fileURL = storeDir.appendingPathComponent("manual_sources.json")
        let future = "{\"schemaVersion\": 99, \"pins\": []}"
        try Data(future.utf8).write(to: fileURL)

        let store = ManualSourceStore(directory: storeDir)
        do {
            _ = try store.pins()
            Issue.record("future schema must throw clean")
        } catch let thrown as ManualSourceError {
            #expect(thrown.reason.contains("99"))
            #expect(thrown.reason.contains("this build writes and reads 1 only"))
        }
        #expect(try Data(contentsOf: fileURL) == Data(future.utf8)) // never auto-delete
    }

    // MARK: (6) Resolver — nil paths with ZERO asserted requests

    @Test func resolverNoPinNilCorruptStoreAlsoNilAndZeroRequests() async throws {
        ManualStubURLProtocol.reset()
        let root = try makeRoot("resolve-nil")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = makeSession()
        let service = ManualSourceResolverService(
            store: ManualSourceStore(directory: root.appendingPathComponent("Store", isDirectory: true)))
        let app = InstalledApp(bundleIdentifier: "io.app.pinned", name: "App", path: "/Applications/App.app", shortVersion: "1.0")

        let cacheDir = try makeRoot("cache")
        #expect(await service.source(for: app, session: session, githubCacheDirectory: cacheDir) == nil)
        #expect(ManualStubURLProtocol.recordedRequests.isEmpty)

        // Honest caveat (documented on the service): a corrupt store reads
        // as "no pin" through the engine seam, because the resolver itself
        // has no error channel (the sheet is where corruption surfaces).
        let dirtyDir = root.appendingPathComponent("Dirty", isDirectory: true)
        try FileManager.default.createDirectory(at: dirtyDir, withIntermediateDirectories: true)
        try Data("{\"slots".utf8).write(to: dirtyDir.appendingPathComponent("manual_sources.json"))
        let dirtyService = ManualSourceResolverService(store: ManualSourceStore(directory: dirtyDir))
        #expect(await dirtyService.source(for: app, session: session, githubCacheDirectory: root) == nil)
        #expect(ManualStubURLProtocol.recordedRequests.isEmpty)
    }

    @Test func resolverGitHubPinEndToEndTagVerbatimOnlyPinnedURL() async throws {
        ManualStubURLProtocol.reset()
        let root = try makeRoot("resolve-github")
        defer { try? FileManager.default.removeItem(at: root) }
        let pinnedURL = "https://api.github.com/repos/pinned/orne/releases/latest"
        ManualStubURLProtocol.stub(manualReleaseJSON(tag: "0.9.0"), status: 200, headers: ["ETag": "\"e-1\""], forURL: pinnedURL)

        try ManualSourceStore(directory: root.appendingPathComponent("Store", isDirectory: true))
            .add(githubPin: "pinned", repo: "orne", bundleID: "io.pin.me")
        let service = ManualSourceResolverService(
            store: ManualSourceStore(directory: root.appendingPathComponent("Store", isDirectory: true)))

        // The app's OWN sparkle feed points at a DIFFERENT repo — the pin
        // must suppress the harvest (returned source is the pinned-init
        // GithubSource AS-IS).
        let app = InstalledApp(
            bundleIdentifier: "io.pin.me", name: "Pinned App", path: "/Applications/Pinned.app",
            shortVersion: "0.1", sparkleFeedURL: "https://github.com/harvest/other/releases/latest")

        let source = try #require(await service.source(for: app, session: makeSession(), githubCacheDirectory: root))
        #expect(type(of: source).kind == .github)

        let info = try await source.fetchUpdateInfo(for: app)
        #expect(info?.source == .github)
        #expect(info?.newestShortVersion == "0.9.0") // tag verbatim
        #expect(ManualStubURLProtocol.recordedRequests.map { $0.url.absoluteString } == [pinnedURL])
    }

    @Test func resolverCaskPinEndToEndManualDetailClaim() async throws {
        ManualStubURLProtocol.reset()
        let root = try makeRoot("resolve-cask")
        defer { try? FileManager.default.removeItem(at: root) }
        let caskURL = "https://formulae.brew.sh/api/cask/firefox.json"
        ManualStubURLProtocol.stub(manualCaskJSON, forURL: caskURL)

        try ManualSourceStore(directory: root.appendingPathComponent("Store", isDirectory: true))
            .add(caskPin: "firefox", bundleID: "org.mozilla.firefox")
        let service = ManualSourceResolverService(
            store: ManualSourceStore(directory: root.appendingPathComponent("Store", isDirectory: true)))

        let source = try #require(await service.source(
            for: makeFirefoxFixtureApp(), session: makeSession(), githubCacheDirectory: root))
        #expect(type(of: source).kind == .cask)

        let info = try #require(await source.fetchUpdateInfo(for: makeFirefoxFixtureApp()))
        #expect(info.source == .cask)
        #expect(info.newestShortVersion == "158.0.1")
        #expect(info.sourceDetail?.contains("manual cask pin") == true)
        #expect(info.sourceDetail?.contains("'firefox'") == true)
        #expect(ManualStubURLProtocol.recordedRequests.map { $0.url.absoluteString } == [caskURL])
    }

    @Test func resolverCaskPin404HonestNilNoManufacturedClaim() async throws {
        ManualStubURLProtocol.reset() // nothing registered → cask URL 404s
        let root = try makeRoot("resolve-404")
        defer { try? FileManager.default.removeItem(at: root) }

        try ManualSourceStore(directory: root.appendingPathComponent("Store", isDirectory: true))
            .add(caskPin: "ghost-cask", bundleID: "io.ghost")
        let service = ManualSourceResolverService(
            store: ManualSourceStore(directory: root.appendingPathComponent("Store", isDirectory: true)))
        let app = InstalledApp(bundleIdentifier: "io.ghost", name: "Ghost", path: "/Applications/Ghost.app", shortVersion: "1.0")

        let source = try #require(await service.source(for: app, session: makeSession(), githubCacheDirectory: root))
        #expect(type(of: source).kind == .cask)

        // .notFound → nil: the pin attests WHERE to look, never that an
        // update exists — no manufactured claims.
        let info = try await source.fetchUpdateInfo(for: app)
        #expect(info == nil)
        #expect(ManualStubURLProtocol.recordedRequests.map { $0.url.absoluteString }
            == ["https://formulae.brew.sh/api/cask/ghost-cask.json"])
    }

    @Test func resolverNoPinForOtherAppReturnsNilWithZeroRequests() async throws {
        ManualStubURLProtocol.reset()
        let root = try makeRoot("resolve-other")
        defer { try? FileManager.default.removeItem(at: root) }

        // A pinned app exists in the store, but the QUERY app has none.
        try ManualSourceStore(directory: root.appendingPathComponent("Store", isDirectory: true))
            .add(caskPin: "firefox", bundleID: "org.mozilla.firefox")
        let service = ManualSourceResolverService(
            store: ManualSourceStore(directory: root.appendingPathComponent("Store", isDirectory: true)))
        let unpinned = InstalledApp(bundleIdentifier: "io.other.app", name: "Other", path: "/Applications/Other.app", shortVersion: "1.0")

        // Matching is by bundleIdentifier EXACTLY — "a pin exists" for the
        // store does NOT accrete onto other apps.
        #expect(await service.source(for: unpinned, session: makeSession(), githubCacheDirectory: root) == nil)
        #expect(ManualStubURLProtocol.recordedRequests.isEmpty)
    }

    // MARK: (7) THE SEAM — engine + real store + real resolver

    @Test func seamPinnedAppUsesPinBuiltinsSuppressedNoPinAppRunsBuiltins() async throws {
        ManualStubURLProtocol.reset()
        let root = try makeRoot("seam-suppress")
        defer { try? FileManager.default.removeItem(at: root) }
        let pinnedURL = "https://api.github.com/repos/pinned/orne/releases/latest"
        ManualStubURLProtocol.stub(manualReleaseJSON(tag: "1.4.2"), forURL: pinnedURL)

        try ManualSourceStore(directory: root.appendingPathComponent("Store", isDirectory: true))
            .add(githubPin: "pinned", repo: "orne", bundleID: "io.seam.pin")

        let service = ManualSourceResolverService(
            store: ManualSourceStore(directory: root.appendingPathComponent("Store", isDirectory: true)))
        let builtin = ManualProbeCounter()
        let engine = UpdateCheckEngine(
            sources: [ManualFakeBuiltinSource(
                counter: builtin,
                claim: UpdateInfo(source: .cask, newestShortVersion: "9.9")
            )],
            manualSource: service.engineResolver(session: makeSession(), githubCacheDirectory: root)
        )

        let pinnedApp = InstalledApp(bundleIdentifier: "io.seam.pin", name: "Pinned", path: "/Applications/Pinned.app", shortVersion: "1.0")
        let pinnedCheck = await engine.check(app: pinnedApp)

        // The builtin's "9.9" claim would beat 1.4.2 on any consulted path —
        // a .github/1.4.2 winner proves the built-in was never queried.
        #expect(pinnedCheck.resolved?.source == .github)
        #expect(pinnedCheck.resolved?.newestShortVersion == "1.4.2")
        #expect(pinnedCheck.candidates.map(\.source) == [.github])
        #expect(pinnedCheck.failures.isEmpty)
        #expect(await builtin.value() == 0)
        #expect(pinnedCheck.verdict == "update")

        // THE SAME engine, an app with NO pin: built-ins run as usual.
        let unpinnedApp = InstalledApp(bundleIdentifier: "io.seam.free", name: "Free", path: "/Applications/Free.app", shortVersion: "1.0")
        let unpinnedCheck = await engine.check(app: unpinnedApp)
        #expect(unpinnedCheck.resolved?.source == .cask)
        #expect(unpinnedCheck.resolved?.newestShortVersion == "9.9")
        #expect(await builtin.value() == 1)
        #expect(unpinnedCheck.verdict == "update")
    }

    @Test func seamNoPinsEngineIdenticalToPlainEngineForUnaffectedApps() async throws {
        ManualStubURLProtocol.reset()
        let root = try makeRoot("seam-plain")
        defer { try? FileManager.default.removeItem(at: root) }

        let service = ManualSourceResolverService(
            store: ManualSourceStore(directory: root.appendingPathComponent("Store", isDirectory: true))) // EMPTY store
        let withSeamCounter = ManualProbeCounter()
        let plainCounter = ManualProbeCounter()
        let app = InstalledApp(bundleIdentifier: "io.seam.same", name: "Same", path: "/Applications/Same.app", shortVersion: "1.0")

        let withSeam = UpdateCheckEngine(
            sources: [ManualFakeBuiltinSource(counter: withSeamCounter, claim: UpdateInfo(source: .cask, newestShortVersion: "2.0"))],
            manualSource: service.engineResolver(session: makeSession(), githubCacheDirectory: root),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let plain = UpdateCheckEngine(
            sources: [ManualFakeBuiltinSource(counter: plainCounter, claim: UpdateInfo(source: .cask, newestShortVersion: "2.0"))],
            now: { Date(timeIntervalSince1970: 1_000) }
        )

        let seamCheck = await withSeam.check(app: app)
        let plainCheck = await plain.check(app: app)
        #expect(seamCheck == plainCheck) // identical verdict/candidates/failures
        #expect(await withSeamCounter.value() == 1)
        #expect(await plainCounter.value() == 1)
        #expect(ManualStubURLProtocol.recordedRequests.isEmpty) // pin-nil path never touches the stubs
    }

    @Test func seamPinnedCask404VerdictUnknownNoBuiltinFallbackNoFakeClaim() async throws {
        ManualStubURLProtocol.reset() // nothing registered → pinned cask 404s
        let root = try makeRoot("seam-404")
        defer { try? FileManager.default.removeItem(at: root) }

        try ManualSourceStore(directory: root.appendingPathComponent("Store", isDirectory: true))
            .add(caskPin: "ghost-cask", bundleID: "io.seam.ghost")

        let service = ManualSourceResolverService(
            store: ManualSourceStore(directory: root.appendingPathComponent("Store", isDirectory: true)))
        let builtin = ManualProbeCounter()
        let engine = UpdateCheckEngine(
            sources: [ManualFakeBuiltinSource(counter: builtin, claim: UpdateInfo(source: .cask, newestShortVersion: "9.9"))],
            manualSource: service.engineResolver(session: makeSession(), githubCacheDirectory: root)
        )
        let app = InstalledApp(bundleIdentifier: "io.seam.ghost", name: "Ghost", path: "/Applications/Ghost.app", shortVersion: "1.0")
        let check = await engine.check(app: app)

        // Honesty: the pin answered nothing (404) AND the owner's
        // attestation stands — no built-in fallback, no fake claim.
        #expect(check.candidates.isEmpty)
        #expect(check.failures.isEmpty)
        #expect(check.resolved == nil)
        #expect(check.verdict == "unknown")
        #expect(await builtin.value() == 0)
    }
}
