// VersionOracle tests — Swift Testing ONLY (XCTest discovery is broken on this
// toolchain: Xcode 27 beta / Swift 6.4 — AGENTS.md gotcha ledger). Pure logic,
// zero networking. Foundation needed for URL fields of UpdateInfo in fixtures.

import Testing
import Foundation
@testable import AppUpdaterCore

@Suite struct VersionOracleTests {
    private let oracle = VersionOracle()

    private func v(_ string: String) -> AppVersion { AppVersion(string) }

    private func info(
        _ source: SourceKind,
        _ version: String,
        confidence: UpdateConfidence = .medium,
        detail: String? = nil
    ) -> UpdateInfo {
        UpdateInfo(
            source: source,
            newestShortVersion: version,
            confidence: confidence,
            sourceDetail: detail
        )
    }

    // MARK: - Comparator: numeric semantics

    @Test func numericCompareDIRECTION() {
        // Documented direction: compare(lhs, rhs) is lhs-relative — .greater ⇔ lhs newer.
        #expect(oracle.compare("1.2.10", "1.2.3") == .greater)
        #expect(oracle.compare("1.2.3", "1.2.10") == .less)
    }

    @Test func tenVersusTwo() {
        #expect(oracle.compare("1.10", "1.2") == .greater)
        #expect(oracle.compare("1.2", "1.10") == .less)
        #expect(oracle.compare("1.10", "1.2.3") == .greater) // 10 > 2 before padding matters
        #expect(oracle.compare("0.10", "0.2") == .greater)   // second component too
    }

    @Test func dateStyleVersions() {
        #expect(oracle.compare("2023.12", "2024.1") == .less)
        #expect(oracle.compare("2024.1", "2023.12") == .greater)
        #expect(oracle.compare("2023.12", "2023.9") == .greater)  // numeric, not lexicographic
        #expect(oracle.compare("2024.1.5", "2024.1.5-228") == .less) // build-numbered hyphen tail wins
    }

    @Test func zeroFillEquality() {
        #expect(oracle.compare("2.4.0", "2.4") == .equal)
        #expect(oracle.compare("2.4", "2.4.0.0.0") == .equal)
        #expect(oracle.compare("1", "1.0") == .equal)
        #expect(oracle.compare("1.", "1.0.0") == .equal) // trailing separator → zero component
        #expect(oracle.compare("1..2", "1.0.2") == .equal) // empty middle → zero component
    }

    @Test func zeroFillDoesNotHideRealDifferences() {
        #expect(oracle.compare("2.4.1", "2.4") == .greater)
        #expect(oracle.compare("2.3", "2.4.0") == .less)
    }

    @Test func leadingZerosNormalize() {
        #expect(oracle.compare("007", "7") == .equal)
        #expect(oracle.compare("1.02", "1.2") == .equal)
        #expect(oracle.compare("0", "0.0") == .equal)
    }

    // MARK: - Comparator: qualifier ranks (alpha < beta < rc < release)

    @Test func suffixRankChain() {
        #expect(oracle.compare("1.0beta", "1.0alpha") == .greater)
        #expect(oracle.compare("1.0rc", "1.0beta") == .greater)
        #expect(oracle.compare("1.0", "1.0rc") == .greater)
        // Full documented chain, transitive:
        #expect(oracle.compare("1.0alpha", "1.0") == .less)
    }

    @Test func plainQualifierEqualsRelease() {
        // Unknown words collapse into the release rank (informative, not order-significant).
        #expect(oracle.compare("1.0plain", "1.0") == .equal)
        #expect(oracle.compare("1.0x", "1.0") == .equal)
        #expect(oracle.compare("1.RC", "1.16") == .less) // "RC" is case-insensitive rc BUT numeric 16 > 0 dominates
        #expect(oracle.compare("1.0plain", "1.0RC") == .greater) // rc ranks 3 < release-rank 4
    }

    @Test func numberedQualifiers() {
        #expect(oracle.compare("1.0beta2", "1.0beta1") == .greater)
        #expect(oracle.compare("1.0beta1", "1.0beta2") == .less)
        #expect(oracle.compare("1.0beta10", "1.0beta9") == .greater) // digit-string compare, no overflow
        #expect(oracle.compare("1.0rc3", "1.0rc") == .greater)       // numbered beats unnumbered
        #expect(oracle.compare("1.0b7", "1.0beta7") == .equal)       // "b" alias of beta
        #expect(oracle.compare("1.0b7", "1.0") == .less)             // Xcode-style prerelease < release
    }

