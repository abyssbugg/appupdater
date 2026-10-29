// HelperProtocolTests.swift — hermetic tests for the helper IPC message
// contract (Sources/AppUpdaterCore/PrivilegedHelper/HelperProtocol.swift).
//
// Swift Testing ONLY — XCTest discovery is broken on this toolchain (AGENTS.md
// gotcha ledger). Swift Testing does not re-export Foundation, so
// `import Foundation` is required here.
//
// Hermeticity: pure message encode/decode/validation — no network, no
// processes, no file I/O, no clocks (request IDs are UUIDs, response
// timestamps are fixed fixtures). No force unwraps anywhere (the lint gate
// treats force_unwrapping as an error, tests included).
//
// Coverage map: JSON round-trips (request + response), deterministic bytes,
// garbage decode refuses, the coder seam is genuinely pluggable (a custom
// wrapping coder round-trips), and the full validate() refusal vocabulary
// (§3.3 name+version+checksum, §3.2 pkg verdict, §3.6 backup zip, protocol
// version mismatch, sha256 shape).

import Foundation
import Testing
@testable import AppUpdaterCore

@Suite
struct HelperProtocolTests {

    // MARK: - Fixture helpers

    /// A fully valid request — every required field present, sha256 well-formed.
    private func makeRequest(
        protocolVersion: Int = HelperProtocol.protocolVersion,
        operation: HelperOperation = .updateApp,
        bundleIdentifier: String = "com.example.app",
        version: String = "2.0",
        appDisplayName: String = "Example App",
        appPath: String = "/Applications/Example App.app",
        stagedArtifactPath: String = "/var/staging/Example-2.0.pkg",
        expectedSha256Hex: String =
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        pkgutilSignatureVerdict: String = "valid on disk",
        backupZipPath: String = "/var/backups/Example-1.0-backup.zip"
    ) -> HelperRequest {
        HelperRequest(
            requestID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")
                ?? UUID(),
            protocolVersion: protocolVersion,
            operation: operation,
            bundleIdentifier: bundleIdentifier,
            version: version,
            appDisplayName: appDisplayName,
            appPath: appPath,
            stagedArtifactPath: stagedArtifactPath,
            expectedSha256Hex: expectedSha256Hex,
            pkgutilSignatureVerdict: pkgutilSignatureVerdict,
            backupZipPath: backupZipPath)
    }

    private func makeResponse(requestID: UUID) -> HelperResponse {
        HelperResponse(
            requestID: requestID,
            protocolVersion: HelperProtocol.protocolVersion,
            succeeded: true,
            installerExitStatus: 0,
            installerOutput: "installer: Package name is Example\ninstaller: The install was successful.",
            failureDetail: nil,
            completedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    // MARK: - Protocol identity

    @Test
    func protocolVersionIsOne() {
        #expect(HelperProtocol.protocolVersion == 1)
    }

    @Test
    func helperLabelUsesRepoIdentifierPrefix() {
        #expect(HelperProtocol.helperLabel == "io.appupdater.AppUpdater.PrivilegedInstallHelper")
    }

    // MARK: - JSON round-trips

    @Test
    func requestJSONRoundTrips() throws {
        let request = makeRequest()
        let coder = HelperMessageCoder.json()
        let data = try coder.encodeRequest(request)
        let decoded = try coder.decodeRequest(data)
        #expect(decoded == request)
    }

    @Test
    func responseJSONRoundTrips() throws {
        let response = makeResponse(
            requestID: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID())
        let coder = HelperMessageCoder.json()
        let data = try coder.encodeResponse(response)
        let decoded = try coder.decodeResponse(data)
        #expect(decoded == response)
    }

    @Test
    func responseCarriesVerbatimInstallerReceiptFields() throws {
        let output = "installer: Package name is Example\ninstaller: The install was successful."
        let response = HelperResponse(
            requestID: UUID(),
            protocolVersion: HelperProtocol.protocolVersion,
            succeeded: false,
            installerExitStatus: 1,
            installerOutput: output,
            failureDetail: "installer exited 1",
            completedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let decoded = try HelperMessageCoder.json().decodeResponse(
            try HelperMessageCoder.json().encodeResponse(response))
        #expect(decoded.installerOutput == output)
        #expect(decoded.installerExitStatus == 1)
        #expect(decoded.failureDetail == "installer exited 1")
        #expect(decoded.succeeded == false)
    }

    @Test
    func jsonEncodingIsDeterministic() throws {
        let request = makeRequest()
        let coder = HelperMessageCoder.json()
        let first = try coder.encodeRequest(request)
        let second = try coder.encodeRequest(request)
        #expect(first == second)
    }

    @Test
    func decodingGarbageThrows() {
        let coder = HelperMessageCoder.json()
        #expect(throws: (any Error).self) {
            try coder.decodeRequest(Data("definitely not json".utf8))
        }
        #expect(throws: (any Error).self) {
            try coder.decodeResponse(Data("{}".utf8))
        }
    }

    // MARK: - Coder seam is genuinely pluggable

    @Test
    func customCoderSeamRoundTrips() throws {
        // A deliberately NON-JSON coder (base64 of the JSON) to prove the
        // seam is the transport plug-in point: a future XPC transport
        // supplies its own coder without touching the message contract.
        let json = HelperMessageCoder.json()
        let base64 = HelperMessageCoder(
            encodeRequest: { request in
                let raw = try json.encodeRequest(request)
                return Data(raw.base64EncodedString().utf8)
            },
            decodeRequest: { data in
                guard let raw = Data(base64Encoded: String(decoding: data, as: UTF8.self)) else {
                    throw HelperRequestIssue.fieldEmpty(what: "base64 payload")
                }
                return try json.decodeRequest(raw)
            },
            encodeResponse: { response in
                let raw = try json.encodeResponse(response)
                return Data(raw.base64EncodedString().utf8)
            },
            decodeResponse: { data in
                guard let raw = Data(base64Encoded: String(decoding: data, as: UTF8.self)) else {
                    throw HelperRequestIssue.fieldEmpty(what: "base64 payload")
                }
                return try json.decodeResponse(raw)
            })
        let request = makeRequest()
        let decoded = try base64.decodeRequest(try base64.encodeRequest(request))
        #expect(decoded == request)
        // ...and the JSON coder cannot read its wire format (the seam really
        // changed the encoding, it did not silently fall back).
        #expect(throws: (any Error).self) {
            try json.decodeRequest(try base64.encodeRequest(request))
        }
    }

