// FeedDerivation.swift — derives CANDIDATE Sparkle feed URLs for apps that never declare
// `SUFeedURL`, from update-frameworks embedded INSIDE the app bundle. Pure, offline, read-only:
// no network is performed here and nothing is launched; every URL produced is only a candidate
// that the engine's fetch+parse layer must still validate (404 ⇒ honest unknown).
//
// Capability source (tracked Tier-2 gap #7, docs/reverse/GAP-ANALYSIS.md): MacUpdater derives
// feeds from embedded updater frameworks via `SparkleFeedDetectionHelper.getSparkleFeedsForApp:
// infoPlist:feedToIgnore:`. Evidence from our independent teardown (docs/reverse/
// MACUPDATER-FINDINGS.md §3.2 "Source 3 — Sparkle appcasts" and §4.1 endpoint table), with the
// teardown's own evidence labels:
//
// - AppCenter: `https://api.appcenter.ms/v0.1/public/sparkle/apps/<id>` — [C] URL format string
//   in the MacUpdater binary. The identifier is a UUID-shaped app secret; the teardown records
//   it as "the 36-char UUID ... read from the framework binary bytes" [C]. Corroborated
//   independently by Microsoft's own documentation ("Enable Sparkle updates", learn.microsoft.com
//   — SUFeedURL is `https://api.appcenter.ms/v0.1/public/sparkle/apps/{app_secret}`; AppCenter
//   was retired 2025-03-31, so the endpoint may answer nothing upstream — the candidate is still
//   derived honestly and a failed fetch degrades to unknown, never a guess).
// - DevMateKit: `https://updates.devmate.com/<bundleIdentifier>.xml` — [C] URL format string,
//   observed live in the teardown log for CleanMyMac / The Unarchiver. Keyed by the app's own
//   CFBundleIdentifier, no binary scan needed.
// - HockeySDK: derivation existence is [C] (framework named in SparkleFeedDetectionHelper), but
//   the exact endpoint/identifier reading was only PARTIALLY traced by the teardown — its open
//   question #6 marks it [U]. We implement the historical HockeyApp standard Sparkle endpoint
//   `https://rink.hockeyapp.net/api/2/apps/<appID>/sparkle/` (32-hex app ID, rink.hockeyapp.net
//   since retired) and label every such candidate UNVERIFIED-in-the-wild in `derivation`.
//
// Scan-target honesty (where the identifier is read from):
// - The teardown-confirmed mechanism reads the embedded framework's binary bytes; that is the
//   primary scan target for AppCenter/HockeySDK. UNVERIFIED addition: we ALSO scan the app's own
//   executable when the framework is present, because AppCenter's public docs place the app
//   secret in `MSAppCenter.start:` code (i.e. the host binary), so framework-only scanning would
//   likely miss real integrations. This extension is marked in the `derivation` field so the
//   coordinator can see exactly which candidates came from an unverified scan target.
// - Both scan targets use the same shape-validated extraction (strict hex/dash boundaries):
//   identifiers are verbatim byte runs, never reconstructed, never guessed. An all-zero
//   placeholder UUID is the only excluded value. No version-nibble check is applied (AppCenter
//   secrets are UUID-SHAPED but their nibble semantics are undocumented — over-filtering would
//   be a silent guess).
//
// Boundaries: this module covers ONLY AppCenter.framework / DevMateKit.framework /
// HockeySDK.framework. `Sparkle.framework` embedded in an app is the DIRECT Sparkle tier —
// covered by the app's declared `SUFeedURL` (SparkleSource) — and is deliberately out of scope
// here, mirroring the teardown's separation of the direct tier from the derived tier. Only
// top-level `Contents/Frameworks/*.framework` bundles are consulted; nested frameworks inside
// frameworks are not scanned. All produced URLs are HTTPS constants by construction (LOCKED
// decision 6 security floor is satisfied at the type level).

import Foundation

/// One candidate Sparkle feed URL derived from an embedded update framework.
/// `framework` names the embedded bundle whose presence gated the derivation;
/// `derivation` carries the honest provenance note (endpoint evidence label + which
/// binary the identifier was read from), suitable for surfacing in sourceDetail.
public struct DerivedSparkleFeed: Equatable, Sendable {
    public let url: URL
    public let framework: String
    public let derivation: String

    public init(url: URL, framework: String, derivation: String) {
        self.url = url
        self.framework = framework
        self.derivation = derivation
    }
}

