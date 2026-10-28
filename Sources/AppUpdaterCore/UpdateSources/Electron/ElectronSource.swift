// Source tier: Electron-app self-update metadata (UPDATEST-FINDINGS §3.7,
// GAP-ANALYSIS #4). Updatest's recipe, applied honest-nil style:
//
//   DETECTION (no network until detected — fast, zero-net refusal path):
//     an app is a candidate ONLY when BOTH of these hold:
//       1. `Contents/Frameworks/Electron Framework.framework` exists, AND
//       2. `Contents/Resources/app-update.yml` OR `Contents/Resources/app.asar`
//          exists.
//     Anything else returns nil before a single byte hits the network.
//
//   PIPELINE A — `app-update.yml` (electron-builder metadata; presence wins:
//   when the yml claims exist, the asar probe below is never attempted):
//     provider routing (v1, per brief):
//       - `provider: github` + owner + repo →
//         GET https://api.github.com/repos/<owner>/<repo>/releases/latest
//         (Accept: application/vnd.github.v3+json) → find the release asset
//         NAMED `latest-mac.yml` (documented choice: the OTHER documented
//         variants — latest-mac-arm64.yml / latest-mac-universal.yml /
//         RELEASES.json — are deliberately skipped for v1 with the arch/channel
//         mapping deferred; see the evidence file's limitations) → download the
//         asset (size guard < 64 KB) → parse as latest-mac.yml.
//       - any other provider CARRYING a plain `url` →
//         GET <url>/latest-mac.yml (HTTPS-only floor, LOCKED decision 6:
//         app-update.yml can declare `http://localhost:8081` — the ZCode-real
//         shape observed on this machine — and that is refused, falling through
//         to pipeline B / nil, never plaintext).
//       - anything else (s3, custom, missing owner/repo/url, malformed) is
//         UNRESOLVABLE for the latest-mac.yml route → pipeline B fallback,
//         else honest nil.
//
//   latest-mac.yml → claim (UpdateInfo):
//     - top-level `version` REQUIRED — never synthesized.
//     - `files[]` entries carry {url, sha512}; the first entry with a usable
//       url becomes the download URL, resolved against the yml ORIGIN's
//       directory (relative join; an absolute url wins). NOTE (recorded for
//       merge review): electron-builder writes x64+arm64+universal block into
//       one list in document order; first-entry picking is the v1 policy, arch
//       matching (this Mac is arm64) is a documented limitation, and the
//       install stage is MANUAL here anyway.
//     - sha256Hex = nil ALWAYS. Only SHA-512 exists upstream (Updatest §3.7
//       contract); our installer verifies SHA-256, so electron claims are
//       INFO+MANUAL by design — the sourceDetail string says so verbatim.
//     - minimumSystemVersion: not carried by latest-mac.yml (that's
//       package.json/Info.plist data; honest nil rather than a guess).
//     - releaseDate: ISO8601-first tolerant parse; releaseNotes = releaseName.
//     - confidence .medium (public self-attested metadata, verified SHA-256
//       impossible at this tier).
//
//   PIPELINE B — asar fallback (Updatest's recipe, REQUIRED by the brief for
//   apps that ship `app.asar` WITHOUT a resolvable app-update.yml — real
//   example on this machine: Claude Desktop):
//     1. Read `Contents/Resources/app.asar` (bounded reads — header slice +
//        member seek, never whole-archive; see AsarReader).
//     2. Load the header JSON's files tree; resolve `package.json`.
//     3. `main` key (default "index.js" when absent) → resolve that member's
//        bytes.
//     4. Regex EXACTLY like Updatest's AsarExtractedUpdateInfo injection:
//          updateURL\s*[=:]\s*['"`]([^'"`]+)['"`]
//          ['"`](https?://update\.electronjs\.org/[^'"`]+)['"`]
//        v1 recovers only the electronjs-hosted service: an updateURL pointing
//        elsewhere is recorded as a non-match (honest nil) rather than routed.
//     5. owner/repo from the matched electronjs URL: first two path segments
//        after the host; any `{platform}/{version}` suffix is stripped by
//        construction (only the first two segments are taken).
//     6. Probe https://update.electronjs.org/<owner>/<repo>/darwin-arm64/
//        <installedVersion or "0.0.0"> → JSON {name, version, url?} — version
//        REQUIRED. The darwin-arm64 template is an EMULATED PROBE documented
//        as a v1 limitation (Updatest scrapes per-arch templates; we probe the
//        arm64 platform template per brief — see the evidence file).
//
//   OK-LANE SEMANTICS (SourceKind .unknown — coordinator-owned enum reuse, NO
//   new kind added):
//     The engine sorts sources by VersionOracle.sourcePrecedence
//     (cask > sparkle > mas > github; unknown kept LAST). VersionOracle's
//     unknown-branch surfaces an unknown-kind claim ONLY when no stronger
//     source produced any candidate. That is exactly Updatest's framing:
//     "apps built with Electron often include their own update system… these
//     apps typically UPDATE THEMSELVES WHEN LAUNCHED" — so an Electron claim is
//     surfaced as info/manual material only when no stronger source has
//     already produced a candidate. Ergo `.unknown`, and so the claim never
//     outbids cask/sparkle/mas/github evidence.
//     KNOWN CONSEQUENCE, recorded for merge review (like SparkleSource's
//     lane-local "no-updater-than-installed" note): this lane does NOT gate on
//     installed-version-newer-or-equal — an equal/stale electron release stays
//     a claim per the brief, because the claim is "what the vendor publishes"
//     info for an app that self-updates at launch, not an install order.
//
//   FAILURE SEMANTICS: every network/parse failure yields nil (this source
//   never throws into the failures path — not even malformed URLs, which
//   resolve to nil-honest here, exactly like CaskSource; the declared `throws`
//   is the frozen UpdateSource contract and is honored by never rethrowing).

