// ScheduleEngine.swift — framework-pure scheduler loop (no AppKit, no persistence).
// Phase 4 · lane scheduler · exclusive file of this lane.
//
// The engine consumes the FROZEN interchange types from Model/ScheduleStore.swift
// (SchedulePolicy / ScheduleState / ScheduleSnapshot — coordinator-owned; if that
// file ever changes: STOP and report, coordinator owns it).
//
// OWNERSHIP BOUNDARY: the engine is a trigger, not a filter and not a store.
// - It does NOT persist (Lane 2 owns schedule.json): whoever consumes the stream
//   persists `ScheduleSnapshot` values.
// - It does NOT filter apps (rules are Lane 2's): it forwards whatever
//   `autoCheckBundleIDs` produces, verbatim, to the `fire` seam.
// - Policy changes do NOT re-load mid-stream: `start` captures one policy for the
//   stream's lifetime. Apply a policy change by starting a new stream (the UI
//   lane owns that restart decision).

import Foundation
import IOKit.ps
import SystemConfiguration

/// MacUpdater-style scheduling engine: a self-contained asynchronous loop that
/// fires the auto-check trigger according to the user's `SchedulePolicy` and
/// reports every observable change as a `ScheduleSnapshot` on an
/// `AsyncStream<ScheduleSnapshot>`.
///
/// # POLICY SEMANTICS (exact, encoded + tested)
/// - ``SchedulePolicy.intervalMinutes`` `<= 0` — scheduling OFF. `nextFire` returns
///   nil and `start` yields exactly one snapshot (the policy-load snapshot) and
///   finishes the stream: nothing to schedule for this stream's lifetime.
/// - Effective interval = `max(15, intervalMinutes)` minutes — the 15-minute floor
///   is enforced here regardless of what arrives in the policy (the loader on
///   Lane 2 clamps too; double protection so a hand-edited schedule.json can never
///   hot-loop the engine). ``nextFire`` encodes the clamp.
/// - **Catch-up fires exactly once per missed slot:** an immediate fire happens at
///   loop start when the persisted ``ScheduleState/lastFireAt`` is already overdue
///   and ``SchedulePolicy/onWakeCatchUp`` is true — marked
///   ``ScheduleState/lastFireWasCatchUp`` `= true`. After it, the cadence anchor is
///   the fire time, so the same slot can never fire again (double-fire never).
///   A missed slot is catch-up-fired at most once; slots missed in a long sleep
///   are covered by that one wake fire, never replayed slot-by-slot.
///   A FIRST-EVER start (persisted `lastFireAt == nil`) is NOT catch-up: its
///   single derived slot is due by construction (`nextFire(nil) == now`) and
///   fires immediately as a NORMAL fire regardless of `onWakeCatchUp`
///   (coordinator fix, Phase 4 — live evidence: a fresh launch recorded a
///   phantom "wake catch-up" for a slot that was never missed).
/// - **Battery skip reschedules at the same interval:** a due fire while
///   `skipOnBattery && isOnBattery()` is DEFERRED — no fire, no state record (state
///   describes fires, not skips — nothing is recorded, honestly), and the loop
///   re-arms at the first strictly-future grid point: an interval after the
///   skipped slot (or further, after a long oversleep). Battery policy also
///   suppresses catch-up: a missed slot will not catch-up-fire while on battery.
/// - **Offline skip (same template as battery):** a due fire while
///   `deferWhenOffline && !isOnline()` is DEFERRED the same way — no fire, no
///   state record, re-arm at the first strictly-future grid point. The probe is
///   evaluated at the decision moment (loop-top `now` / post-sleep wake), so a
///   missed slot will not catch-up-fire while offline either. Default policy
///   `deferWhenOffline == false` never calls the probe.
/// - **Active-window quiet hours (same template as battery):** with a valid
///   window configured (`activeWindowStartMinute`/`activeWindowEndMinute`), a due
///   fire whose DECISION MOMENT's local minute-of-day lies OUTSIDE the window is
///   DEFERRED — no fire, no state record, re-arm at the first strictly-future
///   grid point; catch-up is suppressed outside the window too. The window
///   polices when a fire may HAPPEN, so it is evaluated on the decision moment
///   (like the battery and offline probes), not on the committed slot — an
///   overdue slot whose fire would land outside the window waits. Window edge
///   semantics (decided + documented here, tested): LOCAL minutes-of-day via
///   `Calendar.current`, half-open `[start, end)` — a moment exactly at `start`
///   is INSIDE (fires), exactly at `end` is OUTSIDE (skips). The grid itself
///   never shifts: a skipped slot's successor stays at the next grid point, so
///   the fire pattern tracks the window day by day. Validity: BOTH endpoints
///   set, each in `0...1439`, `start < end` — anything else (one endpoint nil,
///   `start >= end`, out of range) is an invalid window treated as NO
///   restriction; the loader (`RuleStore.clamped`) normalizes invalid windows to
///   nil/nil so the settings pane shows what is enforced, and the engine
///   re-validates independently (same double protection as the interval floor).
///   No overnight wrap: a window crossing midnight is not representable.
/// - **Double-fire never:** after every fire (success or failure) the anchor is
///   the fire time and the next slot is re-derived from it, strictly future;
///   battery, offline, window and missed-slot skips jump to the first
///   strictly-future grid point. Clamp semantics above keep the step ≥ 15 minutes.
///
/// # SEAMS (injected, all `Sendable`)
/// - `clock` — "now" for every decision (default: `Date()`).
/// - `sleep` — the quiescence primitive (default: `Task.sleep`); the loop sleeps
///   the exact delta to the next slot, so a test-injected fake clock + fake sleep
///   make the entire loop deterministic with zero real time.
/// - `isOnBattery` — power-source probe (default: IOKit IOPS below; no AppKit).
/// - `isOnline` — network-path probe (default: SCNetworkReachability to a public
///   IP literal below; no sockets opened, no packets sent — the flags call asks
///   the system whether a path exists). Consulted only when the policy enables
///   `deferWhenOffline`.
/// - `fire` — the scan trigger. Receives the autoCheck bundle-id list and returns
///   the count of apps checked, which the engine records into
///   ``ScheduleState/lastFireAppsChecked``. On throw, the engine records
///   ``ScheduleState/lastFireError`` (verbatim description; see the honesty table
///   in ``attemptFire``) and CADENCE CONTINUES (a failed fire must not turn into
///   an infinite error loop or a stalled engine).
///
/// # FAILURE + CANCELLATION HONESTY
/// - Fire failure: recorded (see above), loop continues at normal cadence.
/// - `sleep` failure (always `CancellationError` for the default seam): the loop
///   finishes the stream — no error swallowed, no zombie loop.
/// - Stream termination (consumer cancels the iteration) cancels the detached
///   runner via the stream's `onTermination`; the loop exits at its next
///   suspension, without an extra fire.
public struct ScheduleEngine: Sendable {

