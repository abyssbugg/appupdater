// ProxySettings.swift — proxy subsystem settings model + persistence (GAP #20).
// Gap-closure sprint · lane proxy · exclusive file of this lane.
//
// REQUIREMENTS EVIDENCE (read-only teardown docs): UPDATEST-FINDINGS.md §3.18 —
// "[confirmed] Proxy subsystem: … manual override with type HTTP/HTTPS/SOCKS5,
// auth user+password (password stored in Keychain: 'Failed to save/load/delete
// proxy password from keychain'), PAC support claim ('Supports HTTP, HTTPS,
// SOCKS proxies and PAC files.'), env-var passthrough (HTTP_PROXY/https_proxy,
// HTTPS_PROXY, ALL_PROXY (SOCKS only)), 'Invalid proxy configuration'".
// GAP-ANALYSIS.md #20. Field shapes implemented here are exactly the ones the
// teardown documents (mode; per-protocol host/port/auth-required); anything the
// teardown does NOT document is marked as OUR decision in a comment — never
// presented as recovered Updatest behavior.
//
// HONESTY BOUNDARY (credential storage): the settings JSON NEVER carries a
// password. Auth passwords live in the Keychain (ProxyKeychain in
// ProxyConfiguration.swift; Updatest's own keychain service name is an open
// teardown question #6 — ours is chosen + documented there, never invented
// as theirs). A non-nil entry's `authRequired` flag only declares that a
// credential must exist in the keychain before the session is usable.
//
// PERSISTENCE (mirrors RuleStore / ScheduleFileStore conventions verbatim):
//   Directory:  default ~/Library/Application Support/AppUpdater (or init seam)
//   File:       proxy_settings.json — JSONEncoder [.prettyPrinted, .sortedKeys],
//               default date strategy (this model carries no dates; the encoder
//               config is kept identical to the sibling stores on purpose)
//   - Init and load() touch nothing on disk; the directory is created lazily
//     on FIRST save only (read-only environments never grow state).
//   - Missing file     → defaults (ProxySettings()).
//   - Unparseable file → defaults + documented log line; the next save
//     honestly replaces the garbage bytes (never a crash, never a partial parse).
//   - Writes are atomic: staging file in the target directory + FileHandle,
//     swapped with replaceItemAt (target exists) or moveItem (first write) —
//     a failed write never corrupts the previous good file.
//   - Log surface: os.Logger subsystem "io.appupdater.AppUpdater", category
//     "proxy-settings". Documented line (RuleStore phrasing, adapted):
//       "proxy_settings.json unparseable (<reason>) — treating as defaults; next save replaces it"
//
// READ-ONLY POSTURE (lane brief): this file never sends traffic; it is the
// configuration surface the coordinator later applies to URLSession(s).

import Foundation
import os

/// Which proxy source governs the updater's network sessions.
/// Values are the documented triad (UPDATEST-FINDINGS §3.18 manual override +
/// system monitoring + "no proxy"); rawValues are wire-stable (never renamed —
/// persisted bytes depend on them).
public enum ProxyMode: String, Codable, Hashable, Sendable {
    /// Follow the live system proxy configuration (SystemProxyMonitor's domain).
    /// Default: the least-intrusive posture — an updater that changes nothing
    /// about the machine's own proxy story unless the user asks (OUR choice;
    /// Updatest's persisted default is not recoverable from the teardown).
    case system
    /// User-entered per-protocol overrides (host/port per protocol; password
    /// in the keychain, never here).
    case manual
    /// Explicitly no proxy: sessions must not use any proxy configuration.
    case none
}

