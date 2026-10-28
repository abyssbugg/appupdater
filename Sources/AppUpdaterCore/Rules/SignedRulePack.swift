// SignedRulePack.swift — verified, FILE-based rule-pack distribution
// (GAP #24, serverless variant; lane vendor-rules).
//
// WHAT THIS IS: a rule-pack FILE (distributed by the owner or a trusted
// publisher by any channel they control — file share, git repo, download
// link) is verified BEFORE any of its rules are applied. The app-side loader
// here NEVER touches a server and NEVER generates keys: it verifies an EdDSA
// signature over the pack's canonical payload bytes against ONE
// caller-provided public key (the coordinator passes the SAME key embedded in
// the app — one trust domain, no new keys). Distribution-channel security is
// the publisher's responsibility; the signature proves publisher
// authenticity and payload integrity, nothing more, and the header says so.
//
// CONTAINER CONCEPT vs MacUpdater's config.json.encr (MACUPDATER-FINDINGS.md
// §4.3): they frame a binary container as magic + RSA-2048 signature +
// LZMA payload, aborting the load on signature failure. We mirror the
// CONCEPT — self-identifying magic, verify-before-apply, refusal on any
// signature problem — with OUR OWN mechanism, noted but not copied:
//
//   • the container is a JSON envelope (schema below), not a binary frame;
//   • the signature is EdDSA over Curve25519 (CryptoKit), not RSA-2048;
//   • the payload is applied unmodified (no compression layer to defend);
//   • the "magic" role is played by the required `format` field, whose value
//     must match exactly, and by `schemaVersion` (currently 1).
//
// ENVELOPE, schema version 1 (exactly these top-level keys — unknown
// top-level keys are REFUSED, the container-integrity stance: everything the
// reader acts on must be either a pinned envelope field or inside the signed
// payload):
//
//   {
//     "format": "appupdater-rule-pack/1",   // magic, exact match required
//     "schemaVersion": 1,                   // integer, must equal 1
//     "payload": { ... },                   // the rules (see below)
//     "signature": "<base64 EdDSA over the canonical payload bytes>"
//   }
//
// PAYLOAD (v1) — rules in the shapes the existing consumers already speak:
//
//   {
//     "caskAliases": { "<derived token>": "<verified cask token>", ... },
//         // EXACTLY the CaskAliases.table shape (derived token → target
//         // token to retry once after a primary-token 404)
//     "caskTokenPins": [ { "bundleID": "...", "token": "..." }, ... ]
//         // EXACTLY the ManualSource cask-pin identity shape (bundle
//         // identifier → cask token pin)
//   }
//
//   Both fields are optional (a pack may carry either or both); unknown
//   payload keys are ALLOWED and surfaced as `unconsumedPayloadKeys` — they
//   are signature-covered but v1 does not act on them (forward-compatible
//   without lying about what was applied). Pin objects must carry EXACTLY
//   {bundleID, token} — a schema change belongs in schemaVersion 2.
//
// CANONICAL BYTES (the exact canonicalization, test-pinned — see
// RulePackCanonicalization): the signature is computed and verified over
//
//   JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys])
//
// i.e. the payload object re-serialized with keys sorted, UTF-8, no other
// options. Signers MUST canonicalize with this exact rule (sign the
// canonical form, never an editor's pretty-print): the loader re-derives the
// canonical bytes from the PARSED file, so any payload whose numbers do not
// survive a JSON round-trip (e.g. a float authored as 1.0 that this
// serializer would emit as 1) fails verification honestly. v1 publishers are
// advised to keep payload values to strings/objects/arrays of strings — v1's
// consumed shapes are strings only, and string payloads canonicalize
// exactly. Duplicate keys inside a JSON object collapse silently at parse
// time (JSONSerialization keeps the last) and CANNOT be detected here — pack
// authors must ensure unique keys; this limitation is a property of the JSON
// format and is documented rather than hidden.
//
// VERIFICATION ORDER (each step refuses with a typed reason, in order):
//   1. read the file (unreadable → .unreadableFile)
//   2. parse top-level JSON object (→ .malformedContainer)
//   3. exact top-level key set {format, schemaVersion, payload, signature}
//      (→ .malformedContainer listing the unexpected keys)
//   4. format == "appupdater-rule-pack/1" (→ .magicMismatch)
//   5. schemaVersion == 1 (→ .unsupportedSchemaVersion)
//   6. signature decodes from standard base64 (→ .signatureFieldMalformed)
//   7. canonicalize payload, verify EdDSA (bad key → .signingKeyInvalid;
//      CryptoKit rejects the signature encoding → .signatureFieldMalformed;
//      verify returns false → .signatureInvalid)
//   8. payload rule validation (→ .payloadRulesMalformed)
//
// Values are consumed VERBATIM: whitespace-padded keys/tokens are refused,
// never trimmed (silently normalizing a rule would misstate what was
// verified). Self-aliases (derived == target) are refused: they change
// nothing and indicate an authoring error.

