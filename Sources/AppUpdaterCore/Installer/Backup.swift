// Backup.swift — pre-swap ZIP backup of the OLD .app bundle (installer step `.backup`).
// Installer lane (backup only). Frozen interchange types live in InstallModels.swift
// (coordinator-owned); this file only implements over them.
//
// Format policy (deliberate divergence, documented — NOT a frozen-type change):
// docs/MACUPDATER-BREAKDOWN.md §1.5 step 5 describes MacUpdater's BackupHelper as
// "DMG (hdiutil) default, ZIP optional". v1 here is ZIP-only (`ditto -c -k --keepParent`);
// DMG/hdiutil backups are reserved for the later hdiutil lane (phase 7 scope). No format
// field was added to the frozen `BackupReceipt` — the format is a property of this
// implementation, stated here instead of inventing an extra field to read.

import Foundation

/// ZIP-only backup of installed apps before the installer swaps their bundle
/// (MacUpdater `BackupHelper` zip-policy variant).
///
/// Layout: `backupsRoot/<bundleIdSanitized>/<isoTimestamp>-<safeName>.zip`
/// - `<bundleIdSanitized>`: `InstalledApp.bundleIdentifier` with `/` and `:` replaced by
///   `_` — one flat per-app folder; the same characters are escaped in bundle names too
///   (Finder stores a display-name `/` as a literal `:` on disk, so it must not be
///   treated as path material either).
/// - `<isoTimestamp>`: the backup's UTC creation time as `2026-10-26T103000Z`
///   (`yyyy-MM-dd'T'HHmmss'Z'`). **Retention orders by this token in the file name —
///   never by filesystem mtime** (mtime moves when files are copied/touched).
/// - `<safeName>`: the app bundle's base name (e.g. `Fixture.app`), escaped as above.
///
/// Same-second collisions do not overwrite: a ` -2` (then ` -3`, …) is inserted before
/// the `.zip` extension until an unused name is found. Deterministic and honest — no
/// existing backup is ever clobbered by a later one.
///
/// Before a receipt is returned, the zip is verified for real: it exists, its size is
/// > 0, and a listing of it contains `<bundleBaseName>/`. Any failed check deletes the
/// partial zip and throws `InstallerError.backupFailed` (with the tool stderr excerpt on
/// the failure path).
///
/// Listing deviation (flagged in the lane report): the brief's `ditto -l <zipPath>` does
/// not exist on this toolchain — or any macOS — so ditto cannot list an archive at all.
/// ditto(1)'s own manual prescribes `unzip -l archive.zip` for PKZip listing, so that
/// system verb (`/usr/bin/unzip`, no extra permissions) performs the check. Creation and
/// extraction still use ditto exclusively.
public struct BackupManager: Sendable {
    public init() {}

    // MARK: - Backup

    /// Zips the OLD app bundle at `app.path` into `backupsRoot` and returns a receipt
    /// describing exactly what was preserved.
    ///
    /// The original short/bundle versions are re-read from the bundle's Info.plist at
    /// backup time (fresh truth on disk — not the scan-time fields), matching the
    /// scanner's property-list reading style (`InfoProbe`, no bundle cache involvement).
    /// If the target file exists (same-second backup), the name gains ` -2`, ` -3`, …
    /// before `.zip` instead of overwriting.
    ///
    /// - Throws: `InstallerError.backupFailed(reason:)` when ditto fails or any
    ///   verification check fails; the partial zip is deleted in both cases.
    public func backup(app: InstalledApp, into backupsRoot: URL) async throws -> BackupReceipt {
        try await backup(app: app, into: backupsRoot, at: Date())
    }

