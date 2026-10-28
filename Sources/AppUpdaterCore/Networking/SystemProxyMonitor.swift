// SystemProxyMonitor.swift — live system-proxy detection via SystemConfiguration
// (GAP #20). Gap-closure sprint · lane proxy · exclusive file of this lane.
//
// REQUIREMENTS EVIDENCE (read-only teardown docs): UPDATEST-FINDINGS.md §3.18 —
// "[confirmed] Proxy subsystem: SystemProxyMonitor creates an SCDynamicStore and
// monitors proxy keys ('[NETWORK] Failed to create SCDynamicStore for proxy
// monitoring', 'Failed to create run loop source…', 'Failed to set proxy
// notification keys'); system proxy display ('Proxy detected: ', 'No system
// proxy detected')" + §8 "SCDynamicStore proxy monitor … imported symbols
// [confirmed]; exact handlers inferred". GAP-ANALYSIS.md #20.
//
// The documented failure strings are mirrored verbatim (minus Updatest's
// "[NETWORK]" log namespace, which is theirs — ours is the Logger category
// "proxy") for the two store-level failures; the third documented string
// ("Failed to create run loop source…") belongs to Updatest's run-loop
// delivery — OUR delivery is queue-based (see the seam-decision note), so its
// activation failure is logged with an honest queue-specific wording instead
// of claiming their run-loop string. The handler bodies behind them were
// never documented, so the plumbing is the standard SystemConfiguration
// recipe — OUR implementation, honestly noted, not a recovered decompile.
//
// CHANGE-NOTIFICATION SEAM DECISION (lane brief asked us to say this here and
// in the report): the SCDynamicStore surface CAN be seam-stubbed cleanly, so
// the committed monitor is EVENT-DRIVEN (SCDynamicStoreSetNotificationKeys +
// SCDynamicStoreSetDispatchQueue) — no poll-on-timer fallback was needed.
// DELIVERY MECHANISM NOTE (coordinator fix 2026-10-28): this SDK's audited
// import of SCDynamicStoreCreateRunLoopSource DROPPED its context parameter
// (the 4-argument C form does not typecheck here — "extra argument in call";
// the 3-argument form does), which made the classic run-loop-source recipe
// unable to carry our callback context. The modern dispatch-queue recipe
// (store created WITH the callback + context, queue attached via
// SCDynamicStoreSetDispatchQueue) probes clean end-to-end and is what ships.
// Every SC entry point the monitor touches (store creation, proxy-dictionary
// read, key registration, queue attach, teardown) lives behind the
// ``SCProxyStore`` closure seam; tests stub the seam with plain dictionaries
// and fire the captured change callback directly (zero real system state —
// the repo's hermetic discipline, FileSystemMonitor-style).
//
// MECHANICS (documented SystemConfiguration surfaces, not Updatest inventions):
// - The proxy dictionary is read from the SC dynamic-store key
//   "State:/Network/Global/IPv4" (the standard global-network state path) and
//   its "Proxies" sub-dictionary, whose keys are the CFNetwork constants
//   kCFNetworkProxies{HTTP,HTTPS,SOCKS}{Enable,Proxy,Port}, the
//   kCFNetworkProxiesExceptionsList array, and the PAC pair
//   kCFNetworkProxiesProxyAutoConfigEnable / kCFNetworkProxiesProxyAutoConfigURLString.
// - Change notifications watch those same keys (plus the store pattern for the
//   global state path, because macOS also rewrites the whole dict on network
//   transitions — watching only leaf keys would miss IP-flap rewrites).
// - A notification that re-reads to the SAME snapshot does not fire the change
//   callback (OUR decision: the pattern above legitimately fires on unrelated
//   network churn; dedupe-by-equality keeps the callback honest — "changed"
//   means the parsed proxy picture changed).
//
// READ-ONLY POSTURE (lane brief): the monitor only READS system state; it
// never opens a connection, never fetches, never sends traffic. It produces
// ``SystemProxySnapshot`` values the coordinator applies elsewhere.
//
// PAC SCOPING (honest): a detected PAC URL is carried on the snapshot
// (``SystemProxySnapshot/pacURL``) and into ProxySettings.pacURL. PAC
// evaluation is NOT implemented (would need a JS engine + resolver-side
// network probes; see ProxyConfiguration.pacLimitationNote). In .system mode
// URLSession's own system-PAC handling covers it natively.

