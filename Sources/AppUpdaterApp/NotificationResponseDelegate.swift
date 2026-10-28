// NotificationResponseDelegate.swift — the UNUserNotificationCenterDelegate
// for the app's local notifications. MOVED VERBATIM from the bottom of
// AppState.swift (GAP #26 polish lane): the file_length gate (error at 1000
// lines) required extracting the two self-contained types from the
// coordinator. Behavior and docs unchanged; the class stays a decision-free
// translator + dispatcher exactly as documented below.

import Foundation
import UserNotifications
import AppUpdaterCore

/// UNUserNotificationCenterDelegate for the app's local notifications.
/// Deliberately decision-free: it translates UN types to plain strings,
/// consults the pure core router (`NotificationActionRouter` — unit-proven
/// without ever spinning a real center), and executes the outcome on the
/// MainActor through AppState's handler. (Originally lived in AppState.swift
/// beside its wiring; moved to its own file for the file_length gate — the
/// wiring `installNotificationActionSupport` remains in AppState.swift, so
/// the delegate and its single consumer are siblings in the same target.)
final class NotificationResponseDelegate:
    NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {

    private let handler: @MainActor (NotificationActionRouter.Outcome) -> Void

    init(handler: @escaping @MainActor (NotificationActionRouter.Outcome) -> Void) {
        self.handler = handler
    }

    /// Action button presses AND body taps (the default action). The routing
    /// DECISION is the pure router's (synchronous, no shared state); only
    /// the EXECUTION hops to the MainActor. The completion handler is called
    /// synchronously on the delegate callback thread — it is a non-Sendable
    /// function value this SDK refuses to send across isolation, and the
    /// response IS handled at that point (classified + dispatched; the
    /// handler itself is fast, non-blocking work on the main queue).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let outcome = NotificationActionRouter.route(
            actionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo)
        Task { @MainActor in
            self.handler(outcome)
        }
        completionHandler()
    }

    /// Banner presentation even while the app is frontmost — this PRESERVES
    /// the pre-delegate behavior (no delegate meant the system default
    /// presentation); returning an empty set here would have narrowed it,
    /// so it doesn't.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}
