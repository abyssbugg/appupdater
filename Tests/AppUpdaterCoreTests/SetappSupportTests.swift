// SetappSupportTests.swift — hermetic tests for Setapp membership
// classification (Sources/AppUpdaterCore/Storefront/SetappSupport.swift,
// GAP #10).
//
// Swift Testing only. Fully hermetic: classification is pure path logic, so
// fixtures are temp directories (never /Applications) plus pure-string checks
// against the documented default root — no filesystem probing of real
// locations, no network, no privilege. Expectations are the documented facts:
// the /Applications/Setapp/ scan root and the shown-but-not-updatable
// handling (UPDATEST-FINDINGS §3.1; MacUpdater's isIgnoredSetappApp).

import Foundation
import Testing
@testable import AppUpdaterCore

// MARK: - Temp fixture helper

/// Creates one fresh temp directory per call; the caller layers fixture
/// bundles under it. Never touches /Applications.
@discardableResult
private func makeSetappTempDir() throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("setapp-support-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

// MARK: - Member fixtures

@Suite("SetappSupport: member classification (documented root)")
struct SetappMemberTests {

    @Test("bundle under a temp root named Setapp → member with documented evidence")
    func bundleUnderFixtureRoot() throws {
        let root = try makeSetappTempDir().appendingPathComponent("Setapp")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = root.appendingPathComponent("Noteplan.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let info = SetappSupport.classify(bundlePath: bundle.path, root: root.path)
        #expect(info.verdict == .member)
        #expect(info.evidence.count == 1)
        #expect(info.evidence[0].contains(root.path))
        #expect(info.evidence[0].contains("UPDATEST-FINDINGS §3.1"))
        #expect(info.note.contains("Setapp apps are updated through the Setapp app"))
        #expect(info.note.contains("isIgnoredSetappApp"))
    }

    @Test("documented default root classifies purely by path string (no FS access)")
    func documentedDefaultRootByString() {
        let info = SetappSupport.classify(bundlePath: "/Applications/Setapp/Bear.app")
        #expect(info.verdict == .member)
        #expect(info.note.contains("shown but not updatable"))
    }

    @Test("case-insensitive containment (macOS default FS)")
    func caseInsensitiveContainment() {
        let info = SetappSupport.classify(bundlePath: "/Applications/setapp/bear.app")
        #expect(info.verdict == .member)
    }

    @Test("path containing .. standardizes into the root → member")
    func dotDotStandardization() {
        let info = SetappSupport.classify(
            bundlePath: "/Applications/Setapp/nested/../Bear.app")
        #expect(info.verdict == .member)
    }

    @Test("root given with a trailing slash still matches")
    func trailingSlashRoot() {
        let info = SetappSupport.classify(
            bundlePath: "/tmp/fix/Setapp/Bear.app",
            root: "/tmp/fix/Setapp/")
        #expect(info.verdict == .member)
    }
}

// MARK: - Not-member fixtures

@Suite("SetappSupport: notMember (outside the documented root)")
struct SetappNotMemberTests {

    @Test("bundle outside the root → notMember with the honest no-marker note")
    func bundleOutsideRoot() throws {
        let base = try makeSetappTempDir()
        let bundle = base.appendingPathComponent("Apps/Bear.app")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let info = SetappSupport.classify(bundlePath: bundle.path, root: base.path + "/Setapp")
        #expect(info.verdict == .notMember)
        #expect(info.evidence.isEmpty)
        #expect(info.note.contains("no plist/entitlement marker"))
        #expect(info.note.contains("MACUPDATER-FINDINGS"))
    }

    @Test("sibling directory that merely CONTAINS the string Setapp is not the root")
    func prefixIsNotSubstringMatch() {
        // "/Applications/SetappHelper/Foo.app" must NOT match root
        // "/Applications/Setapp" — containment requires the "/" boundary.
        let info = SetappSupport.classify(
            bundlePath: "/Applications/SetappHelper/Foo.app")
        #expect(info.verdict == .notMember)
    }
}

// MARK: - Unknown fixtures (first-class)

@Suite("SetappSupport: unknown verdicts")
struct SetappUnknownTests {

    @Test("empty bundle path → unknown with a note, never guessed")
    func emptyPath() {
        let info = SetappSupport.classify(bundlePath: "   ")
        #expect(info.verdict == .unknown)
        #expect(info.evidence.isEmpty)
        #expect(info.note.contains("documented signal"))
    }

    @Test("path equals the root itself → unknown (not a bundle)")
    func pathEqualsRoot() {
        let info = SetappSupport.classify(bundlePath: "/Applications/Setapp")
        #expect(info.verdict == .unknown)
        #expect(info.note.contains("not a bundle"))
    }

    @Test("empty root parameter → unknown, classification withheld")
    func emptyRoot() {
        let info = SetappSupport.classify(bundlePath: "/tmp/Bear.app", root: "")
        #expect(info.verdict == .unknown)
        #expect(info.note.contains("withheld"))
    }

    @Test("the documented root constant is exactly the documented path")
    func documentedRootConstant() {
        #expect(SetappSupport.documentedRoot == "/Applications/Setapp")
    }
}
