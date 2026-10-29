// HelperProtocol.swift — the privileged helper's IPC message contract.
// PrivilegedHelper lane · exclusive file of this lane.
//
// ============================================================================
// HONESTY BOUNDARY — BUILT-DORMANT (docs/threat-model/PRIVILEGED-HELPER-REVIEW.md
// §6, SIGNED BY THE OWNER 2026-10-29): "PROCEED — build dormant."
// ============================================================================
// This module is BUILT and TESTED but PERMANENTLY INERT by default: no code
// path installs, registers, or launches the helper. Activation is ADDITIONALLY
// frozen pending real Apple Developer ID enrollment (§6 box + §4 residual
// risk 2). Until both, the SHIPPED privileged path remains the staged
// owner-command flow (Updatest shape, staged-PKG v1, 94bfd25) — unchanged.
//
// WHAT THIS FILE IS: the versioned IPC surface §1 describes, defined as pure
// Codable message types plus an encoder/decoder seam. There is NO XPC/NSXPC
// transport here and none is implied — a future transport plugs in by
// implementing the coder seam (or the transport layer above it); this file
// stays the wire contract. The helper itself (a separate executable) and its
// transport belong to post-enrollment wiring; nothing in AppUpdaterCore
// constructs or dials one.
//
// CONTRACT GROUNDED IN THE REVIEW DOC (each field traces to a § line):
//   §1    minimal, versioned surface: exactly two operations, installApp and
//         updateApp, both PKG installs via `installer -pkg`; nothing else.
//   §3.3  NO standing rules: every install is a fresh, explicit per-apply
//         call carrying app name + version + checksum; requests lacking all
//         three are REJECTED (validate() below — never trusted by callers).
//   §3.5  payload-authored strings can never become arguments: the request
//         carries receipt-chain-GENERATED identity (bundle identifier +
//         checksum + generated display name), never cask/appcast text
//         verbatim. Enforcement lives with the (future) coordinator wiring;
//         the message shape takes the structured fields by construction.
//   §3.2  the request carries the sha256 AND the `pkgutil --check-signature`
//         verdict gathered at staging time; the helper-side re-verify happens
//         AFTER staging, immediately before `installer`, in the same task
//         (helper runtime behavior, out of scope here — transport is future).
//   §3.6  rollback safety: the request carries the written backup-receipt zip
//         path the user-space installer produces; a request without it is
//         invalid (validate() refuses).
//   §3.8  auditability: responses carry VERBATIM receipts — the exact
//         installer output and exit status, never a summary.
//
// UNSPECIFIED BY THE DOC — HONEST NOTES (never invented silently):
//   • The helper's bundle identifier / launchd label is not fixed by the doc.
//     It is frozen here as ``HelperProtocol.helperLabel``, derived from the
//     repo's own identifier prefix (io.appupdater.AppUpdater — the os.Logger
//     subsystem used across stores), so plan + plist + receipts agree.
//   • The wire version NUMBER is not specified ("versioned" only): v1 is
//     chosen and stamped on every envelope; unknown versions refuse.
//   • Receipt-log persistence (§3.8 helper-side log) is helper-runtime
//     behavior and is NOT specified — out of scope; only the message fields
//     that would feed it are defined here.
//
// NOT wired into the scanner/UI/CLI — the coordinator owns that glue, and the
// signed §6 box means there is no glue to wire until activation gates pass.

import Foundation

// MARK: - Protocol identity

/// The IPC surface's identity constants (see the header's honest notes: the
/// doc fixes "versioned" but not the number, and not the helper's label).
public enum HelperProtocol {

    /// Current wire protocol version stamped on every envelope. Bumped ONLY
    /// additively-and-gated (an unknown version refuses, never guesses).
    public static let protocolVersion = 1

    /// The helper's launchd label / bundle identifier, FROZEN so the plist
    /// template, registration plan and receipts all agree. Derived from the
    /// repo's identifier prefix; the doc leaves the exact name open.
    public static let helperLabel = "io.appupdater.AppUpdater.PrivilegedInstallHelper"
}

// MARK: - Requests (app/CLI → helper)

/// Which of the two (and only two) operations §1 authorizes.
public enum HelperOperation: String, Codable, CaseIterable, Sendable, Hashable {
    /// First-time PKG install of an operator-approved payload (`installer -pkg`).
    case installApp
    /// PKG-based update of an existing app (`installer -pkg` over the recorded target).
    case updateApp
}

/// One fresh, explicit per-apply request (§3.3: no standing rules — every
/// install is its own request). Pure data: everything the helper would need
/// to verify and act, nothing free-form.
public struct HelperRequest: Codable, Hashable, Sendable {

