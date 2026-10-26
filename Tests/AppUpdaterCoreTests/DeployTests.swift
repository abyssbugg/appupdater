// DeployTests.swift — Deploy lane (H): deploy (zip/dmg) + JMSU-style swap, verified by
// REAL execution on disk. Hermetic: everything lives in temp dirs this suite created;
// /Applications and user apps are never touched (9-phase honesty contract).
// Swift Testing only (XCTest collects 0 tests here — gotcha ledger); .serialized keeps
// the hdiutil/ditto/xattr subprocesses from interleaving.

import Foundation
import Testing
@testable import AppUpdaterCore

@Suite(.serialized)
struct DeployTests {
    /// Root wiped at each init (Integration-suite pattern keeps startup
    /// fast); every test additionally gets its own UUID subdirectory so parallel
    /// leftovers from a crashed run can't pollute assertions. Mount dirs are cleaned
    /// by the code under test; product detaches on every path.
    ///
    /// The NAME is unique per PROCESS (static = computed once, not per test):
    /// concurrent `swift test` runners each own their directory, so one
    /// runner's init wipe can never delete another runner's live fixtures —
    /// fixed shared roots used to do exactly that (the Phase-4 cross-process
    /// flake; see AGENTS.md gotcha ledger).
    private var root: URL = Self.sharedRoot
    private static let sharedRoot: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("appupdater-lanedeploy-\(UUID().uuidString)", isDirectory: true)
    private let fm = FileManager.default

    init() {
        try? fm.removeItem(at: Self.sharedRoot)
        try? fm.createDirectory(at: Self.sharedRoot, withIntermediateDirectories: true)
        root = Self.sharedRoot
    }

    // MARK: - Fixtures (real bytes, real bundles)

