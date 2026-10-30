import Foundation
import Testing
@testable import AppUpdaterCore

/// Regressions for two false-positive updates found in the live UI capture
/// 2026-10-30 (Bionic, Telegram Desktop). Each test fails on the pre-fix code.
struct LiveFalsePositiveTests {
    // MARK: semver build metadata

    @Test func buildMetadataIsIgnoredForPrecedence() {
        let oracle = VersionOracle()
        #expect(oracle.compare("1.1.10+8", "1.1.10") == .equal)
        #expect(oracle.compare("1.1.11", "1.1.10+8") == .greater)
        #expect(oracle.compare("1.1.9", "1.1.10+8") == .less)
    }

    @Test func bionicInstalledWithMetadataIsNotOlderThanSameCaskRelease() {
        let (marketing, _) = CaskVersion.split("1.1.10,8")
        #expect(!VersionOracle().isUpdateAvailable(installed: "1.1.10+8", available: marketing))
        #expect(VersionOracle().isUpdateAvailable(installed: "1.1.10+8", available: "1.1.11"))
    }

    @Test func plusWithoutLeadingDigitsStaysUnparseable() {
        // Only real "<version>+<metadata>" is stripped; "+8" alone has no version.
        #expect(!AppVersion("+8").isParseable)
    }

    // MARK: cask bundle-id contradiction

    private func record(_ json: String) throws -> CaskRecord {
        try JSONDecoder().decode(CaskRecord.self, from: Data(json.utf8))
    }

    private let telegramDesktop = InstalledApp(
        bundleIdentifier: "com.tdesktop.Telegram", name: "Telegram", path: "/Applications/Telegram.app")

    @Test func sameNamedCaskFromOtherVendorIsRejected() throws {
        let telegram = try record("""
        {"token":"telegram","version":"13.1.0,283357",
         "artifacts":[{"uninstall":[{"quit":"ru.keepcoder.Telegram"}]},{"app":["Telegram.app"]}]}
        """)
        #expect(telegram.declaredBundleIdentifiers == ["ru.keepcoder.Telegram"])
        #expect(!CaskMatching.caskMatchesInstalledApp(telegram, for: telegramDesktop))
    }

    @Test func caskDeclaringNoIdsStillMatchesByArtifact() throws {
        let desktop = try record("""
        {"token":"telegram-desktop","version":"7.3.3",
         "artifacts":[{"app":["Telegram.app",{"target":"Telegram Desktop.app"}]},
                      {"zap":[{"trash":["~/Library/Preferences/com.tdesktop.Telegram.plist"]}]}]}
        """)
        #expect(desktop.declaredBundleIdentifiers.isEmpty)
        #expect(CaskMatching.caskMatchesInstalledApp(desktop, for: telegramDesktop))
    }

    @Test func sameVendorHelperIdDoesNotContradict() {
        #expect(!CaskMatching.bundleIdentifiersContradict(["com.foo.App.Helper"], "com.foo.App"))
        #expect(!CaskMatching.bundleIdentifiersContradict(["COM.Foo.app"], "com.foo.App"))
        #expect(CaskMatching.bundleIdentifiersContradict(["ru.keepcoder.Telegram"], "com.tdesktop.Telegram"))
        #expect(!CaskMatching.bundleIdentifiersContradict([], "com.tdesktop.Telegram"))
    }

    @Test func quitDeclaredAsArrayInZapIsCollected() throws {
        let rec = try record("""
        {"token":"x","artifacts":[{"zap":{"quit":["com.a.One","com.a.Two"]}},{"app":["X.app"]}]}
        """)
        #expect(rec.declaredBundleIdentifiers == ["com.a.One", "com.a.Two"])
    }
}

/// `InstalledApp.checkedAt` was declared but never set (live finding 2026-10-30).
struct CheckedAtStampTests {
    @Test func engineStampsCheckedAtAndRowsKeepIt() async throws {
        let pinned = Date(timeIntervalSince1970: 1_234_567)
        let app = InstalledApp(bundleIdentifier: "com.example.Stamp", name: "Stamp", path: "/Applications/Stamp.app")
        let check = await UpdateCheckEngine(sources: [], now: { pinned }).check(app: app)
        let stamp = try #require(check.app.checkedAt)
        #expect(stamp == pinned)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appupdater-stamp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RuleStore(directory: dir)
        let rows = await store.evaluate(apps: [app], checks: [check])
        #expect(rows.first?.app.checkedAt == stamp)
    }
}