import CryptoKit
import Foundation

// MARK: - Trust anchor

/// The EdDSA public key the pack signatures are verified against. The
/// coordinator passes the SAME public key embedded in the app (one trust
/// domain, no new keys). The key is a raw 32-byte Curve25519 public key; a
/// base64 convenience init exists for embedding forms.
public struct RulePackPublicKey: Sendable, Hashable {
    public let rawRepresentation: Data

    /// Fails (returns nil) unless the data is exactly a 32-byte Curve25519
    /// public key — the honest, non-throwing shape for callers.
    public init?(rawRepresentation: Data) {
        guard rawRepresentation.count == 32 else { return nil }
        self.rawRepresentation = rawRepresentation
    }

    /// Base64-encoded 32-byte raw key (standard base64, no whitespace).
    public init?(base64Encoded string: String) {
        guard let data = Data(base64Encoded: string) else { return nil }
        self.init(rawRepresentation: data)
    }

    var cryptoKey: Curve25519.Signing.PublicKey? {
        try? Curve25519.Signing.PublicKey(rawRepresentation: rawRepresentation)
    }
}

// MARK: - Rules

/// One per-app cask-token pin from a rule pack — the ManualSource cask-pin
/// identity shape (bundle identifier → token), no more.
public struct RulePackCaskPin: Codable, Hashable, Sendable {
    public let bundleID: String
    public let token: String

    public init(bundleID: String, token: String) {
        self.bundleID = bundleID
        self.token = token
    }
}

/// A verified pack's rules, ready for the coordinator to merge into the
/// resolver. The loader returns this ONLY after signature verification and
/// rule validation both pass.
public struct SignedRulePack: Hashable, Sendable {
    /// The envelope schema version (always 1 for anything this loader accepts).
    public let schemaVersion: Int
    /// Derived token → verified cask token — the exact `CaskAliases.table`
    /// shape, merge-ready.
    public let caskAliases: [String: String]
    /// Per-app cask-token pins — the exact ManualSource cask-pin identity
    /// shape, merge-ready.
    public let caskTokenPins: [RulePackCaskPin]
    /// Payload keys present but not consumed by this schema version. They
    /// were signature-covered; the reader just did not act on them.
    public let unconsumedPayloadKeys: [String]
    /// The pack file's path, verbatim, for receipts.
    public let sourceFile: String

    /// Public for coordinators/tests that synthesize packs in memory; every
    /// DISK-loaded pack goes through the loader's verification instead.
    public init(schemaVersion: Int = RulePackCanonicalization.supportedSchemaVersion,
                caskAliases: [String: String] = [:],
                caskTokenPins: [RulePackCaskPin] = [],
                unconsumedPayloadKeys: [String] = [],
                sourceFile: String) {
        self.schemaVersion = schemaVersion
        self.caskAliases = caskAliases
        self.caskTokenPins = caskTokenPins
        self.unconsumedPayloadKeys = unconsumedPayloadKeys
        self.sourceFile = sourceFile
    }
}

