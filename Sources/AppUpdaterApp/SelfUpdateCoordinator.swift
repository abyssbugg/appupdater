import Foundation
import Sparkle

/// Self-update surface (Phase 5, LOCKED decision 2 + 8): the app updates ITSELF
/// through Sparkle 2 and nothing else. Coordinator-owned wiring notes:
/// - Automatic checks are OFF by Info.plist (`SUEnableAutomaticChecks` false):
///   no hidden network until the owner configures a real feed. Checks happen
///   only through the explicit menu action.
/// - Without `SUPublicEDKey` in the bundle Sparkle refuses to install any
///   update — that refusal is the honest security floor, not a bug.
/// - The standard user driver surfaces its own progress/result dialogs; with a
///   placeholder feed the check fails with an unreachable-host error — honest,
///   never a fake "up to date".
@MainActor
final class SelfUpdateCoordinator {
    /// Strong, long-lived holder: the controller starts the updater engine at
    /// init (`startingUpdater: true`) and must outlive every menu invocation.
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil)

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }
}
