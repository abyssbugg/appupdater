// SecurityPanelLiveTests.swift — LIVE-tool tests for the security panel:
// real /usr/bin/codesign + /usr/sbin/spctl run against fixture .app bundles
// built in a per-process temp root (hermetic: no network, no system apps
// touched, fixtures are ad-hoc-signed which needs no identity).
//
// Swift Testing ONLY — XCTest discovery is broken on this toolchain (Xcode 27
// beta, see AGENTS.md gotcha ledger); `import Foundation` is required.
//
// Fixture discipline (AGENTS.md gotcha ledger): the suite root name embeds a
// per-process UUID and is NEVER wiped; each test builds its own uniquely named
// sub-bundle and removes only that. Two concurrent `swift test` runners never
// share fixture paths.
//
// Reality pins this suite encodes (captured on the macOS 27.2 build host):
//   • an ad-hoc-signed bundle verifies strictly (exit 0) but is Gatekeeper-
//     rejected with no source line — the honest live happy path;
//   • arm64 ld AUTO-SIGNS linked binaries: a never-signed bundle with a
//     compiled executable carries a LINKER-SIGNED inner signature — -dv
//     succeeds, strict deep verify fails, spctl errors (exit 1, honest
//     unknown), entitlements absent;
//   • stripping that signature (--remove-signature) yields the truly-unsigned
//     shape: "code object is not signed at all", spctl
//     rejected/source=no usable signature;
//   • a tampered Resources file: strict verify fails while -dv still exits 0,
//     and spctl exits 1 (an error, not a rejection) — an honest .unknown;
//   • ad-hoc signing WITH --entitlements round-trips the dict readably;
//   • a stray file directly under Contents/ (not Resources/) breaks even
//     codesign -s - (it is scanned as nested code) — fixture discipline.

import Testing
import Foundation
@testable import AppUpdaterCore

// MARK: - Fixture infrastructure (compiled once per process)

private enum LiveFixture {

    /// Per-process root: UUID-named so concurrent `swift test` processes never
    /// collide (AGENTS.md gotcha ledger). Never wiped by the suite itself.
    static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("appupdater-secpanel-live-\(UUID().uuidString)", isDirectory: true)

