// ProxyConfiguration.swift — the pure bridge from ProxySettings to URLSession
// (GAP #20). Gap-closure sprint · lane proxy · exclusive file of this lane.
//
// REQUIREMENTS EVIDENCE (read-only teardown docs): UPDATEST-FINDINGS.md §3.18 —
// "[confirmed] Proxy subsystem: … 'Supports HTTP, HTTPS, SOCKS proxies and PAC
// files.', env-var passthrough (HTTP_PROXY/https_proxy, HTTPS_PROXY, ALL_PROXY
// (SOCKS only)), 'Invalid proxy configuration'" + §3.18 keychain strings
// ("Failed to save/load/delete proxy password from keychain") + §7.4 "Keychain
// … proxy password … Service identifier not recoverable from strings
// [unverified]" (open question #6). GAP-ANALYSIS.md #20.
//
// READ-ONLY POSTURE (lane brief, binding): this file NEVER sends traffic. It
// produces configuration — the connection-proxy dictionary, the keychain
// credential store, the parsed environment passthrough — that the coordinator
// later applies to the app's URLSession(s). No fetch, no probe, no resolution.
//
// DICTIONARY KEYS (the documented nine, exactly):
//   HTTP   kCFNetworkProxiesHTTPEnable / kCFNetworkProxiesHTTPProxy  / kCFNetworkProxiesHTTPPort
//   HTTPS  kCFNetworkProxiesHTTPSEnable / kCFNetworkProxiesHTTPSProxy / kCFNetworkProxiesHTTPSPort
//   SOCKS  kCFNetworkProxiesSOCKSEnable / kCFNetworkProxiesSOCKSProxy / kCFNetworkProxiesSOCKSPort
// PAC keys are deliberately NOT emitted here: this lane does not evaluate PAC
// (see ``ProxyConfiguration/pacLimitationNote``). In .system mode the honest
// answer is NO dictionary at all — a nil connectionProxyDictionary leaves
// URLSession on its own system resolution path, which includes system PAC
// handling natively.
//
// MODE → DICTIONARY SEMANTICS (documented URLSessionConfiguration behavior):
//   .system → nil  — no override; system settings (incl. system PAC) apply.
//   .none   → {}   — an explicit override with no enable keys: no proxy is
//                    configured for the session (each protocol is proxied only
//                    when its Enable key is present and truthy, so an empty
//                    dictionary IS the no-proxy dictionary).
//   .manual → the nine keys from the per-protocol entries; invalid settings
//             THROW with the documented "Invalid proxy configuration" text —
//             never a half dictionary.
//
// KEYCHAIN (documented mechanism; OUR service name): Updatest stores the proxy
// password in the Keychain with a service name the teardown could not recover
// (§7.4, open question #6) — ours is chosen and documented on
// ``ProxyKeychain/service``, never presented as theirs. Generic password items
// (kSecClassGenericPassword), one per protocol, account "proxy.<protocol>".
// The accessibility class is OUR choice (kSecAttrAccessibleAfterFirstUnlock:
// an updater must be able to check while the Mac is logged in but locked —
// Updatest's class is not recoverable from the teardown). Credentials are
// NEVER written into proxy_settings.json (ProxySettings.swift header).
//
// PAC SCOPING (honest, per lane brief): system PAC URLs are DETECTED
// (SystemProxyParser reads kCFNetworkProxiesProxyAutoConfig*) and CARRIED
// (ProxySettings.pacURL). FULL evaluation needs a JS engine AND
// resolver-network probes (myIpAddress et al.) — not implemented here, stated
// in ``ProxyConfiguration/pacLimitationNote`` so no UI ever claims otherwise.

import Foundation
import Security

public enum ProxyConfiguration {

    // MARK: URLSession bridge