import Foundation
import os

public struct ElectronSource: UpdateSource, Sendable {
    /// Fetch User-Agent (repo-wide v1 UA, same surface as the other sources).
    public static let userAgent = "AppUpdater/0.1 (macOS)"

    /// GitHub REST versioned media type, sent with the releases/latest route.
    private static let githubAcceptHeader = "application/vnd.github.v3+json"

    /// Size guard on downloaded latest-mac.yml content (brief: < 64 KB).
    private static let maxLatestMacYmlBytes = 64 * 1024

    /// Size guard on the electronjs JSON probe response (sanity: real answers
    /// are tiny "name/version/url" objects — hundreds of bytes).
    private static let maxElectronjsResponseBytes = 256 * 1024

    /// Size guard on the GitHub releases/latest body (sanity: the response can
    /// carry long release notes; multi-MB bodies indicate an unexpected shape).
    private static let maxGitHubReleaseBytes = 10 * 1024 * 1024

    private static let log = Logger(subsystem: "io.appupdater.AppUpdater", category: "electron")

    private let injectedURLProtocolClasses: [AnyClass]?

    public init() {
        injectedURLProtocolClasses = nil
    }

    /// Test/hermetic seam: URLProtocol classes injected into the session
    /// configuration so suite fixtures answer requests locally (Sparkle/MASSource
    /// pattern). Not used by production call sites (`ElectronSource()`).
    init(urlProtocolClasses: [AnyClass]) {
        injectedURLProtocolClasses = urlProtocolClasses
    }

    public static var kind: SourceKind { .unknown }

    public func fetchUpdateInfo(for app: InstalledApp) async throws -> UpdateInfo? {
        guard Self.detectsElectronBundle(atPath: app.path) else { return nil }

        if let claim = await claimFromAppUpdateYml(app) {
            return claim
        }
        return await claimFromAsar(app)
    }

    // MARK: - Detection (zero network)

    /// Detection (zero network): Electron Framework.framework exists AND
    /// (app-update.yml OR app.asar exists) — see the file-header policy.
    static func detectsElectronBundle(atPath path: String) -> Bool {
        let fileManager = FileManager.default
        let contentRoot = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
        let frameworkDirectory = contentRoot
            .appendingPathComponent("Frameworks", isDirectory: true)
            .appendingPathComponent("Electron Framework.framework", isDirectory: true)
        let appUpdateYml = contentRoot
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("app-update.yml")
        let appAsar = contentRoot
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("app.asar")

        guard fileManager.fileExists(atPath: frameworkDirectory.path) else { return false }
        return fileManager.fileExists(atPath: appUpdateYml.path)
            || fileManager.fileExists(atPath: appAsar.path)
    }

    // MARK: - Pipeline A: app-update.yml → latest-mac.yml

    private func claimFromAppUpdateYml(_ app: InstalledApp) async -> UpdateInfo? {
        let ymlPath = URL(fileURLWithPath: app.path, isDirectory: true)
            .appendingPathComponent("Contents/Resources/app-update.yml").path
        guard FileManager.default.fileExists(atPath: ymlPath) else { return nil }
        guard let ymlData = FileManager.default.contents(atPath: ymlPath) else { return nil }

        let config = ElectronYaml.parseAppUpdateYml(ymlData)
        guard let provider = config.provider?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return nil // no provider key → unresolvable for the yml route (Cue.app's real shape)
        }