import Foundation
import os
import SystemConfiguration

// MARK: - Raw seam value (Sendable stand-in for CF values)

/// One raw value from the SC proxy dictionary, flattened into a Sendable
/// shape so the pure parser below (and the tests) never touch CF types.
/// CFBoolean/CFNumber collapse into `.number` (the SC dict encodes enable
/// flags and ports as numbers); anything else unrecognized is `.unsupported`
/// so the parser can log an honest note instead of crashing or guessing.
public enum SCProxyValue: Sendable, Hashable {
    case number(Int)
    case string(String)
    case array([String])
    case unsupported

    /// Flattens a bridged SC proxy dictionary (Any values from CF) into the
    /// Sendable shape. Order of type probes: String (hosts, PAC URL, scheme
    /// names) → Bool (CFBoolean enable flags) → NSNumber (ports, numeric
    /// enables) → arrays of strings (exceptions); anything else becomes
    /// `.unsupported` so the parser can note it honestly. Array elements that
    /// are not strings are dropped silently INSIDE the array (the exceptions
    /// list is string-typed; a stray element is noise, not a config error —
    /// a wholly-wrong-typed list still lands as `.array([])` and reads
    /// honestly as "no exclusions").
    static func flatten(_ raw: [String: Any]) -> [String: SCProxyValue] {
        var out: [String: SCProxyValue] = [:]
        for (key, value) in raw {
            if let string = value as? String {
                out[key] = .string(string)
            } else if let bool = value as? Bool {
                out[key] = .number(bool ? 1 : 0)
            } else if let number = value as? NSNumber {
                out[key] = .number(number.intValue)
            } else if let array = value as? [Any] {
                var items: [String] = []
                for element in array {
                    if let string = element as? String { items.append(string) }
                }
                out[key] = .array(items)
            } else {
                out[key] = .unsupported
            }
        }
        return out
    }
}

// MARK: - Parsed snapshot

/// One enabled protocol's system proxy entry. Host/port stay OPTIONAL so a
/// malformed system config is represented honestly (nil fields + a note)
/// instead of dropping the entry silently.
public struct SystemProxyEntry: Sendable, Hashable, Codable {
    /// nil when the system config names no usable host for this protocol.
    public var host: String?
    /// nil when the system config names no usable port (or it is out of range).
    public var port: Int?

    public init(host: String?, port: Int?) {
        self.host = host
        self.port = port
    }

    /// true when both halves are present and the port is in 1...65535 —
    /// only a valid entry counts toward "Proxy detected".
    public var isValid: Bool {
        guard let host, let port else { return false }
        return !host.isEmpty && (1...65_535).contains(port)
    }
}

/// The parsed proxy picture of the system at one moment. Codable so the
/// coordinator can hand it to settings/UI surfaces without inventing a
/// second type.
public struct SystemProxySnapshot: Sendable, Hashable, Codable {
    /// Manual-style HTTP entry the system currently reports (nil = off).
    public var http: SystemProxyEntry?
    /// Manual-style HTTPS entry the system currently reports (nil = off).
    public var https: SystemProxyEntry?
    /// Manual-style SOCKS5 entry the system currently reports (nil = off).
    public var socks5: SystemProxyEntry?
    /// Hosts that bypass the system proxy (kCFNetworkProxiesExceptionsList).
    public var exclusions: [String]
    /// The system's PAC file URL when one is enabled (nil otherwise).
    public var pacURL: String?
    /// Honest notes for every malformed/unexpected thing found while parsing
    /// (enable-without-host, non-numeric port, wrong-typed values, …). Empty
    /// = the system config parsed cleanly. These are the "honest unknown
    /// notes" the lane brief requires — never swallowed, never invented.
    public var notes: [String]

