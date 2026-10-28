// Storefront.swift — App Store storefront country data layer (GAP #10).
//
// Contract (docs/reverse/MACUPDATER-FINDINGS.md §3.2 Source 2 + §4.1/§4.4;
// docs/reverse/UPDATEST-FINDINGS.md §3.4; docs/reverse/GAP-ANALYSIS.md #10):
//   MacUpdater's MAS source runs its iTunes lookup PER STOREFRONT COUNTRY
//   (`getMASUpdateinfo:countryCode:appleArcade:`) and ships a data table of
//   countries excluded from lookup: resource `countries_bad.txt` =
//   "countries excluded from lookup". The teardown quotes exactly 28 codes —
//   AE AL AO BH BY CL CO CR DZ EC IN KE KR MD MX RS RU SA UG VN CH TJ GE MT
//   GB BJ SN PE — matching GAP-ANALYSIS #10's "28-country exclusion list".
//   Updatest instead PINS its lookup to `country=US` (URL verbatim in the
//   binary + 420 live cached lookups), and our own MAS source
//   (UpdateSources/MAS) already pins `us` for the same v1 reason.
//
// What is and is NOT documented (honesty discipline):
//   - DOCUMENTED: the 28-code exclusion list and its collective reason
//     ("countries excluded from lookup"). Per-country rationales are NOT in
//     either teardown — every entry below carries that one documented reason;
//     anything more specific would be invented. (Note: the list includes CH
//     and GB, which reads odd but is exactly what the teardown documents.)
//   - NOT DOCUMENTED: how either competitor obtains the machine's LIVE
//     storefront country (no defaults/region probe is named in either
//     teardown; MacUpdater's countryCode parameter source is undocumented).
//     The live mechanism below is therefore OURS and flagged as ours:
//     Apple's documented `StoreKit.Storefront.current` probe. When it is
//     unavailable or empty the verdict is `unknown` — unknown is a
//     first-class outcome, never a locale guess.
//   - Out of scope for this lane: the iTunes lookup itself (network side is
//     owned by UpdateSources/MAS). This is the documented DATA layer:
//     resolve the country, consult the exclusion list, answer honestly.
//
// SEAM: the live probe is injected (StorefrontProbe). Tests stub it; the
// `.live()` default wraps StoreKit and performs no network access. No MAS
// automation here — that is future assistant work.

import Foundation
import StoreKit

// MARK: - Result types

/// The storefront answer for this machine. Immutable by design: a verdict plus
/// its honest provenance note.
public struct StorefrontInfo: Equatable, Sendable {

    /// `eligible` = a known country not on the documented exclusion list;
    /// `excluded` = on the list; `unknown` = the country could not be
    /// determined (first-class verdict, see header).
    public enum Status: Equatable, Sendable {
        case eligible
        case excluded
        case unknown
    }

    /// Raw storefront country code as the probe reported it (trimmed). Nil
    /// exactly when `status == .unknown`.
    public let countryCode: String?

    public let status: Status

    /// One-line provenance/honesty note: what was consulted, what is
    /// documented vs. ours.
    public let note: String

    public init(countryCode: String?, status: Status, note: String) {
        self.countryCode = countryCode
        self.status = status
        self.note = note
    }
}

/// One entry of the documented exclusion list: the country code plus the
/// documented reason. The reason is the SAME documented sentence for every
/// entry on purpose — the teardown documents the list, not per-country
/// rationales.
public struct StorefrontExcludedCountry: Equatable, Sendable {
    public let code: String
    public let reason: String

    public init(code: String, reason: String) {
        self.code = code
        self.reason = reason
    }
}

// MARK: - Storefront

public enum Storefront {

    /// Provenance of the exclusion list (part of the public honesty surface).
    public static let documentedListSource =
        "MACUPDATER-FINDINGS.md §3.2 Source 2: resource countries_bad.txt = "
            + "\"countries excluded from lookup\" (28 codes quoted verbatim; "
            + "count matches GAP-ANALYSIS #10)"

    /// The ONE documented reason (teardown quote). No per-country rationale is
    /// documented anywhere in either teardown, so no entry claims one.
    public static let documentedExclusionReason =
        "listed in MacUpdater's countries_bad.txt — \"countries excluded from lookup\" "
            + "(teardown documents the list, not per-country rationales)"