    /// Correlation identifier: the response echoes it (§3.8 auditability).
    public var requestID: UUID
    /// The protocol version the sender wrote. A mismatch is a validation
    /// failure — never negotiated silently.
    public var protocolVersion: Int
    /// The authorized operation (§1: installApp | updateApp only).
    public var operation: HelperOperation
    /// The target app's bundle identifier (§3.5: identity, never free text).
    public var bundleIdentifier: String
    /// The target app's version, generated from the verified receipt chain
    /// (§3.3 requires version on every request).
    public var version: String
    /// Receipt-chain-generated display name for the receipt log (§3.3
    /// requires the app name on every request; §3.5: generated, never payload
    /// verbatim — the enforcement of that rule belongs to the producer).
    public var appDisplayName: String
    /// Absolute path of the app the request concerns (updateApp: the existing
    /// bundle; installApp: the approved destination). Structured identity,
    /// not free-form commentary.
    public var appPath: String
    /// Absolute path of the STAGED, verified artifact the helper would install
    /// (per-apply staging; per-UUID dir, 0700, removed on every outcome —
    /// §3.2's staging discipline is helper-runtime behavior, out of scope here).
    public var stagedArtifactPath: String
    /// The sha256 the verified receipt chain recorded for the staged artifact
    /// (§3.2). Required and format-checked by ``validate()``.
    public var expectedSha256Hex: String
    /// The `pkgutil --check-signature` verdict text AppUpdater gathered at
    /// staging time (§3.2 carries it in the request). Required.
    public var pkgutilSignatureVerdict: String
    /// Absolute path of the written backup-receipt zip the user-space
    /// installer produced for the target (§3.6: the helper refuses to run
    /// without one — every root install stays reversible). Required.
    public var backupZipPath: String

    public init(
        requestID: UUID = UUID(),
        protocolVersion: Int = HelperProtocol.protocolVersion,
        operation: HelperOperation,
        bundleIdentifier: String,
        version: String,
        appDisplayName: String,
        appPath: String,
        stagedArtifactPath: String,
        expectedSha256Hex: String,
        pkgutilSignatureVerdict: String,
        backupZipPath: String
    ) {
        self.requestID = requestID
        self.protocolVersion = protocolVersion
        self.operation = operation
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.appDisplayName = appDisplayName
        self.appPath = appPath
        self.stagedArtifactPath = stagedArtifactPath
        self.expectedSha256Hex = expectedSha256Hex
        self.pkgutilSignatureVerdict = pkgutilSignatureVerdict
        self.backupZipPath = backupZipPath
    }

    /// Validates the request against §3.3/§3.2/§3.6 + the protocol version.
    /// Pure; the helper-side runtime (future) MUST call this before serving —
    /// and callers may call it before sending. nil = valid.
    public func validate() -> HelperRequestIssue? {
        if protocolVersion != HelperProtocol.protocolVersion {
            return .protocolVersionMismatch(
                expected: HelperProtocol.protocolVersion, actual: protocolVersion)
        }
        if bundleIdentifier.trimmingCharacters(in: .whitespaces).isEmpty {
            return .fieldEmpty(what: "bundleIdentifier")
        }
        if version.trimmingCharacters(in: .whitespaces).isEmpty {
            return .fieldEmpty(what: "version")
        }
        if appDisplayName.trimmingCharacters(in: .whitespaces).isEmpty {
            return .fieldEmpty(what: "appDisplayName")
        }
        if appPath.trimmingCharacters(in: .whitespaces).isEmpty {
            return .fieldEmpty(what: "appPath")
        }
        if stagedArtifactPath.trimmingCharacters(in: .whitespaces).isEmpty {
            return .fieldEmpty(what: "stagedArtifactPath")
        }
        if expectedSha256Hex.isEmpty {
            return .sha256Missing
        }
        if !Self.isHexSha256(expectedSha256Hex) {
            return .sha256Malformed(observedLength: expectedSha256Hex.count)
        }
        if pkgutilSignatureVerdict.trimmingCharacters(in: .whitespaces).isEmpty {
            return .pkgVerdictMissing
        }
        if backupZipPath.trimmingCharacters(in: .whitespaces).isEmpty {
            return .fieldEmpty(what: "backupZipPath")
        }
        return nil
    }

    /// 64 ASCII hex digits — the sha256Hex shape every producer uses.
    private static func isHexSha256(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        let hexDigits = "0123456789abcdefABCDEF"
        return value.allSatisfy { hexDigits.contains($0) }
    }
}