    /// Wall-clock source: the moment "now" for every loop decision.
    public let clock: @Sendable () -> Date

    /// Quiescence primitive: waits one slot delta. The loop treats this seam as
    /// the one suspension point that honors cancellation.
    public let sleep: @Sendable (Duration) async throws -> Void

    /// Power-source probe: `true` ⇔ on battery (per the skipOnBattery policy).
    public let isOnBattery: @Sendable () -> Bool

    /// Network-path probe: `true` ⇔ a network path is currently reachable (per
    /// the deferWhenOffline policy). Never consulted when the policy flag is
    /// false.
    public let isOnline: @Sendable () -> Bool

    /// The scan trigger. Receives the autoCheck bundle-id list and returns the
    /// number of apps checked. Throwing is how the seam reports a failed check
    /// run; the engine records it (honesty table in ``attemptFire``).
    public let fire: @Sendable ([String]?) async throws -> Int

    /// Full-injection init (tests / hermetic environments). Every seam explicit —
    /// no defaults reference internal members (Swift 6.4 public-init gotcha).
    public init(
        clock: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        isOnBattery: @escaping @Sendable () -> Bool,
        isOnline: @escaping @Sendable () -> Bool,
        fire: @escaping @Sendable ([String]?) async throws -> Int
    ) {
        self.clock = clock
        self.sleep = sleep
        self.isOnBattery = isOnBattery
        self.isOnline = isOnline
        self.fire = fire
    }

