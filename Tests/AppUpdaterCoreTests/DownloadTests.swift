// Download + verify tests — hermetic (custom URLProtocol stub; NO network).
// Swift Testing only: XCTest discovery is broken on this toolchain (Xcode 27
// beta — AGENTS.md gotcha ledger); Swift Testing does not re-export
// Foundation, hence the explicit import.
//
// Stub pattern copied from CaskSourceTests (lane cask): same LockedBox +
// stopLoading no-op + urlProtocolDidFinishLoading discipline. Renamed to the
// DL* prefix because test-file top-level declarations are module-visible and
// would otherwise collide with the cask file's StubURLProtocol/LockedBox.
//
// Fixture bytes are in-app literals, hashed externally (shasum -a 256) so the
// downloader's incremental hasher is checked against an INDEPENDENT constant,
// not against itself:
//
//   zip      = PK\x03\x04 + payload → 6537082287548bbc953fc07d44ad67dede2861ba3400089880b8a0718ed0b5e3 (104 bytes; see const below)
//   tampered = WK\x03\x04 + payload → 252b2adb578f93c1ed0f5e5f9b38919b7df7d236260f2bfe6b2860af39cda3a0
//
// The payload is NOT a real archive on purpose: the downloader only checks the
// magic prefix; real extraction belongs to the deploy lane.

import Foundation
import Testing
@testable import AppUpdaterCore

// MARK: - Hermetic URL stub

struct DLRecordedRequest: Sendable {
    let url: URL
    let userAgent: String?
}

/// Serves pre-registered bodies per URL (keyed by absoluteString) and records
/// every request. Unregistered URLs get 404. Everything runs synchronously in
/// startLoading.
final class DLStubURLProtocol: URLProtocol {
    struct StubResponse: Sendable {
        let status: Int
        let body: Data
        let extraHeaders: [String: String]

        init(status: Int, body: Data, extraHeaders: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.extraHeaders = extraHeaders
        }
    }

    private static let stubBox = DLBox<[String: StubResponse]>([:])
    private static let requestBox = DLBox<[DLRecordedRequest]>([])

    static func reset() {
        stubBox.with { stubs in stubs = [:] }
        requestBox.with { requests in requests = [] }
    }

    static func stub(_ body: Data, status: Int = 200, extraHeaders: [String: String] = [:], for urlString: String) {
        stubBox.with { stubs in
            stubs[urlString] = StubResponse(status: status, body: body, extraHeaders: extraHeaders)
        }
    }

    static var recordedRequests: [DLRecordedRequest] {
        requestBox.with { requests in requests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Synchronous stubs complete inside startLoading; CFNetwork still invokes
    /// stopLoading on teardown and the abstract base throws unless overridden.
    /// No-op on purpose (gotcha ledger: lane cask commit a350fde).
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requestBox.with { requests in
            requests.append(DLRecordedRequest(url: url, userAgent: request.value(forHTTPHeaderField: "User-Agent")))
        }
        let stub = Self.stubBox.with { stubs in stubs[url.absoluteString] }
        var headerFields = ["Content-Type": "application/octet-stream"]
        for (key, value) in stub?.extraHeaders ?? [:] {
            headerFields[key] = value
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub?.status ?? 404,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields
        )
        guard let response, let client else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body = stub?.body { client.urlProtocol(self, didLoad: body) }
        client.urlProtocolDidFinishLoading(self)
    }
}

/// Same discipline as the cask lane's LockedBox (copied, renamed: module-level
/// types must not collide across test files).
final class DLBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ initial: Value) { value = initial }

    func with<Result>(_ mutate: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return mutate(&value)
    }
}

// MARK: - Fixtures (byte-accurate; digests computed with shasum -a 256)

private let fixturePayload = "AppUpdater download fixture payload v1. Streaming chunks, CryptoKit sha256, honest byte accounting.\n"

/// 104 bytes starting with the PK\x03\x04 zip signature.
private let zipFixture = Data([0x50, 0x4B, 0x03, 0x04]) + Data(fixturePayload.utf8)

