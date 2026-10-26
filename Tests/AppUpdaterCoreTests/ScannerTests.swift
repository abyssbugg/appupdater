// ScannerTests.swift — hermetic tests for ProductionAppScanner.
// Scan lane only. Swift Testing ONLY — XCTest discovery is broken on this toolchain
// (Xcode 27 beta, see AGENTS.md gotcha ledger). Swift Testing does not re-export Foundation,
// so `import Foundation` is required here.

import Testing
import Foundation
@testable import AppUpdaterCore

// MARK: - Hermetic fixtures (real .app bundles written under a per-test temp directory)

/// Creates a unique scan root under the process temporary directory.
private func makeScanRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("appupdater-scantests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Writes a standard `.app` bundle into `root` (or a plain file when `asDirectory` is false)
/// and returns its URL. `bundleName` must include the ".app" suffix.
@discardableResult
private func writeBundle(
    in root: URL,
    name bundleName: String,
    plist: [String: Any] = [:],
    withMASReceipt: Bool = false,
    asDirectory: Bool = true
) throws -> URL {
    let appURL = root.appendingPathComponent(bundleName)
    if asDirectory {
        let contents = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        if withMASReceipt {
            let receiptDir = contents.appendingPathComponent("_MASReceipt")
            try FileManager.default.createDirectory(at: receiptDir, withIntermediateDirectories: true)
            try Data().write(to: receiptDir.appendingPathComponent("_MASReceipt"))
        }
        if !plist.isEmpty {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
    } else {
        try Data("junk".utf8).write(to: appURL)
    }
    return appURL
}

// MARK: - Helpers shared with assertions

/// Path expectation for one component under a directory the scanner enumerates, derived by
/// *performing the same enumeration* (`contentsOfDirectory`) and applying the same trailing-
/// slash normalization. URL arithmetic (appendingPathComponent/resolvingSymlinksInPath) does
/// not reproduce FileManager's directory-symlink-resolving enumeration (e.g. /var →
/// /private/var under the system temporary directory), so predictions come from enumeration.
private func enumeratedAppPath(_ directory: URL, _ component: String) throws -> String {
    let entries = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil, options: [])
    let entry = try #require(entries.first { $0.lastPathComponent == component })
    var path = entry.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") {
        path.removeLast()
    }
    return path
}

// MARK: - Tests

@Suite struct ScannerTests {

    @Test func mapsInfoPlistBasics() async throws {
        let root = try makeScanRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBundle(in: root, name: "Target.app", plist: [
            "CFBundleIdentifier": "com.acme.target",
            "CFBundleName": "Target",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "123",
            "LSMinimumSystemVersion": "14.0",
        ])

        let apps = try await ProductionAppScanner().scan(directoryURLs: [root])

        #expect(apps.count == 1)
        let app = try #require(apps.first)
        #expect(app.bundleIdentifier == "com.acme.target")
        #expect(app.name == "Target")
        let expectedPath = try enumeratedAppPath(root, "Target.app")
        #expect(app.path == expectedPath)
        #expect(app.shortVersion == "1.2.3")
        #expect(app.bundleVersion == "123")
        #expect(app.minimumSystemVersion == "14.0")
        #expect(app.sparkleFeedURL == nil)
        #expect(app.isMacAppStore == false)
        #expect(app.signatureTeamID == nil)   // codesign is another lane's work
        #expect(app.checkedAt == nil)         // result stamping is another lane's work
    }