    public init(
        http: SystemProxyEntry? = nil,
        https: SystemProxyEntry? = nil,
        socks5: SystemProxyEntry? = nil,
        exclusions: [String] = [],
        pacURL: String? = nil,
        notes: [String] = []
    ) {
        self.http = http
        self.https = https
        self.socks5 = socks5
        self.exclusions = exclusions
        self.pacURL = pacURL
        self.notes = notes
    }

    /// Any valid entry or an enabled PAC counts as "detected" (documented
    /// display mechanic: "Proxy detected: " / "No system proxy detected").
    public var hasAnyProxy: Bool {
        if http?.isValid == true || https?.isValid == true || socks5?.isValid == true { return true }
        return pacURL != nil
    }

    /// The documented display phrasing, verbatim prefix + a factual suffix
    /// (the suffix content is OURS — the teardown shows only the prefix).
    public var detectedDescription: String {
        guard hasAnyProxy else { return "No system proxy detected" }
        var parts: [String] = []
        if let http, let host = http.host, let port = http.port {
            parts.append("http \(host):\(port)")
        }
        if let https, let host = https.host, let port = https.port {
            parts.append("https \(host):\(port)")
        }
        if let socks5, let host = socks5.host, let port = socks5.port {
            parts.append("socks5 \(host):\(port)")
        }
        if let pacURL { parts.append("PAC \(pacURL)") }
        return "Proxy detected: " + parts.joined(separator: ", ")
    }
}

// MARK: - Pure parser (the tested core)

/// Dictionary-key → snapshot parsing. Every key spelling appears exactly once,
/// here (the dictionary builders in ProxyConfiguration.swift spell their OWN
/// set — same constants, separate concern: reading vs writing).
public enum SystemProxyParser {

    /// String forms of the documented CFNetwork proxy dictionary keys —
    /// bridged ONCE here (the constants import as CFString on this SDK) and
    /// consumed by the parser, the dictionary builder, the notification
    /// registration, and the tests. Single source of truth for every spelling.
    public enum Keys {
        public static let httpEnable = kCFNetworkProxiesHTTPEnable as String
        public static let httpHost = kCFNetworkProxiesHTTPProxy as String
        public static let httpPort = kCFNetworkProxiesHTTPPort as String
        public static let httpsEnable = kCFNetworkProxiesHTTPSEnable as String
        public static let httpsHost = kCFNetworkProxiesHTTPSProxy as String
        public static let httpsPort = kCFNetworkProxiesHTTPSPort as String
        public static let socksEnable = kCFNetworkProxiesSOCKSEnable as String
        public static let socksHost = kCFNetworkProxiesSOCKSProxy as String
        public static let socksPort = kCFNetworkProxiesSOCKSPort as String
        public static let exceptions = kCFNetworkProxiesExceptionsList as String
        public static let pacEnable = kCFNetworkProxiesProxyAutoConfigEnable as String
        public static let pacURL = kCFNetworkProxiesProxyAutoConfigURLString as String
    }

    /// The SC proxy dictionary keys consumed by the parser (documented
    /// CFNetwork constants; also the exact key set registered for change
    /// notifications).
    public static let watchedKeys: [String] = [
        Keys.httpEnable, Keys.httpHost, Keys.httpPort,
        Keys.httpsEnable, Keys.httpsHost, Keys.httpsPort,
        Keys.socksEnable, Keys.socksHost, Keys.socksPort,
        Keys.exceptions, Keys.pacEnable, Keys.pacURL,
    ]

    /// The SC dynamic-store key whose "Proxies" sub-dictionary carries the
    /// proxy settings (standard global-network state path).
    public static let globalIPv4StoreKey = "State:/Network/Global/IPv4"
    /// The sub-dictionary name inside the global state dict.
    public static let proxiesSubKey = "Proxies"

