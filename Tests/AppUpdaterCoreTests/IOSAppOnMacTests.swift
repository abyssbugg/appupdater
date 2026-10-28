// IOSAppOnMacTests.swift — hermetic tests for iOS-apps-on-Mac classification
// (Sources/AppUpdaterCore/Storefront/IOSAppOnMac.swift, GAP #10).
//
// Swift Testing only. Fully hermetic: fixtures are REAL bundles layered in
// per-test UUID temp dirs (read through the FileManager-backed reader — the
// repo's own temp space, never /Applications or system paths); the Spotlight
// adamID and pkgutil probe seams are ALWAYS stubbed (canned / nil / throwing
// closures), so no process is ever spawned and there is no network.
//
// Expected shapes mirror UPDATEST-FINDINGS §3.1 verbatim: the four documented
// bundle-relative marker paths, the documented Spotlight key, and the three
// documented fields (trackId, purchaseDate, installedDate). Malformed markers
// must produce the honest unknown verdict with notes, never a guess.

import Foundation
import Testing
@testable import AppUpdaterCore

// MARK: - Fixture helpers (per-test UUID temp dirs; no shared state)

private func makeFixtureBase() throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("iosappmac-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

private func makeBundle(_ name: String = "Fixture.app", in base: URL) throws -> URL {
    let bundle = base.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    return bundle
}

private func writeData(_ data: Data, at url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

private func writePlistDict(_ dict: [String: Any], at url: URL) throws {
    let data = try PropertyListSerialization.data(
        fromPropertyList: dict, format: .binary, options: 0)
    try writeData(data, at: url)
}

private func writeJSONDict(_ dict: [String: Any], at url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: dict)
    try writeData(data, at: url)
}

/// Probes that answer nothing (the "no signal" stub).
private let silentProbes = IOSAppProbes(adamID: { _ in nil }, pkgutil: { _ in nil })

/// A tiny ISO-8601 helper mirroring the implementation's documented attempts
/// (plain first, then fractional seconds — mirrors `documentedDateValue`).
private func isoDate(_ string: String) -> Date? {
    if let date = ISO8601DateFormatter().date(from: string) { return date }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions.insert(.withFractionalSeconds)
    return fractional.date(from: string)
}

// MARK: - Wrapper metadata (Wrapper/iTunesMetadata.plist)

@Suite("IOSAppOnMac: wrapper iTunesMetadata.plist (happy + malformed)")
struct IOSWrapperMetadataTests {

    @Test("happy wrapper: trackId + native plist purchaseDate → iosAppOnMac")
    func happyWrapper() async throws {
        let base = try makeFixtureBase()
        let bundle = try makeBundle(in: base)
        let purchase = Date(timeIntervalSince1970: 1_700_000_000)
        try writePlistDict(
            ["trackId": 123_456, "purchaseDate": purchase],
            at: bundle.appendingPathComponent("Wrapper/iTunesMetadata.plist"))

        let info = await IOSAppOnMac.classify(bundlePath: bundle.path, probes: silentProbes)
        #expect(info.verdict == .iosAppOnMac)
        #expect(info.trackId == "123456")
        #expect(info.purchaseDate == purchase)
        #expect(info.note.contains(
            "This iOS app can only be updated through the Mac App Store"))
        #expect(info.evidence.contains { $0.contains("Wrapper/iTunesMetadata.plist") })
    }

    @Test("ISO-8601 string purchaseDate in the wrapper plist is parsed")
    func isoStringPurchaseDate() async throws {
        let base = try makeFixtureBase()
        let bundle = try makeBundle(in: base)
        try writePlistDict(
            ["trackId": "861309801", "purchaseDate": "2024-03-05T10:20:30Z"],
            at: bundle.appendingPathComponent("Wrapper/iTunesMetadata.plist"))

        let info = await IOSAppOnMac.classify(bundlePath: bundle.path, probes: silentProbes)
        #expect(info.verdict == .iosAppOnMac)
        #expect(info.trackId == "861309801")
        #expect(info.purchaseDate == isoDate("2024-03-05T10:20:30Z"))
    }

    @Test("malformed wrapper plist → unknown with an explicit unreadable note")
    func malformedWrapperPlist() async throws {
        let base = try makeFixtureBase()
        let bundle = try makeBundle(in: base)
        try writeData(
            Data("this is not a plist".utf8),
            at: bundle.appendingPathComponent("Wrapper/iTunesMetadata.plist"))

        let info = await IOSAppOnMac.classify(bundlePath: bundle.path, probes: silentProbes)
        #expect(info.verdict == .unknown)
        #expect(info.trackId == nil)
        #expect(info.note.contains("unreadable"))
        #expect(info.note.contains("not a parseable plist"))
    }

    @Test("unreadable wrapper marker (read throws) → unknown with note")
    func unreadableWrapperMarker() async throws {
        let base = try makeFixtureBase()
        let bundle = try makeBundle(in: base)
        try writeData(Data(), at: bundle.appendingPathComponent("Wrapper/iTunesMetadata.plist"))
        let throwingReader = IOSBundleFileReader(
            read: { _ in throw CocoaError(.fileReadUnknown) },
            exists: { _ in true })

        let info = await IOSAppOnMac.classify(
            bundlePath: bundle.path, reader: throwingReader, probes: silentProbes)
        #expect(info.verdict == .unknown)
        #expect(info.note.contains("read failed"))
    }

    @Test("wrapper marker present but documented field unparseable → still iosAppOnMac, date nil, note")
    func unparseableFieldInsideReadableMarker() async throws {
        let base = try makeFixtureBase()
        let bundle = try makeBundle(in: base)
        try writePlistDict(
            ["trackId": [1, 2], "purchaseDate": "not-a-date"],
            at: bundle.appendingPathComponent("Wrapper/iTunesMetadata.plist"))

        let info = await IOSAppOnMac.classify(bundlePath: bundle.path, probes: silentProbes)
        #expect(info.verdict == .iosAppOnMac)
        #expect(info.trackId == nil)
        #expect(info.purchaseDate == nil)
        #expect(info.evidence.contains { $0.contains("unparseable") })
    }

    @Test("wrapper beats a co-present _MASReceipt (documented-precedence note)")
    func wrapperBeatsMASReceipt() async throws {
        let base = try makeFixtureBase()
        let bundle = try makeBundle(in: base)
        try writePlistDict(
            ["trackId": 42],
            at: bundle.appendingPathComponent("Wrapper/iTunesMetadata.plist"))
        try writeData(
            Data([0x00, 0x01, 0x02]),
            at: bundle.appendingPathComponent("Contents/_MASReceipt/receipt"))

        let info = await IOSAppOnMac.classify(bundlePath: bundle.path, probes: silentProbes)
        #expect(info.verdict == .iosAppOnMac)
        #expect(info.note.contains("wrapper markers beat"))
    }
}