    /// The documented 28-country exclusion list, in the teardown's verbatim
    /// order. Encoded as data (not control flow) so the list itself is
    /// inspectable and testable.
    public static let excludedCountries: [StorefrontExcludedCountry] = [
        StorefrontExcludedCountry(code: "AE", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "AL", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "AO", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "BH", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "BY", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "CL", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "CO", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "CR", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "DZ", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "EC", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "IN", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "KE", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "KR", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "MD", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "MX", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "RS", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "RU", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "SA", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "UG", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "VN", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "CH", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "TJ", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "GE", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "MT", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "GB", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "BJ", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "SN", reason: documentedExclusionReason),
        StorefrontExcludedCountry(code: "PE", reason: documentedExclusionReason),
    ]

    private static let excludedCodesLowercased = Set(excludedCountries.map { $0.code.lowercased() })

    /// Pure, case-insensitive membership test against the documented list.
    /// A nil/blank code never excludes (an unknown storefront cannot be
    /// claimed to be on the list).
    public static func excludes(countryCode: String?) -> Bool {
        guard let trimmed = normalized(countryCode), !trimmed.isEmpty else { return false }
        return excludedCodesLowercased.contains(trimmed)
    }

    /// Resolves the machine's storefront country through the injected probe
    /// and classifies it against the documented list. NEVER throws and never
    /// guesses: a failed/empty probe yields the `unknown` verdict with the
    /// documented-context note. (Async because the Apple-documented probe
    /// `Storefront.current` is an async property on this SDK.)
    public static func currentStorefront(probe: StorefrontProbe = .live()) async -> StorefrontInfo {
        let reading: String?
        do {
            reading = try await probe.read()
        } catch {
            return StorefrontInfo(
                countryCode: nil,
                status: .unknown,
                note: unknownNote + " probe threw: \(error)")
        }
        // Trim for storage; lowercase for MATCHING only (the raw probe value is
        // what gets stored — this contract is asserted by the tests).
        guard let raw = reading else {
            return StorefrontInfo(countryCode: nil, status: .unknown, note: unknownNote)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return StorefrontInfo(countryCode: nil, status: .unknown, note: unknownNote)
        }
        if excludedCodesLowercased.contains(trimmed.lowercased()) {
            return StorefrontInfo(
                countryCode: trimmed,
                status: .excluded,
                note: "storefront \(trimmed) is on the documented 28-country exclusion list ("
                    + documentedListSource + ")")
        }
        return StorefrontInfo(
            countryCode: trimmed,
            status: .eligible,
            note: "storefront \(trimmed) is not on the documented 28-country exclusion list ("
                + documentedListSource + ")")
    }

    // MARK: - Normalization + notes

    /// Trim + lowercase for matching only; the raw probe value is what gets
    /// stored in StorefrontInfo.countryCode.
    private static func normalized(_ code: String?) -> String? {
        code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The honesty note for every unknown verdict: says what is documented,
    /// what is ours, and what the documented fallback behavior is.
    private static var unknownNote: String {
        "machine storefront country not resolvable — neither teardown documents a live-storefront "
            + "probe (MacUpdater's countryCode source is undocumented; Updatest pins country=US, "
            + "verbatim in its lookup URL); this probe (StoreKit Storefront.current) is OURS, "
            + "Apple-documented, and returned nothing here — MAS lookups should stay on the "
            + "documented us pin until the owner says otherwise"
    }
}

// MARK: - Probe seam

/// Injected storefront probe. Tests inject stubs; production uses `.live()`
/// (StoreKit, no network). Deliberately its own tiny type in this lane's
/// Storefront/ directory (house pattern: every lane owns its seam).
public struct StorefrontProbe: Sendable {

    /// Returns the storefront country code, or nil when unavailable. May
    /// throw — the resolver turns a throw into the honest unknown verdict.
    /// Async because the Apple-documented probe (`Storefront.current`) is an
    /// async property on this SDK.
    public typealias Read = @Sendable () async throws -> String?

    private let invoke: Read

    public init(read: @escaping Read) {
        self.invoke = read
    }

    public func read() async throws -> String? {
        try await invoke()
    }

    /// Production probe: Apple's documented `Storefront.current` (async
    /// property on this SDK). Returns nil when no App Store account context
    /// is available (e.g. CI, CLI hosts) — callers then get the honest
    /// unknown verdict.
    public static func live() -> StorefrontProbe {
        StorefrontProbe {
            await StoreKit.Storefront.current?.countryCode
        }
    }
}
