// NotificationNamesTests — pin the FROZEN distributed-event contract: the
// event name bytes (external consumers key on exactly these), the plist-safe
// all-String payload shape, the stable keys, and the HONEST nil mappings
// ("unknown" / "none" — never a fabricated "0", "?" or an empty string).
// Pure tests, no frameworks, no fixtures. Swift Testing (XCTest discovery is
// broken on this toolchain — AGENTS.md gotcha ledger); Foundation imported
// explicitly because Swift Testing does not re-export it.

import Foundation
import Testing
@testable import AppUpdaterCore

@Suite
struct NotificationNamesTests {

    /// The event name is a frozen contract EXTERNAL listeners key on. If
    /// this constant ever changes shape, every downstream script breaks
    /// silently — the string is pinned here byte-for-byte.
    @Test
    func eventNameIsFrozen() {
        #expect(
            NotificationNames.eventName == "io.appupdater.AppUpdater.scheduledFireDidComplete")
    }

    /// Fully-populated payload: stable keys ONLY (no extras), every value
    /// IS a String (plist-safe for the on-machine cross-process round-trip),
    /// and the counts/flags stringify plainly.
    @Test
    func payloadValuesAreAllStringsAcrossStableKeys() {
        let payload = NotificationNames.scheduledFireUserInfo(
            appsChecked: 82, pendingCount: 3, wasCatchUp: true, error: nil)

        let asAny = payload as [String: Any]
        #expect(Set(asAny.keys) == Set([
            "appsChecked", "pendingCount", "wasCatchUp", "error",
        ]))
        for (key, value) in asAny {
            #expect(value is String, "value for key '\(key)' must be String, got \(type(of: value))")
        }
        #expect(payload["appsChecked"] == "82")
        #expect(payload["pendingCount"] == "3")
        #expect(payload["wasCatchUp"] == "true")
        #expect(payload["error"] == "none")
    }

    /// HONEST nil mapping: nothing is invented. `appsChecked == nil` and
    /// `wasCatchUp == nil` read "unknown" (a fake "0" or "?" would
    /// misrepresent a fact the seam genuinely does not know); `error == nil`
    /// reads "none" (no error), never an empty string.
    @Test
    func payloadNilMappingsAreHonest() {
        let payload = NotificationNames.scheduledFireUserInfo(
            appsChecked: nil, pendingCount: 0, wasCatchUp: nil, error: nil)
        #expect(payload["appsChecked"] == "unknown")
        #expect(payload["pendingCount"] == "0")
        #expect(payload["wasCatchUp"] == "unknown")
        #expect(payload["error"] == "none")
    }

    /// Negative/zero-ish facts pass through VERBATIM — no pretty-printing
    /// that could hide a failure ("false" stays "false"; the error text is
    /// carried exactly as produced).
    @Test
    func payloadPassesVerbatimFactsThrough() {
        let payload = NotificationNames.scheduledFireUserInfo(
            appsChecked: 0, pendingCount: 0, wasCatchUp: false,
            error: "schedule.json save failed — boom")
        #expect(payload["appsChecked"] == "0")
        #expect(payload["pendingCount"] == "0")
        #expect(payload["wasCatchUp"] == "false")
        #expect(payload["error"] == "schedule.json save failed — boom")
    }
}