// MARK: - INSTALL_RECEIPT.json (root and .metadata/ forms)

@Suite("IOSAppOnMac: INSTALL_RECEIPT.json wrapper receipts (happy + malformed)")
struct IOSReceiptJSONTests {

    @Test("root receipt: documented fields with ISO date + epoch installedDate")
    func rootReceiptHappy() async throws {
        let base = try makeFixtureBase()
        let bundle = try makeBundle(in: base)
        try writeJSONDict(
            [
                "trackId": 987_654,
                "purchaseDate": "2024-03-05T10:20:30Z",
                "installedDate": 1_710_000_000,
            ],
            at: bundle.appendingPathComponent("INSTALL_RECEIPT.json"))

        let info = await IOSAppOnMac.classify(bundlePath: bundle.path, probes: silentProbes)
        #expect(info.verdict == .iosAppOnMac)
        #expect(info.trackId == "987654")
        #expect(info.purchaseDate == isoDate("2024-03-05T10:20:30Z"))
        #expect(info.installedDate == Date(timeIntervalSince1970: 1_710_000_000))
        #expect(info.evidence.contains { $0.contains("INSTALL_RECEIPT.json") })
    }

    @Test(".metadata/ receipt variant → iosAppOnMac, evidence names the documented path")
    func metadataReceiptVariant() async throws {
        let base = try makeFixtureBase()
        let bundle = try makeBundle(in: base)
        try writeJSONDict(
            ["trackId": 555_001],
            at: bundle.appendingPathComponent(".metadata/INSTALL_RECEIPT.json"))

        let info = await IOSAppOnMac.classify(bundlePath: bundle.path, probes: silentProbes)
        #expect(info.verdict == .iosAppOnMac)
        #expect(info.trackId == "555001")
        #expect(info.evidence.contains { $0.contains(".metadata/INSTALL_RECEIPT.json") })
    }