// MARK: - Refusals

/// Every honest reason a pack can be refused. A refused pack contributes
/// ZERO rules — there is no partial application, no silent builtin fallback
/// for a bad pack (mirrors lock 11's manual-over-builtin discipline).
public enum SignedRulePackRefusal: Error, Hashable, Sendable, CustomStringConvertible {
    case unreadableFile(reason: String)
    case malformedContainer(reason: String)
    case magicMismatch(actual: String)
    case unsupportedSchemaVersion(actual: Int)
    case signatureFieldMalformed(reason: String)
    case signatureInvalid
    case signingKeyInvalid(reason: String)
    case payloadRulesMalformed(reason: String)

    public var description: String {
        switch self {
        case .unreadableFile(let r): return "rule pack unreadable: \(r)"
        case .malformedContainer(let r): return "rule pack container malformed: \(r)"
        case .magicMismatch(let actual): return "rule pack magic mismatch: expected 'appupdater-rule-pack/1', got '\(actual)'"
        case .unsupportedSchemaVersion(let actual): return "rule pack schemaVersion \(actual) unsupported (this build reads version 1)"
        case .signatureFieldMalformed(let r): return "rule pack signature field malformed: \(r)"
        case .signatureInvalid: return "rule pack signature INVALID for the provided public key — pack refused, zero rules applied"
        case .signingKeyInvalid(let r): return "rule pack verification key invalid: \(r)"
        case .payloadRulesMalformed(let r): return "rule pack payload rules malformed: \(r)"
        }
    }
}

// MARK: - Canonicalization (the pinned contract)

/// The exact canonical-byte rule, public so a publisher/signer tool and the
/// loader cannot drift. Signature = EdDSA over `canonicalPayloadBytes(_:)`.
public enum RulePackCanonicalization {

    /// The magic `format` value, exact.
    public static let formatMagic = "appupdater-rule-pack/1"
    /// The only schema version this build reads.
    public static let supportedSchemaVersion = 1

    /// The canonicalization rule's own typed error. JSONSerialization RAISES
    /// an uncatchable NSException (not a Swift error) when asked to WRITE a
    /// non-serializable value on this Foundation — observed:
    /// 'Invalid type in JSON write (_NSInlineData)'. The pre-check below
    /// turns that hard raise into an honest typed throw. The loader can
    /// never hit it (its payloads come from PARSED JSON, always
    /// re-serializable); the guard exists for publisher-side callers.
    public enum CanonicalizationError: Error, Equatable, CustomStringConvertible {
        case notAJSONObject

        public var description: String {
            "payload is not a JSON-object-shaped dictionary (JSONSerialization.isValidJSONObject failed)"
        }
    }

    /// Canonical payload bytes: JSONSerialization with [.sortedKeys], UTF-8,
    /// no other options. Throws `CanonicalizationError.notAJSONObject` when
    /// the payload fails `isValidJSONObject` (pre-check — prevents the
    /// uncatchable NSException raise described on `CanonicalizationError`).
    /// Test-pinned byte-for-byte.
    public static func canonicalPayloadBytes(_ payload: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw CanonicalizationError.notAJSONObject
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}

// MARK: - Loader

public enum SignedRulePackLoader {

    /// Load and verify a rule-pack file. Returns the rules ONLY when every
    /// verification step passes; any refusal means zero rules were produced.
    public static func load(
        fileAt url: URL,
        verifyingWith key: RulePackPublicKey
    ) -> Result<SignedRulePack, SignedRulePackRefusal> {
        let fileData: Data
        do {
            fileData = try Data(contentsOf: url)
        } catch {
            return .failure(.unreadableFile(reason: "\(error)"))
        }
        return verify(fileData: fileData, verifyingWith: key, sourceFile: url.path)
    }