    /// Builds the connectionProxyDictionary for `settings`.
    ///
    /// - .system → nil (no override; URLSession system defaults + system PAC).
    /// - .none   → empty dictionary (explicit no-proxy session).
    /// - .manual → the nine documented keys from valid entries.
    /// - Invalid settings → throws (documented "Invalid proxy configuration"
    ///   + specific reason); a half-built dictionary is never returned.
    public static func connectionProxyDictionary(
        for settings: ProxySettings
    ) throws -> [AnyHashable: Any]? {
        if let reason = settings.validationFailureReason() {
            throw ProxyConfigurationError(reason: reason)
        }
        switch settings.mode {
        case .system:
            return nil
        case .none:
            return [:]
        case .manual:
            return manualDictionary(http: settings.http, https: settings.https, socks5: settings.socks5)
        }
    }

    /// The manual-mode builder core (internal so tests can hit it directly
    /// through @testable): emits exactly the nine documented keys — a
    /// protocol's three keys appear IFF that protocol has a non-nil entry.
    /// Keys come from SystemProxyParser.Keys (the single source of truth for
    /// every CFNetwork proxy-key spelling — bridged to String once, there).
    static func manualDictionary(
        http: ProxyProtocolEntry?, https: ProxyProtocolEntry?, socks5: ProxyProtocolEntry?
    ) -> [AnyHashable: Any] {
        var dict: [AnyHashable: Any] = [:]
        if let http {
            dict[SystemProxyParser.Keys.httpEnable] = NSNumber(value: true)
            dict[SystemProxyParser.Keys.httpHost] = http.host
            dict[SystemProxyParser.Keys.httpPort] = http.port
        }
        if let https {
            dict[SystemProxyParser.Keys.httpsEnable] = NSNumber(value: true)
            dict[SystemProxyParser.Keys.httpsHost] = https.host
            dict[SystemProxyParser.Keys.httpsPort] = https.port
        }
        if let socks5 {
            dict[SystemProxyParser.Keys.socksEnable] = NSNumber(value: true)
            dict[SystemProxyParser.Keys.socksHost] = socks5.host
            dict[SystemProxyParser.Keys.socksPort] = socks5.port
        }
        return dict
    }

    // MARK: PAC honest scoping

    /// The verbatim honest note any PAC-adjacent surface must carry. PAC
    /// evaluation needs a JS engine plus resolver probes (myIpAddress) — the
    /// lane brief explicitly allows shipping the limitation instead of a
    /// half-implementation, and the .system path is covered natively by
    /// URLSession's own system-PAC handling (nil override ⇒ system behavior).
    public static let pacLimitationNote =
        "PAC evaluation not performed (not implemented); system-level URLSession falls back to system PAC handling"
}

/// Honest configuration failure (the documented "Invalid proxy configuration"
/// text + the specific reason from ProxySettings.validationFailureReason).
public struct ProxyConfigurationError: LocalizedError, Sendable {
    public let reason: String
    public var errorDescription: String? { reason }
    public init(reason: String) { self.reason = reason }
}

// MARK: - Environment passthrough (documented var names, OUR precedence note)

/// What the documented environment variables currently ask for, parsed.
/// Updatest passes these through (UPDATEST-FINDINGS §3.18) but the teardown
/// does NOT document the exact precedence between env vars, system proxies,
/// and manual settings — so this lane only PARSES and reports; the
/// coordinator owns any precedence decision (honest note, never invented).
public struct ProxyEnvironmentPassthrough: Sendable, Hashable {
    /// From HTTP_PROXY / http_proxy / https_proxy (both spellings documented).
    public var http: ProxyProtocolEntry?
    /// From HTTPS_PROXY / https_proxy.
    public var https: ProxyProtocolEntry?
    /// From ALL_PROXY / all_proxy — consumed for SOCKS ONLY (documented).
    public var socks5: ProxyProtocolEntry?
    /// Honest parse notes (unparseable values, ignored schemes, …).
    public var notes: [String]

    public init(http: ProxyProtocolEntry? = nil, https: ProxyProtocolEntry? = nil,
                socks5: ProxyProtocolEntry? = nil, notes: [String] = []) {
        self.http = http
        self.https = https
        self.socks5 = socks5
        self.notes = notes
    }
}

public enum ProxyEnvironment {

    /// Reads the passthrough out of the CURRENT process environment
    /// (reading env is introspection, not traffic — posture intact).
    public static func current() -> ProxyEnvironmentPassthrough {
        passthrough(environment: ProcessInfo.processInfo.environment)
    }