    @Test("fractional-seconds ISO string parses (documented attempt set)")
    func fractionalSeconds() async throws {
        let base = try makeFixtureBase()
        let bundle = try makeBundle(in: base)
        try writeJSONDict(
            ["purchaseDate": "2024-03-05T10:20:30.250Z"],
            at: bundle.appendingPathComponent("INSTALL_RECEIPT.json"))

        let info = await IOSAppOnMac.classify(bundlePath: bundle.path, probes: silentProbes)
        #expect(info.purchaseDate == isoDate("2024-03-05T10:20:30.250Z"))
    }

    @Test("malformed receipt JSON → unknown with an explicit unreadable note")
    func malformedReceiptJSON() async throws {
        let base = try makeFixtureBase()
        let bundle = try makeBundle(in: base)
        try writeData(
            Data("[not json".utf8),
            at: bundle.appendingPathComponent("INSTALL_RECEIPT.json"))

        let info = await IOSAppOnMac.classify(bundlePath: bundle.path, probes: silentProbes)
        #expect(info.verdict == .unknown)
        #expect(info.note.contains("not a parseable JSON object"))
    }

    @Test("string trackId in receipt normalizes without breaking the verdict")
    func stringTrackId() async throws {
        let base = try makeFixtureBase()
        let bundle = try makeBundle(in: base)
        try writeJSONDict(
            ["trackId": "  409_201  ".replacingOccurrences(of: "_", with: "")],
            at: bundle.appendingPathComponent("INSTALL_RECEIPT.json"))

        let info = await IOSAppOnMac.classify(bundlePath: bundle.path, probes: silentProbes)
        #expect(info.verdict == .iosAppOnMac)
        #expect(info.trackId == "409201")
    }
}

// MARK: - Mac App Store receipt

@Suite("IOSAppOnMac: Contents/_MASReceipt/receipt (macOS MAS app)")
struct IOSMASReceiptTests {

    @Test("MAS receipt only → macAppStoreApp with documented team + update-path notes")
    func masReceiptOnly() async throws {
        let base = try makeFixtureBase()
        let bundle = try makeBundle(in: base)
        try writeData(
            Data([0xDE, 0xAD, 0xBE, 0xEF]),
            at: bundle.appendingPathComponent("Contents/_MASReceipt/receipt"))

        let info = await IOSAppOnMac.classify(bundlePath: bundle.path, probes: silentProbes)
        #expect(info.verdict == .macAppStoreApp)
        #expect(info.trackId == nil)
        #expect(info.note.contains("76TX64X7HC"))
        #expect(info.note.contains("open the App Store"))
        #expect(info.evidence.contains { $0.contains("Contents/_MASReceipt/receipt") })
    }
}

// MARK: - Absent markers (honest not-IOS verdict)

@Suite("IOSAppOnMac: no documented markers present")
struct IOSAbsentMarkerTests {