    @Test func nameFallsBackToDisplayNameThenFolderName() async throws {
        let root = try makeScanRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBundle(in: root, name: "DisplayOnly.app", plist: [
            "CFBundleIdentifier": "com.acme.displayonly",
            "CFBundleDisplayName": "Shown Name",
        ])
        try writeBundle(in: root, name: "Bare.app", plist: [
            "CFBundleIdentifier": "com.acme.bare",
        ])

        let apps = try await ProductionAppScanner().scan(directoryURLs: [root])
        let byID = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleIdentifier, $0) })

        #expect(byID["com.acme.displayonly"]?.name == "Shown Name")
        #expect(byID["com.acme.bare"]?.name == "Bare")
    }

    @Test func sparkleFeedURLPopulatedWhenSUFeedURLPresent() async throws {
        let root = try makeScanRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let feedURL = "https://updates.acme.example/target/appcast.xml"
        try writeBundle(in: root, name: "Fed.app", plist: [
            "CFBundleIdentifier": "com.acme.fed",
            "CFBundleName": "Fed",
            "SUFeedURL": feedURL,
        ])

        let apps = try await ProductionAppScanner().scan(directoryURLs: [root])
        #expect(apps.count == 1)
        #expect(apps.first?.sparkleFeedURL == feedURL)
    }

    @Test func macAppStoreReceiptDetection() async throws {
        let root = try makeScanRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBundle(in: root, name: "Store.app", plist: [
            "CFBundleIdentifier": "com.acme.store",
            "CFBundleName": "Store",
        ], withMASReceipt: true)
        try writeBundle(in: root, name: "Vendor.app", plist: [
            "CFBundleIdentifier": "com.acme.vendor",
            "CFBundleName": "Vendor",
        ], withMASReceipt: false)

        let apps = try await ProductionAppScanner().scan(directoryURLs: [root])
        let byID = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleIdentifier, $0) })

        #expect(byID["com.acme.store"]?.isMacAppStore == true)
        #expect(byID["com.acme.vendor"]?.isMacAppStore == false)
    }

    @Test func ignoresNonAppEntriesAndNonDirectoryAppFiles() async throws {
        let root = try makeScanRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBundle(in: root, name: "Real.app", plist: [
            "CFBundleIdentifier": "com.acme.real",
            "CFBundleName": "Real",
        ])
        try Data("notes".utf8).write(to: root.appendingPathComponent("Notes.txt"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Support"), withIntermediateDirectories: true)
        try writeBundle(in: root, name: "Fake.app", asDirectory: false)

        let apps = try await ProductionAppScanner().scan(directoryURLs: [root])
        #expect(apps.count == 1)
        #expect(apps.first?.name == "Real")
    }

    @Test func duplicateBundleIdentifiersKeptAsSeparateEntries() async throws {
        let root = try makeScanRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBundle(in: root, name: "One.app", plist: [
            "CFBundleIdentifier": "com.acme.dupe",
            "CFBundleName": "Dupe",
            "CFBundleShortVersionString": "1.0",
        ])
        try writeBundle(in: root, name: "Two.app", plist: [
            "CFBundleIdentifier": "com.acme.dupe",
            "CFBundleName": "Dupe",
            "CFBundleShortVersionString": "2.0",
        ])

        let apps = try await ProductionAppScanner().scan(directoryURLs: [root])
        #expect(apps.count == 2)
        #expect(Set(apps.map(\.bundleIdentifier)) == ["com.acme.dupe"])
        #expect(Set(apps.map(\.id)).count == 2)   // id includes path → distinct, no Identifiable collision
        #expect(Set(apps.compactMap(\.shortVersion)) == ["1.0", "2.0"])
    }

    @Test func deterministicSortOrderByNameThenPath() async throws {
        let root = try makeScanRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBundle(in: root, name: "Z.app", plist: ["CFBundleName": "Zed", "CFBundleIdentifier": "com.z"])
        try writeBundle(in: root, name: "A.app", plist: ["CFBundleName": "Alpha", "CFBundleIdentifier": "com.a"])
        try writeBundle(in: root, name: "B.app", plist: ["CFBundleName": "Beta", "CFBundleIdentifier": "com.b"])

        let apps = try await ProductionAppScanner().scan(directoryURLs: [root])
        #expect(apps.count == 3)
        #expect(apps.map(\.name) == ["Alpha", "Beta", "Zed"])
    }

    @Test func nameTiesSortByPathRegardlessOfInputOrder() async throws {
        let root = try makeScanRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dirA = root.appendingPathComponent("DirA", isDirectory: true)
        let dirB = root.appendingPathComponent("DirB", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)
        try writeBundle(in: dirA, name: "P.app", plist: ["CFBundleName": "Same", "CFBundleIdentifier": "com.pair.a"])
        try writeBundle(in: dirB, name: "P.app", plist: ["CFBundleName": "Same", "CFBundleIdentifier": "com.pair.b"])

        let apps = try await ProductionAppScanner().scan(directoryURLs: [dirB, dirA])
        #expect(apps.count == 2)
        #expect(apps.map(\.name).allSatisfy { $0 == "Same" })
        let expectedPaths = [
            try enumeratedAppPath(dirA, "P.app"),
            try enumeratedAppPath(dirB, "P.app"),
        ]
        #expect(apps.map(\.path) == expectedPaths)
    }

    @Test func followsSymlinkedAppBundleAndReportsTheLinkPath() async throws {
        let root = try makeScanRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let realDir = root.appendingPathComponent("Real", isDirectory: true)
        let linkDir = root.appendingPathComponent("Linked", isDirectory: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)
        let realURL = try writeBundle(in: realDir, name: "Rel.app", plist: [
            "CFBundleIdentifier": "com.acme.rel",
            "CFBundleName": "RelApp",
            "CFBundleShortVersionString": "3.1",
        ])
        let linkURL = linkDir.appendingPathComponent("Rel.app")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: realURL)

        let apps = try await ProductionAppScanner().scan(directoryURLs: [linkDir])
        #expect(apps.count == 1)
        let app = try #require(apps.first)
        let linkedPath = try enumeratedAppPath(linkDir, "Rel.app")
        let targetPath = try enumeratedAppPath(realDir, "Rel.app")
        #expect(app.path == linkedPath)   // entry path = the link itself
        #expect(app.path != targetPath)   // NOT the resolved target
        #expect(app.name == "RelApp")     // values from the link target
        #expect(app.shortVersion == "3.1")
    }

    @Test func degenerateAppBundleWithoutInfoPlistUsesFolderNameIdentity() async throws {
        let root = try makeScanRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBundle(in: root, name: "Mystery.app")   // Contents only, no Info.plist

        let apps = try await ProductionAppScanner().scan(directoryURLs: [root])
        #expect(apps.count == 1)
        let app = try #require(apps.first)
        #expect(app.bundleIdentifier == "Mystery")   // documented fallback: folder name
        #expect(app.name == "Mystery")
        #expect(app.shortVersion == nil)
        #expect(app.bundleVersion == nil)
    }

    @Test func throwsWhenDirectoryCannotBeListed() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("appupdater-does-not-exist-\(UUID().uuidString)", isDirectory: true)
        // Per scan()'s doc comment: an unlistable directory aborts the scan.
        await #expect(throws: Error.self) {
            _ = try await ProductionAppScanner().scan(directoryURLs: [missing])
        }
    }

    @Test func repeatedDirectoryURLYieldsNoDuplicatePaths() async throws {
        let root = try makeScanRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBundle(in: root, name: "A.app", plist: ["CFBundleName": "A", "CFBundleIdentifier": "com.a"])
        try writeBundle(in: root, name: "B.app", plist: ["CFBundleName": "B", "CFBundleIdentifier": "com.b"])

        let once = try await ProductionAppScanner().scan(directoryURLs: [root])
        let twice = try await ProductionAppScanner().scan(directoryURLs: [root, root])
        #expect(once.count == 2)
        #expect(twice.count == 2)   // identical POSIX paths collapse to one entry
    }
}
