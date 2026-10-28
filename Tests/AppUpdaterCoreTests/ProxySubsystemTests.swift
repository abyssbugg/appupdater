// ProxySubsystemTests — coordinator (proxy lane finish): the dead agent left the
// three Networking/ modules WITHOUT tests; this file is the full hermetic suite.
// Swift Testing only (XCTest discovery broken here). Zero network, zero real
// system state: the SC store seam is stubbed with plain dictionaries, the
// keychain with an in-memory fake, the settings store with per-PROCESS unique
// temp directories (the Phase-4 fixture-collision rule).

import Foundation
import Testing
import SystemConfiguration
@testable import AppUpdaterCore

// MARK: - Shared fake keychain (in-memory; the real Security-backed store is
// compile-covered by the lane and exercised by live smoke, never hermetically)

private final class FakeKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    private var failNextSave = false

    func armSaveFailure() { lock.lock(); failNextSave = true; lock.unlock() }

    private func key(_ service: String, _ account: String) -> String { "\(service)|\(account)" }

    func savePassword(service: String, account: String, password: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failNextSave {
            throw ProxyKeychainError(operation: "save", status: -25299 /* errSecDuplicateItem-ish */)
        }
        items[key(service, account)] = password
    }

    func loadPassword(service: String, account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return items[key(service, account)]
    }

    func deletePassword(service: String, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items.removeValue(forKey: key(service, account))
    }
}

// MARK: - ProxySettings + store

@Suite(.serialized)
struct ProxySettingsTests {

    /// Per-PROCESS unique store directory (the Phase-4 collision rule).
    private static let root: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("appupdater-proxy-tests-\(UUID().uuidString)", isDirectory: true)

    private func makeStore() -> ProxySettingsStore {
        ProxySettingsStore(directory: Self.root.appendingPathComponent(UUID().uuidString))
    }

    @Test func missingFileLoadsDefaults() async throws {
        let store = makeStore()
        let loaded = try await store.load()
        #expect(loaded == ProxySettings())          // system mode, no entries
        #expect(loaded.mode == .system)
    }

    @Test func saveThenLoadRoundTrips() async throws {
        let store = makeStore()
        var settings = ProxySettings(mode: .manual)
        settings.https = ProxyProtocolEntry(host: "proxy.corp", port: 8443, authRequired: true)
        settings.socks5 = ProxyProtocolEntry(host: "socks.corp", port: 1080)
        try await store.save(settings)
        let loaded = try await store.load()
        #expect(loaded == settings)
        #expect(loaded.https?.authRequired == true)
    }