    /// Internal seam for deterministic tests: backs up as if performed at `createdAt`.
    /// The public `backup(app:into:)` is this with the current time — no divergence.
    func backup(app: InstalledApp, into backupsRoot: URL, at createdAt: Date) async throws -> BackupReceipt {
        let folderName = Self.sanitizedFolderName(forBundleIdentifier: app.bundleIdentifier)
        guard !folderName.isEmpty else {
            throw InstallerError.backupFailed(
                reason: "app has no usable bundle identifier to derive the backup folder name from")
        }
        var folderIsDirectory: ObjCBool = false
        let folderExistedBefore = FileManager.default.fileExists(
            atPath: backupsRoot.appendingPathComponent(folderName).path(percentEncoded: false),
            isDirectory: &folderIsDirectory) && folderIsDirectory.boolValue
        let folderURL = backupsRoot.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let target = Self.uniqueZipPath(in: backupsRoot, app: app, for: createdAt)
        let appPath = app.path

        let compression = try Self.runProcess(
            executable: "/usr/bin/ditto",
            arguments: ["-c", "-k", "--keepParent", appPath, target.path(percentEncoded: false)])
        guard compression.terminationStatus == 0 else {
            throw Self.backupFailed(
                reason: "ditto exited with status \(compression.terminationStatus): "
                    + Self.excerpt(compression.stderr),
                zipURL: target,
                folderURL: folderURL,
                folderCreated: !folderExistedBefore)
        }

        // Verification 1+2: exists and is non-empty (byte size, not just entry presence).
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: target.path(percentEncoded: false))
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount > 0 else {
            throw Self.backupFailed(
                reason: "backup zip is absent or zero bytes after ditto: "
                    + target.path(percentEncoded: false),
                zipURL: target,
                folderURL: folderURL,
                folderCreated: !folderExistedBefore)
        }

        // Verification 3: the listing shows the bundle's own base name, i.e. the archive
        // really wraps the .app directory (`--keepParent` produces `<name>.app/...`).
        // unzip -l prints one row per zip entry; ditto -x would also suffice but a
        // listing is read-only and cheaper (pure central-directory read).
        let bundleBaseName = (appPath as NSString).lastPathComponent
        let listing = try Self.runProcess(
            executable: "/usr/bin/unzip",
            arguments: ["-l", target.path(percentEncoded: false)])
        let listingText = listing.stdout
        guard listing.terminationStatus == 0,
              listingText.contains("\(bundleBaseName)/")
        else {
            throw Self.backupFailed(
                reason: "backup zip does not verify: listing has no '\(bundleBaseName)/' "
                    + "entry (listing excerpt: "
                    + Self.excerpt(listingText.isEmpty ? listing.stderr : listingText) + ")",
                zipURL: target,
                folderURL: folderURL,
                folderCreated: !folderExistedBefore)
        }