    /// Verify raw envelope bytes (the file front end above delegates here;
    /// public so callers holding in-memory pack bytes — e.g. a downloaded
    /// blob staged by the coordinator — verify through the SAME pipeline).
    public static func verify(
        fileData: Data,
        verifyingWith key: RulePackPublicKey,
        sourceFile: String
    ) -> Result<SignedRulePack, SignedRulePackRefusal> {
        // 1-2: top-level JSON object.
        let top: Any
        do {
            top = try JSONSerialization.jsonObject(with: fileData, options: [])
        } catch {
            return .failure(.malformedContainer(reason: "not valid JSON: \(error)"))
        }
        guard let envelope = top as? [String: Any] else {
            return .failure(.malformedContainer(reason: "top level is \(typeName(top)), not a JSON object"))
        }

        // 3: exact top-level key set.
        let expectedKeys: Set<String> = ["format", "schemaVersion", "payload", "signature"]
        let unexpected = Set(envelope.keys).subtracting(expectedKeys).sorted()
        if !unexpected.isEmpty {
            return .failure(.malformedContainer(
                reason: "unexpected top-level keys \(unexpected) — the v1 envelope carries exactly "
                    + "\(expectedKeys.sorted()) (container-integrity stance: everything the reader acts on is a pinned "
                    + "envelope field or inside the signed payload)"))
        }

        // 4: magic.
        guard let format = envelope["format"] as? String else {
            return .failure(.malformedContainer(reason: "'format' missing or not a string"))
        }
        guard format == RulePackCanonicalization.formatMagic else {
            return .failure(.magicMismatch(actual: format))
        }

        // 5: schema version. Strict integer check: JSON booleans bridge to
        // NSNumber and would coerce through `as? Int` (true → 1), and floats
        // (1.0) must not silently pass as 1 — both are refused here.
        guard let rawVersion = envelope["schemaVersion"] as? NSNumber else {
            return .failure(.malformedContainer(reason: "'schemaVersion' missing or not a number"))
        }
        if CFGetTypeID(rawVersion) == CFBooleanGetTypeID() {
            return .failure(.malformedContainer(reason: "'schemaVersion' is a boolean, not an integer"))
        }
        if CFNumberIsFloatType(rawVersion) {
            return .failure(.malformedContainer(reason: "'schemaVersion' is not an integer"))
        }
        let version = rawVersion.intValue
        guard version == RulePackCanonicalization.supportedSchemaVersion else {
            return .failure(.unsupportedSchemaVersion(actual: version))
        }

        // 6: signature field.
        guard let signatureBase64 = envelope["signature"] as? String else {
            return .failure(.malformedContainer(reason: "'signature' missing or not a string"))
        }
        guard let signatureData = Data(base64Encoded: signatureBase64) else {
            return .failure(.signatureFieldMalformed(
                reason: "not valid standard base64 (strict decode, no whitespace tolerance)"))
        }

        // 7: canonical payload bytes + EdDSA verification.
        guard let payload = envelope["payload"] as? [String: Any] else {
            return .failure(.malformedContainer(reason: "'payload' missing or not a JSON object"))
        }
        let canonical: Data
        do {
            canonical = try RulePackCanonicalization.canonicalPayloadBytes(payload)
        } catch {
            return .failure(.malformedContainer(reason: "payload not canonicalizable: \(error)"))
        }
        guard let cryptoKey = key.cryptoKey else {
            return .failure(.signingKeyInvalid(
                reason: "the provided public key does not construct a Curve25519 signing key (raw representation must be "
                    + "exactly 32 bytes)"))
        }
        do {
            let valid = try cryptoKey.isValidSignature(signatureData, for: canonical)
            guard valid else { return .failure(.signatureInvalid) }
        } catch {
            return .failure(.signatureFieldMalformed(
                reason: "CryptoKit rejected the signature encoding (an Ed25519 signature is exactly 64 bytes): \(error)"))
        }

        // 8: payload rule validation (post-signature: only verified bytes
        // ever reach the rule shapes).
        return validateRules(payload: payload, schemaVersion: version, sourceFile: sourceFile)
    }