    @Test func unparseableFileLoadsDefaultsHonesty() async throws {
        let store = makeStore()
        let dir = store.directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json at all {{{".utf8).write(to: dir.appendingPathComponent("proxy_settings.json"))
        let loaded = try await store.load()
        #expect(loaded == ProxySettings())          // defaults, never a crash
        // The next save honestly replaces the garbage file (round-trip works).
        try await store.save(ProxySettings(mode: .none))
        #expect(try await store.load().mode == .none)
    }

    @Test func legacyJSONWithMissingKeysDecodesToDefaults() async throws {
        // Old/hand-edited payloads missing keys decode honestly (decodeIfPresent).
        let store = makeStore()
        let dir = store.directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let legacy = Data(#"{"mode":"none"}"#.utf8)
        try legacy.write(to: dir.appendingPathComponent("proxy_settings.json"))
        let loaded = try await store.load()
        #expect(loaded.mode == .none)
        #expect(loaded.http == nil && loaded.https == nil && loaded.socks5 == nil)
        #expect(loaded.pacURL == nil)
    }

    @Test func validationMatrix() {
        // Manual with no entries → the documented invalid case.
        #expect(ProxySettings(mode: .manual).isValid == false)
        #expect(ProxySettings(mode: .manual).validationFailureReason()?
            .hasPrefix("Invalid proxy configuration") == true)
        // Empty host / out-of-range port → invalid with specific reasons.
        var bad = ProxySettings(mode: .manual)
        bad.http = ProxyProtocolEntry(host: "   ", port: 8080)
        #expect(bad.isValid == false)
        var badPort = ProxySettings(mode: .manual)
        badPort.https = ProxyProtocolEntry(host: "p", port: 0)
        #expect(badPort.isValid == false)
        // Valid manual passes; entries under system/none are not an error.
        var good = ProxySettings(mode: .manual)
        good.http = ProxyProtocolEntry(host: "proxy.corp", port: 8080)
        #expect(good.isValid)
        var stray = ProxySettings(mode: .system)
        stray.http = ProxyProtocolEntry(host: "ignored", port: 1)
        #expect(stray.isValid)
    }
}

// MARK: - ProxyConfiguration (dictionary bridge + env passthrough + keychain)

@Suite(.serialized)
struct ProxyConfigurationTests {

    @Test func systemModeYieldsNilDictionary() throws {
        let dict = try ProxyConfiguration.connectionProxyDictionary(for: ProxySettings())
        #expect(dict == nil)    // URLSession's own system handling (incl. PAC)
    }

    @Test func noneModeYieldsEmptyDictionary() throws {
        let dict = try ProxyConfiguration.connectionProxyDictionary(
            for: ProxySettings(mode: .none))
        #expect(dict != nil)
        #expect(dict?.isEmpty == true)
    }

    @Test func manualModeEmitsExactlyTheNineDocumentedKeys() throws {
        var settings = ProxySettings(mode: .manual)
        settings.http = ProxyProtocolEntry(host: "h.example", port: 8080)
        settings.socks5 = ProxyProtocolEntry(host: "s.example", port: 1080)
        let dict: [AnyHashable: Any]? = try ProxyConfiguration.connectionProxyDictionary(for: settings)
        let unwrapped = try #require(dict)

        #expect(unwrapped[SystemProxyParser.Keys.httpEnable] as? Int == 1)
        #expect(unwrapped[SystemProxyParser.Keys.httpHost] as? String == "h.example")
        #expect(unwrapped[SystemProxyParser.Keys.httpPort] as? Int == 8080)
        #expect(unwrapped[SystemProxyParser.Keys.socksEnable] as? Int == 1)
        #expect(unwrapped[SystemProxyParser.Keys.socksHost] as? String == "s.example")
        #expect(unwrapped[SystemProxyParser.Keys.socksPort] as? Int == 1080)
        // HTTPS absent → its three keys absent (a protocol's keys appear IFF configured).
        #expect(unwrapped[SystemProxyParser.Keys.httpsEnable] == nil)
        #expect(unwrapped[SystemProxyParser.Keys.httpsHost] == nil)
        #expect(unwrapped[SystemProxyParser.Keys.httpsPort] == nil)
        #expect(unwrapped.count == 6) // 3 keys × 2 configured protocols
    }

    @Test func invalidSettingsThrowNeverHalfDictionary() {
        var settings = ProxySettings(mode: .manual) // no entries → invalid
        #expect(throws: ProxyConfigurationError.self) {
            _ = try ProxyConfiguration.connectionProxyDictionary(for: settings)
        }
    }

    @Test func pacLimitationNoteIsCarriedHonesty() {
        #expect(ProxyConfiguration.pacLimitationNote.contains("not implemented"))
    }

    // MARK: env passthrough

    @Test func envPassthroughDocumentedVariablesParse() {
        let passthrough = ProxyEnvironment.passthrough(environment: [
            "HTTP_PROXY": "http://corp.example:3128",
            "HTTPS_PROXY": "https://secure.example:8443",
            "ALL_PROXY": "socks5://socks.example:1080",
        ])
        #expect(passthrough.http?.host == "corp.example")
        #expect(passthrough.http?.port == 3128)
        #expect(passthrough.https?.host == "secure.example")
        #expect(passthrough.https?.port == 8443)
        #expect(passthrough.socks5?.host == "socks.example")
        #expect(passthrough.socks5?.port == 1080)
        #expect(passthrough.notes.isEmpty)
    }

    @Test func envPassthroughLowercaseSpellingsAndBareEndpoints() {
        let passthrough = ProxyEnvironment.passthrough(environment: [
            "http_proxy": "10.0.0.1:8888",       // bare host:port → variable's scheme
            "https_proxy": "10.0.0.2:8443",
            "all_proxy": "10.0.0.3:1080",
        ])
        #expect(passthrough.http?.host == "10.0.0.1" && passthrough.http?.port == 8888)
        #expect(passthrough.https?.host == "10.0.0.2" && passthrough.https?.port == 8443)
        #expect(passthrough.socks5?.host == "10.0.0.3" && passthrough.socks5?.port == 1080)
    }

    @Test func envPassthroughALLProxyNonSocksIgnoredWithNote() {
        let passthrough = ProxyEnvironment.passthrough(environment: [
            "ALL_PROXY": "http://not-socks.example:8080",
        ])
        #expect(passthrough.socks5 == nil)
        #expect(passthrough.notes.first?.contains("SOCKS only") == true)
    }

    @Test func envPassthroughUserinfoIsRejectedHonesty() {
        // Embedded credentials are REJECTED, never parsed (the repo never
        // round-trips secrets through parsed config): the '@' truncation
        // leaves "user:pass", which is not a valid host:port → honest nil.
        let passthrough = ProxyEnvironment.passthrough(environment: [
            "HTTP_PROXY": "no-port-here",
            "HTTPS_PROXY": "user:pass@host:8443/path",
        ])
        #expect(passthrough.http == nil)
        #expect(passthrough.https == nil)
        #expect(passthrough.notes.count == 2)
        #expect(passthrough.notes.allSatisfy { $0.contains("ignored") })
    }

    // MARK: keychain wrapper (fake store; the real store is compile-covered)

    @Test func keychainRoundTripAndHonestAbsence() throws {
        let keychain = ProxyKeychain(store: FakeKeychain())
        #expect(keychain.hasCredential(for: .https) == false)   // honest absence
        try keychain.saveProxyPassword("s3cret", for: .https)
        #expect(try keychain.loadProxyPassword(for: .https) == "s3cret")
        #expect(keychain.hasCredential(for: .https))
        try keychain.deleteProxyPassword(for: .https)
        #expect(try keychain.loadProxyPassword(for: .https) == nil)
        #expect(keychain.hasCredential(for: .https) == false)
        // Account namespace is per-protocol under the one service.
        #expect(ProxyKeychain.account(for: .https) == "proxy.https")
        #expect(ProxyKeychain.service == "io.appupdater.AppUpdater.proxy")
    }

    @Test func keychainSaveFailureSurfacesDocumentedString() {
        let fake = FakeKeychain()
        let keychain = ProxyKeychain(store: fake)
        fake.armSaveFailure()
        #expect(throws: ProxyKeychainError.self) {
            try keychain.saveProxyPassword("x", for: .http)
        }
    }
}

// MARK: - SystemProxyParser + monitor (stubbed SC seam, zero real system state)

@Suite(.serialized)
struct SystemProxyMonitorTests {