    /// Production wiring: real clock + `Task.sleep` + the IOPS battery probe +
    /// the SystemConfiguration online probe, with the caller-provided `fire`
    /// trigger (the only seam with no sensible default — the scan launcher is
    /// another engine's job). Closures are assigned by explicit branches so each
    /// literal gets the declared `@Sendable` type (ternary loses contextual
    /// @Sendable on this toolchain — gotcha ledger).
    public init(fire: @escaping @Sendable ([String]?) async throws -> Int) {
        let clockSeam: @Sendable () -> Date = { Date() }
        let sleepSeam: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        let batterySeam: @Sendable () -> Bool = { Self.isOnBatteryDefaultProbe() }
        let onlineSeam: @Sendable () -> Bool = { Self.isOnlineDefaultProbe() }
        self.init(
            clock: clockSeam, sleep: sleepSeam, isOnBattery: batterySeam,
            isOnline: onlineSeam, fire: fire)
    }

    // MARK: - Pure math

    /// Pure next-slot computation (no loop, no state, no side effects):
    /// - `policy.intervalMinutes <= 0` → `nil` (scheduling OFF, documented above).
    /// - `lastFireAt == nil` → `now`. The first-ever slot is due immediately and
    ///   fires as a NORMAL fire (not catch-up — nothing was persisted as missed).
    /// - else `lastFireAt + max(15, intervalMinutes) minutes`. The result may lie
    ///   in the PAST — that is how the loop recognizes a missed slot. This pure
    ///   function never clamps to `now`; recognizing "overdue now" is the loop's
    ///   decision (decision points: catch-up at start, grid-skip without it).
    public func nextFire(at lastFireAt: Date?, policy: SchedulePolicy, from now: Date) -> Date? {
        guard policy.intervalMinutes > 0 else { return nil }
        let intervalSeconds = TimeInterval(max(15, policy.intervalMinutes)) * 60
        guard let last = lastFireAt else { return now }
        return last.addingTimeInterval(intervalSeconds)
    }

    /// The fire-call argument, computed from the caller's rule-filtered list:
    /// empty list → `nil` (no apps opted into autoCheck for this fire), non-empty
    /// forwarded verbatim. The engine ALWAYS fires at a due slot regardless of the
    /// list (a fire is a cadence event; "what to check" is entirely the seam's
    /// knowledge — the engine never second-guesses it and never skips a slot).
    static func fireArgument(from list: [String]) -> [String]? {
        list.isEmpty ? nil : list
    }

    // MARK: - Active-window math (pure, tests hit it through @testable)

    /// The policy's active window as a LOCAL minutes-of-day `Range`, or nil when
    /// there is no restriction. A window is VALID only when both endpoints are
    /// set, each within `0...1439`, and `start < end` — an invalid window
    /// (partially configured, degenerate `start == end`, inverted `start > end`,
    /// out of range) honestly means NO restriction, never "skip everything"
    /// (an invalid window must not silently stop the scheduler). The loader
    /// (`RuleStore.clamped`) normalizes invalid windows to nil/nil with the same
    /// rule; this independent re-validation is the window analog of the interval
    /// floor's double protection (a hand-edited schedule.json can never produce
    /// weird gating). No overnight wrap: `start > end` is invalid, not "crosses
    /// midnight".
    static func activeWindow(in policy: SchedulePolicy) -> Range<Int>? {
        guard let start = policy.activeWindowStartMinute,
              let end = policy.activeWindowEndMinute else { return nil }
        guard (0...1_439).contains(start), (0...1_439).contains(end), start < end else {
            return nil
        }
        return start..<end
    }