/// See the file header for the full evidence contract.
public enum SparkleFeedDerivation {
    /// Read-only scan of an installed app bundle (never launches anything, no network).
    /// Returns candidate feed URLs; empty when no known updater framework is embedded or
    /// an embedded framework's identifier cannot be extracted (missing/unreadable binary,
    /// no UUID-shaped string). Empty is an honest "cannot derive", never a fabricated feed.
    public static func candidateFeeds(appBundlePath: String) -> [DerivedSparkleFeed] {
        candidateFeeds(appBundleURL: URL(fileURLWithPath: appBundlePath, isDirectory: true))
    }

    public static func candidateFeeds(appBundleURL: URL) -> [DerivedSparkleFeed] {
        let fileManager = FileManager.default
        let contents = appBundleURL.appendingPathComponent("Contents", isDirectory: true)
        let frameworks = updaterFrameworks(in: contents, fileManager: fileManager)
        guard !frameworks.isEmpty else { return [] }

        let infoPlist = InfoProbe.infoDictionary(appBundleURL: appBundleURL)
        // Host-executable scan target (see header honesty note): resolved from
        // CFBundleExecutable, falling back to the bundle name; nil when absent/unreadable.
        let appExecutable = executableURL(
            in: contents.appendingPathComponent("MacOS", isDirectory: true),
            infoPlist: infoPlist,
            fallbackName: appBundleURL.deletingPathExtension().lastPathComponent,
            fileManager: fileManager)

        var feeds: [DerivedSparkleFeed] = []
        var seenURLs = Set<String>()
        func add(_ feed: DerivedSparkleFeed) {
            if seenURLs.insert(feed.url.absoluteString).inserted {
                feeds.append(feed)
            }
        }

        if let appCenter = frameworks["AppCenter.framework"] {
            let uuids = scanIdentifiers(
                targets: scanTargets(frameworkURL: appCenter, appExecutable: appExecutable),
                extract: dashedUUIDs(in:),
                fileManager: fileManager)
            for (uuid, source) in uuids {
                guard let url = URL(string: "https://api.appcenter.ms/v0.1/public/sparkle/apps/\(uuid)") else {
                    continue
                }
                add(DerivedSparkleFeed(
                    url: url,
                    framework: "AppCenter.framework",
                    derivation: "AppCenter Sparkle feed; app-secret UUID read from \(source.note) "
                        + "[endpoint: MACUPDATER-FINDINGS §4.1 [C], corroborated by AppCenter docs]"))
            }
        }

        if frameworks["DevMateKit.framework"] != nil {
            // Binary-independent: DevMate feeds are keyed by the app's bundle ID.
            // Presence without a bundle ID yields nothing — honest skip, no guess.
            if let bundleID = InfoProbe.string(for: ["CFBundleIdentifier"], in: infoPlist),
               let url = URL(string: "https://updates.devmate.com/\(bundleID).xml") {
                add(DerivedSparkleFeed(
                    url: url,
                    framework: "DevMateKit.framework",
                    derivation: "DevMate feed keyed by the app's CFBundleIdentifier (no binary read) "
                        + "[endpoint: MACUPDATER-FINDINGS §4.1 [C], observed live in teardown]"))
            }
        }

        if let hockey = frameworks["HockeySDK.framework"] {
            let ids = scanIdentifiers(
                targets: scanTargets(frameworkURL: hockey, appExecutable: appExecutable),
                extract: { hexRuns(in: $0, length: 32) },
                fileManager: fileManager)
            for (id, source) in ids {
                guard let url = URL(string: "https://rink.hockeyapp.net/api/2/apps/\(id)/sparkle/") else {
                    continue
                }
                add(DerivedSparkleFeed(
                    url: url,
                    framework: "HockeySDK.framework",
                    derivation: "HockeyApp rink Sparkle feed; app ID hex string read from \(source.note) "
                        + "[endpoint UNVERIFIED-in-the-wild: teardown open question #6 marks derivation [U]]"))
            }
        }

        return feeds
    }

    // MARK: - Bundle enumeration (read-only)