    /// Synthetic .app: Contents/Info.plist + Contents/MacOS/main (`exit 0` shell script).
    private func makeApp(name: String, bundleID: String, shortVersion: String, in dir: URL) throws -> URL {
        let appURL = dir.appendingPathComponent("\(name).app", isDirectory: true)
        try fm.createDirectory(at: appURL.appendingPathComponent("Contents/MacOS", isDirectory: true), withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key><string>\(name)</string>
            <key>CFBundleIdentifier</key><string>\(bundleID)</string>
            <key>CFBundleShortVersionString</key><string>\(shortVersion)</string>
        </dict>
        </plist>
        """
        try plist.write(to: appURL.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        let mainURL = appURL.appendingPathComponent("Contents/MacOS/main")
        try "#!/bin/sh\nexit 0".write(to: mainURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mainURL.path)
        return appURL
    }

    /// zlib/pbzx-free .zip via `ditto -c -k` on the directory holding the artifacts.
    private func zipArtifacts(in dir: URL, name: String) async throws -> URL {
        let zipURL = dir.appendingPathComponent("\(name).zip")
        let run = try await BundleDeployer.runProcess(
            launchPath: "/usr/bin/ditto", arguments: ["-c", "-k", dir.path, zipURL.path])
        #expect(run.succeeded, "fixture zip creation failed: \(run.stderr)")
        return zipURL
    }

    /// HFS+ dmg via `hdiutil create -srcfolder <dir> -ov -fs HFS+` (unprivileged).
    private func dmgArtifacts(in dir: URL, name: String) async throws -> URL {
        let dmgURL = dir.appendingPathComponent("\(name).dmg")
        let run = try await BundleDeployer.runProcess(
            launchPath: "/usr/bin/hdiutil",
            arguments: ["create", "-srcfolder", dir.path, "-ov", "-fs", "HFS+", dmgURL.path])
        #expect(run.succeeded, "fixture dmg creation failed: \(run.stderr)")
        return dmgURL
    }

    private func readShortVersion(appPath: String) -> String? {
        InfoProbe.string(for: ["CFBundleShortVersionString"], in: InfoProbe.infoDictionary(appBundleURL: URL(fileURLWithPath: appPath)))
    }

    private func readBundleID(appPath: String) -> String? {
        InfoProbe.string(for: ["CFBundleIdentifier"], in: InfoProbe.infoDictionary(appBundleURL: URL(fileURLWithPath: appPath)))
    }

    /// `xattr -p <attr> <path>` exit status: 0 = present, nonzero = absent.
    private func quarantineProbeExit(for path: String) async throws -> Int32 {
        try await BundleDeployer.runProcess(
            launchPath: "/usr/bin/xattr", arguments: ["-p", "com.apple.quarantine", path]
        ).exitStatus
    }

    private func mountDirListed(byHdiutil mountDir: URL) async throws -> Bool {
        let info = try await BundleDeployer.runProcess(launchPath: "/usr/bin/hdiutil", arguments: ["info"])
        return info.stdout.contains(mountDir.path) || info.stderr.contains(mountDir.path)
    }

    private func uniqueDir(_ label: String) -> URL {
        root.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: Deploy — zip

    @Test func zipDeployProducesStagedApp() async throws {
        let dir = uniqueDir("zipdeploy")
        _ = try makeApp(name: "Victim", bundleID: "org.test.deploy.zip", shortVersion: "1.0", in: dir)
        let zipURL = try await zipArtifacts(in: dir, name: "bundle")

        let stagingDir = uniqueDir("staging")
        let deployed = try await BundleDeployer.deploy(
            from: DownloadedUpdate(stagedURL: zipURL, kind: .zip, expectedSha256Hex: nil),
            into: stagingDir)

        #expect(deployed.kind == .zip)
        #expect(fm.fileExists(atPath: deployed.stagedAppURL.path))
        #expect(deployed.stagedAppURL.pathExtension.lowercased() == "app")
        #expect(fm.fileExists(atPath: deployed.stagedAppURL.appendingPathComponent("Contents/Info.plist").path))
        #expect(fm.fileExists(atPath: deployed.stagedAppURL.appendingPathComponent("Contents/MacOS/main").path))
        #expect(readBundleID(appPath: deployed.stagedAppURL.path) == "org.test.deploy.zip")
    }

    @Test func emptyArtifactZipIsRefused() async throws {
        let dir = uniqueDir("emptyzip")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "# nothing but a readme".write(to: dir.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        let zipURL = try await zipArtifacts(in: dir, name: "empty")

        await #expect(throws: InstallerError.self) {
            _ = try await BundleDeployer.deploy(
                from: DownloadedUpdate(stagedURL: zipURL, kind: .zip, expectedSha256Hex: nil),
                into: uniqueDir("staging"))
        }
    }

    // MARK: Deploy — dmg (mount discipline)

    @Test func dmgDeployProducesStagedAppAndLeavesNoMount() async throws {
        let dir = uniqueDir("dmgdeploy")
        let appURL = try makeApp(name: "Victim", bundleID: "org.test.deploy.dmg", shortVersion: "1.0", in: dir)
        let dmgURL = try await dmgArtifacts(in: dir, name: "bundle")

        let stagingDir = uniqueDir("staging")
        let deployed = try await BundleDeployer.deploy(
            from: DownloadedUpdate(stagedURL: dmgURL, kind: .dmg, expectedSha256Hex: nil),
            into: stagingDir)

        #expect(deployed.kind == .dmg)
        #expect(deployed.stagedAppURL.lastPathComponent == appURL.lastPathComponent)
        #expect(fm.fileExists(atPath: deployed.stagedAppURL.appendingPathComponent("Contents/Info.plist").path))
        #expect(readBundleID(appPath: deployed.stagedAppURL.path) == "org.test.deploy.dmg")
        // MUST be inside the staging dir (copied OUT of the mount), no mount dir left.
        #expect(deployed.stagedAppURL.path.hasPrefix(stagingDir.path))
        // No leftover .dmgmount-* working dirs in staging either.
        let leftovers = (try? fm.contentsOfDirectory(atPath: stagingDir.path))?.filter { $0.hasPrefix(".dmgmount-") } ?? []
        #expect(leftovers.isEmpty, "mount working dir left behind: \(leftovers)")
    }

    @Test func dmgDeployRefusesAmbiguousArtifactAndStillDetaches() async throws {
        let dir = uniqueDir("dmgdouble")
        _ = try makeApp(name: "Foo", bundleID: "org.test.deploy.foo", shortVersion: "1.0", in: dir)
        _ = try makeApp(name: "Bar", bundleID: "org.test.deploy.bar", shortVersion: "1.0", in: dir)
        let dmgURL = try await dmgArtifacts(in: dir, name: "double")

        let stagingDir = uniqueDir("staging")
        let mountDirParent = stagingDir // mount dirs are created inside staging
        await #expect(throws: InstallerError.self) {
            _ = try await BundleDeployer.deploy(
                from: DownloadedUpdate(stagedURL: dmgURL, kind: .dmg, expectedSha256Hex: nil),
                into: stagingDir)
        }
        // The failure path must ALSO detach: hdiutil info must not list any of our mounts.
        #expect(try await mountDirListed(byHdiutil: mountDirParent) == false)
    }

    // MARK: Swap — happy path

    @Test func swapHappyPathServesV2AndRetainsOld() async throws {
        let dir = uniqueDir("happyswap")
        let apps = dir.appendingPathComponent("apps")
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        let victim = try makeApp(name: "Victim", bundleID: "org.test.swap.happy", shortVersion: "1.0", in: apps)
        let victimPath = victim.path

        // Prepare the staged v2 through the REAL deploy path (zip artifact).
        let artifactDir = uniqueDir("artifact")
        _ = try makeApp(name: "Victim", bundleID: "org.test.swap.happy", shortVersion: "2.0", in: artifactDir)
        let zipURL = try await zipArtifacts(in: artifactDir, name: "v2")
        let stagingDir = uniqueDir("staging")
        let deployed = try await BundleDeployer.deploy(
            from: DownloadedUpdate(stagedURL: zipURL, kind: .zip, expectedSha256Hex: nil),
            into: stagingDir)

        let result = try await AppSwapper.swap(staged: deployed, into: victimPath)

        // Target path now serves v2's plist.
        #expect(fm.fileExists(atPath: victimPath))
        #expect(readShortVersion(appPath: victimPath) == "2.0")
        #expect(readBundleID(appPath: victimPath) == "org.test.swap.happy")
        // Old copy retained at the reported path, still the OLD bundle (v1, same id).
        #expect(result.oldAppMovedTo == victimPath + "~~~appupdater-old~~~")
        #expect(fm.fileExists(atPath: result.oldAppMovedTo))
        #expect(readShortVersion(appPath: result.oldAppMovedTo) == "1.0")
        #expect(readBundleID(appPath: result.oldAppMovedTo) == "org.test.swap.happy")
        // The staged shape is gone (it moved into place).
        #expect(fm.fileExists(atPath: deployed.stagedAppURL.path) == false)
    }

    // MARK: Swap — identity guard

    @Test func identityHijackIsRefusedAndAppUntouched() async throws {
        let dir = uniqueDir("hijack")
        let apps = dir.appendingPathComponent("apps")
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        let victim = try makeApp(name: "Victim", bundleID: "org.test.swap.victim", shortVersion: "1.0", in: apps)
        let victimPath = victim.path

        // Staged imposter: same NAME, different bundle id.
        let artifactDir = uniqueDir("artifact")
        _ = try makeApp(name: "Victim", bundleID: "org.test.swap.imposter", shortVersion: "9.9", in: artifactDir)
        let zipURL = try await zipArtifacts(in: artifactDir, name: "imposter")
        let stagingDir = uniqueDir("staging")
        let deployed = try await BundleDeployer.deploy(
            from: DownloadedUpdate(stagedURL: zipURL, kind: .zip, expectedSha256Hex: nil),
            into: stagingDir)

        do {
            _ = try await AppSwapper.swap(staged: deployed, into: victimPath)
            Issue.record("identity hijack must be refused")
        } catch {
            guard case InstallerError.swapFailed(let reason) = error else {
                Issue.record("expected InstallerError.swapFailed, got \(error)")
                return
            }
            #expect(reason.contains("bundle identifier changed"))
        }
        // Nothing moved: v1 still served at the original path; no old-copy residue.
        #expect(fm.fileExists(atPath: victimPath))
        #expect(readShortVersion(appPath: victimPath) == "1.0")
        #expect(fm.fileExists(atPath: victimPath + "~~~appupdater-old~~~") == false)
    }

    // MARK: Swap — rollback + precondition

    @Test func moveInFailureRollsOldAppBack() async throws {
        let dir = uniqueDir("rollback")
        let apps = dir.appendingPathComponent("apps")
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        let victim = try makeApp(name: "Victim", bundleID: "org.test.swap.roll", shortVersion: "1.0", in: apps)
        let victimPath = victim.path

        // Mechanism to make STEP 5 fail AFTER the aside rename: stage the app inside
        // a directory carrying no write permission — rename(2) out of it needs write
        // on the source directory, so moveItem fails while every earlier step got
        // through. Legit filesystem refusal, no races, no stubs.
        let stagingRoot = uniqueDir("staging")
        let locked = stagingRoot.appendingPathComponent("locked", isDirectory: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        _ = try makeApp(name: "Victim", bundleID: "org.test.swap.roll", shortVersion: "2.0", in: locked)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        let deployed = DeployedBundle(
            stagedAppURL: locked.appendingPathComponent("Victim.app"),
            kind: .zip)

        do {
            _ = try await AppSwapper.swap(staged: deployed, into: victimPath)
            Issue.record("move-in from an unwritable source directory must fail")
        } catch {
            guard case InstallerError.swapFailed = error else {
                Issue.record("expected InstallerError.swapFailed, got \(error)")
                return
            }
        }
        // Rollback: v1 back at the original path; no residue at the aside path.
        #expect(fm.fileExists(atPath: victimPath))
        #expect(readShortVersion(appPath: victimPath) == "1.0")
        #expect(fm.fileExists(atPath: victimPath + "~~~appupdater-old~~~") == false)

        // Restore the lab before wiping (owner can re-grant; keeps teardown clean).
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        try? fm.removeItem(at: stagingRoot)
    }

    @Test func missingStagedAppIsPreconditionFailure() async throws {
        let dir = uniqueDir("missingstaged")
        let apps = dir.appendingPathComponent("apps")
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        let victim = try makeApp(name: "Victim", bundleID: "org.test.swap.missing", shortVersion: "1.0", in: apps)
        let victimPath = victim.path

        let deployed = DeployedBundle(
            stagedAppURL: dir.appendingPathComponent("never-existed.app"),
            kind: .zip)

        await #expect(throws: InstallerError.self) {
            _ = try await AppSwapper.swap(staged: deployed, into: victimPath)
        }
        // Precondition refused BEFORE the first rename: v1 untouched.
        #expect(fm.fileExists(atPath: victimPath))
        #expect(readShortVersion(appPath: victimPath) == "1.0")
        #expect(fm.fileExists(atPath: victimPath + "~~~appupdater-old~~~") == false)
    }

    // MARK: Swap — JMSU parity details

    @Test func swapPreservesOldRootMtime() async throws {
        let dir = uniqueDir("mtime")
        let apps = dir.appendingPathComponent("apps")
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        let victim = try makeApp(name: "Victim", bundleID: "org.test.swap.mtime", shortVersion: "1.0", in: apps)
        let victimPath = victim.path
        let pastDate = Date(timeIntervalSince1970: 1_234_567_890) // 2009-02-13
        try fm.setAttributes([.modificationDate: pastDate], ofItemAtPath: victimPath)

        let artifactDir = uniqueDir("artifact")
        _ = try makeApp(name: "Victim", bundleID: "org.test.swap.mtime", shortVersion: "2.0", in: artifactDir)
        let zipURL = try await zipArtifacts(in: artifactDir, name: "v2")
        let stagingDir = uniqueDir("staging")
        let deployed = try await BundleDeployer.deploy(
            from: DownloadedUpdate(stagedURL: zipURL, kind: .zip, expectedSha256Hex: nil),
            into: stagingDir)

        _ = try await AppSwapper.swap(staged: deployed, into: victimPath)

        let attributes = try fm.attributesOfItem(atPath: victimPath)
        let newMtime = try #require(attributes[.modificationDate] as? Date)
        #expect(abs(newMtime.timeIntervalSince(pastDate)) < 1.0)
    }

    @Test func swapReleasesQuarantineWhenPresent() async throws {
        let dir = uniqueDir("quarantine")
        let apps = dir.appendingPathComponent("apps")
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        let victim = try makeApp(name: "Victim", bundleID: "org.test.swap.quar", shortVersion: "1.0", in: apps)
        let victimPath = victim.path

        let artifactDir = uniqueDir("artifact")
        _ = try makeApp(name: "Victim", bundleID: "org.test.swap.quar", shortVersion: "2.0", in: artifactDir)
        let zipURL = try await zipArtifacts(in: artifactDir, name: "v2")
        let stagingDir = uniqueDir("staging")
        let deployed = try await BundleDeployer.deploy(
            from: DownloadedUpdate(stagedURL: zipURL, kind: .zip, expectedSha256Hex: nil),
            into: stagingDir)

        // Flag the staged bundle exactly like a downloaded artifact would be.
        let flagged = try await BundleDeployer.runProcess(
            launchPath: "/usr/bin/xattr",
            arguments: ["-w", "com.apple.quarantine", "0081;5f9f0000;Chrome;|Chrome", deployed.stagedAppURL.path])
        #expect(flagged.succeeded, "fixture quarantine flag failed: \(flagged.stderr)")
        #expect(try await quarantineProbeExit(for: deployed.stagedAppURL.path) == 0)

        _ = try await AppSwapper.swap(staged: deployed, into: victimPath)

        // After the swap the installed bundle carries NO quarantine (probe = absent).
        #expect(try await quarantineProbeExit(for: victimPath) != 0)
        #expect(readShortVersion(appPath: victimPath) == "2.0")
    }
}