    /// Parses a flattened SC proxy dictionary into a snapshot. Rules:
    /// - An entry is attempted only when its Enable key is a non-zero number.
    /// - Enable with no usable host → nil-host entry + note (honest unknown).
    /// - Port must be a number in 1...65535 → else nil port + note.
    /// - Exceptions must be an array (of strings); anything else → note.
    /// - PAC: Enable non-zero + URL string → pacURL; Enable without URL →
    ///   note; URL without Enable (PAC off) → ignored + note (honest: the
    ///   system says PAC is disabled).
    /// - `.unsupported` values for watched keys → note (never a guess).
    public static func parse(_ dict: [String: SCProxyValue]) -> SystemProxySnapshot {
        var snapshot = SystemProxySnapshot()
        var notes: [String] = []

        func enabled(_ key: String) -> Bool? {
            guard let value = dict[key] else { return nil }
            switch value {
            case .number(let n): return n != 0
            default:
                notes.append("unexpected non-numeric value for \(key)")
                return nil
            }
        }

        func entry(enableKey: String, hostKey: String, portKey: String, name: String)
            -> SystemProxyEntry? {
            guard enabled(enableKey) == true else { return nil }
            var host: String?
            var port: Int?
            switch dict[hostKey] {
            case .string(let s) where !s.isEmpty: host = s
            case .string: notes.append("\(name) proxy enabled but \(hostKey) is empty")
            case .none: notes.append("\(name) proxy enabled but \(hostKey) is missing")
            default: notes.append("unexpected value type for \(hostKey)")
            }
            switch dict[portKey] {
            case .number(let n) where (1...65_535).contains(n): port = n
            case .number(let n):
                notes.append("\(name) proxy port \(n) outside 1...65535")
            case .none:
                notes.append("\(name) proxy enabled but \(portKey) is missing")
            default:
                notes.append("unexpected value type for \(portKey)")
            }
            return SystemProxyEntry(host: host, port: port)
        }

        snapshot.http = entry(
            enableKey: Keys.httpEnable, hostKey: Keys.httpHost, portKey: Keys.httpPort,
            name: "http")
        snapshot.https = entry(
            enableKey: Keys.httpsEnable, hostKey: Keys.httpsHost, portKey: Keys.httpsPort,
            name: "https")
        snapshot.socks5 = entry(
            enableKey: Keys.socksEnable, hostKey: Keys.socksHost, portKey: Keys.socksPort,
            name: "socks")

        switch dict[Keys.exceptions] {
        case .array(let items): snapshot.exclusions = items
        case .none: break
        default: notes.append("unexpected value type for \(Keys.exceptions)")
        }

        let pacEnabled = enabled(Keys.pacEnable) == true
        let pacURL: String?
        switch dict[Keys.pacURL] {
        case .string(let s): pacURL = s
        case .none: pacURL = nil
        default:
            notes.append("unexpected value type for \(Keys.pacURL)")
            pacURL = nil
        }
        if pacEnabled {
            if let pacURL, !pacURL.isEmpty {
                snapshot.pacURL = pacURL
            } else {
                notes.append("PAC enabled but no usable PAC URL configured")
            }
        } else if pacURL != nil {
            notes.append("PAC URL present but PAC is disabled — ignored")
        }

        snapshot.notes = notes
        return snapshot
    }
}

// MARK: - The SC seam

