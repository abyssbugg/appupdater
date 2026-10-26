// Scanner.swift — production AppScanner: directory walk + Info.plist probe per .app bundle.
// Scan lane only. Does NOT run codesign/SecStaticCode — signatureTeamID is another lane's.

import Foundation

/// Scans the given directory URLs for `.app` bundles and builds one `InstalledApp` per found
/// bundle. Implements the frozen `AppScanner` contract.
///
/// Documented behavior:
/// - **One level per directory URL, non-recursive** — mirrors MacUpdater scanning /Applications
///   plus custom folders as flat lists.
/// - **Only `.app` entries are considered** (path extension "app", case-insensitive), and only
///   when the entry is a directory after symlink resolution — so a plain *file* named
///   `Fake.app` is skipped too. Anything else is skipped silently.
/// - **Symlinks are followed**: a symlinked `.app` is accepted; `InstalledApp.path` reports the
///   entry's own (unresolved) path as found on disk, while Info.plist values come from the link
///   target. `/Applications` uses symlinked bundles only rarely, but refusing them would hide
///   real installations.
/// - **Duplicate bundle identifiers stay as separate entries** — each path is its own
///   `InstalledApp` (model id includes path), mirroring MacUpdater's duplicate policy.
/// - **Identical POSIX paths collapse to one entry** (a directory URL passed twice yields no
///   duplicates).
/// - **Deterministic sort**: by `name`, then `path`, using plain lexicographic `<` — NOT a
///   localized comparison, so the order is stable across machines, locales, and cache runs.
/// - **Path reporting**: POSIX string, any trailing slash removed, and the prefix is the
///   filesystem's *canonical* location — FileManager enumerates through directory symlinks,
///   so a directory URL spelled `/var/…` reports entries as `/private/var/…`. This makes one
///   installed location produce one stable path string regardless of how the scan directory
///   was spelled. (App-bundle symlinks themselves are reported at the link path, above.)
/// - **Throws** if a directory URL cannot be listed (missing or unreadable): surfacing
///   misconfiguration beats silently producing a partial scan; per-directory error aggregation
///   belongs to the scan-engine layer above this primitive.
/// - **Field mapping sources**: `CFBundleIdentifier` (fallback: bundle folder name without
///   `.app`), `CFBundleName` (fallback: `CFBundleDisplayName`, then folder name), `path` (POSIX
///   string), `CFBundleShortVersionString`, `CFBundleVersion`, `LSMinimumSystemVersion`,
///   `SUDefaultChannel` taken verbatim when present (Sparkle channel policy; nil when absent or
///   empty), and `SUFeedURL` taken as-is when present. Version-like values tolerate numeric plist
///   values.
/// - **isMacAppStore** is true only when `Contents/_MASReceipt/_MASReceipt` exists.
/// - `signatureTeamID` and `checkedAt` are left nil here (codesign and result-stamping are
///   other lanes' responsibilities).
public struct ProductionAppScanner: AppScanner {
    public init() {}

    public func scan(directoryURLs: [URL]) async throws -> [InstalledApp] {
        var seenPaths = Set<String>()
        var apps: [InstalledApp] = []

        for directory in directoryURLs {
            for entry in try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [])
            where isMacAppBundle(entry) {
                let app = installedApp(at: entry)
                if seenPaths.insert(app.path).inserted {
                    apps.append(app)
                }
            }
        }

        apps.sort { ($0.name, $0.path) < ($1.name, $1.path) }
        return apps
    }

    /// True when `url` ends in ".app" (any case) and resolves (through symlinks) to a directory.
    private func isMacAppBundle(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "app" else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false),
                                              isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Builds the `InstalledApp` for one `.app` bundle directory. Never fails: missing plist
    /// keys fall back to the documented defaults, so a degenerate bundle still appears (with
    /// folder-name-derived identity) rather than vanishing from the scan.
    private func installedApp(at bundleURL: URL) -> InstalledApp {
        let plist = InfoProbe.infoDictionary(appBundleURL: bundleURL)
        let folderName = bundleURL.deletingPathExtension().lastPathComponent
        let posixPath = posixPath(of: bundleURL)

        let sparkleFeed = plist["SUFeedURL"] as? String   // strict String, kept as-is

        // Sparkle channel policy: taken verbatim when present; an empty string counts as unset
        // (nil), matching the documented field-mapping rule above. No trimming — the declaration
        // is the app's own policy, not a normalized value.
        let suDefaultChannel: String?
        if let declared = plist["SUDefaultChannel"] as? String, !declared.isEmpty {
            suDefaultChannel = declared
        } else {
            suDefaultChannel = nil
        }

        var isDirectory: ObjCBool = false
        let receiptURL = bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("_MASReceipt")
            .appendingPathComponent("_MASReceipt")
        let hasReceipt = FileManager.default.fileExists(
            atPath: receiptURL.path(percentEncoded: false), isDirectory: &isDirectory)

        return InstalledApp(
            bundleIdentifier: InfoProbe.string(for: ["CFBundleIdentifier"], in: plist)
                ?? folderName,
            name: InfoProbe.string(for: ["CFBundleName"], in: plist)
                ?? InfoProbe.string(for: ["CFBundleDisplayName"], in: plist)
                ?? folderName,
            path: posixPath,
            shortVersion: InfoProbe.string(for: ["CFBundleShortVersionString"], in: plist),
            bundleVersion: InfoProbe.string(for: ["CFBundleVersion"], in: plist),
            minimumSystemVersion: InfoProbe.string(for: ["LSMinimumSystemVersion"], in: plist),
            isMacAppStore: hasReceipt,
            sparkleFeedURL: sparkleFeed,
            suDefaultChannel: suDefaultChannel
        )
    }

    /// POSIX path with any trailing slash removed (directory entries enumerate as `Foo.app/`).
    private func posixPath(of url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
