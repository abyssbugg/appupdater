// FeedDerivationTests.swift — hermetic tests for the embedded-framework Sparkle feed
// derivation (Scan/FeedDerivation.swift). Zero network: fixtures are REAL app/framework
// bundles built on disk in this suite's own temp root, and the module under test only
// reads bytes (no URLProtocol needed — there is nothing to stub).
// Swift Testing ONLY (XCTest test discovery is broken on this toolchain — gotcha ledger);
// Swift Testing does not re-export Foundation — explicit `import Foundation` below.

import Foundation
import Testing
@testable import AppUpdaterCore

@Suite(.serialized)
struct FeedDerivationTests {
    /// Per-PROCESS unique root (gotcha ledger: fixed shared names collide across concurrent
    /// `swift test` runners); wiped per test in init, DeployTests pattern.
    private var root: URL = Self.sharedRoot
    private static let sharedRoot: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("appupdater-feedderive-\(UUID().uuidString)", isDirectory: true)
    private let fm = FileManager.default

    init() {
        try? fm.removeItem(at: Self.sharedRoot)
        try? fm.createDirectory(at: Self.sharedRoot, withIntermediateDirectories: true)
        root = Self.sharedRoot
    }

    // MARK: - Fixture identifiers (clearly synthetic; shapes only, no real app secrets)

    private static let uuidA = "1b2f3a4c-5d6e-4f70-8a91-2b3c4d5e6f70"
    private static let uuidB = "7e8d9c0b-1a2b-4c3d-8e9f-0a1b2c3d4e5f"
    private static let allZeroUUID = "00000000-0000-0000-0000-000000000000"
    private static let hockeyID = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
    private static let shaLike40Hex = "0123456789abcdef0123456789abcdef01234567"

    // MARK: - Fixtures (real bytes, real bundle layouts)