    @Test func hyphenComponentSplitting() {
        #expect(oracle.compare("1.0-2", "1.0.2") == .equal)
        #expect(oracle.compare("1-0", "1.0") == .equal)
        #expect(oracle.compare("1.2.3-beta1", "1.2.3") == .less) // qualifier tail component < release
        #expect(oracle.compare("1.0-beta1", "1.0-alpha9") == .greater)
    }

    @Test func whitespaceTrimAndVPrefix() {
        #expect(oracle.compare("  1.5  ", "1.5") == .equal)
        #expect(oracle.compare("v1.2", "1.2") == .equal)   // single leading v/V is decoration
        #expect(oracle.compare("V2.0", "2.0") == .equal)
        #expect(oracle.compare("vault", "vault") == .equal) // 'v' NOT followed by digit untouched
    }

    // MARK: - Comparator: garbage never crashes, fallback is documented lex

    @Test func garbageFallbackIsDeterministicLex() {
        // "garbage" has no digits → lexicographic fallback: 'g' > '1' byte-wise.
        #expect(oracle.compare("garbage", "1.0") == .greater)
        #expect(oracle.compare("1.0", "garbage") == .less)
        // Empty is garbage too — it does NOT parse to zero (honesty pin):
        #expect(oracle.compare("", "0") == .less)
        #expect(oracle.compare("", "") == .equal)
        #expect(oracle.compare("   ", " ") == .equal)
        #expect(oracle.compare("!!!", "!!!") == .equal)
        #expect(oracle.compare("???", "abc") == .less) // '?' < 'a'
        // Unknown word WITH digits mid-version ("v2") → whole string falls back:
        #expect(oracle.compare("1.0v2", "1.9") == .less) // lex: '0' < '9' at position 1
        #expect(oracle.compare("1x5", "1x5") == .equal)
    }

    @Test func garbageSweepDoesNotCrash() {
        let weird = ["", "   ", "v", "V", "-", ".", "1x5", "v1.2", "1.0v2", "…gar…", "-1",
                     "beta", "0beta2", "b1a", "228x5", "1.0plain", "***", "版本"]
        let anchors = ["0", "9.9.9", "garbage", "1RC", ""]
        for left in weird {
            for right in anchors {
                _ = oracle.compare(left, right) // must return deterministically, no crash
            }
        }
        #expect(oracle.compare("1x5", "1x5") == .equal) // deterministic on repeat
    }

    @Test func hugeDigitRunsDoNotOverflow() {
        let big = String(repeating: "9", count: 56)
        let slightlyLess = String(repeating: "9", count: 55) + "8"
        #expect(oracle.compare(big, slightlyLess) == .greater)
        #expect(oracle.compare("9223372036854775807", "9223372036854775808") == .less) // Int64 max vs +1
    }

    // MARK: - AppVersion descriptive parse

    @Test func descriptiveParse() throws {
        let version = v("1.0beta7")
        #expect(version.isParseable)
        let components = try #require(version.components)
        #expect(components.count == 2)
        #expect(components[0].number == "1")
        #expect(components[0].qualifier == .plain)
        #expect(components[1].number == "0")
        #expect(components[1].qualifier == .beta)
        #expect(components[1].sequence == "7")
    }

    @Test func descriptiveParseEdgeChunks() throws {
        let buildNumbered = v("2024.1.5-228")
        let components = try #require(buildNumbered.components)
        #expect(components.count == 4)
        #expect(components[3].number == "228")
        #expect(components[3].qualifier == .plain)
    }

    @Test func unparseableIsFlagged() {
        #expect(!v("garbage").isParseable)
        #expect(!v("").isParseable)
        #expect(!v("1x5").isParseable) // unknown word WITH digits → whole-string fallback
        #expect(!v("2.3b1a").isParseable) // compound qualifier tail → invalid
    }

    @Test func structuralEqualityIsParseAdjacent() {
        #expect(v("007") == v("7"))          // normalized digits
        #expect(v(" 1.2 ") == v("1.2"))      // trimmed
        #expect(v("1.2") != v("1.2.0"))      // structural ≠ semantic; use compare() for semantics
        #expect(oracle.compare("1.2", "1.2.0") == .equal)
    }

    // MARK: - isUpdateAvailable

