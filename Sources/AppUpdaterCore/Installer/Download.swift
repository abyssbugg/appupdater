// Download tier of the installer: user-space streaming download with the
// LOCKED security floor baked in (AGENTS.md decision 6 — HTTPS-only; sha256
// verified before any replace; no http fallback, ever).
//
// Policy summary (mirrors MacUpdater's HTTPDownloader +
// SecurityDisallowHTTPConnections / SecurityDisallowUnexpectedChecksum in
// user space, per docs/MACUPDATER-BREAKDOWN.md §1.5 step 2–3):
//
//   - Fail-fast preflight BEFORE any network attempt: nil downloadURL →
//     .unsupportedArtifact; non-https scheme → .httpsRequired; unmapped file
//     extension → .unsupportedArtifact; missing sha256 → .sha256Missing.
//     Refusals therefore never touch the network.
//   - Streaming to disk: the response is consumed as an async byte sequence
//     and flushed to a FileHandle in fixed chunks — the whole artifact is
//     never buffered in memory. The sha256 digest is computed WHILE writing,
//     chunk by chunk (CryptoKit Insecure.SHA256).
//   - If the response carries Content-Length, the received byte count is
//     cross-checked afterwards (mismatch → transport error).
//   - Zip artifacts must start with the PK\x03\x04 signature. DMG honesty:
//     DMGs carry NO leading magic — only the extension is checked here;
//     DMG authenticity is confirmed at MOUNT time by the deploy lane.
//   - MISSING EdDSA install-path decision (documented, deliberate): an update
//     without a sha256 is refused outright with InstallerError.sha256Missing.
//     Sparkle EdDSA verification is Phase 5's job and is NOT active in the v1
//     installer, so a source-provided digest is the only acceptable proof.
//   - Error surfaces: InstallerError is the FROZEN artifact-semantics contract
//     (InstallModels.swift); transport failures (non-2xx status, mid-stream
//     drops, Content-Length mismatch, no HTTP response) therefore surface as
//     URLError(.badServerResponse) with honest descriptions. No transport case
//     is added to the frozen enum from this lane.
//   - Cleanup discipline: any failure AFTER the staging file is created
//     deletes it — no half-artifacts are left behind. Non-2xx statuses throw
//     before the file exists at all, leaving the staging directory untouched.

import CryptoKit
import Foundation

/// Downloads an update artifact into a staging directory and verifies it
/// against the source-provided sha256 (and the zip magic for zips).
public struct UpdateDownloader: Sendable {

    private let session: URLSession

    /// Injectable for testing (hermetic URLSessionConfiguration +
    /// URLProtocol stubs); default `.shared` — mirrors CaskSource's seam.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    private static let userAgent = "AppUpdater/0.1 (macOS)"
    /// Stream-buffer size: bytes accumulate here before flushing to disk.
    private static let streamChunkSize = 1_048_576 // 1 MiB
    /// Zip signature bytes — the sanity gate for .zip artifacts.
    private static let zipMagic = Data([0x50, 0x4B, 0x03, 0x04]) // "PK\x03\x04"
    /// Flat packages (`.pkg`) are xar archives — leading magic "xar!".
    /// (Bundle-style pkg payloads are still caught here; the command-staging
    /// step additionally tells the owner exactly which file will be installed.)
    private static let pkgMagic = Data([0x78, 0x61, 0x72, 0x21]) // "xar!"