    /// Mutable canned dictionary + a change-firing hook behind the seam.
    private final class StubStore: @unchecked Sendable {
        let lock = NSLock()
        var dict: [String: SCProxyValue] = [:]
        var failSetKeys = false
        var failActivate = false
        private(set) var fired: (@Sendable () -> Void)?
        private(set) var invalidateCount = 0

        func arm(callback: @escaping @Sendable () -> Void) {
            lock.lock(); fired = callback; lock.unlock()
        }

        func recordInvalidate() {
            lock.lock(); invalidateCount += 1; lock.unlock()
        }

        func setDict(_ d: [String: SCProxyValue]) { lock.lock(); dict = d; lock.unlock() }
        func fireChange() { lock.lock(); let f = fired; lock.unlock(); f?() }
    }

    private static func httpDict(host: String, port: Int) -> [String: SCProxyValue] {
        [
            SystemProxyParser.Keys.httpEnable: .number(1),
            SystemProxyParser.Keys.httpHost: .string(host),
            SystemProxyParser.Keys.httpPort: .number(port),
        ]
    }

    private func makeSeam(_ stub: StubStore) -> SCProxyStore {
        SCProxyStore(
            readDictionary: { [stub] in
                stub.lock.lock(); defer { stub.lock.unlock() }
                return stub.dict
            },
            setNotificationKeys: { [stub] in
                stub.lock.lock(); defer { stub.lock.unlock() }
                return !stub.failSetKeys
            },
            activateCallback: { [stub] callback in
                // arm() takes the stub's own lock — the closure must NOT hold
                // it (NSLock is not re-entrant: self-deadlock, sampled live).
                if stub.failActivate { return nil }
                stub.arm(callback: callback)
                return ProxyNotificationHandle(invalidate: { [stub] in
                    stub.recordInvalidate()
                })
            },
            invalidate: {})
    }

    @Test func parserTurnsEnabledKeysIntoEntriesAndHonestNotes() {
        var dict = Self.httpDict(host: "sys.example", port: 7890)
        dict[SystemProxyParser.Keys.httpsEnable] = .number(1)   // enabled, no host/port → honest partial
        dict[SystemProxyParser.Keys.exceptions] = .array(["*.local", "10.0.0.0/8"])
        dict[SystemProxyParser.Keys.pacEnable] = .number(0)
        let snapshot = SystemProxyParser.parse(dict)

        #expect(snapshot.http?.isValid == true)
        #expect(snapshot.http?.host == "sys.example")
        #expect(snapshot.http?.port == 7890)
        #expect(snapshot.https != nil && snapshot.https?.isValid == false) // partial, honest
        #expect(snapshot.socks5 == nil)
        #expect(snapshot.exclusions == ["*.local", "10.0.0.0/8"])
        #expect(snapshot.pacURL == nil)
        #expect(snapshot.hasAnyProxy)
    }