/// A typed, wire-stable validation refusal (§3.3: the helper REJECTS requests
/// lacking the required triple — an honest machine-readable reason, never a
/// silent repair).
public enum HelperRequestIssue: Error, CustomStringConvertible, Sendable, Hashable {
    case protocolVersionMismatch(expected: Int, actual: Int)
    case fieldEmpty(what: String)
    case sha256Missing
    case sha256Malformed(observedLength: Int)
    case pkgVerdictMissing

    public var description: String {
        switch self {
        case .protocolVersionMismatch(let expected, let actual):
            return "protocol version mismatch: expected \(expected), request carried \(actual)"
        case .fieldEmpty(let what): return "required field empty or missing: \(what)"
        case .sha256Missing: return "no sha256 on the request — refusing (§3.3)"
        case .sha256Malformed(let length):
            return "sha256 is not 64 ASCII hex digits (observed length \(length))"
        case .pkgVerdictMissing: return "no pkgutil --check-signature verdict on the request — refusing (§3.2)"
        }
    }
}

// MARK: - Responses (helper → app/CLI)

/// The helper's response: the echoed correlation id plus a VERBATIM receipt
/// (§3.8 — the exact installer output/exit, never a summary). The response
/// adds no judgment beyond success/failure and the verbatim evidence.
public struct HelperResponse: Codable, Hashable, Sendable {
    /// Mirrors ``HelperRequest/requestID`` (correlation; §3.8).
    public var requestID: UUID
    /// The protocol version the helper served (== request's, or refused).
    public var protocolVersion: Int
    /// Whether the requested operation completed successfully.
    public var succeeded: Bool
    /// `installer(8)`'s exit status, verbatim (nil when `installer` was never
    /// reached — e.g. a validation refusal before any execution attempt).
    public var installerExitStatus: Int32?
    /// `installer(8)`'s combined output, verbatim (nil when never reached).
    public var installerOutput: String?
    /// The honest failure detail when `succeeded == false` (validation
    /// refusal text, spawn failure, or non-zero installer exit summary).
    public var failureDetail: String?
    /// When the helper finished handling the request (helper-supplied
    /// timestamp; §3.8's receipt log feeds from this).
    public var completedAt: Date

    public init(
        requestID: UUID,
        protocolVersion: Int,
        succeeded: Bool,
        installerExitStatus: Int32? = nil,
        installerOutput: String? = nil,
        failureDetail: String? = nil,
        completedAt: Date
    ) {
        self.requestID = requestID
        self.protocolVersion = protocolVersion
        self.succeeded = succeeded
        self.installerExitStatus = installerExitStatus
        self.installerOutput = installerOutput
        self.failureDetail = failureDetail
        self.completedAt = completedAt
    }
}

// MARK: - Coder seam (the plug-in point for a future transport)

/// The encoder/decoder seam between the message contract and any transport.
/// A future XPC/NSXPC transport plugs in by providing its own coder (or by
/// building on `.json()`); nothing in this module dials a transport.
///
/// `Sendable` by construction: all fields are `@Sendable` closures; the JSON
/// default is stateless. The JSON codec is deterministic (`sortedKeys`) so
/// identical messages produce identical bytes — receipts stay comparable.
public struct HelperMessageCoder: Sendable {

    public var encodeRequest: @Sendable (HelperRequest) throws -> Data
    public var decodeRequest: @Sendable (Data) throws -> HelperRequest
    public var encodeResponse: @Sendable (HelperResponse) throws -> Data
    public var decodeResponse: @Sendable (Data) throws -> HelperResponse

    public init(
        encodeRequest: @escaping @Sendable (HelperRequest) throws -> Data,
        decodeRequest: @escaping @Sendable (Data) throws -> HelperRequest,
        encodeResponse: @escaping @Sendable (HelperResponse) throws -> Data,
        decodeResponse: @escaping @Sendable (Data) throws -> HelperResponse
    ) {
        self.encodeRequest = encodeRequest
        self.decodeRequest = decodeRequest
        self.encodeResponse = encodeResponse
        self.decodeResponse = decodeResponse
    }

    /// The default wire codec: JSON, sorted keys, no dates transformation
    /// (Foundation's default ISO-8601-ish strategy-free encoding is what the
    /// sibling stores use). Errors propagate verbatim — a decode failure is
    /// the transport's refused-message case, never a guessed fallback.
    public static func json() -> HelperMessageCoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        return HelperMessageCoder(
            encodeRequest: { try encoder.encode($0) },
            decodeRequest: { try decoder.decode(HelperRequest.self, from: $0) },
            encodeResponse: { try encoder.encode($0) },
            decodeResponse: { try decoder.decode(HelperResponse.self, from: $0) }
        )
    }
}