        // Versions: fresh off disk at backup time (InfoProbe reads the plist directly,
        // never Bundle's process-wide cache; hermetic bundles need only Contents/).
        let plist = InfoProbe.infoDictionary(appBundleURL: URL(fileURLWithPath: appPath))
        return BackupReceipt(
            zipURL: target,
            originalPath: appPath,
            originalShortVersion: InfoProbe.string(for: ["CFBundleShortVersionString"], in: plist),
            originalBundleVersion: InfoProbe.string(for: ["CFBundleVersion"], in: plist),
            createdAt: createdAt,
            byteCount: byteCount)
    }

    // MARK: - Retention

    /// Deletes the oldest managed backup zips beyond the newest `n`, returning the
    /// deleted paths.
    ///
    /// Housekeeping contract:
    /// - **Managed zips only**: regular files directly inside a per-app subfolder of
    ///   `backupsRoot` whose name is `<18-char timestamp token>-<anything>.zip`
    ///   (`2026-10-26T103000Z` prefix). Anything else — foreign files, non-zip payloads,
    ///   files sitting loose in the root — is left untouched.
    /// - **Newest first by the token in the name** (lexical on the fixed-width token ==
    ///   chronological; never mtime). Same-token ties break by file name ascending.
    ///   The resulting order is total and machine-independent.
    /// - `n` is global across all per-app folders (one retention quota for the store).
    ///   `n <= 0` clears every managed zip.
    /// - Returned paths are POSIX strings in deletion order (the excess tail of the
    ///   newest-first sort, i.e. progressively older). An unused backups root returns
    ///   `[]`; an unreadable root throws.
    public func keepLatest(_ n: Int, in backupsRoot: URL) async throws -> [String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: backupsRoot.path(percentEncoded: false), isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return [] // housekeeping over an unused store: nothing to keep, nothing lost
        }

        var managed: [(token: String, fileName: String, folderURL: URL)] = []
        for folder in try FileManager.default.contentsOfDirectory(
            at: backupsRoot, includingPropertiesForKeys: nil, options: []) {
            var folderIsDirectory: ObjCBool = false
            let folderPath = folder.path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: folderPath, isDirectory: &folderIsDirectory),
                  folderIsDirectory.boolValue
            else { continue }
            for entry in try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: []) {
                let fileName = entry.lastPathComponent
                var entryIsDirectory: ObjCBool = false
                guard let token = Self.managedTimestampToken(ofFileName: fileName),
                      FileManager.default.fileExists(
                        atPath: folder.appendingPathComponent(fileName).path(percentEncoded: false),
                        isDirectory: &entryIsDirectory),
                      !entryIsDirectory.boolValue
                else { continue }
                managed.append((token, fileName, folder))
            }
        }

        // Newest first: token descending (== chronological), name ascending on ties.
        managed.sort {
            if $0.token != $1.token { return $0.token > $1.token }
            return $0.fileName < $1.fileName
        }

        var deleted: [String] = []
        for record in managed.dropFirst(max(0, n)) {
            let fileURL = record.folderURL.appendingPathComponent(record.fileName)
            try FileManager.default.removeItem(at: fileURL)
            deleted.append(fileURL.path(percentEncoded: false))
        }
        return deleted
    }

    // MARK: - Restore hint (documentation-level)

    /// Human instruction for restoring a receipt's backup. Returned text only — the
    /// restore itself stays a user action (the affected app must be quit first).
    public func restoreHint(for receipt: BackupReceipt) -> String {
        let bundleName = (receipt.originalPath as NSString).lastPathComponent
        let parentFolder = (receipt.originalPath as NSString).deletingLastPathComponent
        return "To restore this backup, quit \"\(bundleName)\" first — a restored bundle "
            + "moved onto a running app corrupts it. Then run:\n\n"
            + "    ditto -x -k \"\(receipt.zipURL.path(percentEncoded: false))\" \"\(parentFolder)\"\n\n"
            + "The bundle reappears at \"\(receipt.originalPath)\". If that path is still "
            + "occupied by the new install, move that copy aside first."
    }

    // MARK: - Naming policy (internal; deterministic + reused by tests)

    /// UTC timestamp token, fixed width (`2026-10-26T103000Z`). Built per call —
    /// DateFormatter is not Sendable, so no shared mutable formatter instance.
    static func timestampToken(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    /// Path segment safe for a per-app folder: `/` and `:` become `_` (a bundle id
    /// containing `/` would otherwise nest folders; `:` is illegal in Finder names).
    static func sanitizedFolderName(forBundleIdentifier bundleIdentifier: String) -> String {
        bundleIdentifier
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    /// File-name-safe version of the app bundle's base name (same escapes as above —
    /// Finder's `/`-in-display-name trick lands as a literal `:` on POSIX disk).
    static func escapedSafeName(forBundleBaseName baseName: String) -> String {
        baseName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    /// Quote-free name base for zip files: `<token>-<safeName>.zip`.
    static func zipFileName(for date: Date, bundleBaseName: String) -> String {
        "\(timestampToken(for: date))-\(escapedSafeName(forBundleBaseName: bundleBaseName)).zip"
    }

    /// The (uniqued) target zip URL for a backup performed at `date`.
    static func zipPath(in backupsRoot: URL, app: InstalledApp, for date: Date) -> URL {
        let folderURL = backupsRoot.appendingPathComponent(
            sanitizedFolderName(forBundleIdentifier: app.bundleIdentifier))
        let bundleBaseName = (app.path as NSString).lastPathComponent
        let fileName = zipFileName(for: date, bundleBaseName: bundleBaseName)
        return folderURL.appendingPathComponent(fileName)
    }

    /// Same as `zipPath`, but walks ` -2`, ` -3`, … after the base name (before the
    /// `.zip` extension) until a nonexistent path is found — never overwrites.
    static func uniqueZipPath(in backupsRoot: URL, app: InstalledApp, for date: Date) -> URL {
        let base = zipPath(in: backupsRoot, app: app, for: date)
        let baseName = base.lastPathComponent
        let stem = baseName.hasSuffix(".zip") ? String(baseName.dropLast(4)) : baseName
        var sequence = 1
        var current = base
        while FileManager.default.fileExists(atPath: current.path(percentEncoded: false)) {
            sequence += 1
            let candidate = baseName.hasSuffix(".zip")
                ? "\(stem) -\(sequence).zip"
                : "\(stem)-\(sequence)"
            current = base.deletingLastPathComponent().appendingPathComponent(candidate)
        }
        return current
    }

    /// The 18-char timestamp token underpinning a managed backup name, or nil when the
    /// file name does not match the `<token>-<anything>.zip` policy (fixed widths and
    /// separators checked explicitly — no regex, no locale).
    static func managedTimestampToken(ofFileName fileName: String) -> String? {
        guard fileName.count > 19, fileName.hasSuffix(".zip") else { return nil }
        let token = String(fileName.prefix(18))
        let chars = Array(token)
        func digit(_ i: Int) -> Bool { chars[i].isASCII && chars[i].isNumber }
        let year = (0...3).allSatisfy(digit)
        let month = digit(5) && digit(6)
        let day = digit(8) && digit(9)
        let time = (11...16).allSatisfy(digit)
        let separators = chars[4] == "-" && chars[7] == "-"
            && chars[10] == "T" && chars[17] == "Z"
        guard year, month, day, time, separators else { return nil }
        return token
    }

    // MARK: - Process plumbing

    private struct ProcessOutcome: Sendable {
        var terminationStatus: Int32
        var stdout: String
        var stderr: String
    }

    /// Runs a system tool to completion, then reports its full stdout/stderr streams.
    ///
    /// Process has no completion-style wait beyond `waitUntilExit`, so this blocks one
    /// cooperative thread for the child's lifetime (ditto create and unzip -l are
    /// seconds at most). Pipe reads happen in the same task, stdout first: both tools
    /// write at most a couple of lines to **stderr** even on failure (it cannot fill the
    /// 64 KiB pipe buffer while stdout drains), while stdout scales with zip entry count
    /// (`unzip -l` lists one row per file) — draining it first is what makes this
    /// deadlock-free for large bundles. A tool with stream-scale stderr would need
    /// concurrent draining instead.
    private static func runProcess(executable: String, arguments: [String]) throws -> ProcessOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let stdoutData = try stdout.fileHandleForReading.readToEnd() ?? Data()
        let stderrData = try stderr.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        return ProcessOutcome(
            terminationStatus: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self))
    }

    /// Failure-path cleanup for `backup`: best-effort removal of everything THIS call
    /// created — the partial zip, plus a per-app folder when the call itself created it
    /// and nothing landed in it meanwhile (pre-existing or non-empty folders are never
    /// touched; a parallel backup racing us makes the folder non-empty). Cleanup must
    /// never mask the original failure, so errors are swallowed here while the real
    /// `InstallerError.backupFailed` is returned to be thrown by the caller.
    private static func backupFailed(reason: String, zipURL: URL, folderURL: URL, folderCreated: Bool) -> InstallerError {
        try? removeFileIfPresent(at: zipURL)
        if folderCreated,
           let remaining = try? FileManager.default.contentsOfDirectory(
            atPath: folderURL.path(percentEncoded: false)),
           remaining.isEmpty {
            try? FileManager.default.removeItem(at: folderURL)
        }
        return InstallerError.backupFailed(reason: reason)
    }

    /// Deletes the file at `url` when it exists (no-op otherwise).
    private static func removeFileIfPresent(at url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false),
                                          isDirectory: &isDirectory) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Collapses multi-line tool output to a bounded single-line excerpt for error text.
    private static func excerpt(_ text: String, limit: Int = 200) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else {
            return trimmed.replacingOccurrences(of: "\n", with: " ⏎ ")
        }
        let clipped = String(trimmed.prefix(limit))
        return (clipped + "…").replacingOccurrences(of: "\n", with: " ⏎ ")
    }
}
