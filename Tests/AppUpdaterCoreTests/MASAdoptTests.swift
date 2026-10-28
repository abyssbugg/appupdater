// MASAdopt tests — the MAS→Homebrew adoption gate + its whole-index adapter.
// Hermetic: the gate resolves casks through the injected MASAdoptCaskResolver
// seam (pure functions, zero network); the adapter suite drives a REAL
// CaskIndexStore over a custom URLProtocol stub (no network touched, no
// /Applications or real Application Support referenced, per-test UUID temp
// dirs so no other suite or concurrent runner can collide). Swift Testing only
// (XCTest discovery is broken on this toolchain).

import Foundation
import Testing
@testable import AppUpdaterCore

// MARK: - Fixtures

/// Trimmed real-shape whole-index (same shape family as CaskIndexTests'
/// fixtures, derived from docs/evidence/ff.json): token-path match
/// (google-chrome), scan-path match (firefox via "Firefox.app"), the
/// alias-killer decoy (token "chrome" whose artifacts do NOT match app
/// "Chrome"), and the displayName tie-break pair (Diff Viewer).
private let adoptIndexFixtureJSON = """
[
  {
    "token": "google-chrome",
    "name": ["Google Chrome"],
    "desc": "Web browser",
    "homepage": "https://www.google.com/chrome/",
    "url": "https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg",
    "version": "156.0.8078.48",
    "sha256": {"string": "2f2c9c5e2d98e83428c5cf04309f6a9ea70355a1af69ea7015ee8b3f0e70c96a", "algorithm": "sha256"},
    "artifacts": [{"app": ["Google Chrome.app"]}]
  },
  {
    "token": "firefox",
    "name": ["Mozilla Firefox"],
    "desc": "Web browser",
    "homepage": "https://www.mozilla.org/firefox/",
    "url": "https://download-installer.cdn.mozilla.net/pub/firefox/releases/158.0.1/mac/en-US/Firefox 158.0.1.dmg",
    "version": "158.0.1",
    "sha256": "1d7aa96b51fc9110185047de18228ac87238fba5e42bba53c9d696f88878cba6",
    "artifacts": [{"app": ["Firefox.app"], "target": "/Applications/Firefox.app"}]
  },
  {
    "token": "chrome",
    "name": ["Chrome Remote Desktop"],
    "desc": "Remote access helper",
    "homepage": "https://remotedesktop.google.com/",
    "url": "https://dl.google.com/chrome-remote-desktop/remotedesktop.dmg",
    "version": "159.0.0.1",
    "sha256": "5d5d7f39d7893a3d2a4f03d6a301d7a2e5e93b5f6b6c0f0f1c2a4d5e6f708091",
    "artifacts": [{"app": ["Chrome Remote Desktop.app"]}]
  },
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

private let adoptIndexEndpoint = "https://formulae.brew.sh/api/cask.json"

// MARK: - Hermetic URL stub (self-contained: own box + own class, per the
// cross-suite parallelism convention of this test target)

final class AdoptStubBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ initial: Value) { value = initial }

    func with<Result>(_ mutate: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return mutate(&value)
    }
}

/// Serves the whole-index fixture body. Unregistered URLs get a 404.
/// stopLoading MUST be overridden (cask lane gotcha, commit a350fde): CFNetwork
/// invokes it on teardown and the abstract base throws signal 6.
final class AdoptIndexStubURLProtocol: URLProtocol {
    private static let bodyBox = AdoptStubBox<Data?>(nil)

    static func reset() { bodyBox.with { body in body = nil } }
    static func stub(_ json: String) { bodyBox.with { body in body = Data(json.utf8) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let client else { return }
        let fallback = URL(fileURLWithPath: "/adopt-stub-unregistered")
        let response = HTTPURLResponse(
            url: request.url ?? fallback,
            statusCode: request.url?.absoluteString == adoptIndexEndpoint ? 200 : 404,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])
        guard let response else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = Self.bodyBox.with { body in body }
        if request.url?.absoluteString == adoptIndexEndpoint, let body {
            client.urlProtocol(self, didLoad: body)
        }
        client.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - Suite

@Suite struct MASAdoptTests {

    private let gate = MASAdoptGate()

    // -- fixture builders ---------------------------------------------------

    private func app(
        mas: Bool = true,
        short: String? = "1.2.3",
        name: String = "Pixel Picker",
        bundleID: String = "store.pixel.picker",
        path: String = "/Applications/Pixel Picker.app"
    ) -> InstalledApp {
        InstalledApp(
            bundleIdentifier: bundleID,
            name: name,
            path: path,
            shortVersion: short,
            bundleVersion: "42",
            isMacAppStore: mas)
    }

    private func uniqueMatch(token: String, version: String?, basis: String? = nil)
        -> MASAdoptCaskResolver {
        let basis = basis ?? "token '\(token)'"
        return MASAdoptCaskResolver { _ in
            .unique(MASAdoptCaskResolver.Match(token: token, version: version, basis: basis))
        }
    }

    private func noMatchResolver() -> MASAdoptCaskResolver {
        MASAdoptCaskResolver { _ in MASAdoptCaskResolver.Resolution.none }
    }

    private func ambiguousResolver(detail: String) -> MASAdoptCaskResolver {
        MASAdoptCaskResolver { _ in MASAdoptCaskResolver.Resolution.ambiguous(detail: detail) }
    }

    // -- R1 identity gate ---------------------------------------------------

    @Test func nonMASAppIsRefusedEvenWithAMatch() async {
        let decision = await gate.decide(app: app(mas: false), resolver: uniqueMatch(token: "pixel-picker", version: "1.2.3"))
        #expect(decision.refusalCode == MASAdoptGate.codeNotMacAppStore)
        #expect(decision.refusalReason?.contains("not a Mac App Store install") == true)
        #expect(decision.stagedCommand == nil)
        #expect(decision.caskToken == nil)
    }

    @Test func forceNeverOverridesTheIdentityGate() async {
        let decision = await gate.decide(app: app(mas: false), resolver: uniqueMatch(token: "pixel-picker", version: "1.2.3"), force: true)
        #expect(decision.refusalCode == MASAdoptGate.codeNotMacAppStore)
        #expect(decision.stagedCommand == nil)
        #expect(decision.forced == true) // the flag is recorded, the gate held
    }

    // -- R2/R3 cask existence + uniqueness ----------------------------------

    @Test func noCaskIsRefused() async {
        let decision = await gate.decide(app: app(), resolver: noMatchResolver())
        #expect(decision.refusalCode == MASAdoptGate.codeNoCask)
        #expect(decision.refusalReason?.contains("no Homebrew cask installs this app") == true)
        #expect(decision.stagedCommand == nil)
    }

    @Test func forceNeverOverridesAMissingCask() async {
        let decision = await gate.decide(app: app(), resolver: noMatchResolver(), force: true)
        #expect(decision.refusalCode == MASAdoptGate.codeNoCask)
        #expect(decision.stagedCommand == nil)
    }

    @Test func ambiguousMatchIsRefusedRatherThanGuessed() async {
        let detail = "2 artifact matches: 'pixel-picker', 'pixel-picker-alt'"
        let decision = await gate.decide(app: app(), resolver: ambiguousResolver(detail: detail))
        #expect(decision.refusalCode == MASAdoptGate.codeAmbiguousMatch)
        #expect(decision.refusalReason?.contains(detail) == true)
        #expect(decision.stagedCommand == nil)
        #expect(decision.caskToken == nil)
    }

    @Test func forceNeverOverridesAnAmbiguousMatch() async {
        let decision = await gate.decide(app: app(), resolver: ambiguousResolver(detail: "two casks"), force: true)
        #expect(decision.refusalCode == MASAdoptGate.codeAmbiguousMatch)
        #expect(decision.stagedCommand == nil)
    }

    // -- clean adopt ----------------------------------------------------------

    @Test func cleanAdoptEmitsTheAdoptCommand() async {
        let decision = await gate.decide(app: app(), resolver: uniqueMatch(token: "pixel-picker", version: "1.2.3"))
        #expect(decision.refusalReason == nil)
        #expect(decision.refusalCode == nil)
        #expect(decision.stagedCommand == "brew install --cask --adopt pixel-picker")
        #expect(decision.caskToken == "pixel-picker")
        #expect(decision.caskVersion == "1.2.3")
        #expect(decision.installedVersion == "1.2.3")
        #expect(decision.forced == false)
        #expect(decision.matchBasis == "token 'pixel-picker'")
    }

    @Test func everyEligibleDecisionCarriesTheUnconditionalPaidWarning() async {
        let clean = await gate.decide(app: app(), resolver: uniqueMatch(token: "pixel-picker", version: "1.2.3"))
        let forced = await gate.decide(app: app(short: "1.0"), resolver: uniqueMatch(token: "pixel-picker", version: "2.0"), force: true)
        for decision in [clean, forced] {
            #expect(decision.stagedCommand != nil)
            let paid = decision.warnings.filter { $0.contains("PAID-APP-STORE WARNING") }
            #expect(paid.count == 1)
            #expect(paid.first?.contains("will not transfer") == true)
            #expect(paid.first?.contains("cannot detect whether this app was paid") == true)
        }
    }

    @Test func eligibleDecisionCarriesTheIdentityNote() async {
        let decision = await gate.decide(app: app(), resolver: uniqueMatch(token: "pixel-picker", version: "1.2.3"))
        #expect(decision.warnings.contains { $0.contains("receipt + entitlements") && $0.contains("'pixel-picker'") })
    }

    // -- R4 version mismatch (force-overridable) -----------------------------

    @Test func newerCaskIsAMismatchRefusedWithoutForce() async {
        let decision = await gate.decide(app: app(short: "1.2.3"), resolver: uniqueMatch(token: "pixel-picker", version: "2.0"))
        #expect(decision.refusalCode == MASAdoptGate.codeVersionMismatch)
        #expect(decision.refusalReason?.contains("installed version (1.2.3)") == true)
        #expect(decision.refusalReason?.contains("cask version (2.0)") == true)
        #expect(decision.stagedCommand == nil)
        #expect(decision.caskToken == "pixel-picker") // the match is known even when refused
    }

    @Test func olderCaskIsAlsoAMismatch() async {
        // Bidirectional gate: adopting replaces the app with the cask build,
        // so a cask OLDER than installed is the same replacement risk.
        let refused = await gate.decide(app: app(short: "2.0"), resolver: uniqueMatch(token: "pixel-picker", version: "1.2.3"))
        #expect(refused.refusalCode == MASAdoptGate.codeVersionMismatch)
        #expect(refused.stagedCommand == nil)

        let forced = await gate.decide(app: app(short: "2.0"), resolver: uniqueMatch(token: "pixel-picker", version: "1.2.3"), force: true)
        #expect(forced.stagedCommand == "brew install --cask --force --adopt pixel-picker")
        #expect(forced.forced == true)
    }

    @Test func mismatchWithForceEmitsTheForceCommandAndOverrideReceipt() async {
        let decision = await gate.decide(app: app(short: "1.2.3"), resolver: uniqueMatch(token: "pixel-picker", version: "2.0"), force: true)
        #expect(decision.stagedCommand == "brew install --cask --force --adopt pixel-picker")
        #expect(decision.forced == true)
        #expect(decision.refusalReason == nil)
        let override = decision.warnings.filter { $0.contains("VERSION-MISMATCH OVERRIDE") }
        #expect(override.count == 1)
        #expect(override.first?.contains("installed version (1.2.3)") == true)
        #expect(override.first?.contains("replace the app with the cask version (2.0)") == true)
    }

    @Test func zeroFillEqualityIsNotAMismatch() async {
        // The canonical comparator's zero-fill: "1.2" == "1.2.0" is a CLEAN adopt.
        let decision = await gate.decide(app: app(short: "1.2"), resolver: uniqueMatch(token: "pixel-picker", version: "1.2.0"))
        #expect(decision.refusalReason == nil)
        #expect(decision.stagedCommand == "brew install --cask --adopt pixel-picker")
        #expect(decision.warnings.contains { $0.contains("VERSION-MISMATCH OVERRIDE") } == false)
    }

    // -- R5 version unverifiable (force-overridable) --------------------------

    @Test func unreadableInstalledVersionIsRefusedUntilForced() async {
        let refused = await gate.decide(app: app(short: nil), resolver: uniqueMatch(token: "pixel-picker", version: "2.0"))
        #expect(refused.refusalCode == MASAdoptGate.codeVersionUnverifiable)
        #expect(refused.refusalReason?.contains("installed version unreadable") == true)
        #expect(refused.stagedCommand == nil)

        let forced = await gate.decide(app: app(short: nil), resolver: uniqueMatch(token: "pixel-picker", version: "2.0"), force: true)
        #expect(forced.stagedCommand == "brew install --cask --force --adopt pixel-picker")
        #expect(forced.warnings.contains { $0.contains("VERSION-UNVERIFIABLE OVERRIDE") })
    }

    @Test func versionlessCaskIsRefusedUntilForced() async {
        let refused = await gate.decide(app: app(short: "1.2.3"), resolver: uniqueMatch(token: "pixel-picker", version: nil))
        #expect(refused.refusalCode == MASAdoptGate.codeVersionUnverifiable)
        #expect(refused.refusalReason?.contains("cask version unreadable") == true)
        #expect(refused.stagedCommand == nil)

        let forced = await gate.decide(app: app(short: "1.2.3"), resolver: uniqueMatch(token: "pixel-picker", version: nil), force: true)
        #expect(forced.stagedCommand == "brew install --cask --force --adopt pixel-picker")
        #expect(forced.warnings.contains { $0.contains("VERSION-UNVERIFIABLE OVERRIDE") })
    }

    @Test func blankVersionStringsCountAsUnreadable() async {
        // Trimmed-blank never counts as a version (CaskIndexSource's rule).
        let decision = await gate.decide(app: app(short: "  "), resolver: uniqueMatch(token: "pixel-picker", version: "2.0"))
        #expect(decision.refusalCode == MASAdoptGate.codeVersionUnverifiable)
    }

    // -- invariants ------------------------------------------------------------

    /// One matrix scenario for the decision invariant sweep (a small struct
    /// instead of a large tuple — large_tuple is a lint warning).
    private struct MatrixCase: Sendable {
        let resolver: MASAdoptCaskResolver
        let force: Bool
        let target: InstalledApp
    }

    @Test func decisionInvariantHoldsAcrossTheWholeMatrix() async {
        let scenarios: [MatrixCase] = [
            MatrixCase(resolver: uniqueMatch(token: "pixel-picker", version: "1.2.3"), force: false, target: app()),
            MatrixCase(resolver: uniqueMatch(token: "pixel-picker", version: "1.2.3"), force: true, target: app()),
            MatrixCase(resolver: uniqueMatch(token: "pixel-picker", version: "2.0"), force: false, target: app(short: "1.0")),
            MatrixCase(resolver: uniqueMatch(token: "pixel-picker", version: "2.0"), force: true, target: app(short: "1.0")),
            MatrixCase(resolver: uniqueMatch(token: "pixel-picker", version: nil), force: false, target: app()),
            MatrixCase(resolver: uniqueMatch(token: "pixel-picker", version: nil), force: true, target: app()),
            MatrixCase(resolver: noMatchResolver(), force: false, target: app()),
            MatrixCase(resolver: noMatchResolver(), force: true, target: app()),
            MatrixCase(resolver: ambiguousResolver(detail: "x"), force: false, target: app()),
            MatrixCase(resolver: ambiguousResolver(detail: "x"), force: true, target: app()),
            MatrixCase(resolver: uniqueMatch(token: "pixel-picker", version: "1.2.3"), force: false, target: app(mas: false)),
            MatrixCase(resolver: uniqueMatch(token: "pixel-picker", version: "1.2.3"), force: true, target: app(mas: false)),
        ]
        for scenario in scenarios {
            let decision = await gate.decide(app: scenario.target, resolver: scenario.resolver, force: scenario.force)
            // stagedCommand XOR refusalReason — never both, never neither.
            #expect((decision.stagedCommand != nil) != (decision.refusalReason != nil))
            #expect((decision.refusalCode != nil) == (decision.refusalReason != nil))
        }
    }

    @Test func commandShapesArePinned() {
        #expect(MASAdoptGate.command(token: "google-chrome", force: false) == "brew install --cask --adopt google-chrome")
        #expect(MASAdoptGate.command(token: "google-chrome", force: true) == "brew install --cask --force --adopt google-chrome")
    }

    @Test func decisionCodableRoundTrip() async throws {
        let decision = await gate.decide(app: app(), resolver: uniqueMatch(token: "pixel-picker", version: "2.0"), force: true)
        let data = try JSONEncoder().encode(decision)
        let decoded = try JSONDecoder().decode(MASAdoptDecision.self, from: data)
        #expect(decoded == decision)
    }
}

// MARK: - Production adapter suite (real CaskIndexStore over the URL stub)

@Suite struct MASAdoptStoreAdapterTests {

    private func makeLoadedStore() async throws -> CaskIndexStore {
        AdoptIndexStubURLProtocol.reset()
        AdoptIndexStubURLProtocol.stub(adoptIndexFixtureJSON)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appupdater-masadopt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AdoptIndexStubURLProtocol.self]
        let store = CaskIndexStore(directory: dir, session: URLSession(configuration: config))
        #expect(await store.ensureLoaded())
        return store
    }

    private func discard(_ store: CaskIndexStore) async {
        await store.dropCache()
    }

    @Test func adapterResolvesTheTokenPathMatch() async throws {
        let store = try await makeLoadedStore()
        defer { Task { await discard(store) } }
        let resolver = MASAdoptCaskResolver.store(store)
        let masChrome = InstalledApp(
            bundleIdentifier: "com.google.Chrome",
            name: "Google Chrome",
            path: "/Applications/Google Chrome.app",
            shortVersion: "156.0.8078.48",
            isMacAppStore: true)
        guard case .unique(let match) = await resolver.resolve(masChrome) else {
            Issue.record("expected a unique match")
            return
        }
        #expect(match.token == "google-chrome")
        #expect(match.version == "156.0.8078.48")
        #expect(match.basis == "token 'google-chrome'")
    }

    @Test func adapterResolvesTheScanPathMatch() async throws {
        let store = try await makeLoadedStore()
        defer { Task { await discard(store) } }
        let resolver = MASAdoptCaskResolver.store(store)
        // "Mozilla Firefox" derives token "mozilla-firefox" (absent from the
        // index); the artifact scan finds firefox via "Firefox.app" — the
        // alias-killer path. (Plain "Firefox" would derive "firefox" and hit
        // the TOKEN path instead — that case is pinned in the gate-over-
        // adapter test via "Google Chrome".)
        let masFirefox = InstalledApp(
            bundleIdentifier: "org.mozilla.firefox",
            name: "Mozilla Firefox",
            path: "/Applications/Firefox.app",
            shortVersion: "158.0.1",
            isMacAppStore: true)
        guard case .unique(let match) = await resolver.resolve(masFirefox) else {
            Issue.record("expected a unique match")
            return
        }
        #expect(match.token == "firefox")
        #expect(match.basis == "artifact-name 'Firefox.app'")
    }

    @Test func adapterReportsNoneWhenNoCaskArtifactMatches() async throws {
        let store = try await makeLoadedStore()
        defer { Task { await discard(store) } }
        let resolver = MASAdoptCaskResolver.store(store)
        // MAS "Chrome": the derived token "chrome" record exists but its
        // artifacts ("Chrome Remote Desktop.app") do NOT validate "Chrome.app"
        // — and no scan-path record does either. Honest .none, never the decoy.
        let masChrome = InstalledApp(
            bundleIdentifier: "com.google.Chrome",
            name: "Chrome",
            path: "/Applications/Chrome.app",
            shortVersion: "1.0",
            isMacAppStore: true)
        guard case MASAdoptCaskResolver.Resolution.none = await resolver.resolve(masChrome) else {
            Issue.record("expected no match")
            return
        }
    }

    @Test func adapterInheritsTheDisplayNameTieBreak() async throws {
        let store = try await makeLoadedStore()
        defer { Task { await discard(store) } }
        let resolver = MASAdoptCaskResolver.store(store)
        // Both diffviewer records validate "Diff Viewer.app"; the store keeps
        // the displayName-equal one (documented tie-break, CaskIndexTests-pinned).
        let viewer = InstalledApp(
            bundleIdentifier: "com.example.diffviewer",
            name: "Diff Viewer",
            path: "/Applications/Diff Viewer.app",
            shortVersion: "2.0",
            isMacAppStore: true)
        guard case .unique(let match) = await resolver.resolve(viewer) else {
            Issue.record("expected a unique match")
            return
        }
        #expect(match.token == "diffviewer-second")
        #expect(match.version == "2.0")
    }

    @Test func gateOverTheAdapterProducesARealCleanAdopt() async throws {
        let store = try await makeLoadedStore()
        defer { Task { await discard(store) } }
        let gate = MASAdoptGate()
        let masChrome = InstalledApp(
            bundleIdentifier: "com.google.Chrome",
            name: "Google Chrome",
            path: "/Applications/Google Chrome.app",
            shortVersion: "156.0.8078.48",
            isMacAppStore: true)
        let decision = await gate.decide(app: masChrome, resolver: .store(store))
        #expect(decision.refusalReason == nil)
        #expect(decision.stagedCommand == "brew install --cask --adopt google-chrome")
        #expect(decision.caskVersion == "156.0.8078.48")
        #expect(decision.installedVersion == "156.0.8078.48")
        #expect(decision.matchBasis == "token 'google-chrome'")
        #expect(decision.warnings.contains { $0.contains("PAID-APP-STORE WARNING") })
    }

    @Test func gateOverTheAdapterRefusesAVersionMismatch() async throws {
        let store = try await makeLoadedStore()
        defer { Task { await discard(store) } }
        let gate = MASAdoptGate()
        let masFirefox = InstalledApp(
            bundleIdentifier: "org.mozilla.firefox",
            name: "Firefox",
            path: "/Applications/Firefox.app",
            shortVersion: "157.0.0",
            isMacAppStore: true)
        let decision = await gate.decide(app: masFirefox, resolver: .store(store))
        #expect(decision.refusalCode == MASAdoptGate.codeVersionMismatch)
        #expect(decision.stagedCommand == nil)
        #expect(decision.caskToken == "firefox")
    }
}
