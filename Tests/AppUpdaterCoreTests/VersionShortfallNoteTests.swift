import Foundation
import Testing
@testable import AppUpdaterCore

/// Post-scan honesty: a verified swap whose bundle still declares a version
/// below the claim (cmux 0.65.2 vs claimed 0.65.2.2, live 2026-10-30) says so.
@Suite("Version shortfall note")
struct VersionShortfallNoteTests {
    @Test func emptyWhenClaimReachedOrUnknown() {
        #expect(InstallCoordinator.versionShortfallNote(installed: "2.0", claimed: "2.0").isEmpty)
        #expect(InstallCoordinator.versionShortfallNote(installed: "2.1", claimed: "2.0").isEmpty)
        #expect(InstallCoordinator.versionShortfallNote(installed: nil, claimed: "2.0").isEmpty)
    }

    @Test func presentWhenInstalledFallsShort() {
        let note = InstallCoordinator.versionShortfallNote(installed: "0.65.2", claimed: "0.65.2.2")
        #expect(note.contains("still reports 0.65.2, below the claimed 0.65.2.2"))
    }
}