    // MARK: Rule validation (step 8)

    private static func validateRules(
        payload: [String: Any],
        schemaVersion: Int,
        sourceFile: String
    ) -> Result<SignedRulePack, SignedRulePackRefusal> {
        var aliases: [String: String] = [:]
        var pins: [RulePackCaskPin] = []

        if let aliasValue = payload["caskAliases"] {
            guard let aliasMap = aliasValue as? [String: Any] else {
                return .failure(.payloadRulesMalformed(reason: "'caskAliases' is not a JSON object map of token→token"))
            }
            for (derived, targetValue) in aliasMap {
                guard let target = targetValue as? String else {
                    return .failure(.payloadRulesMalformed(
                        reason: "caskAliases['\(derived)'] target is \(typeName(targetValue)), not a string"))
                }
                if let refusal = ruleTextRefusal(derived, field: "caskAliases key") {
                    return .failure(refusal)
                }
                if let refusal = ruleTextRefusal(target, field: "caskAliases['\(derived)'] target") {
                    return .failure(refusal)
                }
                if derived == target {
                    return .failure(.payloadRulesMalformed(
                        reason: "caskAliases self-alias '\(derived)' → '\(target)' refused (changes nothing; authoring error)"))
                }
                aliases[derived] = target
            }
        }

        if let pinsValue = payload["caskTokenPins"] {
            guard let pinArray = pinsValue as? [[String: Any]] else {
                return .failure(.payloadRulesMalformed(reason: "'caskTokenPins' is not an array of objects"))
            }
            for (index, pinObject) in pinArray.enumerated() {
                let allowed: Set<String> = ["bundleID", "token"]
                let extra = Set(pinObject.keys).subtracting(allowed).sorted()
                guard extra.isEmpty else {
                    return .failure(.payloadRulesMalformed(
                        reason: "caskTokenPins[\(index)] carries unexpected keys \(extra) — a v1 pin is exactly "
                            + "{bundleID, token}; a schema change belongs in schemaVersion 2"))
                }
                guard let bundleID = pinObject["bundleID"] as? String else {
                    return .failure(.payloadRulesMalformed(reason: "caskTokenPins[\(index)] 'bundleID' missing or not a string"))
                }
                guard let token = pinObject["token"] as? String else {
                    return .failure(.payloadRulesMalformed(reason: "caskTokenPins[\(index)] 'token' missing or not a string"))
                }
                if let refusal = ruleTextRefusal(bundleID, field: "caskTokenPins[\(index)] bundleID") {
                    return .failure(refusal)
                }
                if let refusal = ruleTextRefusal(token, field: "caskTokenPins[\(index)] token") {
                    return .failure(refusal)
                }
                pins.append(RulePackCaskPin(bundleID: bundleID, token: token))
            }
        }

        let consumed: Set<String> = ["caskAliases", "caskTokenPins"]
        let unconsumed = Set(payload.keys).subtracting(consumed).sorted()
        return .success(SignedRulePack(
            schemaVersion: schemaVersion,
            caskAliases: aliases,
            caskTokenPins: pins,
            unconsumedPayloadKeys: unconsumed,
            sourceFile: sourceFile))
    }

    /// Rule text is consumed VERBATIM: empty and whitespace-padded values are
    /// refused, never trimmed (silently normalizing a rule would misstate
    /// what was verified). Returns the typed refusal, or nil when the text is
    /// acceptable.
    private static func ruleTextRefusal(_ value: String, field: String) -> SignedRulePackRefusal? {
        if value.isEmpty {
            return .payloadRulesMalformed(reason: "\(field) is empty — refused, never normalized")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != value || trimmed.isEmpty {
            return .payloadRulesMalformed(reason: "\(field) is whitespace-padded — refused, values are consumed verbatim")
        }
        return nil
    }

    private static func typeName(_ value: Any) -> String {
        String(describing: type(of: value))
    }
}