    /// A real Mach-O binary for fixture bundles, compiled once per process via
    /// the toolchain's own swiftc (local, offline). `.failure` carries the
    /// compiler's stderr so a broken environment reports honestly.
    static let binary: Result<URL, FixtureBuildError> = {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let sourceURL = root.appendingPathComponent("FixtureMain.swift")
            try Data("import Foundation\nlet _ = CommandLine.arguments.count\n".utf8)
                .write(to: sourceURL)
            let binaryURL = root.appendingPathComponent("fixture-bin")
            let run = try runTool("/usr/bin/swiftc", ["-o", binaryURL.path, sourceURL.path])
            guard run.status == 0, FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
                return .failure(FixtureBuildError(
                    message: "swiftc failed (exit \(run.status)): \(run.stderr)"))
            }
            return .success(binaryURL)
        } catch {
            return .failure(FixtureBuildError(message: "fixture compile setup failed: \(error)"))
        }
    }()

    /// Builds `<root>/<uuid>-<name>.app` with the compiled binary as its main
    /// executable and a minimal valid Info.plist. NOT signed — call `sign`.
    static func makeApp(named name: String) throws -> URL {
        let bin = try binary.get()
        let appURL = root.appendingPathComponent("\(UUID().uuidString)-\(name).app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bin, to: macOS.appendingPathComponent(name))
        let plist: [String: Any] = [
            "CFBundleExecutable": name,
            "CFBundleIdentifier": "com.appupdater.secpanel.\(name.lowercased())",
            "CFBundleName": name,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return appURL
    }

    /// Ad-hoc signs a fixture (test SETUP: local, offline, no identity).
    /// `extraArgs` carries e.g. `--entitlements <file>`.
    static func sign(_ appURL: URL, extraArgs: [String] = []) throws {
        let run = try runTool(
            SecInspector.codesignPath,
            ["-s", "-"] + extraArgs + [appURL.path])
        guard run.status == 0 else {
            throw FixtureBuildError(message: "codesign -s - failed (exit \(run.status)): \(run.stderr)")
        }
    }

    /// Recursive path+size listing of a bundle — the read-only probe of the
    /// panel: inspecting must not change a single file.
    static func listing(of url: URL) throws -> [FileStamp] {
        var out: [FileStamp] = []
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [])
        else { return out }
        for case let next as URL in enumerator {
            let size = (try? next.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
            out.append(FileStamp(path: next.path, size: size))
        }
        return out.sorted { $0.path < $1.path }
    }

    static func discard(_ appURL: URL) {
        try? FileManager.default.removeItem(at: appURL)
    }
}

private struct FixtureBuildError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct FileStamp: Equatable {
    let path: String
    let size: Int
}

private struct ToolOutput {
    let stdout: String
    let stderr: String
    let status: Int32
}

/// Synchronous direct process helper for TEST SETUP only (signing, compiling).
/// The production path under test uses SecProcessRunner.live() — this exists
/// so the setup itself has no dependency on the seam it exercises.
private func runTool(_ launchPath: String, _ arguments: [String]) throws -> ToolOutput {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
    let stderrData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ToolOutput(
        stdout: String(decoding: stdoutData, as: UTF8.self),
        stderr: String(decoding: stderrData, as: UTF8.self),
        status: process.terminationStatus)
}

// MARK: - Tests

@Suite struct SecurityPanelLiveTests {

    // Same XML the parse-suite fixture carries (newlines inserted between
    // elements for line length; plist XML is whitespace-insensitive).
    private static let sandboxedEntitlementsXML = """
    <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.network.client</key><true/>
    <key>keychain-access-groups</key><array><string>groupA</string><string>groupB</string></array>
    </dict></plist>
    """

    @Test func toolPathsExistOnThisMachine() {
        #expect(FileManager.default.isExecutableFile(atPath: SecInspector.codesignPath))
        #expect(FileManager.default.isExecutableFile(atPath: SecInspector.spctlPath))
    }

    @Test func adHocSignedBundleIsFullyReportedAndUntouched() async throws {
        let appURL = try LiveFixture.makeApp(named: "Happy")
        defer { LiveFixture.discard(appURL) }
        try LiveFixture.sign(appURL)

        let before = try LiveFixture.listing(of: appURL)
        let report = await SecInspector.inspect(appAt: appURL, using: .live())
        let after = try LiveFixture.listing(of: appURL)
        #expect(before == after) // read-only: the panel never modifies the bundle

        #expect(report.signaturePresent == true)
        #expect(report.codesignValid == true)
        #expect(report.isAdHoc == true)
        #expect(report.hardenedRuntime == false)
        #expect(report.linkerSigned == false)
        #expect(report.teamIdentifier == nil) // ad-hoc: honestly no team
        #expect(report.signatureAuthorities.isEmpty)
        #expect(report.cdHash != nil)
        #expect(report.gatekeeperAssessment == .rejected) // ad-hoc is Gatekeeper-rejected
        #expect(report.gatekeeperSource == nil) // verified shape: no source line for ad-hoc
        #expect(report.entitlementsPresent == false) // no entitlements were embedded
        #expect(report.sandboxed == false)
        #expect(report.entitlementKeys.isEmpty)
        #expect(report.notes.contains { $0.contains("bundle carries no entitlements") })
    }

    @Test func linkerSignedExecutableBundleShape() async throws {
        // REAL-WORLD SHAPE (macOS 27.2, arm64): ld auto-signs the linked
        // binary, so a bundle never explicitly signed carries a LINKER-SIGNED
        // inner executable. Machine-verified behavior:
        //   • codesign -dv succeeds (exit 0) via the inner signature —
        //     flags=0x20002(adhoc,linker-signed), TeamIdentifier=not set;
        //   • strict deep verify FAILS ("code has no resources but signature
        //     indicates they must be present");
        //   • spctl exits 1 (an error, not an assessment) → honest .unknown;
        //   • the entitlements probe exits 0 with nothing parseable → no
        //     entitlements (present=false, sandboxed=false).
        let appURL = try LiveFixture.makeApp(named: "LinkerSigned")
        defer { LiveFixture.discard(appURL) }

        let report = await SecInspector.inspect(appAt: appURL, using: .live())
        #expect(report.signaturePresent == true)
        #expect(report.isAdHoc == true)
        #expect(report.linkerSigned == true)
        #expect(report.hardenedRuntime == false)
        #expect(report.teamIdentifier == nil)
        #expect(report.signatureAuthorities.isEmpty)
        #expect(report.cdHash != nil)
        #expect(report.codesignValid == false)
        #expect(report.notes.contains { $0.contains("--deep --strict failed (exit 1)")
            && $0.contains("code has no resources but signature indicates they must be present") })
        #expect(report.gatekeeperAssessment == .unknown)
        #expect(report.notes.contains { $0.contains("could not produce an assessment (exit 1)") })
        #expect(report.entitlementsPresent == false)
        #expect(report.sandboxed == false)
        #expect(report.notes.contains { $0.contains("bundle carries no entitlements") })
    }

    @Test func trulyUnsignedBundleAfterRemoveSignature() async throws {
        // Stripping the linker signature yields the genuinely-unsigned shape:
        // "code object is not signed at all", spctl rejected with
        // source=no usable signature, entitlements unreadable.
        let appURL = try LiveFixture.makeApp(named: "Bare")
        defer { LiveFixture.discard(appURL) }
        let exeURL = appURL.appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent("Bare")
        let strip = try runTool(SecInspector.codesignPath, ["--remove-signature", exeURL.path])
        #expect(strip.status == 0)

        let report = await SecInspector.inspect(appAt: appURL, using: .live())
        #expect(report.signaturePresent == false)
        #expect(report.notes.contains { $0.contains("the bundle is not signed (exit 1)")
            && $0.contains("code object is not signed at all") })
        #expect(report.codesignValid == false)
        #expect(report.gatekeeperAssessment == .rejected)
        #expect(report.gatekeeperSource == "no usable signature")
        #expect(report.teamIdentifier == nil)
        #expect(report.signatureAuthorities.isEmpty)
        #expect(report.entitlementsPresent == nil) // unreadable (unsigned), not absent
        #expect(report.sandboxed == nil)
        #expect(report.hardenedRuntime == nil)
        #expect(report.notes.contains { $0.contains("entitlements unreadable") })
    }

    @Test func tamperedBundleFailsStrictVerifyWithUnknownGatekeeper() async throws {
        // The tamper target lives in Contents/Resources/ (a file directly
        // under Contents/ is treated as nested CODE by codesign and breaks
        // even the SETUP signing — machine-verified).
        let appURL = try LiveFixture.makeApp(named: "Tampered")
        defer { LiveFixture.discard(appURL) }
        let noteURL = appURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
            .appendingPathComponent("note.txt")
        try FileManager.default.createDirectory(
            at: noteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("note".utf8).write(to: noteURL)
        try LiveFixture.sign(appURL)
        try Data("TAMPERED-NOTE".utf8).write(to: noteURL) // break the seal

        let report = await SecInspector.inspect(appAt: appURL, using: .live())
        #expect(report.signaturePresent == true) // -dv still exits 0 on a tampered bundle
        #expect(report.codesignValid == false)
        #expect(report.notes.contains { $0.contains("--deep --strict failed (exit 1)")
            && $0.contains("a sealed resource is missing or invalid") })
        // spctl exits 1 on this shape (an error, not an assessment) — the panel
        // must refuse to call it rejected: unknown is the honest verdict.
        #expect(report.gatekeeperAssessment == .unknown)
        #expect(report.notes.contains { $0.contains("could not produce an assessment (exit 1)") })
    }

    @Test func sandboxedEntitlementsRoundTrip() async throws {
        let appURL = try LiveFixture.makeApp(named: "Sandboxed")
        defer { LiveFixture.discard(appURL) }
        let entURL = LiveFixture.root
            .appendingPathComponent("\(UUID().uuidString)-ent.plist")
        try Data(Self.sandboxedEntitlementsXML.utf8).write(to: entURL)
        defer { try? FileManager.default.removeItem(at: entURL) }
        try LiveFixture.sign(appURL, extraArgs: ["--entitlements", entURL.path])

        let report = await SecInspector.inspect(appAt: appURL, using: .live())
        #expect(report.signaturePresent == true)
        #expect(report.codesignValid == true)
        #expect(report.entitlementsPresent == true)
        #expect(report.sandboxed == true)
        #expect(report.keychainAccessGroupsCount == 2)
        #expect(report.entitlementKeys == [
            "com.apple.security.app-sandbox",
            "com.apple.security.network.client",
            "keychain-access-groups",
        ])
        #expect(report.notes.isEmpty || !report.notes.contains {
            $0.contains("unreadable") || $0.contains("withheld")
        })
    }

    @Test func bundleWithoutExecutableIsReportedNotThrown() async throws {
        let appURL = LiveFixture.root
            .appendingPathComponent("\(UUID().uuidString)-NoExec.app", isDirectory: true)
        defer { LiveFixture.discard(appURL) }
        let contents = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.appupdater.secpanel.noexec"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let report = await SecInspector.inspect(appAt: appURL, using: .live())
        #expect(report.signaturePresent == false) // "code object is not signed at all"
        #expect(report.codesignValid == false)
        #expect(report.gatekeeperAssessment == .rejected)
        #expect(report.gatekeeperSource == "no usable signature")
        #expect(report.entitlementsPresent == nil)
        #expect(report.sandboxed == nil)
        #expect(!report.notes.isEmpty)
    }

    @Test func plainFileAppShortCircuitsWithOneNote() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("appupdater-secpanel-live-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("Fake.app")
        try Data("junk".utf8).write(to: fileURL)

        let report = await SecInspector.inspect(appAt: fileURL, using: .live())
        #expect(report.notes.count == 1)
        #expect(report.notes[0].contains("not a bundle directory"))
        #expect(report.signaturePresent == nil)
        #expect(report.codesignValid == nil)
        #expect(report.gatekeeperAssessment == .unknown)
        #expect(report.sandboxed == nil)
    }
}