    @Test func updateAvailableBasics() {
        #expect(oracle.isUpdateAvailable(installed: "1.2", available: "1.10"))
        #expect(!oracle.isUpdateAvailable(installed: "1.10", available: "1.2"))
        #expect(!oracle.isUpdateAvailable(installed: "2.0", available: "2.0"))     // equal → no
        #expect(!oracle.isUpdateAvailable(installed: "2.0", available: "1.9.1"))
        #expect(oracle.isUpdateAvailable(installed: "1.2", available: "1.2.1"))
    }

    @Test func updateAvailableNilHandling() {
        #expect(oracle.isUpdateAvailable(installed: nil, available: "1.0"))
        #expect(oracle.isUpdateAvailable(installed: nil, available: "2024.1"))
        #expect(!oracle.isUpdateAvailable(installed: nil, available: nil))
        #expect(!oracle.isUpdateAvailable(installed: "1.0", available: nil))
        // Unparseable installed ≈ no installed version (documented estimate of "can't disprove"):
        #expect(oracle.isUpdateAvailable(installed: "garbage", available: "2.0"))
    }

    @Test func updateAvailableRefusesUnrankableClaims() {
        // Available MUST parse to be claimed honestly — even with no installed version:
        #expect(!oracle.isUpdateAvailable(installed: nil, available: "garbage"))
        #expect(!oracle.isUpdateAvailable(installed: nil, available: ""))
        // Equal-by-qualifier-collapse claims nothing new:
        #expect(!oracle.isUpdateAvailable(installed: "1.2", available: "1.2plain"))
        // Leading-v decoration parses:
        #expect(oracle.isUpdateAvailable(installed: "1.2", available: "v1.3"))
        #expect(!oracle.isUpdateAvailable(installed: "v1.5", available: "1.3"))
    }

    // MARK: - Resolver: locked precedence

    @Test func sourcePrecedenceConstant() {
        #expect(VersionOracle.sourcePrecedence == [.cask, .sparkle, .mas, .github])
    }

    @Test func caskBeatsFresherSparkle() {
        // LOCKED-policy pin: cask-1.2 ALWAYS beats sparkle-1.9 — even with lower
        // confidence and even when installed would allow both.
        let candidates = [
            info(.cask, "1.2", confidence: .low, detail: "cask"),
            info(.sparkle, "1.9", confidence: .high, detail: "sparkle"),
        ]
        let resolved = oracle.resolve(candidates: candidates, installedShortVersion: "1.0")
        #expect(resolved?.sourceDetail == "cask")
        #expect(resolved?.source == .cask)
    }

    @Test func caskClaimingNothingSuppressesWeakerSources() {
        // No fall-through: cask says 1.2 < installed 1.3 → nil, NOT sparkle 1.9.
        let candidates = [
            info(.cask, "1.2", detail: "cask"),
            info(.sparkle, "1.9", confidence: .high, detail: "sparkle"),
        ]
        #expect(oracle.resolve(candidates: candidates, installedShortVersion: "1.3") == nil)
    }

    @Test func nilInstalledReturnsGreatestOfTopGroup() {
        let candidates = [
            info(.sparkle, "1.9", detail: "sparkle"),
            info(.cask, "1.2", detail: "cask"),
        ]
        let resolved = oracle.resolve(candidates: candidates, installedShortVersion: nil)
        #expect(resolved?.sourceDetail == "cask") // strongest GROUP decides, not the largest number
    }

    @Test func greatestWithinSameKind() {
        let candidates = [
            info(.cask, "1.9", detail: "a"),
            info(.cask, "1.10", detail: "b"), // numeric: 1.10 > 1.9
            info(.cask, "2.0", detail: "c"),
        ]
        #expect(oracle.resolve(candidates: candidates, installedShortVersion: "1.2")?.sourceDetail == "c")
    }

    @Test func confidenceIsOnlyAWithinKindTieBreak() {
        let lowFirst = [
            info(.cask, "2.0", confidence: .low, detail: "cask-low"),
            info(.cask, "2.0", confidence: .high, detail: "cask-high"),
        ]
        #expect(oracle.resolve(candidates: lowFirst, installedShortVersion: "1.0")?.sourceDetail == "cask-high")
        let highFirst = [
            info(.cask, "2.0", confidence: .high, detail: "cask-high"),
            info(.cask, "2.0", confidence: .low, detail: "cask-low"),
        ]
        #expect(oracle.resolve(candidates: highFirst, installedShortVersion: "1.0")?.sourceDetail == "cask-high")
    }

