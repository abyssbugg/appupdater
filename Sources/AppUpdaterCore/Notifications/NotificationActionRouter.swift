// NotificationActionRouter.swift — the PURE decision for what a delivered
// notification's response MEANS. No frameworks (Foundation only, no
// UserNotifications): the app target's delegate translates the UN types to
// plain strings and consults this router; the delegate itself carries no
// decisions, so the entire routing layer is unit-proven without ever spinning
// a real UNUserNotificationCenter (constraint honored: no test runner hangs).
// Tier-2 gap "notify-actions" lane · exclusive file of this lane.
//
// # DECIDED POLICY (v1, 2026-10-28)
//
// Inputs: the response's `actionIdentifier` string + the notification
// content's `userInfo`. Outputs (``NotificationActionRouter/Outcome``):
//
// - ``Outcome/openMainWindow`` — either the category's
//   ``NotificationActionIDs/actionOpen`` ("Open AppUpdater") OR Apple's
//   default tap on the notification body (``NotificationActionIDs/
//   defaultActionIdentifier``, byte-verified against
//   `UNNotificationDefaultActionIdentifier` in the tests). Tapping EITHER
//   notification shape (actionable or passive summary) opens the window —
//   the body tap has always meant "show me".
// - ``Outcome/stageInstall(bundleID:appName:)`` — ONLY the category's
//   ``NotificationActionIDs/actionStageInstall``. The bundle ID comes from
//   the payload's ``NotificationActionIDs/keyBundleID`` and MUST be
//   non-empty — a missing or empty one is ``Outcome/ignored`` (staging an
//   unnamed app would be a guess, and the consent boundary is never a
//   guess). The display name comes from ``NotificationActionIDs/keyAppName``
//   and falls back to the bundle ID for malformed payloads where staging
//   still works but naming degraded (documented, tested).
// - ``Outcome/ignored`` — anything else (unknown action identifiers,
//   dismissals, actions from categories this app never registered). The
//   delegate executes nothing for it.
//
// EXECUTION BOUNDARY (restated because it decides this file's shape): the
// router never executes — it only classifies. The caller routes
// `.stageInstall` through AppState.requestInstall (pasteboard + verbatim
// text, nothing runs) and `.openMainWindow` through the app's window-opening
// seam. NOTHING is ever executed or auto-applied by a notification tap
// (LOCKED boundary).

import Foundation

public enum NotificationActionRouter {

    /// What the delegate should do with one delivered notification's
    /// response. `Equatable` per the product spec (+ `Hashable`/`Sendable`
    /// as the core's strict-superset convention, no behavior).
    public enum Outcome: Equatable, Hashable, Sendable {
        /// Bring the main window forward (action button or body tap).
        case openMainWindow
        /// Stage the owner-run CLI command for this app through the
        /// existing consent boundary. Nothing executes — pasteboard only.
        case stageInstall(bundleID: String, appName: String)
        /// Unknown/irrelevant response — execute nothing, silently.
        case ignored
    }

    /// Classifies one notification response, per the doc block. Pure: no
    /// I/O, no state. `userInfo` is the raw UN shape (`[AnyHashable: Any]`)
    /// so the delegate can pass it verbatim; only the documented String
    /// values under the frozen keys are read, and non-String values are
    /// ignored (never cast-guessed).
    public static func route(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> Outcome {
        switch actionIdentifier {
        case NotificationActionIDs.actionOpen,
             NotificationActionIDs.defaultActionIdentifier:
            return .openMainWindow
        case NotificationActionIDs.actionStageInstall:
            guard let bundleID = string(userInfo, NotificationActionIDs.keyBundleID),
                  !bundleID.isEmpty
            else { return .ignored }
            let appName = string(userInfo, NotificationActionIDs.keyAppName) ?? bundleID
            return .stageInstall(bundleID: bundleID, appName: appName)
        default:
            return .ignored
        }
    }

    /// Reads a String value from the raw userInfo — `as? String` only, so a
    /// non-String under a frozen key is treated as absent (honest absence,
    /// never a lossy conversion).
    private static func string(_ userInfo: [AnyHashable: Any], _ key: String) -> String? {
        userInfo[key] as? String
    }
}