/// A live SCDynamicStore handle abstracted into Sendable closures so tests can
/// stub the whole surface (hermetic: zero real system state). Failure points
/// map 1:1 onto the three documented error strings:
/// - `SCProxyStore.live()` returning nil → "Failed to create SCDynamicStore for proxy monitoring"
/// - `setNotificationKeys` returning false → "Failed to set proxy notification keys"
/// - `activateCallback` returning nil → "Failed to create run loop source"
public struct SCProxyStore: Sendable {
    /// Reads the CURRENT flattened proxy dictionary (Proxies sub-dict of the
    /// global IPv4 state). An unreachable store yields an empty dictionary
    /// (parse → empty snapshot — honest "nothing detected", never a crash).
    public let readDictionary: @Sendable () -> [String: SCProxyValue]
    /// Registers the proxy keys + global-state pattern for change
    /// notifications. false = the documented key-registration failure.
    public let setNotificationKeys: @Sendable () -> Bool
    /// Activates change delivery: installs `callback` so it runs whenever the
    /// watched keys change. nil = the documented run-loop-source failure. The
    /// returned handle tears the delivery down (idempotent, safe once).
    public let activateCallback:
        @Sendable (@escaping @Sendable () -> Void) -> ProxyNotificationHandle?
    /// Tears the store down (stop notifications, release the store). Idempotent.
    public let invalidate: @Sendable () -> Void

    public init(
        readDictionary: @escaping @Sendable () -> [String: SCProxyValue],
        setNotificationKeys: @escaping @Sendable () -> Bool,
        activateCallback: @escaping @Sendable (
            @escaping @Sendable () -> Void
        ) -> ProxyNotificationHandle?,
        invalidate: @escaping @Sendable () -> Void
    ) {
        self.readDictionary = readDictionary
        self.setNotificationKeys = setNotificationKeys
        self.activateCallback = activateCallback
        self.invalidate = invalidate
    }

    /// A refused store (creation failed): honest nil-returning factory result
    /// — the monitor's documented "Failed to create SCDynamicStore" branch.
    public static func refused() -> SCProxyStore {
        SCProxyStore(
            readDictionary: { [:] },
            setNotificationKeys: { false },
            activateCallback: { _ in nil },
            invalidate: {})
    }

    /// The real SystemConfiguration binding. nil = store creation failed
    /// (documented failure #1). Everything the closures capture is boxed in
    /// `@unchecked Sendable` holders with the same documented judgment as
    /// FileSystemMonitor's CallbackBox: immutable CF/C values, each consumed
    /// exactly once by the one teardown path.
    public static func live() -> SCProxyStore? {
        // The store is created WITH the change callback + context (the retained
        // LiveStoreBox token): this SDK's import of SCDynamicStoreCreateRunLoop-
        // Source dropped its context parameter, so the run-loop recipe cannot
        // carry a callback — the dispatch-queue recipe below is the carrier.
        let box = LiveStoreBox()
        var context = SCDynamicStoreContext(
            version: 0, info: box.contextToken, retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(
            nil, "io.appupdater.proxy-monitor" as CFString, liveStoreChanged, &context)
        else {
            box.releaseToken() // never handed to SC — release the retained token
            return nil
        }
        box.adoptStore(store)
        return SCProxyStore(
            readDictionary: { [box] in box.readProxyDictionary() },
            setNotificationKeys: { [box] in box.setNotificationKeys() },
            activateCallback: { [box] callback in
                box.activateDelivery(callback: callback)
            },
            invalidate: { [box] in box.invalidate() }
        )
    }
}

/// The C entry point for SC change notifications: routes to the boxed store
/// (the context pointer IS the retained LiveStoreBox). Guarded against the
/// released state by the box itself.
private func liveStoreChanged(
    store: SCDynamicStore, changedKeys: CFArray?, info: UnsafeMutableRawPointer?
) {
    guard let info else { return }
    Unmanaged<LiveStoreContext>.fromOpaque(info).takeUnretainedValue().box?.deliverChange()
}

/// A live change-delivery handle (run loop source + its dedicated run loop
/// thread). `invalidate` is safe exactly once (the monitor consumes its handle
/// during teardown and never keeps a second copy).
public struct ProxyNotificationHandle: Sendable {
    public let invalidate: @Sendable () -> Void