/// Same fixture with the FIRST magic byte dead (P→W): zip gate must reject.
private let tamperedFixture: Data = {
    var data = zipFixture
    data[0] = 0x57
    return data
}()

private let knownZipSHA256 = "6537082287548bbc953fc07d44ad67dede2861ba3400089880b8a0718ed0b5e3"
private let knownTamperedSHA256 = "252b2adb578f93c1ed0f5e5f9b38919b7df7d236260f2bfe6b2860af39cda3a0"

// MARK: - Tests

@Suite(.serialized)
struct DownloadTests {

    private func makeDownloader() -> UpdateDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DLStubURLProtocol.self]
        return UpdateDownloader(session: URLSession(configuration: configuration))
    }

    private func makeStagingDir(named name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("appupdater-download-tests")
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func dirFiles(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    private func diskBytes(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    private func httpsZipURL() -> URL {
        URL(string: "https://updates.example.test/downloads/artifact.zip")!
    }

    // (1) Happy path: zip streams to the right staging filename, hash matches,
    // kind is .zip, exactly one request left the process with our UA.
    @Test func happyPathStagesVerifiedZip() async throws {
        DLStubURLProtocol.reset()
        let url = httpsZipURL()
        DLStubURLProtocol.stub(zipFixture, extraHeaders: ["Content-Length": String(zipFixture.count)], for: url.absoluteString)
        let dir = try makeStagingDir(named: "happy")
        let info = UpdateInfo(
            source: .github,
            newestShortVersion: "1.2.3",
            downloadURL: url,
            // UPPERCASED on purpose — comparison must be case-insensitive.
            sha256Hex: knownZipSHA256.uppercased()
        )

        let result = try await makeDownloader().downloadAndVerify(from: info, into: dir)

        #expect(result.kind == .zip)
        #expect(result.stagedURL == dir.appendingPathComponent("artifact.zip"))
        #expect(try diskBytes(result.stagedURL) == zipFixture)
        let fileDigest = try Checksum.sha256Hex(ofFile: result.stagedURL)
        #expect(fileDigest == knownZipSHA256)
        let fileBytes = try Checksum.byteCount(ofFile: result.stagedURL)
        #expect(fileBytes == Int64(zipFixture.count))
        #expect(result.expectedSha256Hex == knownZipSHA256)

        let files = try dirFiles(dir)
        #expect(files == ["artifact.zip"])

        let requests = DLStubURLProtocol.recordedRequests
        #expect(requests.count == 1)
        #expect(requests.first?.url == url)
        #expect(requests.first?.userAgent == "AppUpdater/0.1 (macOS)")
    }

    // (2) sha256 mismatch → InstallerError with BOTH hex values in the
    // message, staging file cleaned up.
    @Test func sha256MismatchReportsBothHexes() async throws {
        DLStubURLProtocol.reset()
        let url = httpsZipURL()
        DLStubURLProtocol.stub(zipFixture, extraHeaders: ["Content-Length": String(zipFixture.count)], for: url.absoluteString)
        let dir = try makeStagingDir(named: "mismatch")
        let info = UpdateInfo(
            source: .github,
            newestShortVersion: "1.2.3",
            downloadURL: url,
            sha256Hex: knownTamperedSHA256 // honest 64-hex but not THIS file's digest
        )

        do {
            _ = try await makeDownloader().downloadAndVerify(from: info, into: dir)
            Issue.record("expected sha256Mismatch, got a staged DownloadedUpdate")
        } catch let error as InstallerError {
            guard case .sha256Mismatch(let expected, let actual) = error else {
                Issue.record("wrong InstallerError case: \(error)")
                return
            }
            #expect(expected == knownTamperedSHA256)
            #expect(actual == knownZipSHA256)
            let message = String(describing: error)
            #expect(message.contains(knownTamperedSHA256))
            #expect(message.contains(knownZipSHA256))
        } catch {
            Issue.record("wrong error domain: \(error)")
        }

        let files = try dirFiles(dir)
        #expect(files == []) // cleanup discipline: no half-artifact
        #expect(DLStubURLProtocol.recordedRequests.count == 1) // the download DID attempt
    }

    // (3a) Missing sha256 (nil) → refuse, message names the source, and no
    // network request is made at all.
    @Test func missingShaRefusesNamingSource() async throws {
        DLStubURLProtocol.reset()
        let url = httpsZipURL()
        DLStubURLProtocol.stub(zipFixture, for: url.absoluteString) // would serve if asked
        let dir = try makeStagingDir(named: "nosh-a")
        let info = UpdateInfo(source: .cask, newestShortVersion: "158.0.1", downloadURL: url, sha256Hex: nil)

        do {
            _ = try await makeDownloader().downloadAndVerify(from: info, into: dir)
            Issue.record("expected sha256Missing for a nil digest")
        } catch let error as InstallerError {
            guard case .sha256Missing(let what) = error else {
                Issue.record("wrong InstallerError case: \(error)")
                return
            }
            #expect(what == "cask")
            #expect(String(describing: error).contains("cask"))
        } catch {
            Issue.record("wrong error domain: \(error)")
        }

        let files = try dirFiles(dir)
        #expect(files == [])
        #expect(DLStubURLProtocol.recordedRequests.isEmpty) // refused before any network
    }

    // (3b) Whitespace-only sha256 counts as missing after normalization.
    @Test func whitespaceOnlyShaRefuses() async throws {
        DLStubURLProtocol.reset()
        let url = httpsZipURL()
        let dir = try makeStagingDir(named: "nosh-b")
        let info = UpdateInfo(source: .github, newestShortVersion: "1.0.0", downloadURL: url, sha256Hex: "   \n\t  ")

        do {
            _ = try await makeDownloader().downloadAndVerify(from: info, into: dir)
            Issue.record("expected sha256Missing for a whitespace-only digest")
        } catch let error as InstallerError {
            guard case .sha256Missing(let what) = error else {
                Issue.record("wrong InstallerError case: \(error)")
                return
            }
            #expect(what == "github")
        } catch {
            Issue.record("wrong error domain: \(error)")
        }

        #expect(DLStubURLProtocol.recordedRequests.isEmpty)
    }

    // (4) http:// target → httpsRequired, and ZERO network attempts were made.
    @Test func httpURLRefusedWithoutNetwork() async throws {
        DLStubURLProtocol.reset()
        let dir = try makeStagingDir(named: "http")
        let httpURL = URL(string: "http://updates.example.test/downloads/artifact.dmg")!
        let info = UpdateInfo(
            source: .github,
            newestShortVersion: "1.0.0",
            downloadURL: httpURL,
            sha256Hex: knownZipSHA256 // even with a digest present, scheme is refused
        )

        do {
            _ = try await makeDownloader().downloadAndVerify(from: info, into: dir)
            Issue.record("expected httpsRequired for an http:// target")
        } catch let error as InstallerError {
            guard case .httpsRequired(let refusedURL) = error else {
                Issue.record("wrong InstallerError case: \(error)")
                return
            }
            #expect(refusedURL == "http://updates.example.test/downloads/artifact.dmg")
            #expect(String(describing: error).contains("HTTPS-only"))
        } catch {
            Issue.record("wrong error domain: \(error)")
        }

        let files = try dirFiles(dir)
        #expect(files == [])
        #expect(DLStubURLProtocol.recordedRequests.isEmpty) // http never left the process
    }

    // (5) Unsupported extension → unsupportedArtifact through the full
    // pipeline: the refusal happens in preflight, so NO network request is
    // made and nothing is staged. (The mapping table gets its own test below.)
    @Test func unsupportedExtensionRefusedWithoutNetwork() async throws {
        DLStubURLProtocol.reset()
        let dir = try makeStagingDir(named: "ext")
        let pkgURL = URL(string: "https://updates.example.test/downloads/tool.pkg")!
        let info = UpdateInfo(
            source: .github,
            newestShortVersion: "1.0.0",
            downloadURL: pkgURL,
            sha256Hex: knownZipSHA256
        )

        do {
            _ = try await makeDownloader().downloadAndVerify(from: info, into: dir)
            Issue.record("expected unsupportedArtifact for .pkg")
        } catch let error as InstallerError {
            guard case .unsupportedArtifact(let reason) = error else {
                Issue.record("wrong InstallerError case: \(error)")
                return
            }
            #expect(reason.contains("pkg"))
        } catch {
            Issue.record("wrong error domain: \(error)")
        }

        let files = try dirFiles(dir)
        #expect(files == [])
        #expect(DLStubURLProtocol.recordedRequests.isEmpty)
    }

    // (5b) The mapping table itself, no network involved.
    @Test func kindFromExtensionMapping() throws {
        #expect(try UpdateDownloader.kindFromExtension(url: URL(string: "https://x.test/downloads/App.dmg")!) == .dmg)
        #expect(try UpdateDownloader.kindFromExtension(url: URL(string: "https://x.test/downloads/Inner_archive.ZIP")!) == .zip)
        #expect(try UpdateDownloader.kindFromExtension(url: URL(string: "https://x.test/downloads/Firefox%20158.0.1.dmg")!) == .dmg)

        for bad in ["pkg", "tbz", "tgz", "bin", "tar.gz"] {
            do {
                _ = try UpdateDownloader.kindFromExtension(url: URL(string: "https://x.test/downloads/up.\(bad)")!)
                Issue.record("expected unsupportedArtifact for .\(bad), got a kind")
            } catch let error as InstallerError {
                guard case .unsupportedArtifact(let reason) = error else {
                    Issue.record("wrong InstallerError case for .\(bad): \(error)")
                    return
                }
                #expect(reason.contains("v1 installs .dmg and .zip"))
            } catch {
                Issue.record("wrong error domain: \(error)")
            }
        }
    }

    // (6) Zip with a tampered PK prefix, digest-correct on the tampered bytes:
    // digest passes, magic fails → magicMismatch and the staging dir is EMPTY.
    @Test func tamperedZipMagicRefusedAndCleaned() async throws {
        DLStubURLProtocol.reset()
        let url = httpsZipURL()
        DLStubURLProtocol.stub(tamperedFixture, extraHeaders: ["Content-Length": String(tamperedFixture.count)], for: url.absoluteString)
        let dir = try makeStagingDir(named: "magic")
        let info = UpdateInfo(
            source: .github,
            newestShortVersion: "1.2.3",
            downloadURL: url,
            sha256Hex: knownTamperedSHA256 // verified against the TAMPERED bytes
        )

        do {
            _ = try await makeDownloader().downloadAndVerify(from: info, into: dir)
            Issue.record("expected magicMismatch for tampered PK prefix")
        } catch let error as InstallerError {
            guard case .magicMismatch(let reason) = error else {
                Issue.record("wrong InstallerError case: \(error)")
                return
            }
            #expect(reason.contains("PK"))
            #expect(String(describing: error).contains("magic/extension mismatch"))
        } catch {
            Issue.record("wrong error domain: \(error)")
        }

        let files = try dirFiles(dir)
        #expect(files == []) // staging file removed after the failed gate
    }

    // (7) Non-2xx (404): transport error thrown BEFORE any byte is written —
    // the staging dir stays exactly as it was. Error surface is URLError
    // (see Download.swift header: InstallerError is frozen semantics-only).
    @Test func http404ThrowsBeforeWriting() async throws {
        DLStubURLProtocol.reset()
        let dir = try makeStagingDir(named: "e404")
        let info = UpdateInfo(
            source: .github,
            newestShortVersion: "1.2.3",
            downloadURL: httpsZipURL(), // unregistered in the stub → 404
            sha256Hex: knownZipSHA256
        )

        do {
            _ = try await makeDownloader().downloadAndVerify(from: info, into: dir)
            Issue.record("expected a transport error for HTTP 404")
        } catch let error as URLError {
            #expect(error.code == .badServerResponse)
            #expect(error.localizedDescription.contains("HTTP 404"))
        } catch {
            Issue.record("wrong error domain: \(error)")
        }

        let files = try dirFiles(dir)
        #expect(files == []) // nothing was ever created, let alone half-written
        #expect(DLStubURLProtocol.recordedRequests.count == 1) // the attempt itself
    }

    // (7b) Content-Length cross-check: declared ≠ received → same honest
    // transport surface, staging file cleaned up.
    @Test func contentLengthMismatchThrowsAndCleans() async throws {
        DLStubURLProtocol.reset()
        let url = httpsZipURL()
        DLStubURLProtocol.stub(zipFixture, extraHeaders: ["Content-Length": "999999"], for: url.absoluteString)
        let dir = try makeStagingDir(named: "len")
        let info = UpdateInfo(
            source: .github,
            newestShortVersion: "1.2.3",
            downloadURL: url,
            sha256Hex: knownZipSHA256 // bytes themselves are fine — length isn't
        )

        do {
            _ = try await makeDownloader().downloadAndVerify(from: info, into: dir)
            Issue.record("expected a transport error on Content-Length mismatch")
        } catch let error as URLError {
            #expect(error.code == .badServerResponse)
            #expect(error.localizedDescription.contains("content-length mismatch"))
            #expect(error.localizedDescription.contains("999999"))
        } catch {
            Issue.record("wrong error domain: \(error)")
        }

        let files = try dirFiles(dir)
        #expect(files == [])
    }

    // (7c) Stream longer than the 1 MiB flush boundary: the incremental
    // hasher is checked against the INDEPENDENT full-file Checksum helper —
    // a chunk-boundary bug cannot cancel out against itself here.
    @Test func streamsBeyondChunkBoundaryIntoCleanFile() async throws {
        DLStubURLProtocol.reset()
        let url = URL(string: "https://updates.example.test/downloads/big.zip")!

        var body = Data([0x50, 0x4B, 0x03, 0x04])
        var rng = UInt64(0x9E3779B97F4A7C15)
        for _ in 0..<(1_048_576 + 512) {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            body.append(UInt8(truncatingIfNeeded: rng >> 33))
        }
        DLStubURLProtocol.stub(body, extraHeaders: ["Content-Length": String(body.count)], for: url.absoluteString)

        let dir = try makeStagingDir(named: "big")
        let referenceFile = dir.appendingPathComponent("reference.data")
        try body.write(to: referenceFile)
        let expectedDigest = try Checksum.sha256Hex(ofFile: referenceFile)

        let info = UpdateInfo(source: .github, newestShortVersion: "9.0.0", downloadURL: url, sha256Hex: expectedDigest)
        let result = try await makeDownloader().downloadAndVerify(from: info, into: dir)

        #expect(result.kind == .zip)
        let stagedBytes = try diskBytes(result.stagedURL)
        #expect(stagedBytes == body)
        let stagedCount = try Checksum.byteCount(ofFile: result.stagedURL)
        #expect(stagedCount == Int64(body.count))
        #expect(result.expectedSha256Hex == expectedDigest)
    }

    // (8) Checksum helpers: fixture bytes ↔ externally known digest, sizes,
    // whitespace/case normalization.
    @Test func checksumHelpersMatchKnownDigests() throws {
        let dir = try makeStagingDir(named: "sha")
        let fileURL = dir.appendingPathComponent("fixture.out")
        try zipFixture.write(to: fileURL)

        let digest = try Checksum.sha256Hex(ofFile: fileURL)
        #expect(digest == knownZipSHA256) // independent shasum constant
        let byteCount = try Checksum.byteCount(ofFile: fileURL)
        #expect(byteCount == 104)

        #expect(Checksum.normalizeHex("  6537082287548bbc953fc07d44ad67dede2861ba3400089880b8a0718ed0b5e3 ") == knownZipSHA256)
        #expect(Checksum.normalizeHex("AB CDEF\n\t01") == "abcdef01")
        #expect(Checksum.normalizeHex("   ") == "")
    }
}