/// One per-protocol manual entry — exactly the documented field shapes
/// (host, port, auth required flag; UPDATEST-FINDINGS §3.18). The password the
/// flag promises is KEYCHAIN-only (see file header); a persisted entry with
/// `authRequired == true` and no keychain credential is an honestly-declared
/// incomplete configuration the coordinator surfaces, never a silent fallback.
public struct ProxyProtocolEntry: Codable, Hashable, Sendable {
    /// Proxy hostname or IP (verbatim user input; no DNS resolution here —
    /// this lane never touches the network).
    public var host: String
    /// TCP port. Valid range 1...65535 (checked by ``ProxySettings/isValid``;
    /// the model stores what it is given and VALIDATES honestly rather than
    /// clamping user input behind their back).
    public var port: Int
    /// true = this protocol's session requires proxy authentication; the
    /// username/password pair is stored in the KEYCHAIN (account names
    /// documented on ``ProxyKeychain``).
    public var authRequired: Bool

    public init(host: String, port: Int, authRequired: Bool = false) {
        self.host = host
        self.port = port
        self.authRequired = authRequired
    }
}

/// The persisted proxy settings payload (Codable + Hashable per lane brief).
public struct ProxySettings: Codable, Hashable, Sendable {
    public var mode: ProxyMode
    /// Manual HTTP entry (nil = HTTP not manually configured).
    public var http: ProxyProtocolEntry?
    /// Manual HTTPS entry (nil = HTTPS not manually configured).
    public var https: ProxyProtocolEntry?
    /// Manual SOCKS5 entry (nil = SOCKS not manually configured).
    public var socks5: ProxyProtocolEntry?
    /// System-detected PAC file URL (kCFNetworkProxiesProxyAutoConfigURLString,
    /// carried by SystemProxyMonitor's snapshot). NEVER user-typed and never a
    /// secret; nil unless the SYSTEM currently names a PAC file. PAC evaluation
    /// is NOT implemented (see ProxyConfiguration.pacLimitationNote) — the URL
    /// is carried so the coordinator can display it and so .system mode can
    /// lean on URLSession's built-in system PAC handling.
    public var pacURL: String?

    public init(
        mode: ProxyMode = .system,
        http: ProxyProtocolEntry? = nil,
        https: ProxyProtocolEntry? = nil,
        socks5: ProxyProtocolEntry? = nil,
        pacURL: String? = nil
    ) {
        self.mode = mode
        self.http = http
        self.https = https
        self.socks5 = socks5
        self.pacURL = pacURL
    }

    /// Decode tolerance (additive-contract requirement, SchedulePolicy pattern):
    /// every key decodes with `decodeIfPresent` so settings persisted by older
    /// builds (or hand-edited files missing keys) decode to honest defaults
    /// instead of failing the whole file. Encoding stays synthesized (every
    /// key always written).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(ProxyMode.self, forKey: .mode) ?? .system
        http = try container.decodeIfPresent(ProxyProtocolEntry.self, forKey: .http)
        https = try container.decodeIfPresent(ProxyProtocolEntry.self, forKey: .https)
        socks5 = try container.decodeIfPresent(ProxyProtocolEntry.self, forKey: .socks5)
        pacURL = try container.decodeIfPresent(String.self, forKey: .pacURL)
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case http
        case https
        case socks5
        case pacURL
    }

    // MARK: Validation (documented "Invalid proxy configuration" surface)

    /// true when the settings can be applied as-is. The documented invalid
    /// case is "Invalid proxy configuration" (UPDATEST-FINDINGS §3.18); the
    /// specific reasons below are OUR enumeration of what that string must
    /// cover (the teardown does not itemize them):
    /// - mode == .manual with NO entries at all (nothing to override with);
    /// - any non-nil entry with an empty/whitespace host;
    /// - any non-nil entry with a port outside 1...65535.
    /// Entries present in .system/.none modes are not validated as an error —
    /// they are simply NOT APPLIED (ProxyConfiguration documents that) — but a
    /// malformed entry is still reported by `validationFailureReason` so the
    /// settings pane can show why it will be ignored.
    public var isValid: Bool { validationFailureReason() == nil }

    /// nil = valid; otherwise the honest reason (leading with the documented
    /// literal "Invalid proxy configuration" + a specific suffix the UI can
    /// render verbatim).
    public func validationFailureReason() -> String? {
        let entries: [(String, ProxyProtocolEntry?)] = [
            ("http", http), ("https", https), ("socks5", socks5),
        ]
        for (name, entry) in entries {
            guard let entry else { continue }
            if entry.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Invalid proxy configuration: \(name) host is empty"
            }
            if !(1...65_535).contains(entry.port) {
                return "Invalid proxy configuration: \(name) port \(entry.port) is outside 1...65535"
            }
        }
        if mode == .manual, http == nil, https == nil, socks5 == nil {
            return "Invalid proxy configuration: manual mode with no per-protocol entries"
        }
        return nil
    }
}