    /// Top-level `Contents/Frameworks/*.framework` directories, filtered to the three known
    /// updater frameworks, keyed by exact directory name, in sorted (deterministic) order.
    /// Nested frameworks are not consulted (documented v1 boundary).
    static func updaterFrameworks(
        in contents: URL, fileManager: FileManager = .default
    ) -> [String: URL] {
        let knownNames = ["AppCenter.framework", "DevMateKit.framework", "HockeySDK.framework"]
        let frameworksDir = contents.appendingPathComponent("Frameworks", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: frameworksDir, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [:] }
        var result: [String: URL] = [:]
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            let name = entry.lastPathComponent
            guard knownNames.contains(name), entry.pathExtension == "framework" else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { continue }
            result[name] = entry
        }
        return result
    }

    /// Resolves the app's main executable inside `macOSDir` from CFBundleExecutable
    /// (falling back to `fallbackName`), or nil when absent/not a readable file.
    static func executableURL(
        in macOSDir: URL, infoPlist: [String: Any], fallbackName: String,
        fileManager: FileManager = .default
    ) -> URL? {
        let names = [InfoProbe.string(for: ["CFBundleExecutable"], in: infoPlist), fallbackName]
            .compactMap { $0 }
        for name in names {
            let candidate = macOSDir.appendingPathComponent(name, isDirectory: false)
            if isReadableFile(candidate, fileManager) {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Identifier extraction

    /// Where a candidate identifier was read from — drives the honest `derivation` note.
    private enum IdentifierSource {
        case frameworkBinary(URL)
        case appExecutable(URL)

        var note: String {
            switch self {
            case .frameworkBinary:
                return "the embedded framework's binary bytes (teardown-confirmed target)"
            case .appExecutable:
                return "the app executable bytes (UNVERIFIED scan target; AppCenter docs place the secret in start() code)"
            }
        }
    }

    /// Fixed target order: framework binary first (teardown-confirmed), then the app executable
    /// (labeled addition) when resolvable.
    private static func scanTargets(frameworkURL: URL, appExecutable: URL?) -> [IdentifierSource] {
        var targets = [IdentifierSource.frameworkBinary(frameworkURL)]
        if let appExecutable {
            targets.append(.appExecutable(appExecutable))
        }
        return targets
    }

    /// Scan target order is fixed: framework binary first (teardown-confirmed), then the app
    /// executable (labeled addition). Returns (identifier, source) pairs in first-appearance
    /// order, deduplicated per identifier.
    private static func scanIdentifiers(
        targets: [IdentifierSource], extract: (Data) -> [String],
        fileManager: FileManager
    ) -> [(String, IdentifierSource)] {
        var result: [(String, IdentifierSource)] = []
        var seen = Set<String>()
        for target in targets {
            guard let binaryURL: URL = {
                switch target {
                case .frameworkBinary(let url): return frameworkExecutableURL(url, fileManager: fileManager)
                case .appExecutable(let url): return url
                }
            }(), let data = readBinaryPrefix(binaryURL, fileManager: fileManager) else { continue }
            for identifier in extract(data) where seen.insert(identifier).inserted {
                result.append((identifier, target))
            }
        }
        return result
    }

    /// Resolves an embedded framework's Mach-O executable WITHOUT `Bundle(url:)` (Bundle caches
    /// by URL process-wide — a reinstalled bundle must be re-read from disk, the InfoProbe
    /// policy). Checks CFBundleExecutable from the framework's own Info.plist, then the
    /// name-derived binary, in both the classic (`Versions/A/`) and flat layouts.
    static func frameworkExecutableURL(
        _ frameworkURL: URL, fileManager: FileManager = .default
    ) -> URL? {
        let name = frameworkURL.deletingPathExtension().lastPathComponent
        var executables = [name]
        for infoURL in [
            frameworkURL.appendingPathComponent("Versions/A/Resources/Info.plist", isDirectory: false),
            frameworkURL.appendingPathComponent("Resources/Info.plist", isDirectory: false),
        ] {
            if let data = try? Data(contentsOf: infoURL),
               let plist = locallyParsedPlist(data),
               let executable = InfoProbe.string(for: ["CFBundleExecutable"], in: plist),
               !executables.contains(executable) {
                executables.insert(executable, at: 0)
            }
        }
        for executable in executables {
            for baseURL in [
                frameworkURL.appendingPathComponent("Versions/A", isDirectory: true),
                frameworkURL,
            ] {
                let candidate = baseURL.appendingPathComponent(executable, isDirectory: false)
                if isReadableFile(candidate, fileManager) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Reads at most `maxBinaryScanBytes` from a binary (frameworks are multi-MB; the cap keeps
    /// huge host executables from being slurped whole — UUID-shaped secrets live in string
    /// sections near the front, so truncation is a bounded trade, documented here).
    private static func readBinaryPrefix(
        _ url: URL, fileManager: FileManager
    ) -> Data? {
        guard isReadableFile(url, fileManager) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return handle.readData(ofLength: maxBinaryScanBytes)
    }

    /// Size guard on each scanned binary (house pattern: ElectronSource/GithubSource caps).
    static let maxBinaryScanBytes = 64 * 1024 * 1024

    private static func isReadableFile(_ url: URL, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isReadableFile(atPath: url.path)
        else { return false }
        return true
    }

    /// Parses plist bytes (XML or binary) locally — the framework's own Info.plist needs the
    /// same cache-free read policy as the app's, but InfoProbe only exposes file-URL parsing
    /// (Scan/InfoProbe.swift) and is lane-owned, so the dictionary root is derived here.
    private static func locallyParsedPlist(_ data: Data) -> [String: Any]? {
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let root = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: &format)
        else { return nil }
        return root as? [String: Any]
    }

    // MARK: - Shape-validated scanners

    /// UUID-shaped identifiers: 8-4-4-4-12 hex groups separated by dashes, with STRICT
    /// boundaries (neighboring bytes may be neither hex digits nor dashes, so fragments of
    /// longer hex/dash chains never match). Verbatim, deduplicated, in byte order. The
    /// all-zero placeholder is excluded; everything else is surfaced verbatim.
    static func dashedUUIDs(in data: Data) -> [String] {
        scanHexStrings(in: data, groups: [8, 4, 4, 4, 12], separator: UInt8(ascii: "-"))
            .filter { $0.lowercased() != "00000000-0000-0000-0000-000000000000" }
    }

    /// Plain hex runs of exactly `length` characters with the same strict boundaries (a dashed
    /// UUID's segments can therefore never satisfy a 32-hex HockeyApp ID match, and 40/64-char
    /// git/SHA hex runs can never yield a 32-char substring match).
    static func hexRuns(in data: Data, length: Int) -> [String] {
        scanHexStrings(in: data, groups: [length], separator: nil)
            .filter { $0.lowercased() != String(repeating: "0", count: length) }
    }

    /// Core scanner: finds ASCII strings shaped as `groups` hex runs separated by `separator`
    /// (one run when nil), each match bounded on both sides by non-hex, non-separator bytes.
    static func scanHexStrings(in data: Data, groups: [Int], separator: UInt8?) -> [String] {
        let bytes = [UInt8](data)
        let byteCount = bytes.count
        let separatorWidth = separator == nil ? 0 : 1
        let matchLength = groups.reduce(0, +) + (groups.count - 1) * separatorWidth
        guard matchLength > 0, byteCount >= matchLength else { return [] }
        var found: [String] = []
        var seen = Set<String>()

        var index = 0
        while index <= byteCount - matchLength {
            // A match can only START on a hex digit that is not inside a longer hex/dash run.
            guard isHex(bytes[index]) else { index += 1; continue }
            if index > 0 {
                let previous = bytes[index - 1]
                if isHex(previous) || previous == separator {
                    index += 1
                    continue
                }
            }
            var offset = index
            var matches = true
            for (groupIndex, width) in groups.enumerated() {
                guard bytes[offset..<(offset + width)].allSatisfy({ isHex($0) }) else {
                    matches = false
                    break
                }
                offset += width
                if let dash = separator, groupIndex < groups.count - 1 {
                    guard bytes[offset] == dash else { matches = false; break }
                    offset += 1
                }
            }
            if matches, offset < byteCount {
                let trailing = bytes[offset]
                // Trailing hex digit (substring of a longer run) or trailing dash
                // (fragment of a longer dash chain) both invalidate the match.
                if isHex(trailing) || trailing == separator {
                    matches = false
                }
            }
            if matches, let candidate = String(bytes: bytes[index..<offset], encoding: .ascii),
               seen.insert(candidate).inserted {
                found.append(candidate)
                index = offset
            } else {
                index += 1
            }
        }
        return found
    }

    /// 256-entry hex-digit lookup (0-9, a-f, A-F).
    private static let isHexDigit: [Bool] = {
        var table = [Bool](repeating: false, count: 256)
        for byte in UInt8(ascii: "0")...UInt8(ascii: "9") { table[Int(byte)] = true }
        for byte in UInt8(ascii: "a")...UInt8(ascii: "f") { table[Int(byte)] = true }
        for byte in UInt8(ascii: "A")...UInt8(ascii: "F") { table[Int(byte)] = true }
        return table
    }()

    private static func isHex(_ byte: UInt8) -> Bool {
        isHexDigit[Int(byte)]
    }
}
