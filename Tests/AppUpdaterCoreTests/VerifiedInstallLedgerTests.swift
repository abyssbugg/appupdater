import Foundation
import Testing
@testable import AppUpdaterCore

/// cmux shape (live 2026-10-30): a verified apply of a claimed 0.65.2.2 reads
/// back as 0.65.2 because the vendor's bundle under-declares its version.
@Suite("VerifiedInstallLedger — no re-offer loop, never a stale suppression")
struct VerifiedInstallLedgerTests {

    private static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("appupdater-verifiedinstall-\(UUID().uuidString)")
    private let workspace: URL
    private let ledger: VerifiedInstallLedger
    private let appURL: URL

    init() throws {
        workspace = Self.root.appendingPathComponent(UUID().uuidString)
        ledger = VerifiedInstallLedger(directory: workspace.appendingPathComponent("support"))
        appURL = workspace.appendingPathComponent("Victim.app")
        let macOS = appURL.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.victim", "CFBundleShortVersionString": "0.65.2",
            "CFBundleVersion": "113", "CFBundleExecutable": "victim"
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: appURL.appendingPathComponent("Contents/Info.plist"))
        try Data("new bytes".utf8).write(to: macOS.appendingPathComponent("victim"))
    }

    private var app: InstalledApp {
        InstalledApp(bundleIdentifier: "com.example.victim", name: "Victim", path: appURL.path,
                     shortVersion: "0.65.2", bundleVersion: "113")
    }

    private func outcome(claim: String, final: String?, aborted: InstallStep? = nil) throws -> InstallOutcome {
        let update = UpdateInfo(source: .github, newestShortVersion: claim,
                                downloadURL: try #require(URL(string: "https://example.com/victim.dmg")),
                                sha256Hex: String(repeating: "a", count: 64), confidence: .medium)
        let plan = try InstallPlanner().plan(app: app, update: update)
        return InstallOutcome(plan: plan, receipts: [], abortedStep: aborted,
                              finalInstalledShortVersion: final, backup: nil)
    }

    @Test func shortfallApplyIsRecordedWithExecutableHash() throws {
        let record = try #require(try ledger.recordIfShortfall(try outcome(claim: "0.65.2.2", final: "0.65.2")))
        #expect(record.claimedShortVersion == "0.65.2.2")
        #expect(record.installedShortVersion == "0.65.2")
        #expect(record.executableSHA256 == VerifiedInstallLedger.executableSHA256(appPath: appURL.path))
        #expect(ledger.load() == [record])
    }

    @Test func nonShortfallOutcomesAreNeverRecorded() throws {
        #expect(try ledger.recordIfShortfall(try outcome(claim: "0.65.2", final: "0.65.2")) == nil)
        #expect(try ledger.recordIfShortfall(try outcome(claim: "0.65.2.2", final: "0.65.2", aborted: .swapBundles)) == nil)
        #expect(try ledger.recordIfShortfall(try outcome(claim: "0.65.2.2", final: nil)) == nil)
        #expect(ledger.load().isEmpty)
    }

    @Test func matchRequiresSameClaimVersionAndBytes() throws {
        try ledger.recordIfShortfall(try outcome(claim: "0.65.2.2", final: "0.65.2"))
        #expect(ledger.matchingRecord(for: app, claimedVersion: "0.65.2.2") != nil)
        #expect(ledger.matchingRecord(for: app, claimedVersion: "0.65.3") == nil)
        var moved = app
        moved.shortVersion = "0.65.1"
        #expect(ledger.matchingRecord(for: moved, claimedVersion: "0.65.2.2") == nil)
        #expect(ledger.matchingRecord(for: app, claimedVersion: "0.65.2.2", executableHash: { _ in "other" }) == nil)
        try Data("vendor shipped new bytes".utf8)
            .write(to: appURL.appendingPathComponent("Contents/MacOS/victim"))
        #expect(ledger.matchingRecord(for: app, claimedVersion: "0.65.2.2") == nil)
    }

    @Test func engineReadsRecordedClaimAsCurrentWithNote() async throws {
        let claim = UpdateInfo(source: .github, newestShortVersion: "0.65.2.2",
                               downloadURL: try #require(URL(string: "https://example.com/victim.dmg")),
                               confidence: .medium)
        let source = FixedClaimSource(claim: claim)
        let before = await UpdateCheckEngine(sources: [source], verifiedInstalls: ledger).check(app: app)
        #expect(before.verdict == "update")
        #expect(before.verifiedInstallNote == nil)

        try ledger.recordIfShortfall(try outcome(claim: "0.65.2.2", final: "0.65.2"))
        let after = await UpdateCheckEngine(sources: [source], verifiedInstalls: ledger).check(app: app)
        #expect(after.verdict == "current")
        #expect(after.resolved == nil)
        #expect(after.candidates == [claim])
        #expect(after.verifiedInstallNote?.contains("0.65.2.2 was installed and verified") == true)

        let newer = UpdateInfo(source: .github, newestShortVersion: "0.65.3",
                               downloadURL: try #require(URL(string: "https://example.com/v.dmg")), confidence: .medium)
        let later = await UpdateCheckEngine(sources: [FixedClaimSource(claim: newer)], verifiedInstalls: ledger)
            .check(app: app)
        #expect(later.verdict == "update")
    }

    private struct FixedClaimSource: UpdateSource {
        static var kind: SourceKind { .github }
        var claim: UpdateInfo
        func fetchUpdateInfo(for app: InstalledApp) async throws -> UpdateInfo? { claim }
    }
}
