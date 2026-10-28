// Deploy.swift — Deploy lane (H): turn a downloaded artifact into a staged app bundle.
//
// Contract (docs/MACUPDATER-BREAKDOWN.md §1.5 + lane brief):
//   .zip  → `ditto -x -k zip stagingDir`, then find the ONE .app inside.
//   .dmg  → `hdiutil attach <dmg> -nobrowse -readonly -quiet -mountpoint <empty dir>`
//           (explicit mountpoint = no volume guessing), find the app inside the mount,
//           copy it OUT via `ditto` (preserves attrs + mtimes), THEN detach. The mount
//           is detached on EVERY path — success, error, even the copy failing — the
//           defer-style wrapper below guarantees it; a mount is never left behind.
//
// Documented divergences:
//   • Exactly-one .app rule: 0 found OR **≥2** found both throw
//     InstallerError.noAppFoundInArtifact(kind:) — the brief prescribes this reuse
//     even for the plurality case (the frozen error enum has no "too many candidates"
//     case; MacUpdater's own messages separated the two).
//   • Nested-helper exclusion: descent stops at the first .app boundary so an app's
//     own embedded bundles (LoginItems helpers etc.) don't register as candidates.
//   • hdiutil attach failure → InstallerError.unsupportedArtifact(reason:).
//   • DMG staging layout: the .app is copied out at its *mount-relative path*, so the
//     staging tree mirrors the image layout. A volume root that IS itself the .app
//     cannot be expressed this way → unsupportedArtifact (honest v1 limitation).
//   • Deploy does NOT read or judge quarantine state (frozen DeployedBundle has no
//     note field; the swap step's record covers identity claims — lane brief).
//   • Deploy is dumb-but-safe extraction: it does NOT bundle-identifier-match the
//     staged app against any target (that is the swap + post-scan's job).

import Foundation

/// Result of AppSwapper.swap — reports where the old app was moved aside.
/// Local to the Deploy lane per the brief (not shared; lanes' private result types
/// may coexist). The old copy is RETAINED at that path by policy: disposition
/// (trash) belongs to the Integration lane's coordinator step, not to the swap.
public struct SwapResult: Sendable {
    public let oldAppMovedTo: String

    public init(oldAppMovedTo: String) {
        self.oldAppMovedTo = oldAppMovedTo
    }
}

/// Deploy lane's public entry: artifact → staged .app bundle.
public enum BundleDeployer {
    /// Extracts `updated`'s staged artifact into `stagingDir` and returns the single
    /// .app bundle found. `stagingDir` is created if missing; it should be fresh —
    /// a pre-populated one surfaces stale bundles as ambiguous-candidate errors.
    public static func deploy(from updated: DownloadedUpdate, into stagingDir: URL) async throws -> DeployedBundle {
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let stagedAppURL: URL
        switch updated.kind {
        case .zip:
            stagedAppURL = try await extractZip(at: updated.stagedURL, into: stagingDir)
        case .dmg:
            stagedAppURL = try await extractDmg(at: updated.stagedURL, into: stagingDir)
        case .pkg:
            // UNREACHABLE by construction: a pkg plan ends at .stageOwnerCommand
            // (the coordinator's staged-PKG branch terminates before any backup/
            // deploy step). Seeing one here means the coordinator's step order
            // regressed — honest error, never a silent guess.
            throw InstallerError.unsupportedArtifact(
                reason: "pkg is never deployed: the staged-PKG branch must terminate before deploy (coordinator sequencing bug)")
        }
        return DeployedBundle(stagedAppURL: stagedAppURL, kind: updated.kind)
    }

    // MARK: - Artifact kinds

    /// .zip: `ditto -x -k <zip> <stagingDir>` (ditto honors Store64/Zip resource forks
    /// and preserves attrs/mtimes), then exactly-one .app search over stagingDir.
    /// The found app is left exactly where extraction placed it (zip layout IS the
    /// staging layout) — no extra move, no extra copy.
    private static func extractZip(at zipURL: URL, into stagingDir: URL) async throws -> URL {
        let run = try await runProcess(launchPath: "/usr/bin/ditto", arguments: [
            "-x", "-k", zipURL.path, stagingDir.path,
        ])
        guard run.succeeded else {
            throw InstallerError.unsupportedArtifact(
                reason: "ditto zip extraction failed (exit \(run.exitStatus)): \(run.stderr)")
        }
        return try soleAppBundle(in: stagingDir, artifactKind: .zip)
    }