    public init(invalidate: @escaping @Sendable () -> Void) {
        self.invalidate = invalidate
    }
}

// MARK: - Real SystemConfiguration binding internals

/// The SC callback-context carrier: a tiny object whose ONLY job is to be
/// retained by SC and route callbacks to the box. It exists because the box
/// cannot hand `self` to SC before its own stored properties are initialized
/// (Swift init-order rule) — the context is created and retained FIRST, and
/// the (by-then-complete) box is attached to it as the final init step.
private final class LiveStoreContext: @unchecked Sendable {
    var box: LiveStoreBox?
    init() {}
}

/// Boxes the live SCDynamicStore + its change delivery so @Sendable closures
/// and the C context pointer may carry it (CF types have no Sendable
/// conformance on this toolchain — FileSystemMonitor's documented CallbackBox
/// judgment applies unchanged). Lifetime: the context is retained at init and
/// released exactly once by `invalidate` (or when store creation fails before
/// the context is ever handed to SC); the closures also capture the box, so
/// the box outlives both the seam and the SC context.
private final class LiveStoreBox: @unchecked Sendable {
    /// Set by `adoptStore` right after successful store creation. Immutable
    /// afterwards; only the C callback (which fires after adoption) reads it.
    private(set) var store: SCDynamicStore?
    /// The retained context handed to SC as the callback-info pointer.
    let contextToken: UnsafeMutableRawPointer
    private let context: LiveStoreContext

    private let lock: NSLock
    private var storeAdopted: Bool
    private var changeCallback: (@Sendable () -> Void)?
    private var queue: DispatchQueue?
    private var tokenReleased: Bool

    init() {
        store = nil
        storeAdopted = false
        changeCallback = nil
        queue = nil
        tokenReleased = false
        lock = NSLock()
        context = LiveStoreContext()
        contextToken = Unmanaged.passRetained(context).toOpaque()
        // self is fully initialized here — safe to hand to the context.
        context.box = self
    }

    /// Hands the created store to the box (the closures' store access runs
    /// after this; the C callback can only fire after the queue attaches).
    func adoptStore(_ store: SCDynamicStore) {
        lock.lock()
        defer { lock.unlock() }
        self.store = store
        storeAdopted = true
    }

    /// Releases the retained context when store creation failed before the
    /// context was ever handed to SC (one-shot; never called after adopt).
    func releaseToken() {
        lock.lock()
        defer { lock.unlock() }
        guard !storeAdopted, !tokenReleased else { return }
        tokenReleased = true
        Unmanaged<LiveStoreContext>.fromOpaque(contextToken).release()
    }

    /// Flattens State:/Network/Global/IPv4 → "Proxies" into SCProxyValues.
    func readProxyDictionary() -> [String: SCProxyValue] {
        lock.lock()
        let store = self.store
        lock.unlock()
        guard let store,
              let global = SCDynamicStoreCopyValue(
                store, SystemProxyParser.globalIPv4StoreKey as CFString)
                  as? [String: Any],
              let proxies = global[SystemProxyParser.proxiesSubKey] as? [String: Any]
        else { return [:] }
        return SCProxyValue.flatten(proxies)
    }

    /// Registers the watched keys + the global-state pattern (false = the
    /// documented key-registration failure). Requires an adopted store.
    func setNotificationKeys() -> Bool {
        lock.lock()
        let store = self.store
        lock.unlock()
        guard let store else { return false }
        return SCDynamicStoreSetNotificationKeys(
            store,
            SystemProxyParser.watchedKeys as CFArray,
            [SystemProxyParser.globalIPv4StoreKey] as CFArray)
    }