    /// Pure parse of the documented variable set:
    /// - HTTP: `HTTP_PROXY` then `https_proxy` (the documented pair, both
    ///   spellings checked; first present wins — OUR order note, the
    ///   teardown documents only the names).
    /// - HTTPS: `HTTPS_PROXY` then `https_proxy`.
    /// - SOCKS: `ALL_PROXY` then `all_proxy`, consumed for SOCKS ONLY.
    /// Values parse as `scheme://host:port` or bare `host:port`; bare values
    /// default to the variable's own scheme (http/https/socks5). A
    /// non-socks5 ALL_PROXY is ignored with a note (documented SOCKS-only
    /// rule). Anything unparseable → note, never a crash, never a guess.
    public static func passthrough(environment: [String: String]) -> ProxyEnvironmentPassthrough {
        var result = ProxyEnvironmentPassthrough()
        var notes: [String] = []

        func lookup(_ names: [String]) -> (name: String, value: String)? {
            for name in names {
                if let value = environment[name], !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    return (name, value)
                }
            }
            return nil
        }

        if let found = lookup(["HTTP_PROXY", "http_proxy", "https_proxy"]) {
            let (entry, note) = Self.parseEndpoint(
                found.value, defaultScheme: "http", label: found.name)
            result.http = entry
            if let note { notes.append(note) }
        }
        if let found = lookup(["HTTPS_PROXY", "https_proxy"]) {
            let (entry, note) = Self.parseEndpoint(
                found.value, defaultScheme: "https", label: found.name)
            result.https = entry
            if let note { notes.append(note) }
        }
        if let found = lookup(["ALL_PROXY", "all_proxy"]) {
            if Self.scheme(of: found.value) == nil || Self.scheme(of: found.value) == "socks5" {
                let (entry, note) = Self.parseEndpoint(
                    found.value, defaultScheme: "socks5", label: found.name)
                result.socks5 = entry
                if let note { notes.append(note) }
            } else {
                notes.append("\(found.name) ignored: ALL_PROXY is consumed for SOCKS only (documented)")
            }
        }

        result.notes = notes
        return result
    }

    /// `host:port` / `scheme://host:port` → entry + optional honest note.
    /// (Entry auth is always false: env-var URLs with embedded credentials
    /// are REJECTED with a note — credentials belong in the keychain, and
    /// the repo never round-trips secrets through parsed config.)
    static func parseEndpoint(
        _ raw: String, defaultScheme: String, label: String
    ) -> (ProxyProtocolEntry?, String?) {
        var remainder = raw.trimmingCharacters(in: .whitespaces)
        if let schemeEnd = remainder.range(of: "://") {
            remainder = String(remainder[schemeEnd.upperBound...])
        }
        // Strip any path/userinfo remainder honestly (noted, not silently).
        if let slash = remainder.firstIndex(where: { $0 == "/" || $0 == "@" }) {
            let note = "\(label): ignoring '\(String(remainder[slash...]))' after the endpoint"
            remainder = String(remainder[..<slash])
            return endpointOrNote(remainder, label: label, note: note)
        }
        return endpointOrNote(remainder, label: label, note: nil)
    }

    private static func endpointOrNote(
        _ hostPort: String, label: String, note: String?
    ) -> (ProxyProtocolEntry?, String?) {
        let parts = hostPort.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let port = Int(parts[1]), (1...65_535).contains(port) else {
            return (nil, "\(label): value not parseable as host:port — ignored")
        }
        let host = String(parts[0])
        if host.isEmpty {
            return (nil, "\(label): value not parseable as host:port — ignored")
        }
        return (ProxyProtocolEntry(host: host, port: port, authRequired: false), note)
    }

    static func scheme(of value: String) -> String? {
        guard let range = value.range(of: "://") else { return nil }
        return String(value[..<range.lowerBound]).lowercased()
    }
}

// MARK: - Keychain (credentials live here, NEVER in the settings JSON)