    /// LOCAL minute-of-day (0...1439) of `date` via `Calendar.current` — quiet
    /// hours are a user-local-time concept. Tests evaluate the same calendar on
    /// the same machine, so expectations are machine-consistent without a
    /// calendar seam.
    static func minuteOfDay(of date: Date, calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    /// `true` ⇔ `moment`'s local minute-of-day lies inside the policy's active
    /// window (half-open `[start, end)`: start inclusive, end exclusive). No
    /// valid window → always true (no restriction).
    static func isInsideActiveWindow(_ moment: Date, policy: SchedulePolicy) -> Bool {
        guard let window = activeWindow(in: policy) else { return true }
        return window.contains(minuteOfDay(of: moment))
    }

    // MARK: - Loop

    /// Starts the loop and returns its snapshot stream.
    ///
    /// - Yields one snapshot up front (the policy-load snapshot) so the UI sees
    ///   the loaded pair immediately, even when scheduling is off.
    /// - Then yields a snapshot after EVERY state change (each fire attempt —
    ///   success and failure both change state and both yield). Battery skips and
    ///   missed-slot skips record nothing, so they yield nothing.
    /// - The stream finishes when: scheduling is off (right after the policy-load
    ///   snapshot), a `sleep` throws (cancellation or seam failure), the loop
    ///   body exits, or the consumer terminates the stream (runner cancelled via
    ///   `onTermination`).
    /// - The runner is a detached utility-rate task: a background scheduler with
    ///   Sendable value captures only (nonisolated async → global executor).
    ///
    /// `autoCheckBundleIDs` is consulted afresh immediately before every fire, so
    /// rule changes apply to the next fire without restarting the stream.
    public func start(
        policy: SchedulePolicy,
        state: ScheduleState,
        autoCheckBundleIDs: @escaping @Sendable () async -> [String]
    ) async -> AsyncStream<ScheduleSnapshot> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let runner = Task.detached(priority: .utility) { [engine = self] in
                await engine.run(
                    policy: policy,
                    initial: state,
                    autoCheckBundleIDs: autoCheckBundleIDs,
                    emit: { continuation.yield($0) },
                    finish: { continuation.finish() }
                )
            }
            continuation.onTermination = { _ in runner.cancel() }
        }
    }

    /// The loop body. The loop tracks ONE committed slot (`slot`) — the exact
    /// grid moment it currently intends to fire (possibly deferred). Structure:
    ///
    /// 1. No committed slot → derive from the anchor via `nextFire`; nil there
    ///    (scheduling off, or an invariant break) → honest stream end.
    /// 2. Committed slot due at loop top (persisted miss / start-overdue):
    ///    policy-skip gates in fixed order — battery, offline, active window —
    ///    each deferring to the first strictly-future grid point (no record);
    ///    then catch-up fire (exactly once, then normal cadence); otherwise
    ///    missed-slot grid-skip to the first strictly-future grid point. A
    ///    FIRST-EVER fire (nil anchor) passes the same gates first — it is a
    ///    normal fire, not an exempt one.
    /// 3. Future slot: sleep the exact delta → cancellation surfaces as the
    ///    thrown error → stream finishes (no swallow).
    /// 4. Short wake (woke before slot: keeper jitter or seams) → keep sleeping.
    /// 5. Due after sleep: the same three policy-skip gates re-arm relative to
    ///    the WAKE time (probes evaluated at the decision moment, window on the
    ///    decision moment's local minute-of-day); a passing fire clears the
    ///    committed slot — the next one derives from the fire-time anchor
    ///    (double-fire never).
    ///
    /// Flaw history note (per protocol §4): the first draft re-derived the slot
    /// from a skip-updated ANCHOR, which landed one interval late — a deferred
    /// slot must be re-armed as the committed SLOT itself, not fed back through
    /// `nextFire` as a last-fire anchor. The committed-slot model encodes that
    /// decision; the skip-path test (`noCatchUpSkipsGridAndKeepsCadence`) holds
    /// it.
    private func run(
        policy: SchedulePolicy,
        initial: ScheduleState,
        autoCheckBundleIDs: @escaping @Sendable () async -> [String],
        emit: @escaping @Sendable (ScheduleSnapshot) -> Void,
        finish: @escaping @Sendable () -> Void
    ) async {
        var state = initial
        // Cadence anchor: the last ACTUAL fire (or the persisted lastFireAt at
        // start). Updated only when a fire happens; skips never touch it — they
        // re-arm the committed slot instead, so no skipped point can be mistaken
        // for a fired one.
        var anchor = initial.lastFireAt
        // The committed grid moment the loop is sleeping toward; nil = derive.
        var slot: Date?

        emit(ScheduleSnapshot(policy: policy, state: state))

        guard policy.intervalMinutes > 0 else {
            finish()
            return
        }
        let effectiveInterval = TimeInterval(max(15, policy.intervalMinutes)) * 60

        while !Task.isCancelled {
            let now = clock()
            let dueAt: Date
            if let committed = slot {
                dueAt = committed
            } else {
                guard let derived = nextFire(at: anchor, policy: policy, from: now) else {
                    finish()
                    return
                }
                dueAt = derived
                slot = derived
            }

            if dueAt <= now {
                if policy.skipOnBattery && isOnBattery() {
                    slot = Self.firstFutureSlot(
                        after: dueAt, intervalSeconds: effectiveInterval, relativeTo: now)
                    continue
                }
                if policy.deferWhenOffline && !isOnline() {
                    slot = Self.firstFutureSlot(
                        after: dueAt, intervalSeconds: effectiveInterval, relativeTo: now)
                    continue
                }
                if !Self.isInsideActiveWindow(now, policy: policy) {
                    slot = Self.firstFutureSlot(
                        after: dueAt, intervalSeconds: effectiveInterval, relativeTo: now)
                    continue
                }
                if anchor == nil {
                    // FIRST-EVER start (coordinator fix at Phase-4
                    // reconciliation, live-evidence-driven): nextFire(nil)
                    // == now makes this slot due by construction — it is
                    // NOT a missed slot, so it fires immediately as a
                    // NORMAL fire, unconditioned by the catch-up policy
                    // (nextFire's documented semantics). Before this fix a
                    // fresh launch recorded lastFireWasCatchUp = true and
                    // the menu printed "wake catch-up for a missed slot"
                    // although nothing had ever been missed. Persisted-nil
                    // anchor exists only at loop start, so the two
                    // onWakeCatchUp=false tests (persisted, grid-skip) are
                    // unaffected.
                    (state, anchor) = await attemptFire(
                        policy: policy, state: state, isCatchUp: false,
                        autoCheckBundleIDs: autoCheckBundleIDs, emit: emit)
                    slot = nil
                } else if policy.onWakeCatchUp {
                    (state, anchor) = await attemptFire(
                        policy: policy, state: state, isCatchUp: true,
                        autoCheckBundleIDs: autoCheckBundleIDs, emit: emit)
                    slot = nil
                } else {
                    slot = Self.firstFutureSlot(
                        after: dueAt, intervalSeconds: effectiveInterval, relativeTo: now)
                }
                continue
            }

            do {
                try await sleep(Duration.seconds(dueAt.timeIntervalSince(now)))
            } catch {
                finish()
                return
            }

            let wokeAt = clock()
            guard wokeAt >= dueAt else { continue }
            if policy.skipOnBattery && isOnBattery() {
                slot = Self.firstFutureSlot(
                    after: dueAt, intervalSeconds: effectiveInterval, relativeTo: wokeAt)
                continue
            }
            if policy.deferWhenOffline && !isOnline() {
                slot = Self.firstFutureSlot(
                    after: dueAt, intervalSeconds: effectiveInterval, relativeTo: wokeAt)
                continue
            }
            if !Self.isInsideActiveWindow(wokeAt, policy: policy) {
                slot = Self.firstFutureSlot(
                    after: dueAt, intervalSeconds: effectiveInterval, relativeTo: wokeAt)
                continue
            }
            (state, anchor) = await attemptFire(
                policy: policy, state: state, isCatchUp: false,
                autoCheckBundleIDs: autoCheckBundleIDs, emit: emit)
            slot = nil
        }
        finish()
    }

    /// One fire attempt. Updates the anchor + records the attempt into `state`,
    /// emits one snapshot (success and failure BOTH yield — a failed fire is a
    /// state change), and returns the updated pair.
    ///
    /// Honesty table (documented contract, encoded here + tested):
    /// - `lastFireAt` := attempt time — on SUCCESS AND on failure. The cadence
    ///   anchor must not slip by the length of a scan attempt, and a failed fire
    ///   must not turn into an immediate re-fire loop.
    /// - `lastFireWasCatchUp` := this attempt's type (both outcomes) — it
    ///   describes the attempt, and the attempt did happen.
    /// - success: `lastFireAppsChecked` := returned count, `lastFireError` := nil
    ///   (clears a previous failure: the LAST fire's outcome is what is stored).
    /// - failure: `lastFireError` := verbatim `String(describing:)` (opaque by
    ///   design, per the ScheduleState doc comment); `lastFireAppsChecked`
    ///   intentionally untouched — the error text is the UI's signal that the
    ///   number may be stale, and the engine never invents a count.
    private func attemptFire(
        policy: SchedulePolicy,
        state: ScheduleState,
        isCatchUp: Bool,
        autoCheckBundleIDs: @escaping @Sendable () async -> [String],
        emit: @escaping @Sendable (ScheduleSnapshot) -> Void
    ) async -> (state: ScheduleState, anchor: Date?) {
        var state = state
        let firedAt = clock()
        let list = await autoCheckBundleIDs()
        state.lastFireAt = firedAt
        state.lastFireWasCatchUp = isCatchUp
        do {
            let count = try await fire(Self.fireArgument(from: list))
            state.lastFireAppsChecked = count
            state.lastFireError = nil
        } catch {
            state.lastFireError = String(describing: error)
        }
        emit(ScheduleSnapshot(policy: policy, state: state))
        return (state, firedAt)
    }

    /// First missed-slot grid point STRICTLY in the future: `slot + k·interval`
    /// with the smallest k ≥ 1 giving a point > `now`. Iterates one interval per
    /// missed slot (integer-cheap arithmetic; no sleeps between steps). Used for
    /// every skip path so a deferred anchor can never re-enter a due branch
    /// (double-fire never).
    static func firstFutureSlot(
        after slot: Date, intervalSeconds: TimeInterval, relativeTo now: Date
    ) -> Date {
        var candidate = slot
        while candidate <= now {
            candidate = candidate.addingTimeInterval(intervalSeconds)
        }
        return candidate
    }

    /// Default online probe via SystemConfiguration reachability (no sockets, no
    /// packets — `SCNetworkReachabilityGetFlags` asks the system whether a
    /// network path to the target currently exists). Probed against a public IP
    /// literal (no DNS involved). `true` ⇔ a path is REACHABLE and needs no
    /// connection intervention; a captive portal (`connectionRequired`) reads as
    /// offline — the conservative side, deferring a check that would likely
    /// fail. Unreadable/absent state reads as ONLINE (`true`): the honest asym-
    /// metric default, mirroring the battery probe's unreadable→AC choice — a
    /// fire that fails records `lastFireError` (state surfaces the failure), a
    /// defer records NOTHING (state would silently stall), so when the probe is
    /// blind the branch with an honest error surface is the one taken. Only
    /// invoked when the policy enables `deferWhenOffline`.
    private static func isOnlineDefaultProbe() -> Bool {
        guard let reachability = SCNetworkReachabilityCreateWithName(nil, "1.1.1.1") else {
            return true
        }
        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(reachability, &flags) else { return true }
        return flags.contains(.reachable) && !flags.contains(.connectionRequired)
    }

    /// Default battery probe via IOKit IOPS (no AppKit, no Process): true ⇔ ANY
    /// power source reports the battery-power state. Unreadable or absent power
    /// sources (some VMs) read as AC (false) — an honest default that never
    /// crashes; a test injects a fake probe and never exercises this branch's
    /// decision logic, only its live binding (called once in a test expecting
    /// either boolean). If the C bridge were ever to fail to compile, the honest
    /// fallback is a documented seam warning, NOT a fake "on AC" policy decision
    /// — this implementation is the primary path, compile-verified by the gate.
    private static func isOnBatteryDefaultProbe() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [AnyObject]
        else { return false }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any],
                let state = description[kIOPSPowerSourceStateKey as String] as? String
            else { continue }
            if state == kIOPSBatteryPowerValue { return true }
        }
        return false
    }
}