        if provider == "github" {
            return await claimFromGithubProvider(owner: config.owner, repo: config.repo)
        }

        // Generic-style provider with a plain base url. HTTPS-only floor
        // (LOCKED decision 6): plain-http bases (the real localhost dev shape)
        // and url-less providers (s3/custom) never join here.
        guard var base = config.url?.trimmingCharacters(in: .whitespaces), !base.isEmpty,
              let baseURL = URL(string: base), baseURL.scheme?.lowercased() == "https" else {
            return nil
        }
        if !base.hasSuffix("/") { base += "/" }
        guard let ymlURL = URL(string: base + "latest-mac.yml") else { return nil }

        guard let body = await httpGet(ymlURL, accept: nil, maxBytes: Self.maxLatestMacYmlBytes) else {
            return nil
        }
        let latest = ElectronYaml.parseLatestMacYml(body)
        return claim(from: latest, ymlOrigin: ymlURL)
    }

    private func claimFromGithubProvider(owner: String?, repo: String?) async -> UpdateInfo? {
        guard let owner = Self.clean(owner), let repo = Self.clean(repo) else { return nil }
        // Brief-locked release API endpoint; percent-encode path segments so no
        // stray "/" can change the URL shape.
        let escapedOwner = owner.addingPercentEncoding(withAllowedCharacters: .rfc3986PathSegment) ?? owner
        let escapedRepo = repo.addingPercentEncoding(withAllowedCharacters: .rfc3986PathSegment) ?? repo
        guard let endpoint = URL(string: "https://api.github.com/repos/\(escapedOwner)/\(escapedRepo)/releases/latest") else {
            return nil
        }
        guard let body = await httpGet(endpoint, accept: Self.githubAcceptHeader, maxBytes: Self.maxGitHubReleaseBytes) else {
            return nil // non-200/malformed → pipeline B fallback per brief
        }
        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: body)
        } catch {
            return nil
        }
        // Asset named EXACTLY "latest-mac.yml" (documented choice; other yml
        // archive variants are v1-skipped — see the file header).
        guard let asset = release.assets?.first(where: { $0.name == "latest-mac.yml" }),
              let assetURLString = asset.browserDownloadUrl?.trimmingCharacters(in: .whitespaces),
              assetURLString.lowercased().hasPrefix("https://"),
              let ymlURL = URL(string: assetURLString) else {
            return nil
        }
        guard let ymlBody = await httpGet(ymlURL, accept: nil, maxBytes: Self.maxLatestMacYmlBytes) else {
            return nil
        }
        let latest = ElectronYaml.parseLatestMacYml(ymlBody)
        return claim(from: latest, ymlOrigin: ymlURL)
    }

    /// Builds the claim from parsed latest-mac.yml. `version` is REQUIRED —
    /// missing/blank version ⇒ nil (never synthesizes a version).
    private func claim(from latest: LatestMacYml, ymlOrigin: URL) -> UpdateInfo? {
        guard let version = Self.clean(latest.version) else { return nil }
        // First files[] entry with a usable url (document-order pick; the
        // arch-matching refinement is a documented v1 limitation — the file
        // header records it for merge review).
        let entry = latest.files.first { Self.clean($0.url) != nil }
        let resolvedFileURL: URL?
        if let entry, let entryURLString = Self.clean(entry.url) {
            resolvedFileURL = Self.resolvingFileURL(entryURLString, againstOriginDirectory: ymlOrigin)
        } else {
            resolvedFileURL = nil
        }

        let origin = ymlOrigin.absoluteString
        return UpdateInfo(
            source: .unknown,
            newestShortVersion: version,
            newestBundleVersion: nil, // latest-mac.yml has no CFBundleVersion equivalent
            downloadURL: resolvedFileURL,
            // ONLY SHA-512 exists upstream (Updatest §3.7); our installer
            // verifies SHA-256, so electron claims are info+manual BY DESIGN.
            sha256Hex: nil,
            minimumSystemVersion: nil, // not carried by latest-mac.yml — honest nil
            releaseDate: ElectronYaml.parseReleaseDate(latest.releaseDate),
            releaseNotes: Self.clean(latest.releaseName),
            confidence: .medium,
            // Verbatim honesty note required by the lane brief (split into
            // parts to keep every source line lint-clean):
            sourceDetail: Self.claimDetail(
                provenance: "electron-builder metadata from \(origin);",
                integrityClause: "only SHA-512 published upstream —")
        )
    }

    /// Relative `files[].url` names join the yml ORIGIN's directory; an
    /// absolute url (any scheme) wins verbatim. Malformed names → nil.
    static func resolvingFileURL(_ name: String, againstOriginDirectory origin: URL) -> URL? {
        if let absolute = URL(string: name), absolute.scheme?.isEmpty == false {
            return absolute
        }
        // Relative: join against the origin minus its last path component
        // (`…/stable/latest-mac.yml` ⇒ `…/stable/`), keeping the authority.
        var base = origin.deletingLastPathComponent().absoluteString
        if !base.hasSuffix("/") { base += "/" }
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .rfc3986PathSegment) else {
            return nil
        }
        return URL(string: base + encoded)
    }

    // MARK: - Pipeline B: app.asar → package.json → main → electronjs URL

    private func claimFromAsar(_ app: InstalledApp) async -> UpdateInfo? {
        let asarPath = URL(fileURLWithPath: app.path, isDirectory: true)
            .appendingPathComponent("Contents/Resources/app.asar").path
        guard FileManager.default.fileExists(atPath: asarPath) else { return nil }
        guard let archive = AsarReader.open(asarPath: asarPath) else { return nil }
        guard let packageJson = AsarReader.packageJsonData(in: archive, asarPath: asarPath) else { return nil }

        // Brief: "main" (default "index.js").
        let mainFile = Self.mainFile(fromPackageJson: packageJson)
        let segments = mainFile.split(separator: "/").map(String.init)
        guard !segments.isEmpty else { return nil }
        guard let mainBytes = AsarReader.readMember(segments, in: archive, asarPath: asarPath) else {
            return nil // main file missing from the header (real apps do this) — honest nil
        }

        guard let ownerRepo = Self.ownerRepo(fromMainScript: mainBytes) else { return nil }
        Self.log.notice(
            "electron asar probe matched update.electronjs.org for \(ownerRepo.owner, privacy: .public)/\(ownerRepo.repo, privacy: .public)"
        )

        // Brief-locked emulated probe platform template: darwin-arm64, with the
        // installed version when the scanner captured one, else "0.0.0" (the
        // documented probe fallback — some endpoints answer any version).
        let installedVersion = Self.clean(app.shortVersion) ?? Self.clean(app.bundleVersion) ?? "0.0.0"
        let escapedInstalled = installedVersion.addingPercentEncoding(withAllowedCharacters: .rfc3986PathSegment) ?? installedVersion
        guard let probe = URL(string: "https://update.electronjs.org/\(ownerRepo.owner)/\(ownerRepo.repo)/darwin-arm64/\(escapedInstalled)") else {
            return nil
        }
        guard let body = await httpGet(probe, accept: Self.githubAcceptHeader, maxBytes: Self.maxElectronjsResponseBytes) else {
            return nil
        }
        let answer: ElectronjsUpdate
        do {
            answer = try JSONDecoder().decode(ElectronjsUpdate.self, from: body)
        } catch {
            return nil
        }
        // version REQUIRED — never synthesize.
        guard let version = Self.clean(answer.version) else { return nil }
        // Optional url: HTTPS-only floor again (the electronjs service hands
        // out release-asset URLs; anything non-https is refused like every
        // other download surface on the LOCKED security floor).
        var downloadURL: URL?
        if let urlString = Self.clean(answer.url), let url = URL(string: urlString),
           url.scheme?.lowercased() == "https" {
            downloadURL = url
        }

        return UpdateInfo(
            source: .unknown,
            newestShortVersion: version,
            newestBundleVersion: nil,
            downloadURL: downloadURL,
            sha256Hex: nil, // no hash upstream; info+manual by design (see file header)
            minimumSystemVersion: nil,
            releaseDate: nil, // update.electronjs.org probes provide no date — honest nil
            releaseNotes: Self.clean(answer.name),
            confidence: .medium,
            // Honest provenance + the lane's honesty clause (adapted for this
            // upstream: no artifact hashes at all). Composed of joined parts
            // to keep every source line lint-clean.
            sourceDetail: Self.claimDetail(
                provenance: "electron self-update probe of \(ownerRepo.owner)/\(ownerRepo.repo)"
                    + " via update.electronjs.org (darwin-arm64 emulated probe from asar package.json/main);",
                integrityClause: "no artifact hashes published by this upstream —")
        )
    }

    /// The lane's honesty clause. Composes, byte-exact:
    ///   "<provenance> <integrityClause> automatic install disabled; the app
    ///    updates itself / manual staged install"
    /// The suffix is BY DESIGN for the whole lane (electron claims are
    /// info+manual — see the file header sha256Hex policy).
    static func claimDetail(provenance: String, integrityClause: String) -> String {
        provenance + " " + integrityClause
            + " automatic install disabled; the app updates itself / manual staged install"
    }

    // MARK: - Networking

    /// GET with the lane's headers and sane status/size gates. Returns the body
    /// when the status is 2xx and the size fits the guard, else nil. All the
    /// networked paths of this source converge here so "failure ⇒ nil" holds
    /// structurally (CaskSource-style honest nil, never a throw).
    private func httpGet(_ url: URL, accept: String?, maxBytes: Int) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let injected = injectedURLProtocolClasses {
            configuration.protocolClasses = injected
        }
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let payload: (data: Data, response: URLResponse)
        do {
            payload = try await session.data(for: request)
        } catch {
            return nil // network failure → honest nil
        }
        guard let http = payload.response as? HTTPURLResponse else { return nil }
        guard (200..<300).contains(http.statusCode) else { return nil }
        guard payload.data.count <= maxBytes else { return nil }
        return payload.data
    }

    // MARK: - Extraction helpers (internal for hermetic tests)

    /// package.json `main`, defaulting to "index.js" when absent/unreadable
    /// (per brief). Normalizes "./x" → "x" and skips interior "." segments so
    /// the rebuilt segment list matches the header files tree.
    static func mainFile(fromPackageJson data: Data) -> String {
        var name = "index.js"
        if let tree = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let declared = tree["main"] as? String {
            let trimmed = declared.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { name = trimmed }
        }
        let parts = name.split(separator: "/").filter { $0 != "." }
        return parts.joined(separator: "/")
    }

    /// Updatest's TWO AsarReader regexes, joined into the v1 policy above:
    /// each regex contributes its FIRST capture; candidates are tried in
    /// Updatest-first-match order and only an https://update.electronjs.org
    /// URL yields owner/repo (the `{platform}/{version}` suffix is stripped by
    /// construction — only the first two path segments after the host are
    /// taken).
    static func ownerRepo(fromMainScript bytes: Data) -> (owner: String, repo: String)? {
        let text = String(decoding: bytes, as: UTF8.self)
        var candidates: [String] = []
        // Regex 1: updateURL\s*[=:]\s*['"`]([^'"`]+)['"`]
        if let hit = Self.regexFirstCapture(
            pattern: #"updateURL\s*[=:]\s*['"`]([^'"`]+)['"`]"#, in: text) {
            candidates.append(hit)
        }
        // Regex 2: ['"`](https?://update\.electronjs\.org/[^'"`]+)['"`]
        if let hit = Self.regexFirstCapture(
            pattern: #"['"`](https?://update\.electronjs\.org/[^'"`]+)['"`]"#, in: text) {
            candidates.append(hit)
        }

        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: trimmed) else { continue }
            guard url.scheme?.lowercased() == "https" else { continue } // LOCKED floor
            guard let host = url.host, host.lowercased().hasSuffix("update.electronjs.org") else { continue }
            let segments = url.pathComponents.filter { $0 != "/" }
            guard segments.count >= 2 else { continue }
            let owner = segments[0]
            let repo = segments[1]
            guard !owner.isEmpty, !repo.isEmpty else { continue }
            let encodedOwner = owner.addingPercentEncoding(withAllowedCharacters: .rfc3986PathSegment) ?? owner
            let encodedRepo = repo.addingPercentEncoding(withAllowedCharacters: .rfc3986PathSegment) ?? repo
            return (encodedOwner, encodedRepo)
        }
        return nil
    }

    /// First match's capture group 1, or nil (Updatest's first-match policy).
    static func regexFirstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              match.range(at: 1).location != NSNotFound,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// Minimal decode of the electronjs probe response: `{name, version, url?}` —
/// version REQUIRED by the caller; url optional.
private struct ElectronjsUpdate: Decodable {
    var name: String?
    var version: String?
    var url: String?
}

/// Minimal decode of the GitHub releases/latest response — only the assets
/// array's name + browser_download_url matter (live-shape field names:
/// "assets"[].{"name","browser_download_url"}, sample: stablyai/orca release
/// JSON, 2026-10-27 lane probe).
private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        var name: String?
        var browserDownloadUrl: String?
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }
    var assets: [Asset]?
}

private extension CharacterSet {
    /// RFC 3986 path `pchar` set WITHOUT "/" — used to percent-encode RELATIVE
    /// artifact file names and owner/repo segments so that no stray "/" can
    /// change the join structure (URLPathAllowed keeps "/" unescaped, which is
    /// wrong for a single path segment).
    static var rfc3986PathSegment: CharacterSet {
        CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@")
    }
}
