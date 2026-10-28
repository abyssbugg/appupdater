// Cask pkg-claim tests — the strictly-gated pkg-only evidence class that lets
// pkg-only casks (tailscale-app shape: artifacts carry `pkg`, NO `app`) drive
// the staged owner-command flow. Hermetic (custom URLProtocol stub; NO network
// is touched, no /Applications or real Application Support is ever referenced).
// Swift Testing only: XCTest discovery is broken on this toolchain (Xcode 27 beta).
//
// Stub discipline mirrors CaskIndexTests: this file owns its OWN URLProtocol
// class + static state so its suites can run in parallel with every other
// suite's without cross-contaminating fixture tables. Fixtures are true-to-shape
// (pkg directive + uninstall cleanup block, as the live tailscale-app cask renders).

import Foundation
import Testing
@testable import AppUpdaterCore

// MARK: - Hermetic URL stub (whole-index endpoint, this file's private table)

final class PkgClaimStubURLProtocol: URLProtocol {
    struct PkgStubResponse: Sendable {
        let status: Int
        let body: Data?
    }

    private static let box = PkgClaimStubBox<[String: PkgStubResponse]>([:])

    static func reset() {
        Self.box.with { stubs in stubs = [:] }
    }

    static func stub(_ json: String, status: Int = 200, forURLString url: String) {
        let body = json.isEmpty ? nil : Data(json.utf8)
        Self.box.with { stubs in stubs[url] = PkgStubResponse(status: status, body: body) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let answer = Self.box.with { stubs in stubs[url.absoluteString] }
        let response = HTTPURLResponse(
            url: url,
            statusCode: answer?.status ?? 404,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])
        guard let response else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body = answer?.body { client.urlProtocol(self, didLoad: body) }
        client.urlProtocolDidFinishLoading(self)
    }
}

/// Tiny thread-safe box for the stub state (independent copy from
/// CaskIndexTests' StubBox so this lane's test file is self-contained).
final class PkgClaimStubBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ initial: Value) { value = initial }

    func with<Result>(_ mutate: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return mutate(&value)
    }
}

// MARK: - Fixtures

private let pkgIndexEndpointURL = "https://formulae.brew.sh/api/cask.json"
private let pkgSHA = "3f7ce0b1a2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d"

/// The pkg-only shape that motivated the lane: `pkg` directive present, NO `app`
/// directive anywhere (the uninstall block is cleanup, never install evidence).
private let pkgOnlyIndexJSON = """
[
  {
    "token": "tailscale-app",
    "name": ["Tailscale"],
    "desc": "Mesh VPN",
    "homepage": "https://tailscale.com/",
    "url": "https://pkgs.tailscale.com/stable/Tailscale-1.104.4-macos.pkg",
    "version": "1.104.4",
    "sha256": "\(pkgSHA)",
    "artifacts": [
      {"pkg": ["Tailscale-1.104.4-macos.pkg"]},
      {"uninstall": [{"delete": "/Applications/Tailscale.app"}]}
    ]
  }
]
"""

/// App-artifact record + pkg-only record, BOTH plausibly claiming app
/// "Tailscale": the stronger app-artifact path must win untouched.
private let appArtifactWinsIndexJSON = """
[
  {
    "token": "tailscale-app",
    "name": ["Tailscale"],
    "url": "https://pkgs.tailscale.com/stable/Tailscale-1.104.4-macos.pkg",
    "version": "1.104.4",
    "sha256": "\(pkgSHA)",
    "artifacts": [{"pkg": ["Tailscale-1.104.4-macos.pkg"]}]
  },
  {
    "token": "tailscale-macos",
    "name": ["Tailscale"],
    "url": "https://example.com/Tailscale.dmg",
    "version": "1.103.0",
    "sha256": "aaaab1fc9110185047de18228ac87238fba5e42bba53c9d696f88878cba6",
    "artifacts": [{"app": ["Tailscale.app"]}]
  }
]
"""

/// TWO DISTINCT pkg-only records deriving the same app name — weaker evidence
/// demands uniqueness, so this index must resolve to nil.
private let twoPkgRecordsIndexJSON = """
[
  {
    "token": "tailscale-app",
    "name": ["Tailscale"],
    "url": "https://pkgs.tailscale.com/stable/Tailscale-1.104.4-macos.pkg",
    "version": "1.104.4",
    "sha256": "\(pkgSHA)",
    "artifacts": [{"pkg": ["Tailscale-1.104.4-macos.pkg"]}]
  },
  {
    "token": "tailscale-alt",
    "name": ["Tailscale"],
    "url": "https://mirror.example.com/tailscale-2.0.pkg",
    "version": "2.0",
    "sha256": "bbbba1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d",
    "artifacts": [{"pkg": ["tailscale-2.0.pkg"]}]
  }
]
"""

// MARK: - Derivation rules (pure)

@Suite struct CaskPkgDerivedNameTests {

