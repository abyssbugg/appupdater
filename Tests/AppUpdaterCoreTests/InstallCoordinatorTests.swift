// InstallCoordinatorTests — Phase 3 close-out gate (coordinator lane).
//
// REAL-DISK end-to-end executor chains in temp workspaces only — /Applications
// is never touched (the destructive real-app apply stays an owner-run CLI
// action). The downloader tier is hermetic: a URLProtocol stub carrying BINARY
// Data bodies (dmg fixtures are arbitrary bytes that the String-based shared
// stub from IntegrationTests would corrupt). Everything downstream runs for
// real: ditto zip/deploy, hdiutil dmg mount/copy, JMSU renames, Info.plist
// reads. The user's real Trash is never touched either — the old-copy
// disposition is an injected fake that moves the retained copy into the test
// workspace's own trash dir and records it.
//
// Swift Testing only (XCTest discovery is broken on this toolchain).

import Foundation
import Testing
@testable import AppUpdaterCore

// MARK: - Binary-capable download stub (LockedBox pattern; see gotcha ledger)

final class ApplyStubURLProtocol: URLProtocol {
    struct Stub: Sendable {
        let status: Int
        let body: Data
    }

    private static let routes = LockedBox<[String: Stub]>([:])

    static func reset() {
        routes.with { routes in routes = [:] }
    }

    static func stub(_ body: Data, status: Int = 200, for absoluteURL: String) {
        routes.with { routes in routes[absoluteURL] = Stub(status: status, body: body) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    // Gotcha ledger: CFNetwork teardown requires the no-op override.
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let stub = Self.routes.with { routes in routes[url.absoluteString] }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub?.status ?? 404,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/octet-stream",
                "Content-Length": String(stub?.body.count ?? 0),
            ]
        )
        guard let response, let client else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: stub?.body ?? Data())
        client.urlProtocolDidFinishLoading(self)
    }
}

private func applyStubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ApplyStubURLProtocol.self]
    return URLSession(configuration: configuration)
}

// MARK: - Real-disk fixtures (real processes: ditto / hdiutil)