    // MARK: - validate() — the §3.3/§3.2/§3.6 refusal vocabulary

    @Test
    func validRequestValidatesClean() {
        #expect(makeRequest().validate() == nil)
        #expect(makeRequest(operation: .installApp).validate() == nil)
    }

    @Test
    func wrongProtocolVersionRefuses() throws {
        let issue = try #require(makeRequest(protocolVersion: 99).validate())
        guard case .protocolVersionMismatch(let expected, let actual) = issue else {
            Issue.record("expected protocolVersionMismatch, got \(issue)")
            return
        }
        #expect(expected == HelperProtocol.protocolVersion)
        #expect(actual == 99)
    }

    @Test
    func missingConsentTripleRefuses() throws {
        // §3.3: app name + version + checksum must ALL be present.
        let noName = try #require(makeRequest(appDisplayName: "").validate())
        #expect(noName == .fieldEmpty(what: "appDisplayName"))
        let noVersion = try #require(makeRequest(version: "  ").validate())
        #expect(noVersion == .fieldEmpty(what: "version"))
        let noSha = try #require(makeRequest(expectedSha256Hex: "").validate())
        #expect(noSha == .sha256Missing)
    }

    @Test
    func missingIdentityAndPathsRefuse() throws {
        #expect(makeRequest(bundleIdentifier: "").validate() == .fieldEmpty(what: "bundleIdentifier"))
        #expect(makeRequest(appPath: "").validate() == .fieldEmpty(what: "appPath"))
        #expect(makeRequest(stagedArtifactPath: "").validate() == .fieldEmpty(what: "stagedArtifactPath"))
    }

    @Test
    func malformedSha256Refuses() throws {
        let short = try #require(
            makeRequest(expectedSha256Hex: String(repeating: "a", count: 63)).validate())
        guard case .sha256Malformed(let length) = short else {
            Issue.record("expected sha256Malformed, got \(short)")
            return
        }
        #expect(length == 63)
        let nonHex = try #require(
            makeRequest(expectedSha256Hex: String(repeating: "z", count: 64)).validate())
        guard case .sha256Malformed(let hexLength) = nonHex else {
            Issue.record("expected sha256Malformed, got \(nonHex)")
            return
        }
        #expect(hexLength == 64)
        let upperCaseIsFine = makeRequest(
            expectedSha256Hex: String(repeating: "A", count: 64))
        #expect(upperCaseIsFine.validate() == nil)
    }

    @Test
    func missingPkgVerdictRefuses() throws {
        // §3.2: the pkgutil --check-signature verdict travels in the request.
        let issue = try #require(makeRequest(pkgutilSignatureVerdict: "").validate())
        #expect(issue == .pkgVerdictMissing)
    }

    @Test
    func missingBackupZipRefuses() throws {
        // §3.6: every root install must carry the reversible backup receipt.
        let issue = try #require(makeRequest(backupZipPath: "").validate())
        #expect(issue == .fieldEmpty(what: "backupZipPath"))
    }
}
