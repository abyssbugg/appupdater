// NotificationNames.swift — documented distributed-event contract + the
// plist-safe payload builder. Framework-pure: Foundation ONLY (compiles into
// every target that links AppUpdaterCore — app, CLI, future importer — with
// no AppKit/UserNotifications dependency).
// Phase-4-lane notifications · exclusive file of this lane.
//
// # SCRIPTABILITY CONTRACT (v1, decided by coordinator 2026-10-26)
//
// After EVERY scheduled fire completes — BOTH the scan-only branch (no apps
// opted into autoCheck) and the targeted branch (with opt-ins), regardless of
// whether any local notification was posted — the app posts ONE distributed
// notification:
//
// - `name`        ＝ ``eventName`` (frozen constant below)
// - `object`      ＝ nil (the event is the fire, not any specific app)
// - `userInfo`    ＝ ``scheduledFireUserInfo(appsChecked:pendingCount:wasCatchUp:error:)``
// - `deliverImmediately` ＝ false (delivered when the system deems the
//   posting process idle; standard queued-distribution behavior)
//
// WHO LISTENS: external consumers — the owner's scripts, other apps, any
// tooling that wants to react to "a scheduled check just finished and here is
// how it went". The app itself is only the POSTER; nothing in-app consumes
// this event. Manual Check Now never posts it (scheduled fires only — same
// boundary as ScheduleState, see AppState docs).
//
// HOW A CONSUMER REGISTERS (one-line Swift snippet, text form):
//
//     DistributedNotificationCenter.default().addObserver(
//         observer, selector: #selector(handleScheduledFire(_:)),
//         name: Notification.Name(AppUpdaterCore.NotificationNames.eventName),
//         object: nil)
//
// In the handler read `note.userInfo.flatMap { $0 as? [String: String] }`.
// Every value IS a String (key-by-key contract below) — plist-safe by design.
//
// macOS DELIVERY FACT (documented divergence from cross-machine hopes):
// macOS delivers the userInfo payload ONLY to ON-MACHINE observers.
// Cross-machine distributed-notification observers see the event name but
// NOT the payload. On-machine payloads round-trip through property lists —
// which is exactly why every value here is a plist-safe String, never a
// Number, Bool, or nil (an absent-but-honest fact is spelled out as a
// string, see the mapping table on ``scheduledFireUserInfo``).
//
// The failure honesty note: posting happens on the SUCCESS path only (a fire
// that throws records its error into ScheduleState instead — no fake
// "completed" event is posted). The payload keeps the `error` key so the
// contract stays shape-stable if event posting is ever extended to failure
// paths; today it is always `none` at the posting site.

import Foundation

public enum NotificationNames {

    /// The distributed event posted after every scheduled fire completes.
    /// FROZEN string: external listeners key on the exact bytes. Changing it
    /// is a one-way contract break and requires the coordinator + a migration
    /// note in the docs.
    public static let eventName = "io.appupdater.AppUpdater.scheduledFireDidComplete"

    /// Builds the cross-process payload for ``eventName`` on this SDK's
    /// actual posting (see the module doc block for the who/when).
    ///
    /// STABLE KEYS (frozen, never reordered in meaning):
    /// - `"appsChecked"`  — how many apps the fire inventoried/checked per the
    ///   ScheduleState honesty rules. `nil` (never ran / not knowable) maps
    ///   to the string `"unknown"` — a fake `"0"` or `"?"` would be a
    ///   fabricated number or an obscure glyph; "unknown" states the fact.
    /// - `"pendingCount"` — how many apps are pending updates after the
    ///   rules pass. Never nil (the count is always known at the posting
    ///   site); stringified with plain `String(Int)`.
    /// - `"wasCatchUp"`   — `true`/`false` when the fire's catch-up identity
    ///   is known; `nil` maps to `"unknown"`. The fire seam genuinely does
    ///   not know its own catch-up identity at posting time (the engine
    ///   records it into ScheduleState AFTER the fire returns), so the app
    ///   passes nil, not a stale or guessed flag.
    /// - `"error"`        — the verbatim failure text, or `nil` on success;
    ///   `nil` maps to `"none"` (honest "no error", not an empty string that
    ///   would look like a swallowed fact).
    ///
    /// Every value is a String — the guarantee the plist round-trip and the
    /// consumer side (`as? [String: String]`) rest on. Typed as
    /// `[String: String]` (the shape the consumer casts to); the poster
    /// passes it into userInfo untouched.
    public static func scheduledFireUserInfo(
        appsChecked: Int?,
        pendingCount: Int,
        wasCatchUp: Bool?,
        error: String?
    ) -> [String: String] {
        [
            "appsChecked": appsChecked.map(String.init) ?? "unknown",
            "pendingCount": String(pendingCount),
            "wasCatchUp": wasCatchUp.map(String.init) ?? "unknown",
            "error": error ?? "none",
        ]
    }
}