/// Persistence for ``ProxySettings`` (see the file header for the full
/// contract — a RuleStore mirror). `Sendable` by construction: all state is
/// immutable after init; every method re-derives from disk so concurrent UI
/// callers always see one truth.
public struct ProxySettingsStore: Sendable {

    /// Filename inside the store directory (sibling of rules.json and
    /// schedule.json per the frozen Model/ScheduleStore.swift layout comment).
    private static let fileName = "proxy_settings.json"

    static let log = Logger(subsystem: "io.appupdater.AppUpdater", category: "proxy-settings")

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    /// Store directory — the ONLY test seam (real temp directories in tests,
    /// no protocol indirection; RuleStore convention).
    public let directory: URL

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// Builds a store rooted at `directory`. Passing nil selects the shared,
    /// user-visible default directory; nothing is touched on disk here.
    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    /// Same default as RuleStore (`~/Library/Application Support/AppUpdater`),
    /// so all three settings files live together.
    static var defaultDirectory: URL { RuleStore.defaultDirectory }

    /// Loads the persisted settings. Robust by contract:
    /// - missing/unreadable file → defaults (honest absence, nothing created);
    /// - unparseable bytes → defaults + the documented log line; the next
    ///   save honestly replaces the garbage file.
    /// A decode failure of an individual VALUE (e.g. an out-of-grammar enum
    /// rawValue) is the same unparseable case — JSONDecoder is all-or-nothing.
    public func load() async throws -> ProxySettings {
        guard let data = try? Data(contentsOf: fileURL) else {
            return ProxySettings()
        }
        do {
            return try Self.decoder.decode(ProxySettings.self, from: data)
        } catch {
            Self.log.error(
                "proxy_settings.json unparseable (\(String(describing: error), privacy: .public)) — treating as defaults; next save replaces it"
            )
            return ProxySettings()
        }
    }

    /// Persists `settings` atomically as canonical JSON. Throws on failure —
    /// a settings change the user asked to set MUST surface its failure,
    /// never vanish into memory-only state (RuleStore convention).
    public func save(_ settings: ProxySettings) async throws {
        let data = try Self.encoder.encode(settings)
        try writeBytesAtomically(data, to: fileURL)
    }

    /// Staging + atomic swap (file-local RuleStore/ScheduleFileStore mirror:
    /// the staging file lives in the target directory so the final rename is
    /// same-volume, and a failure anywhere before the swap leaves the previous
    /// good file untouched).
    private func writeBytesAtomically(_ data: Data, to target: URL) throws {
        let dir = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staging = dir.appendingPathComponent(
            ".\(target.lastPathComponent)-\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: staging) }

        guard FileManager.default.createFile(atPath: staging.path, contents: Data()) else {
            throw ProxySettingsWriteFailure(
                reason: "could not stage proxy_settings.json write in \(dir.path)")
        }
        do {
            let handle = try FileHandle(forWritingTo: staging)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
        } catch {
            throw ProxySettingsWriteFailure(
                reason: "staging proxy_settings.json write failed: \(String(describing: error))")
        }

        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: target)
        }
    }
}

/// Honest persistence failure (mirrors RuleStoreWriteFailure; the UI surfaces
/// the verbatim text, not "success" theater).
public struct ProxySettingsWriteFailure: LocalizedError, Sendable {
    public let reason: String
    public var errorDescription: String? { "ProxySettingsStore write failed: \(reason)" }
    public init(reason: String) { self.reason = reason }
}
