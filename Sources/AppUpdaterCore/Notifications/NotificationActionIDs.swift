// NotificationActionIDs.swift — the FROZEN identifier surface for actionable
// notifications + the plist-safe payload builder. Framework-pure: Foundation
// ONLY (compiles into every target that links AppUpdaterCore — app, CLI,
// tests — with no AppKit/UserNotifications dependency), exactly like the
// sibling `NotificationNames` contract.
// Tier-2 gap "notify-actions" lane · exclusive file of this lane.
//
// # CATEGORY / ACTION DESIGN (v1, decided 2026-10-28)
//
// ONE category is registered by the app target at launch:
//
//   identifier:      ``categoryPendingUpdate``
//   action 1:        ``actionOpen``   → "Open AppUpdater"   (.foreground)
//   action 2:        ``actionStageInstall`` → "Stage Install Command"
//
// The category is attached ONLY to a notification the pure
// ``NotificationActionPlanner`` judged actionable: a scheduled fire whose
// fire-to-fire diff (NotificationDecider) surfaced EXACTLY ONE newly pending
// app AND that app resolves to exactly one bundle ID and is stageable by the
// existing consent boundary (MAS apps never stage — planner input `stageable:
// false` keeps them on the passive summary). Multi-app fires and any
// ambiguous shape keep the EXISTING passive summary, byte-for-byte — the
// actionable shape extends, never replaces.
//
// NOTHING on this category executes anything. Both actions route through the
// existing consent boundary (AppState): "Open AppUpdater" brings the main
// window forward; "Stage Install Command" copies the owner-run CLI command to
// the pasteboard exactly like the window's Stage button. The boundary is the
// product.
//
// STABILITY: these strings are FROZEN. macOS caches notification categories
// per bundle ID, and any external tooling keying on identifiers would break
// silently on a change. Renaming requires a coordinator decision + a
// migration note in the docs, the same bar as `NotificationNames.eventName`.

import Foundation

public enum NotificationActionIDs {

    /// The actionable notification category: a single named pending update.
    public static let categoryPendingUpdate =
        "io.appupdater.AppUpdater.category.pendingUpdate"

    /// "Open AppUpdater" — open the main window (posted with
    /// `.foreground` so the system brings the app forward first).
    public static let actionOpen = "io.appupdater.AppUpdater.action.open"

    /// "Stage Install Command" — copy the owner-run CLI command for the
    /// NAMED app to the pasteboard. Never executes anything.
    public static let actionStageInstall =
        "io.appupdater.AppUpdater.action.stageInstall"

    /// Apple's constant for tapping the notification BODY itself (as opposed
    /// to one of the category's actions), mirrored as a literal so this file
    /// stays framework-free. BYTE-VERIFIED against
    /// `UNNotificationDefaultActionIdentifier` in the test suite
    /// (NotificationActionTests imports UserNotifications and asserts the
    /// equality — if Apple ever changed the constant, that test fails first).
    public static let defaultActionIdentifier =
        "com.apple.UNNotificationDefaultActionIdentifier"

    /// Payload key: the pending app's display name (verbatim from the scan).
    public static let keyAppName = "appName"

    /// Payload key: the pending app's bundle identifier — the value the
    /// delegate stages through the existing consent boundary.
    public static let keyBundleID = "bundleID"

    /// Builds the cross-surface payload for a ``categoryPendingUpdate``
    /// notification. Every value IS a String and plist-safe by construction
    /// (same contract as `NotificationNames.scheduledFireUserInfo`) — the
    /// delegate reads both keys back as `[String: String]`.
    public static func pendingUpdateUserInfo(
        appName: String, bundleID: String
    ) -> [String: String] {
        [keyAppName: appName, keyBundleID: bundleID]
    }
}