    @Test func duplicateVersionsFirstWinsStable() {
        let candidates = [
            info(.cask, "2.0", detail: "first"),
            info(.cask, "2.0", detail: "second"),
            info(.cask, "2.0", detail: "third"),
        ]
        #expect(oracle.resolve(candidates: candidates, installedShortVersion: "1.0")?.sourceDetail == "first")
    }

    @Test func masBeatsGithub() {
        let candidates = [
            info(.github, "9.0", detail: "gh"),
            info(.mas, "2.0", detail: "mas"),
        ]
        #expect(oracle.resolve(candidates: candidates, installedShortVersion: "1.0")?.sourceDetail == "mas")
    }

    @Test func fullPrecedenceOrderFourKinds() {
        let candidates = [
            info(.github, "9.0", detail: "gh"),
            info(.mas, "8.0", detail: "mas"),
            info(.sparkle, "7.0", detail: "sparkle"),
            info(.cask, "1.0", detail: "cask"),
        ]
        #expect(oracle.resolve(candidates: candidates, installedShortVersion: "0.5")?.sourceDetail == "cask")
    }

    @Test func mixedKindEndToEnd() {
        let candidates = [
            info(.unknown, "9.9", confidence: .high, detail: "unknown-noise"),
            info(.github, "3.0", confidence: .low, detail: "gh"),
            info(.mas, "2.2", confidence: .low, detail: "mas"),
            info(.sparkle, "2.1", confidence: .low, detail: "sparkle"),
            info(.cask, "2.2", confidence: .low, detail: "cask-2.2-low"),
            info(.cask, "2.2", confidence: .medium, detail: "cask-2.2-medium"),
            info(.cask, "1.4", confidence: .high, detail: "cask-1.4-high"),
        ]
        let resolved = oracle.resolve(candidates: candidates, installedShortVersion: "1.4")
        // cask group → greatest eligible 2.2 → confidence medium beats low → "cask-2.2-medium".
        #expect(resolved?.sourceDetail == "cask-2.2-medium")
        #expect(resolved?.source == .cask)
        #expect(resolved?.confidence == .medium)
    }

    @Test func unknownOnlyListReturnsItForCaller() {
        let candidates = [info(.unknown, "9.9", detail: "unknown-only")]
        #expect(oracle.resolve(candidates: candidates, installedShortVersion: "1.0")?.sourceDetail == "unknown-only")
    }

    @Test func unknownOnlyMultipleStableFirst() {
        let candidates = [
            info(.unknown, "9.9", detail: "u-first"),
            info(.unknown, "10.0", detail: "u-second"),
        ]
        #expect(oracle.resolve(candidates: candidates, installedShortVersion: nil)?.sourceDetail == "u-first")
    }

    @Test func unknownNeverAutoSelectedOverKnown() {
        // Known group exists but claims nothing greater → nil (unknown NOT surfaced):
        let blocked = [info(.cask, "1.0", detail: "cask"), info(.unknown, "9.9", detail: "u")]
        #expect(oracle.resolve(candidates: blocked, installedShortVersion: "5.0") == nil)
        // Known group eligible wins even when unknown compares greater:
        let competing = [info(.mas, "2.0", detail: "mas"), info(.unknown, "9.9", detail: "u")]
        #expect(oracle.resolve(candidates: competing, installedShortVersion: "1.0")?.sourceDetail == "mas")
    }

    @Test func emptyAndDegenerateResolverCases() {
        #expect(oracle.resolve(candidates: [], installedShortVersion: "1.0") == nil)
        // Installed unparseable ≈ none: greatest of strongest group still returned:
        let candidates = [info(.cask, "2.0", detail: "c2")]
        #expect(oracle.resolve(candidates: candidates, installedShortVersion: "garbage")?.sourceDetail == "c2")
        // Installed greater than everything → nil:
        let stale = [info(.cask, "1.0", detail: "cank"), info(.github, "0.9", detail: "g")]
        #expect(oracle.resolve(candidates: stale, installedShortVersion: "2.0") == nil)
    }

    @Test func vPrefixFixMislead() {
        // "v1.2" is valid decoration (single leading v before digit), it IS parseable.
        #expect(v("v1.2").isParseable)
        #expect(v("v1.2").raw == "v1.2") // raw echoes input; body stripped internally
        #expect(oracle.compare("v1.2", "1.2") == .equal)
    }
}