    @Test func parserMalformedValuesBecomeNotesNeverCrashes() {
        var dict = Self.httpDict(host: "h", port: 7890)
        dict[SystemProxyParser.Keys.httpPort] = .unsupported
        dict[SystemProxyParser.Keys.pacEnable] = .number(1)     // PAC on…
        dict[SystemProxyParser.Keys.pacURL] = .number(42)      // …URL wrong type → note
        let snapshot = SystemProxyParser.parse(dict)
        #expect(snapshot.pacURL == nil)
        #expect(snapshot.notes.contains("unexpected value type for \(SystemProxyParser.Keys.pacURL)"))
        #expect(snapshot.notes.contains("unexpected value type for \(SystemProxyParser.Keys.httpPort)"))
    }

    @Test func monitorStartDeliversInitialSnapshotAndChangesWithDedupe() async throws {
        let stub = StubStore()
        stub.setDict(Self.httpDict(host: "sys.example", port: 7890))
        let monitor = SystemProxyMonitor(makeStore: { makeSeam(stub) })

        let sink = LockedBox<[SystemProxySnapshot]>([])
        monitor.start(onChange: { snap in sink.with { $0.append(snap) } })
        #expect(monitor.isRunning)

        // 1) the initial snapshot was delivered without any change firing
        #expect(sink.with { $0.count } == 1)
        #expect(sink.with { $0.first?.http?.port } == 7890)

        // 2) a change that re-reads to the SAME picture is an honest no-op
        stub.fireChange()
        #expect(sink.with { $0.count } == 1)

        // 3) a real change (new host) re-reads, parses, and fires once
        stub.setDict(Self.httpDict(host: "sys2.example", port: 7891))
        stub.fireChange()
        #expect(sink.with { $0.count } == 2)
        let latest = try #require(sink.with { $0.last })
        #expect(latest.http?.host == "sys2.example")

        monitor.stop()
        #expect(monitor.isRunning == false)
    }

    @Test func monitorRetiresHonestlyOnEachDocumentedFailure() {
        // Delivery accounting: the initial read is delivered BEFORE the later
        // seam steps run (documented composition), so failure #1 produces no
        // delivery while #2/#3 produce exactly the initial one. Retired
        // monitors deliver nothing further and read isRunning == false.
        let sink = LockedBox<[SystemProxySnapshot]>([])

        // Failure #1: store creation refused.
        let dead = SystemProxyMonitor(makeStore: { nil })
        dead.start(onChange: { snap in sink.with { $0.append(snap) } })
        #expect(dead.isRunning == false)
        #expect(sink.with { $0.isEmpty })

        // Failure #2: key registration refused (after the initial read).
        let keyFail = StubStore()
        keyFail.failSetKeys = true
        let keyMonitor = SystemProxyMonitor(makeStore: { makeSeam(keyFail) })
        keyMonitor.start(onChange: { snap in sink.with { $0.append(snap) } })
        #expect(keyMonitor.isRunning == false)
        #expect(sink.with { $0.count } == 1)

        // Failure #3: activation refused (OUR queue-attach slot).
        let actFail = StubStore()
        actFail.failActivate = true
        let actMonitor = SystemProxyMonitor(makeStore: { makeSeam(actFail) })
        actMonitor.start(onChange: { snap in sink.with { $0.append(snap) } })
        #expect(actMonitor.isRunning == false)
        #expect(sink.with { $0.count } == 2)
    }

    @Test func monitorStopIsIdempotentAndDropsLateCallbacks() {
        let stub = StubStore()
        stub.setDict(Self.httpDict(host: "sys.example", port: 7890))
        let monitor = SystemProxyMonitor(makeStore: { makeSeam(stub) })
        let sink = LockedBox<[SystemProxySnapshot]>([])
        monitor.start(onChange: { snap in sink.with { $0.append(snap) } })

        monitor.stop()
        monitor.stop()                    // idempotent by contract
        stub.fireChange()                 // late delivery after stop → dropped
        #expect(sink.with { $0.count } == 1) // only the initial snapshot ever fired
    }
}
