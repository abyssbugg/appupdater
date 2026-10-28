// SignedRulePackTests.swift — hermetic tests for the EdDSA-verified rule-pack
// loader (GAP #24 serverless variant, lane vendor-rules).
//
// Swift Testing ONLY (AGENTS.md gotcha ledger); Foundation imported
// separately.
//
// Hermeticity: no network, no processes. Keypairs are generated in-process
// via CryptoKit Curve25519.Signing.PrivateKey() (explicitly allowed by the
// lane brief); pack files are written into fresh per-test UUID temp roots
// (per-process-unique-root rule — never a shared wiped constant). No force
// unwraps anywhere (the lint gate errors on force_unwrapping, tests included).
//
// The canonicalization fixture tests are BYTE-PINNED: the exact UTF-8 bytes
// a payload canonicalizes to are asserted verbatim, so any drift in the
// canonicalization rule (the one thing signers and verifiers must agree on)
// fails loudly instead of silently invalidating distributed packs.

import CryptoKit
import Foundation
import Testing
@testable import AppUpdaterCore

@Suite
struct SignedRulePackTests {

    // MARK: - Fixtures

    private let fm = FileManager.default

    private func newRoot() throws -> URL {
        let url = fm.temporaryDirectory
            .appendingPathComponent("rulepack-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeKeyPair() throws -> (privateKey: Curve25519.Signing.PrivateKey, publicKey: RulePackPublicKey) {
        let privateKey = Curve25519.Signing.PrivateKey()
        guard let publicKey = RulePackPublicKey(rawRepresentation: privateKey.publicKey.rawRepresentation) else {
            Issue.record("generated public key rejected by the wrapper — impossible fixture state")
            throw TestFailure()
        }
        return (privateKey, publicKey)
    }

    private struct TestFailure: Error {}

    /// A v1 payload mixing both rule shapes (keys authored UNSORTED on
    /// purpose — canonicalization must sort them).
    private func mixedPayload() -> [String: Any] {
        [
            "caskAliases": [
                "chrome": "google-chrome",
                "code": "visual-studio-code",
            ],
            "caskTokenPins": [
                ["bundleID": "org.example.foo", "token": "foo-app"],
            ],
        ]
    }

    /// Build and sign a v1 envelope exactly as the header documents, with
    /// hooks for every refusal-relevant field.
    private func envelopeData(payload: [String: Any],
                              signingKey: Curve25519.Signing.PrivateKey?,
                              format: String = RulePackCanonicalization.formatMagic,
                              schemaVersion: Any = 1,
                              signatureOverride: String? = nil,
                              omitSignature: Bool = false,
                              extraTopLevel: [String: Any] = [:]) throws -> Data {
        var envelope: [String: Any] = [:]
        if !format.isEmpty { envelope["format"] = format }
        envelope["schemaVersion"] = schemaVersion
        envelope["payload"] = payload
        if !omitSignature {
            if let signatureOverride {
                envelope["signature"] = signatureOverride
            } else if let signingKey {
                let canonical = try RulePackCanonicalization.canonicalPayloadBytes(payload)
                let signature = try signingKey.signature(for: canonical)
                envelope["signature"] = signature.base64EncodedString()
            }
        }
        for (key, value) in extraTopLevel {
            envelope[key] = value
        }
        return try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted])
    }

    private func writePack(_ data: Data, in root: URL, named: String = "rules.json") throws -> URL {
        let url = root.appendingPathComponent(named)
        try data.write(to: url)
        return url
    }

    private func expectRefusal(
        _ result: Result<SignedRulePack, SignedRulePackRefusal>,
        _ refusal: (SignedRulePackRefusal) -> Bool,
        _ label: String
    ) throws -> SignedRulePackRefusal {
        guard case .failure(let r) = result else {
            Issue.record("\(label): expected a refusal, got valid pack")
            throw TestFailure()
        }
        #expect(refusal(r), "\(label): wrong refusal \(r)")
        return r
    }

    // Case matchers for the refusal closure above (kept as named helpers —
    // single-line `if case … { … } return …` closures read badly).
    private func isMalformed(_ r: SignedRulePackRefusal) -> Bool {
        if case .malformedContainer = r { return true }
        return false
    }

    private func isPayloadRules(_ r: SignedRulePackRefusal) -> Bool {
        if case .payloadRulesMalformed = r { return true }
        return false
    }

    private func isUnreadable(_ r: SignedRulePackRefusal) -> Bool {
        if case .unreadableFile = r { return true }
        return false
    }

    private func isSignatureField(_ r: SignedRulePackRefusal) -> Bool {
        if case .signatureFieldMalformed = r { return true }
        return false
    }

    // MARK: Canonicalization (byte-pinned contract)

    @Test
    func canonicalBytesAreSortedCompactUTF8() throws {
        let payload: [String: Any] = [
            "caskAliases": [
                "chrome": "google-chrome",
                "code": "visual-studio-code",
            ],
        ]
        let canonical = try RulePackCanonicalization.canonicalPayloadBytes(payload)
        let text = try #require(String(data: canonical, encoding: .utf8))
        #expect(text == #"{"caskAliases":{"chrome":"google-chrome","code":"visual-studio-code"}}"#)
    }

    @Test
    func canonicalBytesSortTopLevelKeysAndPinObjectFields() throws {
        let canonical = try RulePackCanonicalization.canonicalPayloadBytes(mixedPayload())
        let text = try #require(String(data: canonical, encoding: .utf8))
        #expect(text == "{\"caskAliases\":{\"chrome\":\"google-chrome\",\"code\":\"visual-studio-code\"},"
            + "\"caskTokenPins\":[{\"bundleID\":\"org.example.foo\",\"token\":\"foo-app\"}]}")
    }

    @Test
    func canonicalBytesRejectNonSerializablePayloadsAsTypedError() {
        // JSONSerialization RAISES an uncatchable NSException (not a Swift
        // error) when asked to WRITE a non-serializable value on this
        // Foundation — observed: 'Invalid type in JSON write (_NSInlineData)'.
        // The canonicalizer pre-checks with isValidJSONObject and throws the
        // typed error instead; the loader's payloads come from parsed JSON
        // and can never hit this path.
        #expect(throws: RulePackCanonicalization.CanonicalizationError.self) {
            _ = try RulePackCanonicalization.canonicalPayloadBytes(["bad": Data([0x00])])
        }
        #expect(JSONSerialization.isValidJSONObject(mixedPayload())) // and real payloads pass the same pre-check
    }

    // MARK: Happy paths

    @Test
    func validMixedPackLoadsFromDiskWithRulesIntact() throws {
        let root = try newRoot()
        let keys = try makeKeyPair()
        let data = try envelopeData(payload: mixedPayload(), signingKey: keys.privateKey)
        let file = try writePack(data, in: root)

        let result = SignedRulePackLoader.load(fileAt: file, verifyingWith: keys.publicKey)
        guard case .success(let pack) = result else {
            Issue.record("expected valid, got \(result)")
            return
        }
        #expect(pack.schemaVersion == 1)
        #expect(pack.caskAliases == ["chrome": "google-chrome", "code": "visual-studio-code"])
        #expect(pack.caskTokenPins.count == 1)
        #expect(pack.caskTokenPins.first?.bundleID == "org.example.foo")
        #expect(pack.caskTokenPins.first?.token == "foo-app")
        #expect(pack.unconsumedPayloadKeys.isEmpty)
        #expect(pack.sourceFile == file.path)
    }

    @Test
    func inMemoryBytesVerifyThroughTheSamePipeline() throws {
        let keys = try makeKeyPair()
        let data = try envelopeData(payload: mixedPayload(), signingKey: keys.privateKey)
        let result = SignedRulePackLoader.verify(fileData: data, verifyingWith: keys.publicKey, sourceFile: "memory")
        guard case .success(let pack) = result else {
            Issue.record("expected valid, got \(result)")
            return
        }
        #expect(pack.sourceFile == "memory")
        #expect(pack.caskAliases["chrome"] == "google-chrome")
    }

    @Test
    func pinsOnlyPackIsValid() throws {
        let keys = try makeKeyPair()
        let payload: [String: Any] = ["caskTokenPins": [["bundleID": "org.a.b", "token": "b-token"]]]
        let data = try envelopeData(payload: payload, signingKey: keys.privateKey)
        guard case .success(let pack) = SignedRulePackLoader.verify(fileData: data, verifyingWith: keys.publicKey, sourceFile: "m") else {
            Issue.record("expected valid")
            return
        }
        #expect(pack.caskAliases.isEmpty)
        #expect(pack.caskTokenPins == [RulePackCaskPin(bundleID: "org.a.b", token: "b-token")])
    }

    @Test
    func unicodeRuleValuesSurviveCanonicalizationAndVerification() throws {
        let keys = try makeKeyPair()
        let payload: [String: Any] = ["caskAliases": ["török": "tök-app"]]
        let data = try envelopeData(payload: payload, signingKey: keys.privateKey)
        guard case .success(let pack) = SignedRulePackLoader.verify(fileData: data, verifyingWith: keys.publicKey, sourceFile: "m") else {
            Issue.record("expected valid")
            return
        }
        #expect(pack.caskAliases["török"] == "tök-app")
    }

    @Test
    func unknownPayloadKeysAreSignatureCoveredButUnconsumed() throws {
        let keys = try makeKeyPair()
        var payload = mixedPayload()
        payload["futureField"] = "reserved-for-v2"
        let data = try envelopeData(payload: payload, signingKey: keys.privateKey)
        guard case .success(let pack) = SignedRulePackLoader.verify(fileData: data, verifyingWith: keys.publicKey, sourceFile: "m") else {
            Issue.record("expected valid")
            return
        }
        #expect(pack.unconsumedPayloadKeys == ["futureField"])
        #expect(pack.caskAliases["chrome"] == "google-chrome") // consumed rules unaffected
    }

    // MARK: Signature failures (the verify-before-apply core)

    @Test
    func tamperedPayloadRefusedAsSignatureInvalid() throws {
        let keys = try makeKeyPair()
        // Sign one payload, ship a DIFFERENT one under the same signature.
        let signedData = try envelopeData(payload: mixedPayload(), signingKey: keys.privateKey)
        guard var envelope = try JSONSerialization.jsonObject(with: signedData) as? [String: Any] else {
            throw TestFailure()
        }
        envelope["payload"] = ["caskAliases": ["chrome": "EVIL-REPLACEMENT"]]
        let tampered = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted])
        let result = SignedRulePackLoader.verify(fileData: tampered, verifyingWith: keys.publicKey, sourceFile: "m")
        _ = try expectRefusal(result, { $0 == .signatureInvalid }, "tampered payload")
    }

    @Test
    func signatureFromDifferentKeyRefusedAsSignatureInvalid() throws {
        let signer = try makeKeyPair()
        let other = try makeKeyPair()
        let data = try envelopeData(payload: mixedPayload(), signingKey: signer.privateKey)
        let result = SignedRulePackLoader.verify(fileData: data, verifyingWith: other.publicKey, sourceFile: "m")
        _ = try expectRefusal(result, { $0 == .signatureInvalid }, "wrong key")
    }

    @Test
    func corruptedButValidBase64SignatureRefusedAsSignatureInvalid() throws {
        let keys = try makeKeyPair()
        let payload = mixedPayload()
        // Sign DIFFERENT bytes (the envelope's own signature is therefore
        // valid base64 but wrong for the shipped payload).
        let decoy = try keys.privateKey.signature(for: Data("decoy".utf8))
        let data = try envelopeData(payload: payload, signingKey: nil,
                                    signatureOverride: decoy.base64EncodedString())
        let result = SignedRulePackLoader.verify(fileData: data, verifyingWith: keys.publicKey, sourceFile: "m")
        _ = try expectRefusal(result, { $0 == .signatureInvalid }, "decoy signature")
    }

    @Test
    func missingSignatureKeyRefusedAsMalformedContainer() throws {
        let keys = try makeKeyPair()
        let data = try envelopeData(payload: mixedPayload(), signingKey: keys.privateKey, omitSignature: true)
        let result = SignedRulePackLoader.verify(fileData: data, verifyingWith: keys.publicKey, sourceFile: "m")
        let refusal = try expectRefusal(result, { $0 == .malformedContainer(reason: "'signature' missing or not a string") },
                                        "missing signature")
        #expect(refusal.description.contains("missing or not a string"))
    }

    @Test
    func nonBase64SignatureRefusedAsSignatureFieldMalformed() throws {
        let keys = try makeKeyPair()
        let data = try envelopeData(payload: mixedPayload(), signingKey: nil, signatureOverride: "!!! not base64 !!!")
        let result = SignedRulePackLoader.verify(fileData: data, verifyingWith: keys.publicKey, sourceFile: "m")
        let refusal = try expectRefusal(result, {
            if case .signatureFieldMalformed = $0 { return true }
            return false
        }, "bad base64")
        #expect(refusal.description.contains("base64"))
    }

    @Test
    func wrongLengthSignatureRefusedAsSignatureInvalid() throws {
        let keys = try makeKeyPair()
        let short = Data([0x01, 0x02, 0x03])
        let data = try envelopeData(payload: mixedPayload(), signingKey: nil,
                                    signatureOverride: short.base64EncodedString())
        let result = SignedRulePackLoader.verify(fileData: data, verifyingWith: keys.publicKey, sourceFile: "m")
        // Observed CryptoKit behavior on this SDK: Curve25519's
        // isValidSignature returns FALSE (rather than throwing) for a
        // signature whose length is not 64 — so the honest outcome is
        // signatureInvalid. The .signatureFieldMalformed branch stays as
        // defense-in-depth for any CryptoKit path that does throw.
        let refusal = try expectRefusal(result, { $0 == .signatureInvalid }, "wrong length")
        #expect(refusal.description.contains("INVALID"))
    }

    // MARK: Envelope failures

    @Test
    func wrongFormatMagicRefused() throws {
        let keys = try makeKeyPair()
        let data = try envelopeData(payload: mixedPayload(), signingKey: keys.privateKey, format: "some-other-pack/9")
        let result = SignedRulePackLoader.verify(fileData: data, verifyingWith: keys.publicKey, sourceFile: "m")
        let refusal = try expectRefusal(result, { $0 == .magicMismatch(actual: "some-other-pack/9") }, "magic")
        #expect(refusal.description.contains("appupdater-rule-pack/1"))
    }

    @Test
    func unsupportedSchemaVersionRefusedVerbatim() throws {
        let keys = try makeKeyPair()
        let data = try envelopeData(payload: mixedPayload(), signingKey: keys.privateKey, schemaVersion: 2)
        let result = SignedRulePackLoader.verify(fileData: data, verifyingWith: keys.publicKey, sourceFile: "m")
        _ = try expectRefusal(result, { $0 == .unsupportedSchemaVersion(actual: 2) }, "schema 2")
    }

    @Test
    func booleanSchemaVersionRefusedNotCoerced() throws {
        // JSON `true` bridges to NSNumber and would coerce to 1 through a
        // naive `as? Int` — the loader must refuse it instead.
        let keys = try makeKeyPair()
        let data = try envelopeData(payload: mixedPayload(), signingKey: keys.privateKey, schemaVersion: true)
        let result = SignedRulePackLoader.verify(fileData: data, verifyingWith: keys.publicKey, sourceFile: "m")
        let refusal = try expectRefusal(result, {
            if case .malformedContainer = $0 { return true }
            return false
        }, "boolean schemaVersion")
        #expect(refusal.description.contains("boolean"))
    }

    @Test
    func floatSchemaVersionRefusedNotCoerced() throws {
        // A NON-INTEGRAL float is refused. (Exactly "1.0" in the file would
        // round-trip through JSONSerialization's number formatting to the
        // integer 1 and is indistinguishable at parse time — schemaVersion is
        // a pinned ENVELOPE field outside the signed payload, so that
        // ambiguity cannot affect signature verification.)
        let keys = try makeKeyPair()
        let data = try envelopeData(payload: mixedPayload(), signingKey: keys.privateKey, schemaVersion: 1.5)
        let result = SignedRulePackLoader.verify(fileData: data, verifyingWith: keys.publicKey, sourceFile: "m")
        let refusal = try expectRefusal(result, {
            if case .malformedContainer = $0 { return true }
            return false
        }, "float schemaVersion")
        #expect(refusal.description.contains("not an integer"))
    }

    @Test
    func unexpectedTopLevelKeyRefusedWithTheKeyNamed() throws {
        let keys = try makeKeyPair()
        let data = try envelopeData(payload: mixedPayload(), signingKey: keys.privateKey,
                                    extraTopLevel: ["sneakyUnsigned": "value"])
        let result = SignedRulePackLoader.verify(fileData: data, verifyingWith: keys.publicKey, sourceFile: "m")
        let refusal = try expectRefusal(result, {
            if case .malformedContainer = $0 { return true }
            return false
        }, "extra key")
        #expect(refusal.description.contains("sneakyUnsigned"))
    }

    @Test
    func nonObjectPayloadRefused() throws {
        let keys = try makeKeyPair()
        let envelope: [String: Any] = [
            "format": RulePackCanonicalization.formatMagic,
            "schemaVersion": 1,
            "payload": "not-an-object",
            "signature": Data([0x00]).base64EncodedString(),
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let result = SignedRulePackLoader.verify(fileData: data, verifyingWith: keys.publicKey, sourceFile: "m")
        let refusal = try expectRefusal(result, {
            if case .malformedContainer = $0 { return true }
            return false
        }, "payload not object")
        #expect(refusal.description.contains("payload"))
    }

    @Test
    func topLevelArrayAndNonJSONFilesRefusedAsMalformed() throws {
        let keys = try makeKeyPair()
        let arrayData = try JSONSerialization.data(withJSONObject: [[1, 2, 3]])
        let arrayRefusal = try expectRefusal(
            SignedRulePackLoader.verify(fileData: arrayData, verifyingWith: keys.publicKey, sourceFile: "m"),
            isMalformed,
            "top-level array")
        #expect(arrayRefusal.description.contains("not a JSON object"))
        let garbageRefusal = try expectRefusal(
            SignedRulePackLoader.verify(fileData: Data("not json at all".utf8), verifyingWith: keys.publicKey, sourceFile: "m"),
            isMalformed,
            "non-JSON")
        #expect(garbageRefusal.description.contains("not valid JSON"))
    }

    @Test
    func unreadablePackFileRefusedHonest() throws {
        let keys = try makeKeyPair()
        let ghost = try newRoot().appendingPathComponent("missing.json")
        let refusal = try expectRefusal(
            SignedRulePackLoader.load(fileAt: ghost, verifyingWith: keys.publicKey),
            isUnreadable,
            "unreadable file")
        #expect(refusal.description.contains("rule pack unreadable"))
    }

    // MARK: Rule-shape validation

    @Test
    func selfAliasRefused() throws {
        let keys = try makeKeyPair()
        let payload: [String: Any] = ["caskAliases": ["chrome": "chrome"]]
        let data = try envelopeData(payload: payload, signingKey: keys.privateKey)
        let result = SignedRulePackLoader.verify(fileData: data, verifyingWith: keys.publicKey, sourceFile: "m")
        let refusal = try expectRefusal(result, {
            if case .payloadRulesMalformed = $0 { return true }
            return false
        }, "self alias")
        #expect(refusal.description.contains("self-alias"))
    }

    @Test
    func whitespacePaddedRuleValueRefusedNotNormalized() throws {
        let keys = try makeKeyPair()
        let payload: [String: Any] = ["caskAliases": ["chrome": " google-chrome "]]
        let data = try envelopeData(payload: payload, signingKey: keys.privateKey)
        let result = SignedRulePackLoader.verify(fileData: data, verifyingWith: keys.publicKey, sourceFile: "m")
        let refusal = try expectRefusal(result, {
            if case .payloadRulesMalformed = $0 { return true }
            return false
        }, "padded value")
        #expect(refusal.description.contains("verbatim"))
    }

    @Test
    func emptyAliasKeyRefused() throws {
        let keys = try makeKeyPair()
        let payload: [String: Any] = ["caskAliases": ["": "google-chrome"]]
        let data = try envelopeData(payload: payload, signingKey: keys.privateKey)
        let result = SignedRulePackLoader.verify(fileData: data, verifyingWith: keys.publicKey, sourceFile: "m")
        let refusal = try expectRefusal(result, {
            if case .payloadRulesMalformed = $0 { return true }
            return false
        }, "empty key")
        #expect(refusal.description.contains("empty"))
    }

    @Test
    func nonStringAliasTargetRefused() throws {
        let keys = try makeKeyPair()
        let payload: [String: Any] = ["caskAliases": ["chrome": 42]]
        let data = try envelopeData(payload: payload, signingKey: keys.privateKey)
        let result = SignedRulePackLoader.verify(fileData: data, verifyingWith: keys.publicKey, sourceFile: "m")
        let refusal = try expectRefusal(result, {
            if case .payloadRulesMalformed = $0 { return true }
            return false
        }, "non-string target")
        #expect(refusal.description.contains("not a string"))
    }

    @Test
    func aliasesNotAMapRefused() throws {
        let keys = try makeKeyPair()
        let payload: [String: Any] = ["caskAliases": [["chrome": "google-chrome"]]]
        let data = try envelopeData(payload: payload, signingKey: keys.privateKey)
        let result = SignedRulePackLoader.verify(fileData: data, verifyingWith: keys.publicKey, sourceFile: "m")
        _ = try expectRefusal(result, {
            if case .payloadRulesMalformed = $0 { return true }
            return false
        }, "aliases not a map")
    }

    @Test
    func pinWithUnexpectedKeysRefused() throws {
        let keys = try makeKeyPair()
        let payload: [String: Any] = ["caskTokenPins": [["bundleID": "org.a", "token": "t", "note": "extra"]]]
        let data = try envelopeData(payload: payload, signingKey: keys.privateKey)
        let result = SignedRulePackLoader.verify(fileData: data, verifyingWith: keys.publicKey, sourceFile: "m")
        let refusal = try expectRefusal(result, {
            if case .payloadRulesMalformed = $0 { return true }
            return false
        }, "extra pin keys")
        #expect(refusal.description.contains("schemaVersion 2"))
    }

    @Test
    func pinMissingTokenRefused() throws {
        let keys = try makeKeyPair()
        let payload: [String: Any] = ["caskTokenPins": [["bundleID": "org.a"]]]
        let data = try envelopeData(payload: payload, signingKey: keys.privateKey)
        let result = SignedRulePackLoader.verify(fileData: data, verifyingWith: keys.publicKey, sourceFile: "m")
        let refusal = try expectRefusal(result, {
            if case .payloadRulesMalformed = $0 { return true }
            return false
        }, "missing token")
        #expect(refusal.description.contains("'token'"))
    }

    @Test
    func pinsNotAnArrayRefused() throws {
        let keys = try makeKeyPair()
        let payload: [String: Any] = ["caskTokenPins": "nope"]
        let data = try envelopeData(payload: payload, signingKey: keys.privateKey)
        let result = SignedRulePackLoader.verify(fileData: data, verifyingWith: keys.publicKey, sourceFile: "m")
        _ = try expectRefusal(result, {
            if case .payloadRulesMalformed = $0 { return true }
            return false
        }, "pins not an array")
    }

    // MARK: Trust anchor validation

    @Test
    func publicKeyWrapperAcceptsOnly32ByteKeys() throws {
        let keys = try makeKeyPair()
        #expect(RulePackPublicKey(rawRepresentation: keys.privateKey.publicKey.rawRepresentation) != nil)
        #expect(RulePackPublicKey(rawRepresentation: Data(repeating: 0x01, count: 31)) == nil)
        #expect(RulePackPublicKey(rawRepresentation: Data(repeating: 0x01, count: 33)) == nil)
        #expect(RulePackPublicKey(base64Encoded: keys.privateKey.publicKey.rawRepresentation.base64EncodedString()) != nil)
        #expect(RulePackPublicKey(base64Encoded: "not base64!") == nil)
    }

    @Test
    func garbageBytesKeyVerifiesAsSignatureInvalidNotKeyInvalid() throws {
        // Any 32 bytes construct a Curve25519 key (Ed25519 accepts arbitrary
        // public-key bytes), so a wrong 32-byte key yields signatureInvalid.
        // The .signingKeyInvalid path stays as defense-in-depth behind the
        // wrapper (its failable init gates the 32-byte length) and the
        // cryptoKey nil case, which a 32-byte key cannot reach by itself.
        let keys = try makeKeyPair()
        let data = try envelopeData(payload: mixedPayload(), signingKey: keys.privateKey)
        guard let badKey = RulePackPublicKey(rawRepresentation: Data(repeating: 0xAB, count: 32)) else {
            throw TestFailure()
        }
        #expect(badKey.cryptoKey != nil)
        let result = SignedRulePackLoader.verify(fileData: data, verifyingWith: badKey, sourceFile: "m")
        _ = try expectRefusal(result, { $0 == .signatureInvalid }, "garbage key")
    }

    // MARK: Refusal text honesty

    @Test
    func signatureInvalidRefusalSaysZeroRulesApplied() {
        let text = SignedRulePackRefusal.signatureInvalid.description
        #expect(text.contains("INVALID"))
        #expect(text.contains("zero rules applied"))
    }
}