    @Test("empty bundle dir → notIOSAppOnMac; pkgutil skip is an explicit note")
    func emptyBundle() async throws {
        let base = try makeFixtureBase()
        let bundle = try makeBundle(in: base)

        let info = await IOSAppOnMac.classify(bundlePath: bundle.path, probes: silentProbes)
        #expect(info.verdict == .notIOSAppOnMac)
        #expect(info.trackId == nil)
        #expect(info.evidence.contains { $0.contains("none of the documented markers") })
        #expect(info.note.contains("pkgutil probe skipped"))
    }

    @Test("bundle with identifier but nil probes → notIOSAppOnMac; identifier read is evidence")
    func withIdentifierAndSilentProbes() async throws {
        let base = try makeFixtureBase()
        let bundle = try makeBundle(in: base)
        try writePlistDict(
            ["CFBundleIdentifier": "com.fixture.bear"],
            at: bundle.appendingPathComponent("Contents/Info.plist"))

        let info = await IOSAppOnMac.classify(bundlePath: bundle.path, probes: silentProbes)
        #expect(info.verdict == .notIOSAppOnMac)
        #expect(info.evidence.contains { $0.contains("com.fixture.bear") })
        #expect(info.note.contains("pkgutil returned nothing"))
    }
}

// MARK: - Spotlight kMDItemAppStoreAdamID probe

@Suite("IOSAppOnMac: Spotlight kMDItemAppStoreAdamID (stubbed seam)")
struct IOSAdamIDProbeTests {

    @Test("adamID present alone → unknown with trackId surfaced and mapping flagged")
    func adamIDAlone() async throws {
        let base = try makeFixtureBase()
        let bundle = try makeBundle(in: base)
        let probes = IOSAppProbes(adamID: { _ in "522198089" }, pkgutil: { _ in nil })

        let info = await IOSAppOnMac.classify(bundlePath: bundle.path, probes: probes)
        #expect(info.verdict == .unknown)
        #expect(info.trackId == "522198089")
        #expect(info.note.contains("kMDItemAppStoreAdamID"))
        #expect(info.evidence.contains { $0.contains("mapping flagged as our reading") })
    }

    @Test("adamID probe throws → unknown (documented signal set incomplete)")
    func adamIDThrows() async throws {
        let base = try makeFixtureBase()
        let bundle = try makeBundle(in: base)
        struct Boom: Error {}
        let probes = IOSAppProbes(adamID: { _ in throw Boom() }, pkgutil: { _ in nil })

        let info = await IOSAppOnMac.classify(bundlePath: bundle.path, probes: probes)
        #expect(info.verdict == .unknown)
        #expect(info.note.contains("probe threw"))
        #expect(info.note.contains("incomplete"))
    }

    @Test("empty-string adamID counts as absent → notIOSAppOnMac")
    func adamIDEmpty() async throws {
        let base = try makeFixtureBase()
        let bundle = try makeBundle(in: base)
        let probes = IOSAppProbes(adamID: { _ in "  " }, pkgutil: { _ in nil })

        let info = await IOSAppOnMac.classify(bundlePath: bundle.path, probes: probes)
        #expect(info.verdict == .notIOSAppOnMac)
        #expect(info.trackId == nil)
    }
}

// MARK: - pkgutil probe (stubbed seam)

@Suite("IOSAppOnMac: pkgutil shell-out (stubbed seam)")
struct IOSPkgutilProbeTests {

    private func bundleWithIdentifier() throws -> URL {
        let base = try makeFixtureBase()
        let bundle = try makeBundle(in: base)
        try writePlistDict(
            ["CFBundleIdentifier": "com.fixture.pkgapp"],
            at: bundle.appendingPathComponent("Contents/Info.plist"))
        return bundle
    }