    @Test func tailscalePkgDerivesTailscale() {
        #expect(CaskMatching.pkgDerivedMatchName(fromPkgFilename: "Tailscale-1.104.4-macos.pkg") == "tailscale")
    }

    @Test func sublimeTextPkgDerivesSublimeText() {
        #expect(CaskMatching.pkgDerivedMatchName(fromPkgFilename: "Sublime-Text-4.pkg") == "sublime-text")
    }

    @Test func versionOnlyFilenameYieldsNil() {
        #expect(CaskMatching.pkgDerivedMatchName(fromPkgFilename: "1.2.3.pkg") == nil)
    }

    @Test func leftoverTokenWithDigitYieldsNil() {
        #expect(CaskMatching.pkgDerivedMatchName(fromPkgFilename: "App2-1.0.pkg") == nil)
    }

    @Test func emptyAfterDropsYieldsNil() {
        // "macos" and "installer" both sit in the platform/build drop set.
        #expect(CaskMatching.pkgDerivedMatchName(fromPkgFilename: "macos-installer.pkg") == nil)
    }

    @Test func longHexTokenIsDropped() {
        // "deadbeef12345678" is pure hex of length ≥ 8 (a build/hash token).
        #expect(CaskMatching.pkgDerivedMatchName(fromPkgFilename: "DeadBeef12345678.pkg") == nil)
    }

    @Test func underscoreAndSpaceSplitsJoinWithDash() {
        #expect(CaskMatching.pkgDerivedMatchName(fromPkgFilename: "My_App 2.0.pkg") == "my-app")
    }

    @Test func vPrefixedVersionTokenIsDropped() {
        #expect(CaskMatching.pkgDerivedMatchName(fromPkgFilename: "Tailscale-v2.pkg") == "tailscale")
    }
}

// MARK: - pkgArtifactsMatchInstalledApp gates

@Suite struct CaskPkgArtifactMatchTests {

    private func record(_ json: String) throws -> CaskRecord {
        try JSONDecoder().decode(CaskRecord.self, from: Data(json.utf8))
    }