    /// .dmg: attach on a dedicated empty mount-dir, find the one .app, ditto it out
    /// at its mount-relative path, detach — the wrapper below detaches on every path.
    private static func extractDmg(at dmgURL: URL, into stagingDir: URL) async throws -> URL {
        let mountDir = stagingDir.appendingPathComponent(
            ".dmgmount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountDir, withIntermediateDirectories: true)

        do {
            let attach = try await runProcess(launchPath: "/usr/bin/hdiutil", arguments: [
                "attach", dmgURL.path, "-nobrowse", "-readonly", "-quiet",
                "-mountpoint", mountDir.path,
            ])
            guard attach.succeeded else {
                throw InstallerError.unsupportedArtifact(
                    reason: "hdiutil attach failed (exit \(attach.exitStatus)): \(attach.stderr)")
            }

            let mountedAppURL = try soleAppBundle(in: mountDir, artifactKind: .dmg)
            let destination = try stagingDestination(for: mountedAppURL, mountRoot: mountDir, stagingDir: stagingDir)
            let copy = try await runProcess(launchPath: "/usr/bin/ditto", arguments: [
                mountedAppURL.path, destination.path,
            ])
            guard copy.succeeded else {
                throw InstallerError.unsupportedArtifact(
                    reason: "ditto copy from mount failed (exit \(copy.exitStatus)): \(copy.stderr)")
            }

            // Success path: detach FIRST (never leave a mount), then drop the mount dir.
            try? await detachMount(mountDir)          // failure here = resource-leak, not an install failure
            try? FileManager.default.removeItem(at: mountDir)
            return destination
        } catch {
            // Defer-style wrapper (Swift has no async defer): clean the mount on every
            // failure path. The detach result never masks the original error.
            try? await detachMount(mountDir)
            try? FileManager.default.removeItem(at: mountDir)
            throw error
        }
    }

    /// `hdiutil detach <mountpoint> -quiet`. Throws honestly so callers that care can
    /// observe a leak; the deploy wrapper swallows it only when an installer error
    /// already takes precedence.
    private static func detachMount(_ mountDir: URL) async throws {
        let run = try await runProcess(launchPath: "/usr/bin/hdiutil", arguments: [
            "detach", mountDir.path, "-quiet",
        ])
        guard run.succeeded else {
            throw InstallerError.unsupportedArtifact(
                reason: "hdiutil detach failed (exit \(run.exitStatus)): \(run.stderr)")
        }
    }

    /// App-relative staging destination: `<mountRoot>/A/B/Foo.app` → `<stagingDir>/A/B/Foo.app`.
    /// Refuses to merge into an existing destination (ditto merge semantics would
    /// make a Frankenstein bundle). A volume root that is itself the .app cannot be
    /// copied out this way — honest limitation (see header).
    private static func stagingDestination(for mountedAppURL: URL, mountRoot: URL, stagingDir: URL) throws -> URL {
        // Both sides resolved through /var ↔ /private/var symlinks so a staging dir
        // under NSTemporaryDirectory prefix-matches app paths found by the enumerator.
        let rootPath = mountRoot.resolvingSymlinksInPath().path
        let appPath = mountedAppURL.resolvingSymlinksInPath().path
        guard appPath.hasPrefix(rootPath + "/") else {
            throw InstallerError.unsupportedArtifact(
                reason: "unexpected mount layout: \(appPath) outside \(rootPath)")
        }
        let relative = String(appPath.dropFirst(rootPath.count + 1))
        guard !relative.isEmpty else {
            throw InstallerError.unsupportedArtifact(
                reason: "dmg volume root is itself the .app — staging layout unsupported")
        }
        let destination = stagingDir.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: destination.path) == false else {
            throw InstallerError.unsupportedArtifact(
                reason: "staging layout collision at \(destination.path) — refusing to merge")
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        return destination
    }

    /// One .app inside `root` (recursive), stopping descent at each .app boundary so
    /// embedded helper bundles don't count. 0 or ≥2 → noAppFoundInArtifact (divergence).
    static func soleAppBundle(in root: URL, artifactKind: InstallKind) throws -> URL {
        var candidates: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        else {
            throw InstallerError.noAppFoundInArtifact(kind: artifactKind) // unreadable ⇒ honestly nothing found
        }
        while let next = enumerator.nextObject() as? URL {
            let values = try? next.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            guard next.pathExtension.lowercased() == "app" else { continue }
            candidates.append(next)
            enumerator.skipDescendants()
        }
        guard candidates.count == 1 else {
            throw InstallerError.noAppFoundInArtifact(kind: artifactKind)
        }
        return candidates[0]
    }

    // MARK: - Process helper (shared with the swap lane's file, same lane)

    internal struct ProcessRun: Sendable {
        let stdout: String
        let stderr: String
        let exitStatus: Int32
        var succeeded: Bool { exitStatus == 0 }
    }

    /// Runs a helper binary synchronously through an async wrapper (lane brief:
    /// "Synchronous + async wrapper execution"). The Process is created, drained,
    /// waited on and read entirely inside the dispatch closure so no non-Sendable
    /// state crosses the Swift 6 boundary. Pipes are drained to EOF before
    /// waitUntilExit — our helpers (ditto/hdiutil/xattr/chmod) are single-purpose and
    /// quiet, so output is bounded by design.
    static func runProcess(launchPath: String, arguments: [String]) async throws -> ProcessRun {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessRun, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do { try process.run() } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
                let stderrData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: ProcessRun(
                    stdout: String(decoding: stdoutData, as: UTF8.self),
                    stderr: String(decoding: stderrData, as: UTF8.self),
                    exitStatus: process.terminationStatus))
            }
        }
    }
}
