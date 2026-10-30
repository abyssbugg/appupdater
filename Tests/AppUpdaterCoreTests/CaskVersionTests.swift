import Foundation
import Testing
@testable import AppUpdaterCore

/// Live 2026-10-30: Devin installed 3.11.234 was reported as an update to
/// "3.11.234,92c8…" (raw cask string compared). Marketing part only.
@Suite struct CaskVersionTests {
    @Test func splitsBuildSuffix() {
        let parts = CaskVersion.split("3.11.234,92c83011d1139eee53ac0629125938d536d4cd9c")
        #expect(parts.marketing == "3.11.234")
        #expect(parts.build == "92c83011d1139eee53ac0629125938d536d4cd9c")
    }

    @Test func plainVersionUnchanged() {
        let parts = CaskVersion.split("1.4.0")
        #expect(parts.marketing == "1.4.0")
        #expect(parts.build == nil)
    }

    @Test func onlyFirstCommaSplits() {
        let parts = CaskVersion.split("2.1,b10,extra")
        #expect(parts.marketing == "2.1")
        #expect(parts.build == "b10,extra")
    }

    @Test func emptyBuildIsNil() {
        #expect(CaskVersion.split("5.0,").build == nil)
    }

    @Test func equalMarketingIsNotAnUpdate() {
        let claim = UpdateInfo(source: .cask, newestShortVersion: CaskVersion.split("3.11.234,92c8").marketing)
        #expect(VersionOracle().resolve(candidates: [claim], installedShortVersion: "3.11.234") == nil)
    }

    @Test func newerMarketingIsAnUpdate() {
        let claim = UpdateInfo(source: .cask, newestShortVersion: CaskVersion.split("0.21.2,088d292d364f").marketing)
        #expect(VersionOracle().resolve(candidates: [claim], installedShortVersion: "0.0.0")?.newestShortVersion == "0.21.2")
    }

    /// Live 2026-10-30: installed Warp 0.2026.10.21.08.25.02 was reported as an
    /// update to the cask's 0.2026.10.21.08.25.stable_02 — the same release.
    @Test func stableChannelLabelIsTheSameRelease() {
        let marketing = CaskVersion.split("0.2026.10.21.08.25.stable_02").marketing
        #expect(marketing == "0.2026.10.21.08.25.02")
        #expect(!VersionOracle().isUpdateAvailable(installed: "0.2026.10.21.08.25.02", available: marketing))
        let newer = CaskVersion.split("0.2026.10.28.08.25.stable_01").marketing
        #expect(VersionOracle().isUpdateAvailable(installed: "0.2026.10.21.08.25.02", available: newer))
    }

    @Test func stableSpellingsNormalizeAndOthersAreUntouched() {
        #expect(CaskVersion.split("1.2.stable-03").marketing == "1.2.03")
        #expect(CaskVersion.split("1.2.Stable7").marketing == "1.2.7")
        #expect(CaskVersion.split("1.2.stable").marketing == "1.2.stable")
        #expect(CaskVersion.split("1.2.stable_x1").marketing == "1.2.stable_x1")
        #expect(CaskVersion.split("1.2.beta_03").marketing == "1.2.beta_03")
        #expect(CaskVersion.split("2.0.0-rc1").marketing == "2.0.0-rc1")
    }
}