    private func pkgRecordJSON(
        url: String = "https://pkgs.tailscale.com/stable/Tailscale-1.104.4-macos.pkg",
        sha256: String? = pkgSHA,
        pkg: [String] = ["Tailscale-1.104.4-macos.pkg"]
    ) -> String {
        let shaPart = sha256.map { "\"sha256\": \"\($0)\"," } ?? ""
        let pkgPart = pkg.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
        {
          "token": "tailscale-app",
          "name": ["Tailscale"],
          "url": "\(url)",
          "version": "1.104.4",
          \(shaPart)
          "artifacts": [ {"pkg": [\(pkgPart)]} ]
        }
        """
    }

    private func tailscaleApp(name: String = "Tailscale", path: String = "/Applications/Tailscale.app") -> InstalledApp {
        InstalledApp(bundleIdentifier: "io.tailscale.mac", name: name, path: path)
    }

    @Test func nameMatchAccepted() throws {
        let record = try record(pkgRecordJSON())
        #expect(CaskMatching.pkgArtifactsMatchInstalledApp(record: record, for: tailscaleApp()))
    }

    @Test func nameMismatchRefused() throws {
        let record = try record(pkgRecordJSON(pkg: ["Something-Else-1.0.pkg"]))
        #expect(!CaskMatching.pkgArtifactsMatchInstalledApp(record: record, for: tailscaleApp()))
    }

    @Test func missingSha256Refused() throws {
        // A pkg claim without a checksum is worthless — the staged flow's floor.
        let record = try record(pkgRecordJSON(sha256: nil))
        #expect(!CaskMatching.pkgArtifactsMatchInstalledApp(record: record, for: tailscaleApp()))
    }

    @Test func nonPkgRecordURLRefused() throws {
        // A pkg artifact listed under a dmg url is misleading evidence.
        let record = try record(pkgRecordJSON(url: "https://pkgs.tailscale.com/stable/Tailscale-1.104.4-macos.dmg"))
        #expect(!CaskMatching.pkgArtifactsMatchInstalledApp(record: record, for: tailscaleApp()))
    }

    @Test func pathBasenameCountsAsInstalledName() throws {
        let record = try record(pkgRecordJSON())
        let app = tailscaleApp(name: "Tailscale VPN", path: "/Applications/Tailscale.app")
        #expect(CaskMatching.pkgArtifactsMatchInstalledApp(record: record, for: app))
    }
}

// MARK: - Store resolution + source/planner end-to-end

@Suite(.serialized)
struct CaskIndexPkgClaimTests {

    private func makeStore() -> (store: CaskIndexStore, directory: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cask-pkg-claim-\(UUID().uuidString)", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PkgClaimStubURLProtocol.self]
        let store = CaskIndexStore(directory: dir, session: URLSession(configuration: configuration))
        return (store, dir)
    }

    private let tailscaleApp = InstalledApp(
        bundleIdentifier: "io.tailscale.mac",
        name: "Tailscale",
        path: "/Applications/Tailscale.app")

    // (1) The app-artifact paths ALWAYS win: with an app-artifact record present,
    // the pkg-only record is never consulted (even though it would also match).
    @Test func appArtifactMatchWinsOverPkgOnlyRecord() async throws {
        PkgClaimStubURLProtocol.reset()
        PkgClaimStubURLProtocol.stub(appArtifactWinsIndexJSON, forURLString: pkgIndexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        let match = try #require(await store.resolvedMatch(for: tailscaleApp))
        guard case .artifactName(let record, let artifact) = match else {
            Issue.record("expected the app-artifact path to win, got \(match)")
            return
        }
        #expect(record.token == "tailscale-macos")
        #expect(artifact == "Tailscale.app")
    }

    // (2) TWO distinct pkg-only records both matching → nil (weaker evidence
    // demands uniqueness; a wrong derivation stages the WRONG pkg for sudo).
    @Test func twoDistinctPkgOnlyRecordsRefusedForUniqueness() async throws {
        PkgClaimStubURLProtocol.reset()
        PkgClaimStubURLProtocol.stub(twoPkgRecordsIndexJSON, forURLString: pkgIndexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        let match = await store.resolvedMatch(for: tailscaleApp)
        #expect(match == nil)
    }

    // (3) Exactly ONE pkg-only record → the match fires, carrying a basis
    // fragment that names the pkg file and the honest derivation.
    @Test func singlePkgOnlyRecordMatchesWithHonestBasis() async throws {
        PkgClaimStubURLProtocol.reset()
        PkgClaimStubURLProtocol.stub(pkgOnlyIndexJSON, forURLString: pkgIndexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        let match = try #require(await store.resolvedMatch(for: tailscaleApp))
        guard case .pkgArtifact(let record, let artifact, let derived) = match else {
            Issue.record("expected the pkg-artifact path, got \(match)")
            return
        }
        #expect(record.token == "tailscale-app")
        #expect(artifact == "Tailscale-1.104.4-macos.pkg")
        #expect(derived == "tailscale")
        #expect(match.basisFragment == "pkg-artifact 'Tailscale-1.104.4-macos.pkg' (derived 'tailscale')")
    }

    // (4) Store-level: the sha256 floor holds end-to-end — a pkg-only record
    // without a checksum never resolves.
    @Test func pkgOnlyRecordWithoutSha256Refused() async throws {
        PkgClaimStubURLProtocol.reset()
        PkgClaimStubURLProtocol.stub(
            pkgOnlyIndexJSON.replacingOccurrences(of: "\"sha256\": \"\(pkgSHA)\",", with: "\"sha256\": \"\","),
            forURLString: pkgIndexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        let match = await store.resolvedMatch(for: tailscaleApp)
        #expect(match == nil)
    }

    // (5) Store-level: a pkg-artifact claim under a non-pkg `url` never resolves.
    @Test func pkgOnlyRecordWithNonPkgURLRefused() async throws {
        PkgClaimStubURLProtocol.reset()
        PkgClaimStubURLProtocol.stub(
            pkgOnlyIndexJSON.replacingOccurrences(
                of: "https://pkgs.tailscale.com/stable/Tailscale-1.104.4-macos.pkg",
                with: "https://pkgs.tailscale.com/stable/Tailscale-1.104.4-macos.dmg"),
            forURLString: pkgIndexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        let match = await store.resolvedMatch(for: tailscaleApp)
        #expect(match == nil)
    }

    // (6) End-to-end: pkg-only cask → CaskIndexSource UpdateInfo whose download
    // URL is the cask .pkg URL → InstallPlanner yields the staged-owner-command
    // plan (kind .pkg, steps ending .stageOwnerCommand — installer(8) never run).
    @Test func pkgClaimSourcesStagedOwnerCommandPlan() async throws {
        PkgClaimStubURLProtocol.reset()
        PkgClaimStubURLProtocol.stub(pkgOnlyIndexJSON, forURLString: pkgIndexEndpointURL)
        let (store, dir) = await makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(await store.ensureLoaded() == true)
        let source = CaskIndexSource(store: store)
        let info = try #require(try await source.fetchUpdateInfo(for: tailscaleApp))

        #expect(info.source == .cask)
        #expect(info.newestShortVersion == "1.104.4")
        #expect(info.downloadURL?.absoluteString == "https://pkgs.tailscale.com/stable/Tailscale-1.104.4-macos.pkg")
        #expect(info.sha256Hex == pkgSHA)
        #expect(info.sourceDetail == "Homebrew cask whole-index; matched by pkg-artifact 'Tailscale-1.104.4-macos.pkg' (derived 'tailscale'); self-attested (sha256 lives in the same unsigned JSON).")

        let plan = try InstallPlanner().plan(app: tailscaleApp, update: info)
        #expect(plan.kind == .pkg)
        #expect(plan.steps == [.download, .verifySha256, .verifyArtifactMagic, .stageOwnerCommand])
        #expect(plan.stagedCommand == "sudo installer -pkg <staged-pkg-path> -target /")
    }
}