    /// Streams `update`'s artifact into `dir` and verifies it. On success
    /// returns the staged file; on any verified failure the staging file is
    /// removed. The order of checks decides which error wins when several
    /// policy violations coexist — earlier refusals never make a request:
    ///
    ///   1. nil downloadURL              → InstallerError.unsupportedArtifact
    ///   2. non-https scheme             → InstallerError.httpsRequired (no request)
    ///   3. unmapped file extension      → InstallerError.unsupportedArtifact (no request)
    ///   4. sha256 missing/whitespace    → InstallerError.sha256Missing   (no request)
    ///   5. non-2xx HTTP status (404…)   → URLError(.badServerResponse)    (file never created)
    ///   6. Content-Length ≠ received    → URLError(.badServerResponse)    (file removed)
    ///   7. digest mismatch              → InstallerError.sha256Mismatch   (file removed)
    ///   8. zip NOT starting PK\x03\x04 / pkg NOT starting "xar!"
    ///                                 → InstallerError.magicMismatch   (file removed)
    public func downloadAndVerify(from update: UpdateInfo, into dir: URL) async throws -> DownloadedUpdate {
        guard let url = update.downloadURL else {
            throw InstallerError.unsupportedArtifact(reason: "missing download URL")
        }
        guard url.scheme?.lowercased() == "https" else {
            throw InstallerError.httpsRequired(url: url.absoluteString)
        }
        // ONE kind resolver for plan AND execution: `InstallPlanner.kind(from:)`
        // (path extension, else a query-string hint for extensionless URLs such
        // as Warp's `…/download/brew?…&package=dmg`). Before 2026-10-30 the
        // downloader read only the path extension, so a plan the planner
        // accepted was refused here at execution time. `kindFromExtension`
        // stays the source of the honest refusal message when neither yields.
        let kind = try InstallPlanner.kind(from: url) ?? Self.kindFromExtension(url: url)

        // Digest comparisons are case-insensitive hex: normalize BOTH sides
        // before comparing whatever formatting the source used.
        let expectedHex = Checksum.normalizeHex(update.sha256Hex ?? "")
        guard !expectedHex.isEmpty else {
            throw InstallerError.sha256Missing(what: update.source.rawValue)
        }

        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        // HTTPS floor across REDIRECTS (LOCKED decision 6): the task delegate
        // refuses any hop to a non-https URL before that request is made (the
        // 3xx is then delivered as the final response and refused below as
        // non-2xx); the final-URL check is defense in depth.
        let (stream, response) = try await session.bytes(for: request, delegate: HTTPSOnlyRedirectDelegate())
        guard let http = response as? HTTPURLResponse else {
            throw Self.downloadFailed(status: -1, url: url.absoluteString, detail: "did not receive an HTTP response")
        }
        if let finalURL = http.url, finalURL.scheme?.lowercased() != "https" {
            throw InstallerError.httpsRequired(url: finalURL.absoluteString)
        }
        // Non-2xx (404s included) throws BEFORE the staging file exists —
        // nothing is ever written for a status we do not accept.
        guard (200..<300).contains(http.statusCode) else {
            throw Self.downloadFailed(status: http.statusCode, url: url.absoluteString, detail: "status not accepted")
        }
        // Missing or unparseable Content-Length (chunked responses) → no cross-check.
        let declaredLength = Int64(http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) } ?? -1)

        let stagedURL = dir.appendingPathComponent(Self.stagedFilename(from: url, kind: kind))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // A leftover from an aborted prior run could tail PAST the fresh
            // write (we write from offset 0 over old bytes); start from
            // nothing so the staged file is exactly the received stream.
            try? FileManager.default.removeItem(at: stagedURL)
            FileManager.default.createFile(atPath: stagedURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: stagedURL)

            // Same Xcode-27-beta adaptation as Checksum.swift: the
            // `Insecure.SHA256` spelling dropped from the SDK; top-level
            // `SHA256` is the identical hash (it was an alias, nothing else).
            var hasher = SHA256()
            var received: Int64 = 0
            var chunk = Data()
            chunk.reserveCapacity(Self.streamChunkSize)
            do {
                for try await byte in stream {
                    chunk.append(byte)
                    if chunk.count >= Self.streamChunkSize {
                        hasher.update(data: chunk)
                        try handle.write(contentsOf: chunk)
                        received += Int64(chunk.count)
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                if !chunk.isEmpty {
                    hasher.update(data: chunk)
                    try handle.write(contentsOf: chunk)
                    received += Int64(chunk.count)
                }
                try handle.close()
            } catch {
                // Disk or stream failure — surface so the outer catch cleans up.
                try? handle.close()
                throw error
            }

            if declaredLength > 0, declaredLength != received {
                throw Self.downloadFailed(
                    status: http.statusCode,
                    url: url.absoluteString,
                    detail: "content-length mismatch: declared \(declaredLength) bytes, received \(received)"
                )
            }

            let actualHex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard actualHex == expectedHex else {
                throw InstallerError.sha256Mismatch(expected: expectedHex, actual: actualHex)
            }

            // Magic sanity gate — zips + pkgs. DMGs have no leading magic:
            // authenticity is confirmed at MOUNT time by the deploy lane
            // (honest boundary, not a gap the installer papers over).
            switch kind {
            case .zip:
                try Self.verifyZipMagic(at: stagedURL)
            case .pkg:
                try Self.verifyPKGMagic(at: stagedURL)
            case .dmg:
                break
            }

            return DownloadedUpdate(stagedURL: stagedURL, kind: kind, expectedSha256Hex: expectedHex)
        } catch {
            // ANY failure after the staging file was created removes it.
            try? FileManager.default.removeItem(at: stagedURL)
            throw error
        }
    }

    // MARK: - Mapping + static helpers (internal; test-visible via @testable)

    /// Artifact kind by file extension. v1 handles .dmg and .zip in user
    /// space; .pkg joined 2026-10-27 as the staged-owner-command kind
    /// (download + verify + leave staged + print the sudo command — the
    /// installer is never executed here). Anything else (tbz/tgz/bin, or no
    /// extension at all) is an honest hard error.
    static func kindFromExtension(url: URL) throws -> InstallKind {
        let filename = url.lastPathComponent.lowercased()
        let ext: String
        if let dot = filename.lastIndex(of: "."), filename.index(after: dot) < filename.endIndex {
            ext = String(filename[filename.index(after: dot)...])
        } else {
            ext = ""
        }
        switch ext {
        case "dmg":
            return .dmg
        case "zip":
            return .zip
        case "pkg":
            return .pkg
        default:
            let shown = ext.isEmpty ? "none" : ext
            throw InstallerError.unsupportedArtifact(
                reason: "file extension '\(shown)' — v1 installs .dmg and .zip in user space; "
                    + ".pkg is staged for an owner-run `sudo installer` command; "
                    + "tbz/tgz/bin are refused outright"
            )
        }
    }

    /// Staging filename: the URL's last path component (percent-decoded).
    /// A URL without a file component stages under a neutral name, which the
    /// extension gate then refuses — no extension is ever invented here.
    static func resolvedFilename(from url: URL) -> String {
        let component = url.lastPathComponent
        guard !component.isEmpty, component != "/" else { return "download.bin" }
        return component
    }

    /// The staged file name: the URL's last path component, suffixed with the
    /// resolved kind when the path itself does not already carry it (query-hint
    /// URLs: `…/download/brew?package=dmg` → `brew.dmg`), so every staged
    /// artifact's extension tells downstream tools what it is.
    static func stagedFilename(from url: URL, kind: InstallKind) -> String {
        let base = resolvedFilename(from: url)
        let suffix = "." + kind.rawValue
        return base.lowercased().hasSuffix(suffix) ? base : base + suffix
    }

    /// Zip sanity check: a staged zip MUST start with PK\x03\x04. Anything
    /// else (empty file, tampered prefix, HTML error page, …) is
    /// .magicMismatch — the staged file itself is removed by the caller.
    static func verifyZipMagic(at stageURL: URL) throws {
        let handle = try FileHandle(forReadingFrom: stageURL)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: zipMagic.count) ?? Data()
        guard head.starts(with: zipMagic) else {
            throw InstallerError.magicMismatch(reason: "staged zip does not start with the PK\\x03\\x04 signature")
        }
    }

    /// Pkg sanity check: a flat package is an xar archive and MUST start with
    /// "xar!". Anything else is .magicMismatch — the staged file is removed by
    /// the caller. (This is a byte check only; signature validation of the
    /// pkg is `pkgutil --check-signature`, which is the OWNER's step — the
    /// printed command can be reviewed before it is ever run.)
    static func verifyPKGMagic(at stageURL: URL) throws {
        let handle = try FileHandle(forReadingFrom: stageURL)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: pkgMagic.count) ?? Data()
        guard head.starts(with: pkgMagic) else {
            throw InstallerError.magicMismatch(reason: "staged pkg does not start with the xar! signature")
        }
    }

    /// Honest transport-error surface (see file header): URLError carries the
    /// status + detail in its description; InstallerError stays frozen.
    private static func downloadFailed(status: Int, url: String, detail: String) -> URLError {
        URLError(.badServerResponse, userInfo: [
            NSLocalizedDescriptionKey: "download failed: HTTP \(status) from \(url) (\(detail))"
        ])
    }
}

/// Per-task redirect guard for artifact downloads (LOCKED decision 6: HTTPS
/// only). URLSession follows redirects silently by default — including an
/// https → http downgrade — so every hop is vetted here: a non-https target
/// is refused (nil = do not follow), which surfaces the 3xx itself as the
/// final response, refused by the caller's 2xx gate. No request is ever sent
/// to the downgraded URL.
final class HTTPSOnlyRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        request.url?.scheme?.lowercased() == "https" ? request : nil
    }
}
