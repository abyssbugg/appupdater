// StorefrontTests.swift — hermetic tests for the storefront data layer
// (Sources/AppUpdaterCore/Storefront/Storefront.swift, GAP #10).
//
// Swift Testing only (XCTest discovery is broken on this toolchain — AGENTS.md
// gotcha ledger). Fully hermetic: the storefront probe seam is ALWAYS stubbed,
// so `StoreKit.Storefront.current` is never invoked and nothing touches the
// network or the App Store account context. The exclusion-list expectations
// are the verbatim documented codes from MACUPDATER-FINDINGS.md §3.2 Source 2
// (resource `countries_bad.txt`, 28 codes, order as quoted).

import Foundation
import Testing
@testable import AppUpdaterCore

// MARK: - Documented exclusion-list data

@Suite("Storefront: 28-country exclusion list data")
struct StorefrontExclusionListTests {

    private let documentedOrder = [
        "AE", "AL", "AO", "BH", "BY", "CL", "CO", "CR", "DZ", "EC", "IN", "KE", "KR", "MD",
        "MX", "RS", "RU", "SA", "UG", "VN", "CH", "TJ", "GE", "MT", "GB", "BJ", "SN", "PE",
    ]

    @Test("list holds exactly the 28 documented codes, in the documented order")
    func documentedCountAndOrder() {
        #expect(Storefront.excludedCountries.count == 28)
        #expect(Storefront.excludedCountries.map(\.code) == documentedOrder)
    }

    @Test("every entry carries the ONE documented reason (no invented rationales)")
    func documentedReasonOnEveryEntry() {
        for entry in Storefront.excludedCountries {
            #expect(entry.reason == Storefront.documentedExclusionReason)
            #expect(entry.reason.contains("countries_bad.txt"))
        }
        #expect(Storefront.documentedListSource.contains("countries_bad.txt"))
    }

    @Test("codes are uppercase two-letter")
    func codeShape() {
        for entry in Storefront.excludedCountries {
            #expect(entry.code.count == 2)
            #expect(entry.code == entry.code.uppercased())
        }
    }
}

// MARK: - Pure membership test

@Suite("Storefront: excludes(countryCode:) pure matching")
struct StorefrontExcludesTests {

    @Test("every documented code excludes, case-insensitively (upper and lower)")
    func documentedCodesExcludeCaseInsensitively() {
        for entry in Storefront.excludedCountries {
            #expect(Storefront.excludes(countryCode: entry.code))
            #expect(Storefront.excludes(countryCode: entry.code.lowercased()))
            #expect(Storefront.excludes(countryCode: "  \(entry.code.lowercased()) "))
        }
    }

    @Test("undocumented countries never exclude")
    func undocumentedCountriesDoNotExclude() {
        #expect(!Storefront.excludes(countryCode: "US"))
        #expect(!Storefront.excludes(countryCode: "us"))
        #expect(!Storefront.excludes(countryCode: "DE"))
        #expect(!Storefront.excludes(countryCode: "ZZ"))
    }

    @Test("nil/blank codes never exclude (an unknown storefront cannot be claimed listed)")
    func nilAndBlankNeverExclude() {
        #expect(!Storefront.excludes(countryCode: nil))
        #expect(!Storefront.excludes(countryCode: ""))
        #expect(!Storefront.excludes(countryCode: "   "))
    }
}

// MARK: - Seam-stubbed resolution

@Suite("Storefront: currentStorefront(probe:) with stubbed seam")
struct StorefrontResolutionTests {

    /// Tiny error type for the throwing-stub cases (Sendable).
    private struct ProbeBoom: Error {}

    @Test("eligible country → eligible with raw code preserved")
    func eligibleCountry() async {
        let info = await Storefront.currentStorefront(probe: StorefrontProbe { "US" })
        #expect(info.status == .eligible)
        #expect(info.countryCode == "US")
        #expect(info.note.contains("not on the documented 28-country exclusion list"))
    }

    @Test("excluded country (with surrounding whitespace) → excluded, documented note")
    func excludedCountry() async {
        let info = await Storefront.currentStorefront(probe: StorefrontProbe { " RU " })
        #expect(info.status == .excluded)
        #expect(info.countryCode == "RU")
        #expect(info.note.contains("28-country exclusion list"))
        #expect(info.note.contains("countries_bad.txt"))
    }

    @Test("lowercased documented code still excludes (case-insensitive)")
    func lowercasedExcluded() async {
        let info = await Storefront.currentStorefront(probe: StorefrontProbe { "gb" })
        #expect(info.status == .excluded)
        #expect(info.countryCode == "gb")
    }

    @Test("nil probe → honest unknown verdict with the documented-context note")
    func nilProbeIsUnknown() async {
        let info = await Storefront.currentStorefront(probe: StorefrontProbe { nil })
        #expect(info.status == .unknown)
        #expect(info.countryCode == nil)
        #expect(info.note.contains("neither teardown documents a live-storefront probe"))
        #expect(info.note.contains("Updatest pins country=US"))
    }

    @Test("blank probe string → unknown, never guessed")
    func blankProbeIsUnknown() async {
        let info = await Storefront.currentStorefront(probe: StorefrontProbe { "   " })
        #expect(info.status == .unknown)
        #expect(info.countryCode == nil)
    }

    @Test("throwing probe → unknown with the throw surfaced in the note")
    func throwingProbeIsUnknown() async {
        let info = await Storefront.currentStorefront(probe: StorefrontProbe { throw ProbeBoom() })
        #expect(info.status == .unknown)
        #expect(info.countryCode == nil)
        #expect(info.note.contains("probe threw"))
    }
}
