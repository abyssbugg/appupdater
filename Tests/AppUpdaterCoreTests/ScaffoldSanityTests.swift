// Scaffold sanity tests. Owns ONLY model-level checks.
// (Scanner / Cask / Sparkle / MAS / VersionOracles add their own files in these folders.)
// Swift Testing (not XCTest): XCTest discovery is broken on this toolchain (Xcode 27 beta).

import Testing
import Foundation
@testable import AppUpdaterCore

@Suite struct ScaffoldSanityTests {
    @Test func installedAppRoundTrip() throws {
        let app = InstalledApp(
            bundleIdentifier: "io.appupdater.test",
            name: "Test App",
            path: "/Applications/Test.app",
            shortVersion: "1.2.3",
            bundleVersion: "123",
            isMacAppStore: false,
            sparkleFeedURL: "https://example.com/appcast.xml"
        )
        let decoded = try JSONDecoder().decode(InstalledApp.self, from: try JSONEncoder().encode(app))
        #expect(decoded == app)
    }

    @Test func updateInfoSourceAndConfidence() throws {
        let info = UpdateInfo(
            source: .cask,
            newestShortVersion: "2.0",
            downloadURL: URL(string: "https://example.com/app.dmg"),
            sha256Hex: "abc",
            confidence: .low
        )
        let decoded = try JSONDecoder().decode(UpdateInfo.self, from: try JSONEncoder().encode(info))
        #expect(decoded.source == .cask)
        #expect(decoded.confidence == .low)
        #expect(decoded.sha256Hex == "abc")
    }
}