/// The credential storage seam (injected so tests use an in-memory fake —
/// the repo has no keychain seam precedent, so this lane introduces one; a
/// real Security-backed implementation ships alongside it and is exercised
/// by the coordinator's live smoke, like FileSystemMonitor's live FSEvents
/// proof, never by the hermetic suite).
public protocol KeychainStoring: Sendable {
    /// Stores (or overwrites) the password for (service, account).
    func savePassword(service: String, account: String, password: String) throws
    /// Loads the password; nil = no item (honest absence, not an error).
    func loadPassword(service: String, account: String) throws -> String?
    /// Deletes the password; deleting a missing item is success (idempotent).
    func deletePassword(service: String, account: String) throws
}

/// Which protocol's credential (account namespace under the one service).
public enum ProxyProtocolName: String, Sendable, CaseIterable {
    case http
    case https
    case socks5
}

/// The real Security.framework store: generic password items
/// (kSecClassGenericPassword), delete-then-add update semantics, and the
/// documented accessibility choice (see file header). NOT covered by the
/// hermetic suite — the protocol seam is; this type compiles the real path.
public struct SecurityKeychainStore: KeychainStoring {
    public init() {}

    public func savePassword(service: String, account: String, password: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary) // idempotent overwrite semantics
        var attributes = query
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ProxyKeychainError(operation: "save", status: status)
        }
    }

    public func loadPassword(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil } // honest absence
        guard status == errSecSuccess, let data = result as? Data else {
            throw ProxyKeychainError(operation: "load", status: status)
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func deletePassword(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { return } // idempotent by contract
        guard status == errSecSuccess else {
            throw ProxyKeychainError(operation: "delete", status: status)
        }
    }
}

/// Keychain wrapper for proxy credentials: fixes the service name, derives
/// per-protocol accounts, and mirrors the documented failure strings.
public struct ProxyKeychain: Sendable {
    /// OUR service name (Updatest's is unrecoverable — teardown open
    /// question #6; this is the documented choice for AppUpdater).
    public static let service = "io.appupdater.AppUpdater.proxy"

    /// The underlying seam (SecurityKeychainStore in production; a fake in
    /// tests). Injected — never constructed globally.
    private let store: KeychainStoring

    public init(store: KeychainStoring) {
        self.store = store
    }

    /// Keychain account name for one protocol's credential.
    public static func account(for protocolName: ProxyProtocolName) -> String {
        "proxy.\(protocolName.rawValue)"
    }

    /// Stores the password. Failure logs the documented string verbatim and
    /// rethrows — the settings UI surfaces it, never a silent loss.
    public func saveProxyPassword(
        _ password: String, for protocolName: ProxyProtocolName
    ) throws {
        do {
            try store.savePassword(
                service: Self.service, account: Self.account(for: protocolName), password: password)
        } catch {
            ProxyLog.log.error("Failed to save proxy password from keychain")
            throw error
        }
    }

    /// Loads the password; nil = none stored (honest absence).
    public func loadProxyPassword(for protocolName: ProxyProtocolName) throws -> String? {
        do {
            return try store.loadPassword(
                service: Self.service, account: Self.account(for: protocolName))
        } catch {
            ProxyLog.log.error("Failed to load proxy password from keychain")
            throw error
        }
    }

    /// Deletes the password (idempotent by the seam's contract).
    public func deleteProxyPassword(for protocolName: ProxyProtocolName) throws {
        do {
            try store.deletePassword(
                service: Self.service, account: Self.account(for: protocolName))
        } catch {
            ProxyLog.log.error("Failed to delete proxy password from keychain")
            throw error
        }
    }

    /// true when a credential is stored for `protocolName` (the settings UI's
    /// honest "auth configured" probe; never implies the password is valid).
    public func hasCredential(for protocolName: ProxyProtocolName) -> Bool {
        (try? loadProxyPassword(for: protocolName)) != nil
    }
}

/// Keychain failure carrying the OSStatus (the documented "Failed to …
/// proxy password from keychain" family, plus the status for diagnostics).
public struct ProxyKeychainError: LocalizedError, Sendable {
    public let operation: String
    public let status: Int32
    public var errorDescription: String? {
        "Failed to \(operation) proxy password from keychain (status \(status))"
    }
    public init(operation: String, status: Int32) {
        self.operation = operation
        self.status = status
    }
}