    @Test("pkgutil receipt with install-time → installedDate; mapping flagged in evidence")
    func installTimeMapped() async throws {
        let bundle = try bundleWithIdentifier()
        let probes = IOSAppProbes(
            adamID: { _ in nil },
            pkgutil: { _ in "package-id: com.fixture.pkgapp\ninstall-time: 1710000000\n" })

        let info = await IOSAppOnMac.classify(bundlePath: bundle.path, probes: probes)
        #expect(info.verdict == .unknown)
        #expect(info.installedDate == Date(timeIntervalSince1970: 1_710_000_000))
        #expect(info.evidence.contains { $0.contains("FLAGGED") })
    }

    @Test("pkgutil receipt without install-time → unknown, installedDate left nil with note")
    func noInstallTime() async throws {
        let bundle = try bundleWithIdentifier()
        let probes = IOSAppProbes(
            adamID: { _ in nil },
            pkgutil: { _ in "package-id: com.fixture.pkgapp\nversion: 1.2.3\n" })

        let info = await IOSAppOnMac.classify(bundlePath: bundle.path, probes: probes)
        #expect(info.verdict == .unknown)
        #expect(info.installedDate == nil)
        #expect(info.note.contains("no install-time line"))
    }

    @Test("pkgutil probe throws → unknown (documented signal set incomplete)")
    func pkgutilThrows() async throws {
        let bundle = try bundleWithIdentifier()
        struct Boom: Error {}
        let probes = IOSAppProbes(adamID: { _ in nil }, pkgutil: { _ in throw Boom() })

        let info = await IOSAppOnMac.classify(bundlePath: bundle.path, probes: probes)
        #expect(info.verdict == .unknown)
        #expect(info.note.contains("pkgutil probe threw"))
        #expect(info.note.contains("incomplete"))
    }

    @Test("missing Info.plist → pkgutil skipped note, honest notIOSAppOnMac")
    func pkgutilSkipped() async throws {
        let base = try makeFixtureBase()
        let bundle = try makeBundle(in: base)

        let info = await IOSAppOnMac.classify(bundlePath: bundle.path, probes: silentProbes)
        #expect(info.verdict == .notIOSAppOnMac)
        #expect(info.note.contains("pkgutil probe skipped"))
    }
}

// MARK: - Missing bundle + constants

@Suite("IOSAppOnMac: missing bundle + documented constants")
struct IOSMissingBundleTests {

    /// Probe stub that records invocations (to prove no probe runs for a
    /// missing bundle). Thread-safe box; Swift Testing runs suites in parallel.
    private final class ProbeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    @Test("missing bundle → unknown; NO probe is invoked")
    func missingBundleRunsNoProbes() async {
        let counter = ProbeCounter()
        let probes = IOSAppProbes(
            adamID: { _ in counter.increment(); return nil },
            pkgutil: { _ in counter.increment(); return nil })

        let info = await IOSAppOnMac.classify(
            bundlePath: "/nonexistent-iosappmac-fixture/\(UUID().uuidString).app",
            probes: probes)
        #expect(info.verdict == .unknown)
        #expect(info.note.contains("bundle path not found"))
        #expect(counter.value == 0)
    }

    @Test("documented marker paths are verbatim from UPDATEST-FINDINGS §3.1")
    func documentedConstants() {
        #expect(IOSAppOnMac.wrapperMetadataPath == "Wrapper/iTunesMetadata.plist")
        #expect(IOSAppOnMac.installReceiptPath == "INSTALL_RECEIPT.json")
        #expect(IOSAppOnMac.metadataInstallReceiptPath == ".metadata/INSTALL_RECEIPT.json")
        #expect(IOSAppOnMac.macReceiptPath == "Contents/_MASReceipt/receipt")
        #expect(IOSAppOnMac.spotlightAdamIDKey == "kMDItemAppStoreAdamID")
        #expect(
            IOSAppOnMac.documentedWrapperUpdateCopy
                .contains("iOS apps must be updated through the Mac App Store"))
    }
}