    /// Activates change delivery: arms the callback and attaches a dedicated
    /// serial queue via SCDynamicStoreSetDispatchQueue (false = the activation
    /// failure slot — OUR queue-attach wording, see the header note). One-shot
    /// per store: a second activation returns nil (the monitor activates once).
    func activateDelivery(callback: @escaping @Sendable () -> Void)
        -> ProxyNotificationHandle? {
        lock.lock()
        defer { lock.unlock() }
        guard storeAdopted, changeCallback == nil, queue == nil, !tokenReleased
        else { return nil }
        changeCallback = callback
        guard let store else { return nil } // unreachable after adoptStore, honest guard
        let queue = DispatchQueue(label: "io.appupdater.proxy-monitor.delivery")
        guard SCDynamicStoreSetDispatchQueue(store, queue) else {
            changeCallback = nil
            return nil
        }
        self.queue = queue
        return ProxyNotificationHandle(invalidate: { [weak self] in
            self?.invalidate()
        })
    }

    /// The C-callback entry point: forward to the armed callback (late
    /// deliveries after teardown are dropped by the nil'ed callback).
    func deliverChange() {
        lock.lock()
        let callback = changeCallback
        lock.unlock()
        callback?()
    }

    /// One-shot teardown: detach the queue (no further SC deliveries), clear
    /// the callback, release the retained token. Safe to call repeatedly.
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        if let queue, let store {
            SCDynamicStoreSetDispatchQueue(store, nil)
            self.queue = nil
        }
        changeCallback = nil
        if !tokenReleased {
            tokenReleased = true
            Unmanaged<LiveStoreContext>.fromOpaque(contextToken).release()
        }
    }
}

// MARK: - The monitor

/// Live system-proxy monitor (SCDynamicStore-backed; see file header for the
/// documented mechanics, the seam decision, and the read-only posture).
///
/// Public surface:
/// - `start(onChange:)` — creates the store through the seam, reads the
///   initial snapshot, registers the documented key set, activates change
///   delivery. Any documented failure logs its verbatim string, leaves
///   `isRunning` false, and RETIRES the instance (fresh monitor for a retry).
/// - `currentSnapshot()` — lock-backed copy of the last parsed picture.
/// - `stop()` — full teardown; idempotent.
///
/// The change callback runs on the SC delivery thread (real) or the test
/// thread (stub) — documented, never dispatched further by this lane.
public final class SystemProxyMonitor: @unchecked Sendable {

    /// The SC seam. `live` in production; stubs in tests.
    public let makeStore: @Sendable () -> SCProxyStore?

    /// Lock-backed honest state (FileSystemMonitor's LifecycleState pattern,
    /// trimmed to what this monitor needs). Never held across a suspension
    /// point; all fields guarded.
    private let state = MonitorState()
    private let lock = NSLock()
    private var snapshotStore: SystemProxySnapshot
    private var notificationHandle: ProxyNotificationHandle?
    private var storeSeam: SCProxyStore?
    private var tearingDown = false

    public var isRunning: Bool { state.isRunning() }

    /// Full-injection init (tests / hermetic environments); production default
    /// written inline per the Swift 6.4 public-init gotcha.
    public init(makeStore: @escaping @Sendable () -> SCProxyStore? = { SCProxyStore.live() }) {
        self.makeStore = makeStore
        self.snapshotStore = SystemProxySnapshot()
    }

    // MARK: Start / stop

    /// Starts monitoring and reports the INITIAL parsed snapshot through
    /// `onChange` as well (callers learn the current picture without polling;
    /// documented as OUR composition choice — Updatest's exact first-delivery
    /// behavior was never documented). A second start while running is a
    /// documented no-op. Retires the instance on any seam failure.
    public func start(onChange: @escaping @Sendable (SystemProxySnapshot) -> Void) {
        guard state.claimStart() else { return }

        guard let seam = makeStore() else {
            ProxyLog.log.error("Failed to create SCDynamicStore for proxy monitoring")
            state.retire()
            return
        }
        storeSeam = seam

        // Initial read BEFORE activation so the first callback always has a
        // baseline to diff against.
        let initial = SystemProxyParser.parse(seam.readDictionary())
        lock.lock()
        snapshotStore = initial
        lock.unlock()
        onChange(initial)

        // Arm the change pipeline BEFORE activation: the SC thread can fire a
        // change the instant the source is scheduled, so intake must already
        // be open (the initial delivery above used the direct parameter).
        state.armChangeCallback(onChange)

        guard seam.setNotificationKeys() else {
            ProxyLog.log.error("Failed to set proxy notification keys")
            seam.invalidate()
            storeSeam = nil
            state.retire()
            return
        }

        guard let handle = seam.activateCallback({ [weak self] in
            self?.handleChangeNotification()
        }) else {
            ProxyLog.log.error(
                "Failed to attach the proxy change delivery queue (SCDynamicStoreSetDispatchQueue)")
            seam.invalidate()
            storeSeam = nil
            state.retire()
            return
        }

        lock.lock()
        notificationHandle = handle
        lock.unlock()
        state.commitRunning()
    }