private enum ApplyFixture {
    struct Outcome {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Builds a physical .app fixture (Info.plist + executable stub) on disk.
    static func makeApp(
        in parent: URL,
        name: String,
        bundleID: String,
        shortVersion: String,
        bundleVersion: String
    ) throws -> URL {
        let appURL = parent.appendingPathComponent("\(name).app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key><string>\(name)</string>
            <key>CFBundleIdentifier</key><string>\(bundleID)</string>
            <key>CFBundleShortVersionString</key><string>\(shortVersion)</string>
            <key>CFBundleVersion</key><string>\(bundleVersion)</string>
        </dict>
        </plist>
        """
        try plist.write(
            to: appURL.appendingPathComponent("Contents/Info.plist"),
            atomically: true, encoding: .utf8)
        let binary = appURL.appendingPathComponent("Contents/MacOS/\(name)")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return appURL
    }

    /// Zips `appURL` WITH its parent bundle (ditto -c -k --keepParent).
    static func makeZip(of appURL: URL, at zipURL: URL) throws -> Outcome {
        run("/usr/bin/ditto", ["-c", "-k", "--keepParent", appURL.path, zipURL.path])
    }

    /// Builds a dmg whose volume root contains `appURL` (wrapped in its own
    /// srcfolder — a volume root that IS the app is an honest deploy refusal).
    static func makeDmg(containing appURL: URL, srcFolder: URL, at dmgURL: URL) throws -> Outcome {
        try FileManager.default.createDirectory(at: srcFolder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: appURL, to: srcFolder.appendingPathComponent(
            appURL.lastPathComponent, isDirectory: true))
        return run("/usr/bin/hdiutil", [
            "create", "-srcfolder", srcFolder.path, "-ov", "-fs", "HFS+", dmgURL.path,
        ])
    }

    /// Extracts a ditto zip for integrity checks.
    static func unzip(_ zipURL: URL, into dir: URL) throws -> Outcome {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return run("/usr/bin/ditto", ["-x", "-k", zipURL.path, dir.path])
    }

    static func run(_ launchPath: String, _ arguments: [String]) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try? process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Outcome(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }

    /// Raw Info.plist bytes (for byte-equality backups / tamper checks).
    static func plistBytes(of appURL: URL) throws -> Data {
        try Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
    }

    /// Short version read straight off disk (independent of the coordinator).
    static func shortVersion(of appURL: URL) throws -> String? {
        let plist = InfoProbe.infoDictionary(appBundleURL: appURL)
        return InfoProbe.string(for: ["CFBundleShortVersionString"], in: plist)
    }
}

@Suite(.serialized)
struct InstallCoordinatorTests {
    private var root: URL
    private var victimPath: URL { root.appendingPathComponent("apps/Victim.app", isDirectory: true) }
    private var stagingRoot: URL { root.appendingPathComponent("staging", isDirectory: true) }
    private var backupsRoot: URL { root.appendingPathComponent("backups", isDirectory: true) }
    private var testTrash: URL { root.appendingPathComponent("test-trash", isDirectory: true) }
    private let victimBundleID = "org.appupdater.coordinator.victim"

    init() {
        // Per-test recycled workspace (struct init runs per test; no deinit).
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("appupdater-coordinator", isDirectory: true)
        try? FileManager.default.removeItem(at: workspace)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        root = workspace
        ApplyStubURLProtocol.reset()
    }
}

extension InstallCoordinatorTests {
    // MARK: Wiring helpers (injected seams; hermetic everywhere)

    /// Records opener calls; never invokes the real NSWorkspace opener.
    private func fakeTerminator(openerCalls: LockedBox<[URL]>, alwaysRunning: Bool) -> AppTerminator {
        // Explicit branch assignment — the ternary form refuses to carry the
        // `@MainActor @Sendable` type through inference (Swift 6.4).
        let runningSeam: @MainActor @Sendable () -> [RunningRef]
        if alwaysRunning {
            runningSeam = { [RunningRef(bundleIdentifier: "org.appupdater.coordinator.victim")] }
        } else {
            runningSeam = { [] }
        }
        let terminateSeam: @MainActor @Sendable (RunningRef) -> Bool = { _ in true }
        let openerSeam: @MainActor @Sendable (URL) async throws -> Bool = { url in
            openerCalls.with { $0.append(url) }
            return true
        }
        return AppTerminator(
            running: runningSeam, terminate: terminateSeam, opener: openerSeam,
            pollInterval: .milliseconds(5))
    }

    private struct Seams {
        let openerCalls: LockedBox<[URL]>
        let disposed: LockedBox<[URL]>
    }

    /// Fake disposition: moves the retained old copy into the TEST trash dir
    /// (same volume, plain rename) and records where it went. The user's real
    /// Trash is never involved.
    private func coordinator(
        _ seams: Seams,
        hook: (@Sendable (DownloadedUpdate) throws -> Void)? = nil
    ) -> InstallCoordinator {
        let trashDir = testTrash
        let disposed = seams.disposed
        let disposition: @Sendable (URL) throws -> String? = { oldCopy in
            try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
            let destination = trashDir.appendingPathComponent(oldCopy.lastPathComponent)
            try FileManager.default.moveItem(at: oldCopy, to: destination)
            disposed.with { $0.append(URL(fileURLWithPath: destination.path)) }
            return destination.path
        }
        return InstallCoordinator(
            downloader: UpdateDownloader(session: applyStubSession()),
            terminator: fakeTerminator(openerCalls: seams.openerCalls, alwaysRunning: false),
            disposeOfOldCopy: disposition,
            postDownloadHook: hook)
    }

    /// The fixture's OWN name is served — the planner derives the artifact kind
    /// from the download URL's extension (locked rule), so the URL carries a
    /// realistic .zip/.dmg name, not a synthetic one.
    private func servedURL(for artifact: URL) -> URL {
        URL(string: "https://fixtures.local/updates/\(artifact.lastPathComponent)")!
    }

    private func planOf(
        artifact: URL,
        claim: String = "2.0",
        sha256Hex: String? = nil,
        victimVersions: (old: String, new: String) = ("1.0", "2.0")
    ) throws -> InstallPlan {
        let sha = try sha256Hex ?? Checksum.sha256Hex(ofFile: artifact)
        let update = UpdateInfo(
            source: .cask,
            newestShortVersion: claim,
            downloadURL: servedURL(for: artifact),
            sha256Hex: sha,
            confidence: .medium)
        let victim = InstalledApp(
            bundleIdentifier: victimBundleID,
            name: "Victim",
            path: victimPath.path,
            shortVersion: victimVersions.old,
            bundleVersion: "10")
        return try InstallPlanner().plan(app: victim, update: update)
    }

    /// Serves the fixture (bytes of `artifact`) from the test URL.
    private func serve(_ artifact: URL) throws {
        ApplyStubURLProtocol.stub(try Data(contentsOf: artifact), for: servedURL(for: artifact).absoluteString)
    }

    /// Standard v1 victim on disk. Returns the victim's original plist bytes.
    @discardableResult
    private func makeVictim(version: String = "1.0", buildNumber: String = "10") throws -> Data {
        try FileManager.default.createDirectory(
            at: victimPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        let victim = try ApplyFixture.makeApp(
            in: victimPath.deletingLastPathComponent(), name: "Victim",
            bundleID: victimBundleID, shortVersion: version, bundleVersion: buildNumber)
        return try ApplyFixture.plistBytes(of: victim)
    }
}

extension InstallCoordinatorTests {
    // MARK: The gate tests

    /// Full 9-step v1 → v2 apply on real disk: receipts green and in order,
    /// swapped bundle serves v2 under the SAME bundle id, backup verified by a
    /// byte-equal restore round-trip, old copy recorded into the test trash,
    /// staging workspace removed, opener never called.
    @Test func happyZipApplyEndToEndV1ToV2() async throws {
        let originalPlist = try makeVictim()
        let next = try ApplyFixture.makeApp(
            in: root.appendingPathComponent("artifact-src", isDirectory: true),
            name: "Victim", bundleID: victimBundleID,
            shortVersion: "2.0", bundleVersion: "20")
        let zipURL = root.appendingPathComponent("victim-2.0.zip")
        try ApplyFixture.makeZip(of: next, at: zipURL)
        try serve(zipURL)

        let seams = Seams(openerCalls: LockedBox<[URL]>([]), disposed: LockedBox<[URL]>([]))
        let coordinator = coordinator(seams)
        let plan = try planOf(artifact: zipURL)
        let outcome = await coordinator.run(
            plan, stagingRoot: stagingRoot, backupsRoot: backupsRoot, relaunchRequested: false)

        // Every planned step ran and succeeded, in the locked order.
        let stepSequence = outcome.receipts.map { $0.step }
        #expect(stepSequence == plan.steps) // exactly the 9 locked steps
        #expect(outcome.receipts.allSatisfy { $0.succeeded })
        #expect(outcome.abortedStep == nil)
        #expect(outcome.finalInstalledShortVersion == "2.0")
        #expect(outcome.receipts.contains { $0.step == .verifySha256 && $0.detail.contains("independent re-verification") })
        #expect(outcome.receipts.contains { $0.step == .relaunch && $0.detail.contains("not requested") })

        // The bundle now at the victim's path: v2 bytes, unchanged identity.
        #expect(try ApplyFixture.shortVersion(of: victimPath) == "2.0")
        let installedInfo = InfoProbe.infoDictionary(appBundleURL: victimPath)
        #expect(InfoProbe.string(for: ["CFBundleIdentifier"], in: installedInfo) == victimBundleID)

        // Old copy: gone from the ~~~ slot, recorded in the test trash with the
        // ORIGINAL v1 plist byte-equal.
        let retainedPath = victimPath.path + "~~~appupdater-old~~~"
        #expect(!FileManager.default.fileExists(atPath: retainedPath))
        #expect(seams.disposed.with { $0 }.count == 1)
        let retainedURL = try #require(seams.disposed.with { $0 }.first)
        #expect(try Data(contentsOf: retainedURL.appendingPathComponent("Contents/Info.plist")) == originalPlist)

        // Backup verified for real: receipts green + restore round-trip is
        // byte-equal for the plist.
        let backup = try #require(outcome.backup)
        #expect(FileManager.default.fileExists(atPath: backup.zipURL.path))
        #expect(backup.byteCount > 0)
        #expect(backup.originalPath == victimPath.path)
        #expect(backup.originalShortVersion == "1.0")
        let restored = root.appendingPathComponent("backup-restore", isDirectory: true)
        try ApplyFixture.unzip(backup.zipURL, into: restored)
        let restoredPlist = try Data(contentsOf: restored
            .appendingPathComponent("Victim.app/Contents/Info.plist"))
        #expect(restoredPlist == originalPlist)

        // Relaunch: request never dispatched (not asked for).
        #expect(seams.openerCalls.with { $0 }.isEmpty)

        // Staging hygiene: workspace removed, nothing half-artifact left over.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path))?.isEmpty ?? true)
    }

    /// Wrong source sha256 → the downloader refuses; abort lands on
    /// `.download`, the victim is untouched, no backup is made, nothing
    /// lingered in staging.
    @Test func sha256MismatchAbortsAtDownloadLeavesNothing() async throws {
        let originalPlist = try makeVictim()
        let next = try ApplyFixture.makeApp(
            in: root.appendingPathComponent("artifact-src", isDirectory: true),
            name: "Victim", bundleID: victimBundleID,
            shortVersion: "2.0", bundleVersion: "20")
        let zipURL = root.appendingPathComponent("victim-2.0.zip")
        try ApplyFixture.makeZip(of: next, at: zipURL)
        try serve(zipURL)

        let seams = Seams(openerCalls: LockedBox<[URL]>([]), disposed: LockedBox<[URL]>([]))
        let plan = try planOf(artifact: zipURL, sha256Hex: String(repeating: "0", count: 64))
        let outcome = await coordinator(seams).run(
            plan, stagingRoot: stagingRoot, backupsRoot: backupsRoot)

        #expect(outcome.abortedStep == .download)
        #expect(outcome.receipts.count == 1)
        #expect(outcome.receipts.first?.step == .download)
        #expect(outcome.receipts.first?.succeeded == false)
        #expect(outcome.finalInstalledShortVersion == nil)
        #expect(outcome.backup == nil)
        #expect(try ApplyFixture.plistBytes(of: victimPath) == originalPlist) // victim untouched
        #expect(!FileManager.default.fileExists(atPath: victimPath.path + "~~~appupdater-old~~~"))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: backupsRoot.path))?.isEmpty ?? true)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path))?.isEmpty ?? true)
        #expect(outcome.receipts.first?.detail.contains("sha256 mismatch") == true)
    }

    /// Post-download mutation of the staged bytes is caught by the
    /// INDEPENDENT verifySha256 (defense in depth) — abort at that step, with
    /// the download step's receipt still green above it.
    @Test func postDownloadMutationCaughtByIndependentVerify() async throws {
        _ = try makeVictim()
        let next = try ApplyFixture.makeApp(
            in: root.appendingPathComponent("artifact-src", isDirectory: true),
            name: "Victim", bundleID: victimBundleID,
            shortVersion: "2.0", bundleVersion: "20")
        let zipURL = root.appendingPathComponent("victim-2.0.zip")
        try ApplyFixture.makeZip(of: next, at: zipURL)
        try serve(zipURL)

        let seams = Seams(openerCalls: LockedBox<[URL]>([]), disposed: LockedBox<[URL]>([]))
        let plan = try planOf(artifact: zipURL)
        let corrupting: @Sendable (DownloadedUpdate) throws -> Void = { downloaded in
            // Simulated pipeline bug / TOCTOU: flip one byte AFTER the
            // downloader's own hash-while-writing already blessed it.
            let handle = try FileHandle(forWritingTo: downloaded.stagedURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0x00]))
        }
        let outcome = await coordinator(seams, hook: corrupting).run(
            plan, stagingRoot: stagingRoot, backupsRoot: backupsRoot)

        #expect(outcome.abortedStep == .verifySha256)
        #expect(outcome.receipts.map { $0.step } == [.download, .verifySha256])
        #expect(outcome.receipts.first?.succeeded == true)          // downloader passed
        #expect(outcome.receipts.last?.succeeded == false)          // independent verify caught it
        #expect(outcome.backup == nil)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path))?.isEmpty ?? true)
    }

    /// A staged bundle claiming a DIFFERENT bundle id is refused by the swap's
    /// identity guard; the old install is preserved byte-equal, the backup
    /// (already performed) survives in the outcome, and no relaunch/post-scan
    /// receipt is fabricated.
    @Test func identityHijackRefusedOldInstallPreserved() async throws {
        let originalPlist = try makeVictim()
        let hijacker = try ApplyFixture.makeApp(
            in: root.appendingPathComponent("artifact-src", isDirectory: true),
            name: "Victim", bundleID: "org.appupdater.hijacker",
            shortVersion: "9.9", bundleVersion: "99")
        let zipURL = root.appendingPathComponent("victim-hijack.zip")
        try ApplyFixture.makeZip(of: hijacker, at: zipURL)
        try serve(zipURL)

        let seams = Seams(openerCalls: LockedBox<[URL]>([]), disposed: LockedBox<[URL]>([]))
        let plan = try planOf(artifact: zipURL, claim: "9.9")
        let outcome = await coordinator(seams).run(
            plan, stagingRoot: stagingRoot, backupsRoot: backupsRoot)

        #expect(outcome.abortedStep == .swapBundles)
        // Attempted steps: everything up to and including the refused swap.
        #expect(outcome.receipts.map { $0.step } == plan.steps.prefix(7).map { $0 })
        #expect(try #require(outcome.receipts.last).step == .swapBundles)
        #expect(outcome.receipts.last?.succeeded == false)

        // Old install preserved EXACTLY (nothing was ever renamed).
        #expect(try ApplyFixture.plistBytes(of: victimPath) == originalPlist)
        #expect(try ApplyFixture.shortVersion(of: victimPath) == "1.0")
        #expect(!FileManager.default.fileExists(atPath: victimPath.path + "~~~appupdater-old~~~"))
        #expect(seams.disposed.with { $0 }.isEmpty) // nothing to dispose

        // The backup already performed is honestly retained in the outcome.
        let backup = try #require(outcome.backup)
        #expect(backup.originalShortVersion == "1.0")

        // Refusal reason names the identity change.
        #expect(outcome.receipts.last?.detail.contains("bundle identifier changed") == true)
    }

    /// An app that refuses to quit within the budget aborts BEFORE deploy —
    /// the stuck instance is reported honestly, no half-install happens.
    @Test func quitTimedOutAbortsBeforeDeploy() async throws {
        let originalPlist = try makeVictim()
        let next = try ApplyFixture.makeApp(
            in: root.appendingPathComponent("artifact-src", isDirectory: true),
            name: "Victim", bundleID: victimBundleID,
            shortVersion: "2.0", bundleVersion: "20")
        let zipURL = root.appendingPathComponent("victim-2.0.zip")
        try ApplyFixture.makeZip(of: next, at: zipURL)
        try serve(zipURL)

        let openerCalls = LockedBox<[URL]>([])
        let runningSeam: @MainActor @Sendable () -> [RunningRef] = {
            [RunningRef(bundleIdentifier: "org.appupdater.coordinator.victim")] // never leaves
        }
        let terminateSeam: @MainActor @Sendable (RunningRef) -> Bool = { _ in true }
        let openerSeam: @MainActor @Sendable (URL) async throws -> Bool = { url in
            openerCalls.with { $0.append(url) }
            return true
        }
        let stubborn = AppTerminator(
            running: runningSeam, terminate: terminateSeam, opener: openerSeam,
            pollInterval: .milliseconds(5))
        let disposed = LockedBox<[URL]>([])
        let trashDir = testTrash
        let disposition: @Sendable (URL) throws -> String? = { oldCopy in
            try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
            let destination = trashDir.appendingPathComponent(oldCopy.lastPathComponent)
            try FileManager.default.moveItem(at: oldCopy, to: destination)
            disposed.with { $0.append(URL(fileURLWithPath: destination.path)) }
            return destination.path
        }
        let coordinator = InstallCoordinator(
            downloader: UpdateDownloader(session: applyStubSession()),
            terminator: stubborn,
            disposeOfOldCopy: disposition,
            postDownloadHook: nil)

        let plan = try planOf(artifact: zipURL)
        let outcome = await coordinator.run(
            plan, stagingRoot: stagingRoot, backupsRoot: backupsRoot,
            relaunchRequested: false, quitTimeout: 0.05)

        #expect(outcome.abortedStep == .quitRunningApp)
        #expect(outcome.receipts.map { $0.step } == plan.steps.prefix(5).map { $0 })
        #expect(outcome.receipts.last?.succeeded == false)
        #expect(outcome.receipts.last?.detail.contains("could not quit") == true)

        // Nothing moved: victim intact, no deploy leftovers, opener untouched.
        #expect(try ApplyFixture.plistBytes(of: victimPath) == originalPlist)
        #expect(openerCalls.with { $0 }.isEmpty)
        #expect(disposed.with { $0 }.isEmpty)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path))?.isEmpty ?? true)
    }

    /// Full apply of a dmg artifact: honest no-magic boundary recorded at
    /// verifyArtifactMagic, and NO lingering hdiutil mounts after the run.
    @Test func happyDmgApplyEndToEndNoLeftoverMounts() async throws {
        let originalPlist = try makeVictim()
        let next = try ApplyFixture.makeApp(
            in: root.appendingPathComponent("artifact-src", isDirectory: true),
            name: "Victim", bundleID: victimBundleID,
            shortVersion: "3.1", bundleVersion: "31")
        let dmgURL = root.appendingPathComponent("victim-3.1.dmg")
        let mount = try ApplyFixture.makeDmg(
            containing: next,
            srcFolder: root.appendingPathComponent("dmg-src", isDirectory: true),
            at: dmgURL)
        guard mount.status == 0 else {
            Issue.record("hdiutil create failed: \(mount.stderr)")
            return
        }
        try serve(dmgURL)

        let seams = Seams(openerCalls: LockedBox<[URL]>([]), disposed: LockedBox<[URL]>([]))
        let plan = try planOf(artifact: dmgURL, claim: "3.1")
        let outcome = await coordinator(seams).run(
            plan, stagingRoot: stagingRoot, backupsRoot: backupsRoot)

        #expect(outcome.abortedStep == nil)
        #expect(outcome.receipts.allSatisfy { $0.succeeded })
        #expect(outcome.finalInstalledShortVersion == "3.1")
        #expect(try ApplyFixture.shortVersion(of: victimPath) == "3.1")
        let installedInfo = InfoProbe.infoDictionary(appBundleURL: victimPath)
        #expect(InfoProbe.string(for: ["CFBundleIdentifier"], in: installedInfo) == victimBundleID)
        #expect(outcome.backup != nil)
        #expect(try ApplyFixture.plistBytes(of: victimPath) != originalPlist) // v3.1 differs
        #expect(!FileManager.default.fileExists(atPath: victimPath.path + "~~~appupdater-old~~~"))
        #expect(seams.disposed.with { $0 }.count == 1)

        // No mounts left behind: the dedicated `.dmgmount-` prefix (unique to
        // our deploy lane's mount dirs) must appear NOWHERE in the registry.
        // Same check on the staging tree: the workspace was removed either way.
        let info = ApplyFixture.run("/usr/bin/hdiutil", ["info"])
        try #require(info.status == 0, "hdiutil info failed: \(info.stderr)")
        #expect(info.stdout.contains(".dmgmount-") == false)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path))?.isEmpty ?? true)
    }

    /// relaunchRequested: true → exactly ONE launch request, for the swapped
    /// bundle's own path (never some invented path, never twice).
    @Test func relaunchRequestedAsksOpenerExactlyOnceAtTheVictimPath() async throws {
        _ = try makeVictim()
        let next = try ApplyFixture.makeApp(
            in: root.appendingPathComponent("artifact-src", isDirectory: true),
            name: "Victim", bundleID: victimBundleID,
            shortVersion: "2.0", bundleVersion: "20")
        let zipURL = root.appendingPathComponent("victim-2.0.zip")
        try ApplyFixture.makeZip(of: next, at: zipURL)
        try serve(zipURL)

        let seams = Seams(openerCalls: LockedBox<[URL]>([]), disposed: LockedBox<[URL]>([]))
        let plan = try planOf(artifact: zipURL)
        let outcome = await coordinator(seams).run(
            plan, stagingRoot: stagingRoot, backupsRoot: backupsRoot, relaunchRequested: true)

        #expect(outcome.abortedStep == nil)
        let calls = seams.openerCalls.with { $0 }
        #expect(calls.count == 1)
        #expect(calls.first?.path == victimPath.path)
        #expect(outcome.receipts.contains { $0.step == .relaunch && $0.detail.contains("relaunch requested") })
    }

    /// Machine gate: the outcome is fully Codable — CLI/GUI reports survive the
    /// JSON round-trip with identical receipts, abort state and versions.
    @Test func outcomeCodableRoundTrip() async throws {
        _ = try makeVictim()
        let next = try ApplyFixture.makeApp(
            in: root.appendingPathComponent("artifact-src", isDirectory: true),
            name: "Victim", bundleID: victimBundleID,
            shortVersion: "2.0", bundleVersion: "20")
        let zipURL = root.appendingPathComponent("victim-2.0.zip")
        try ApplyFixture.makeZip(of: next, at: zipURL)
        try serve(zipURL)

        let seams = Seams(openerCalls: LockedBox<[URL]>([]), disposed: LockedBox<[URL]>([]))
        let plan = try planOf(artifact: zipURL)
        let outcome = await coordinator(seams).run(
            plan, stagingRoot: stagingRoot, backupsRoot: backupsRoot)
        #expect(outcome.abortedStep == nil)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let roundTrip = try decoder.decode(
            InstallOutcome.self, from: try encoder.encode(outcome))

        #expect(roundTrip.abortedStep == outcome.abortedStep)
        #expect(roundTrip.finalInstalledShortVersion == outcome.finalInstalledShortVersion)
        #expect(roundTrip.receipts.count == outcome.receipts.count)
        #expect(roundTrip.receipts.map(\.step) == outcome.receipts.map(\.step))
        #expect(roundTrip.receipts.map(\.succeeded) == outcome.receipts.map(\.succeeded))
        #expect(roundTrip.backup?.byteCount == outcome.backup?.byteCount)
        #expect(roundTrip.backup?.originalShortVersion == outcome.backup?.originalShortVersion)
        #expect(roundTrip.plan == outcome.plan)
    }
}