    /// Synthetic .app: Contents/Info.plist + Contents/MacOS/<name> with the given bytes.
    /// `bundleID` nil omits CFBundleIdentifier entirely (honest-missing fixture).
    private func makeApp(
        name: String, bundleID: String?, executableBytes: Data, in dir: URL
    ) throws -> URL {
        let appURL = dir.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(
            at: contents.appendingPathComponent("MacOS", isDirectory: true),
            withIntermediateDirectories: true)
        var plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key><string>\(name)</string>
            <key>CFBundleExecutable</key><string>\(name)</string>
        """
        if let bundleID {
            plist += "\n    <key>CFBundleIdentifier</key><string>\(bundleID)</string>"
        }
        plist += "\n</dict>\n</plist>\n"
        try plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try executableBytes.write(to: contents.appendingPathComponent("MacOS/\(name)"))
        return appURL
    }

    /// Embedded framework. Classic layout: `<fw>/Versions/A/<name>` + `<fw>/Versions/A/Resources/
    /// Info.plist` (CFBundleExecutable). Flat layout: `<fw>/<name>` + `<fw>/Resources/Info.plist`.
    /// `binaryBytes` nil = framework dir WITHOUT a readable binary (missing-framework-binary case).
    private func makeFramework(
        name: String, binaryBytes: Data?, flat: Bool = false, in parent: URL
    ) throws -> URL {
        let fwURL = parent.appendingPathComponent("\(name).framework", isDirectory: true)
        let binaryDir = flat ? fwURL : fwURL.appendingPathComponent("Versions/A", isDirectory: true)
        let resourcesDir = flat
            ? fwURL.appendingPathComponent("Resources", isDirectory: true)
            : fwURL.appendingPathComponent("Versions/A/Resources", isDirectory: true)
        try fm.createDirectory(at: binaryDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key><string>\(name)</string>
            <key>CFBundleIdentifier</key><string>com.example.embedded.\(name)</string>
        </dict>
        </plist>
        """
        try plist.write(to: resourcesDir.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        if let binaryBytes {
            try binaryBytes.write(to: binaryDir.appendingPathComponent(name))
        }
        return fwURL
    }

    private func binaryData(_ text: String) -> Data {
        Data(text.utf8)
    }

    // MARK: - No frameworks / empty honesty

    @Test func appWithoutUpdaterFrameworksYieldsNoCandidates() throws {
        let app = try makeApp(
            name: "Plain", bundleID: "com.example.plain",
            executableBytes: binaryData("plain main bytes"), in: root)
        #expect(SparkleFeedDerivation.candidateFeeds(appBundlePath: app.path).isEmpty)
    }

    // MARK: - AppCenter

    @Test func appCenterUUIDInFrameworkBinaryYieldsFeed() throws {
        let dir = root.appendingPathComponent("t-appcenter-fw", isDirectory: true)
        let app = try makeApp(
            name: "Centered", bundleID: "com.example.centered",
            executableBytes: binaryData("no secret in host"), in: dir)
        try makeFramework(
            name: "AppCenter",
            binaryBytes: binaryData("AppCenterSDK \(Self.uuidA) config"),
            in: app.appendingPathComponent("Contents/Frameworks", isDirectory: true))

        let feeds = SparkleFeedDerivation.candidateFeeds(appBundlePath: app.path)
        let feed = try #require(feeds.first)
        #expect(feeds.count == 1)
        #expect(feed.url.absoluteString == "https://api.appcenter.ms/v0.1/public/sparkle/apps/\(Self.uuidA)")
        #expect(feed.framework == "AppCenter.framework")
        // Honesty provenance: teardown-confirmed target, verified endpoint label.
        #expect(feed.derivation.contains("framework's binary bytes"))
        #expect(!feed.derivation.contains("UNVERIFIED scan target"))
        #expect(feed.derivation.contains("[C]"))
    }

    @Test func appCenterSecretInAppExecutableYieldsLabeledCandidate() throws {
        // UNVERIFIED scan target (file-header honesty note): AppCenter docs place the app
        // secret in start() code (host binary), so the host executable is scanned too when
        // the framework is present — and the derivation note must SAY it is unverified.
        let dir = root.appendingPathComponent("t-appcenter-host", isDirectory: true)
        let app = try makeApp(
            name: "HostSecret", bundleID: "com.example.host",
            executableBytes: binaryData("MSAppCenter.start(\"\(Self.uuidB)\")"), in: dir)
        try makeFramework(
            name: "AppCenter", binaryBytes: binaryData("framework binary without any uuid"),
            in: app.appendingPathComponent("Contents/Frameworks", isDirectory: true))

        let feeds = SparkleFeedDerivation.candidateFeeds(appBundlePath: app.path)
        let feed = try #require(feeds.first)
        #expect(feeds.count == 1)
        #expect(feed.url.absoluteString == "https://api.appcenter.ms/v0.1/public/sparkle/apps/\(Self.uuidB)")
        #expect(feed.derivation.contains("UNVERIFIED scan target"))
    }

    @Test func duplicateUUIDsDedupeAndOrderIsFrameworkBinaryFirst() throws {
        let dir = root.appendingPathComponent("t-appcenter-dedupe", isDirectory: true)
        let app = try makeApp(
            name: "Dupe", bundleID: "com.example.dupe",
            executableBytes: binaryData("\(Self.uuidB) then again \(Self.uuidA)"), in: dir)
        try makeFramework(
            name: "AppCenter",
            binaryBytes: binaryData("\(Self.uuidA) repeated \(Self.uuidA)"),
            in: app.appendingPathComponent("Contents/Frameworks", isDirectory: true))

        let feeds = SparkleFeedDerivation.candidateFeeds(appBundlePath: app.path)
        try #require(feeds.count == 2, "expected exactly two candidates, got \(feeds)")
        #expect(feeds[0].url.absoluteString.hasSuffix(Self.uuidA))  // framework binary first
        #expect(feeds[1].url.absoluteString.hasSuffix(Self.uuidB))  // host binary second
        #expect(feeds[0].url.absoluteString != feeds[1].url.absoluteString)
    }

    @Test func allZeroPlaceholderUUIDExcluded() throws {
        let dir = root.appendingPathComponent("t-appcenter-zero", isDirectory: true)
        let app = try makeApp(
            name: "Zero", bundleID: "com.example.zero",
            executableBytes: binaryData("nothing"), in: dir)
        try makeFramework(
            name: "AppCenter",
            binaryBytes: binaryData("\(Self.allZeroUUID) and \(Self.uuidA)"),
            in: app.appendingPathComponent("Contents/Frameworks", isDirectory: true))

        let feeds = SparkleFeedDerivation.candidateFeeds(appBundlePath: app.path)
        #expect(feeds.count == 1)
        #expect(try #require(feeds.first).url.absoluteString.hasSuffix(Self.uuidA))
    }

    @Test func boundaryRulesRejectHexAndDashChainFragments() throws {
        let dir = root.appendingPathComponent("t-appcenter-bounds", isDirectory: true)
        let hostJunk = "9\(Self.uuidA) \(Self.uuidB)a \(Self.uuidA)-ffff \(Self.shaLike40Hex)"
        let app = try makeApp(
            name: "Bounds", bundleID: "com.example.bounds",
            executableBytes: binaryData(hostJunk), in: dir)
        try makeFramework(
            name: "AppCenter", binaryBytes: binaryData("clean framework"),
            in: app.appendingPathComponent("Contents/Frameworks", isDirectory: true))

        // Preceding hex digit, trailing hex digit, trailing dash, and a 40-hex SHA-like run
        // must ALL fail the strict boundary rules — no fragment is promoted to a candidate.
        #expect(SparkleFeedDerivation.candidateFeeds(appBundlePath: app.path).isEmpty)
    }

    @Test func identifierAtDataStartAndEndStillMatches() throws {
        // Edge boundaries: a UUID at offset 0 (no leading byte) and one at EOF (no trailing
        // byte) are complete matches, not fragments.
        let uuids = SparkleFeedDerivation.dashedUUIDs(in: binaryData(Self.uuidA))
        #expect(uuids == [Self.uuidA])
    }

    // MARK: - DevMate

    @Test func devMateKitFrameworkYieldsBundleIDFeed() throws {
        let dir = root.appendingPathComponent("t-devmate", isDirectory: true)
        let app = try makeApp(
            name: "DevMateApp", bundleID: "com.example.devmate.app",
            executableBytes: binaryData("main"), in: dir)
        try makeFramework(
            name: "DevMateKit", binaryBytes: nil,  // DevMate needs no binary read
            in: app.appendingPathComponent("Contents/Frameworks", isDirectory: true))

        let feeds = SparkleFeedDerivation.candidateFeeds(appBundlePath: app.path)
        let feed = try #require(feeds.first)
        #expect(feeds.count == 1)
        #expect(feed.url.absoluteString == "https://updates.devmate.com/com.example.devmate.app.xml")
        #expect(feed.framework == "DevMateKit.framework")
        #expect(feed.derivation.contains("CFBundleIdentifier"))
        #expect(feed.derivation.contains("[C]"))
    }

    @Test func devMateFrameworkWithoutBundleIDYieldsNothing() throws {
        let dir = root.appendingPathComponent("t-devmate-nobid", isDirectory: true)
        let app = try makeApp(
            name: "NoBid", bundleID: nil,
            executableBytes: binaryData("main"), in: dir)
        try makeFramework(
            name: "DevMateKit", binaryBytes: nil,
            in: app.appendingPathComponent("Contents/Frameworks", isDirectory: true))

        // Presence without a bundle ID is an honest skip — never a guessed feed.
        #expect(SparkleFeedDerivation.candidateFeeds(appBundlePath: app.path).isEmpty)
    }

    // MARK: - HockeySDK

    @Test func hockeyAppIDYieldsRinkFeedLabeledUnverified() throws {
        let dir = root.appendingPathComponent("t-hockey", isDirectory: true)
        let app = try makeApp(
            name: "HockeyApp", bundleID: "com.example.hockey",
            executableBytes: binaryData("main"), in: dir)
        try makeFramework(
            name: "HockeySDK",
            binaryBytes: binaryData("BITHockeyManager \(Self.hockeyID) end"),
            in: app.appendingPathComponent("Contents/Frameworks", isDirectory: true))

        let feeds = SparkleFeedDerivation.candidateFeeds(appBundlePath: app.path)
        let feed = try #require(feeds.first)
        #expect(feeds.count == 1)
        #expect(feed.url.absoluteString == "https://rink.hockeyapp.net/api/2/apps/\(Self.hockeyID)/sparkle/")
        #expect(feed.framework == "HockeySDK.framework")
        // Teardown marks the Hockey derivation [U] — the note must carry that label.
        #expect(feed.derivation.contains("UNVERIFIED-in-the-wild"))
        #expect(feed.derivation.contains("[U]"))
    }

    @Test func dashedUUIDAndLongHexRunsNeverBecomeHockeyIDs() throws {
        let dir = root.appendingPathComponent("t-hockey-negatives", isDirectory: true)
        let app = try makeApp(
            name: "HockeyNeg", bundleID: "com.example.hockeyneg",
            executableBytes: binaryData("main"), in: dir)
        // A dashed UUID's 32 hex chars are dash-interrupted; a 40-hex run cannot yield a
        // 32-hex match (strict hex boundaries). Neither may surface as a Hockey candidate.
        try makeFramework(
            name: "HockeySDK",
            binaryBytes: binaryData("\(Self.uuidA) \(Self.shaLike40Hex)"),
            in: app.appendingPathComponent("Contents/Frameworks", isDirectory: true))

        #expect(SparkleFeedDerivation.candidateFeeds(appBundlePath: app.path).isEmpty)
    }

    // MARK: - Honest empty on missing/unreadable framework binaries

    @Test func frameworkWithoutReadableBinaryYieldsNoAppCenterCandidate() throws {
        let dir = root.appendingPathComponent("t-appcenter-nobinary", isDirectory: true)
        let app = try makeApp(
            name: "GhostFw", bundleID: "com.example.ghost",
            executableBytes: binaryData("main"), in: dir)
        try makeFramework(
            name: "AppCenter", binaryBytes: nil,  // dir + Info.plist, no binary
            in: app.appendingPathComponent("Contents/Frameworks", isDirectory: true))

        #expect(SparkleFeedDerivation.candidateFeeds(appBundlePath: app.path).isEmpty)
    }

    @Test func missingAppCenterBinaryDoesNotBlockDevMateDerivation() throws {
        let dir = root.appendingPathComponent("t-mixed-nobinary", isDirectory: true)
        let app = try makeApp(
            name: "Mixed", bundleID: "com.example.mixed",
            executableBytes: binaryData("main"), in: dir)
        try makeFramework(
            name: "AppCenter", binaryBytes: nil,
            in: app.appendingPathComponent("Contents/Frameworks", isDirectory: true))
        try makeFramework(
            name: "DevMateKit", binaryBytes: nil,
            in: app.appendingPathComponent("Contents/Frameworks", isDirectory: true))

        let feeds = SparkleFeedDerivation.candidateFeeds(appBundlePath: app.path)
        #expect(feeds.count == 1)
        #expect(try #require(feeds.first).framework == "DevMateKit.framework")
    }

    // MARK: - Multi-framework composition + determinism

    @Test func allThreeFrameworksProduceAllFamiliesInSortedOrder() throws {
        let dir = root.appendingPathComponent("t-all-three", isDirectory: true)
        let app = try makeApp(
            name: "Everything", bundleID: "com.example.everything",
            executableBytes: binaryData("main"), in: dir)
        let frameworksDir = app.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        try makeFramework(name: "HockeySDK", binaryBytes: binaryData("id \(Self.hockeyID)"), in: frameworksDir)
        try makeFramework(name: "AppCenter", binaryBytes: binaryData("secret \(Self.uuidA)"), in: frameworksDir)
        try makeFramework(name: "DevMateKit", binaryBytes: nil, in: frameworksDir)

        let feeds = SparkleFeedDerivation.candidateFeeds(appBundlePath: app.path)
        try #require(feeds.count == 3, "expected exactly three candidates, got \(feeds)")
        #expect(feeds[0].url.absoluteString == "https://api.appcenter.ms/v0.1/public/sparkle/apps/\(Self.uuidA)")
        #expect(feeds[1].url.absoluteString == "https://updates.devmate.com/com.example.everything.xml")
        #expect(feeds[2].url.absoluteString == "https://rink.hockeyapp.net/api/2/apps/\(Self.hockeyID)/sparkle/")
        #expect(feeds.map(\.framework) == ["AppCenter.framework", "DevMateKit.framework", "HockeySDK.framework"])
    }

    @Test func flatFrameworkLayoutIsResolved() throws {
        let dir = root.appendingPathComponent("t-flat", isDirectory: true)
        let app = try makeApp(
            name: "FlatApp", bundleID: "com.example.flat",
            executableBytes: binaryData("main"), in: dir)
        try makeFramework(
            name: "AppCenter", binaryBytes: binaryData("secret \(Self.uuidB)"), flat: true,
            in: app.appendingPathComponent("Contents/Frameworks", isDirectory: true))

        let feeds = SparkleFeedDerivation.candidateFeeds(appBundlePath: app.path)
        #expect(feeds.count == 1)
        #expect(try #require(feeds.first).url.absoluteString.hasSuffix(Self.uuidB))
    }

    @Test func repeatedScansOfSameBundleAreIdentical() throws {
        // The executable resolution is deliberately Bundle(url:)-free (no process-wide
        // cache) — repeated scans of the same path must re-read and agree.
        let dir = root.appendingPathComponent("t-repeat", isDirectory: true)
        let app = try makeApp(
            name: "Repeat", bundleID: "com.example.repeat",
            executableBytes: binaryData("nothing here"), in: dir)
        try makeFramework(
            name: "AppCenter", binaryBytes: binaryData("\(Self.uuidA)"),
            in: app.appendingPathComponent("Contents/Frameworks", isDirectory: true))

        let first = SparkleFeedDerivation.candidateFeeds(appBundlePath: app.path)
        let second = SparkleFeedDerivation.candidateFeeds(appBundlePath: app.path)
        #expect(first == second)
        #expect(!first.isEmpty)
    }
}