    /// Full teardown: the SC delivery stops first (late callbacks dropped),
    /// the store is invalidated, running goes false. Idempotent.
    public func stop() {
        lock.lock()
        if tearingDown {
            lock.unlock()
            return
        }
        tearingDown = true
        let handle = notificationHandle
        notificationHandle = nil
        let seam = storeSeam
        storeSeam = nil
        lock.unlock()

        handle?.invalidate()
        seam?.invalidate()
        state.stop()
    }

    /// The last parsed snapshot (initial read, or the latest change). Empty
    /// snapshot before a successful start.
    public func currentSnapshot() -> SystemProxySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotStore
    }

    // MARK: Change delivery

    /// The seam-level change entry point: re-read, parse, dedupe by equality,
    /// store, and fire the user callback ON THE DELIVERY THREAD (documented).
    /// Delivery after `stop()` is dropped (intake closed — never crash).
    private func handleChangeNotification() {
        lock.lock()
        let seam = storeSeam
        lock.unlock()
        guard let seam, state.intakeIsOpen() else { return }

        let parsed = SystemProxyParser.parse(seam.readDictionary())
        lock.lock()
        let previous = snapshotStore
        let changed = previous != parsed
        if changed { snapshotStore = parsed }
        lock.unlock()
        guard changed else { return } // unrelated network churn: honest no-op
        state.fireChange(parsed)
    }
}

// MARK: - Locked state + logging

/// Locked lifecycle slide (trimmed LifecycleState): claim → commit/retire
/// start handshake, running/intake flags, and the change-callback slot.
private final class MonitorState: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var running = false
    private var intakeOpen = false
    private var retired = false
    private var onChange: (@Sendable (SystemProxySnapshot) -> Void)?

    func isRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func intakeIsOpen() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return intakeOpen
    }

    /// Claims the start slot; a second start (or a retired instance) refuses.
    func claimStart() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !started, !retired else { return false }
        started = true
        return true
    }

    /// Stores the change callback + opens intake once the start is real.
    func armChangeCallback(_ onChange: @escaping @Sendable (SystemProxySnapshot) -> Void) {
        lock.lock()
        self.onChange = onChange
        intakeOpen = true
        lock.unlock()
    }

    /// Invokes the change callback OUTSIDE the lock (user code must never run
    /// under our mutex; re-entrancy safety is documented on start()).
    func fireChange(_ snapshot: SystemProxySnapshot) {
        lock.lock()
        let callback = onChange
        lock.unlock()
        callback?(snapshot)
    }

    func commitRunning() {
        lock.lock()
        running = true
        lock.unlock()
    }

    /// A seam failure: the instance retires (isRunning never became true; a
    /// fresh monitor is required for a retry — FileSystemMonitor semantics).
    func retire() {
        lock.lock()
        retired = true
        lock.unlock()
    }

    func stop() {
        lock.lock()
        running = false
        intakeOpen = false
        lock.unlock()
    }
}

/// Logger surface (documented strings mirror the teardown verbatim minus
/// Updatest's "[NETWORK]" namespace — see file header).
enum ProxyLog {
    static let log = Logger(subsystem: "io.appupdater.AppUpdater", category: "proxy")
}
