// ScheduleEngineTests.swift — hermetic ScheduleEngine loop tests (lane scheduler).
// Swift Testing ONLY — XCTest discovery is broken on this toolchain (Xcode 27 beta,
// AGENTS.md gotcha ledger). Swift Testing does not re-export Foundation, so
// `import Foundation` is required here.
//
// Hermetic design: the engine's clock/sleep/battery/fire seams are all harness-
// injected. The loop is driven by `Harness.advance`, which moves a fake clock and
// resumes the parked sleeper at (or past) its wake time, so the loop's next
// `clock()` call observes the advanced time. No real scheduling time is consumed
// between loop steps; assertions wait on bounded real-time polls for completion
// flags only (never coupling assertions to the fake clock, never hanging).

import Testing
import Foundation
@testable import AppUpdaterCore

@Suite(.serialized)
struct ScheduleEngineTests {

    /// Engine epoch for every harness: an arbitrary exact double-precision
    /// instant. All test arithmetic is whole minutes (exact in binary floating
    /// point), so Date equality assertions are exact.
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private static let minute: TimeInterval = 60

    private static func mins(_ n: Double) -> Duration { .seconds(n * 60) }

    enum TestError: Error { case boom }

    // MARK: (12) default battery probe — live IOKit binding

    /// The LIVE default probe runs once through the IOPS C bridge. The boolean is
    /// hardware-dependent, so either value passes (per brief); the evidence is the
    /// call completing without trapping.
    @Test func defaultBatteryProbeBindsLiveIOPS() {
        let engine = ScheduleEngine(fire: { _ in 0 })
        let probe = engine.isOnBattery()
        #expect(probe == true || probe == false)
    }

    // MARK: (1) nextFire pure math

    /// Pure-math contract: scheduled-off nil; nil lastFireAt → now; +interval
    /// future; a missed slot stays in the past (clamping a past slot to now is
    /// the LOOP's decision, not the pure function's); the 15-minute floor is
    /// enforced by the math itself below the floor.
    @Test func nextFirePureMath() throws {
        let engine = ScheduleEngine(fire: { _ in 0 })
        let now = Self.epoch

        #expect(engine.nextFire(at: now, policy: SchedulePolicy(intervalMinutes: 0), from: now) == nil)
        #expect(engine.nextFire(at: now, policy: SchedulePolicy(intervalMinutes: -7), from: now) == nil)

        #expect(engine.nextFire(at: nil, policy: SchedulePolicy(intervalMinutes: 42), from: now) == now)

        let sixty = engine.nextFire(
            at: now.addingTimeInterval(-Self.minute), policy: SchedulePolicy(intervalMinutes: 60), from: now)
        #expect(sixty == now.addingTimeInterval(59 * Self.minute))

        let clamped = engine.nextFire(
            at: now.addingTimeInterval(-Self.minute), policy: SchedulePolicy(intervalMinutes: 5), from: now)
        #expect(clamped == now.addingTimeInterval(14 * Self.minute))
        let onFloor = engine.nextFire(
            at: now.addingTimeInterval(-Self.minute), policy: SchedulePolicy(intervalMinutes: 15), from: now)
        #expect(onFloor == now.addingTimeInterval(14 * Self.minute))

        let overdue = engine.nextFire(
            at: now.addingTimeInterval(-30 * Self.minute),
            policy: SchedulePolicy(intervalMinutes: 15), from: now)
        #expect(overdue == now.addingTimeInterval(-15 * Self.minute))
        #expect(try #require(overdue) < now)
    }

    // MARK: (2) catch-up fires exactly once

    /// Persisted lastFireAt overdue + onWakeCatchUp → exactly ONE immediate
    /// catch-up fire at loop start (no clock advance needed), then normal ticks.
    @Test func catchUpFiresExactlyOnce() async throws {
        let harness = Harness()
        let run = await runEngine(
            harness,
            policy: SchedulePolicy(intervalMinutes: 15, skipOnBattery: false, onWakeCatchUp: true),
            state: ScheduleState(
                lastFireAt: Self.epoch.addingTimeInterval(-30 * Self.minute),
                lastFireAppsChecked: 0)
        )
        defer { run.cancelIteration() }

        // Catch-up already fired without any clock passing.
        #expect(await waitUntil(harness.fireCount == 1))
        #expect(harness.fireArguments == [Self.defaultIDs])
        #expect(harness.fireTimes == [Self.epoch])

        await step(harness, 15)
        #expect(await waitUntil(harness.fireCount == 2))
        await step(harness, 15)
        #expect(await waitUntil(harness.fireCount == 3))
        let states = run.collector.states
        #expect(states.count == 4) // policy-load + 3 post-fire
        #expect(states[0].state.lastFireWasCatchUp == nil) // persisted: never ran yet
        let flags = states.dropFirst().map { $0.state.lastFireWasCatchUp }
        #expect(flags == [true, false, false])
        // After the catch-up, cadence continues normally (exactly once).
        #expect(states[3].state.lastFireAt == Self.epoch.addingTimeInterval(30 * Self.minute))
    }

    // MARK: (3) normal tick fire after the interval elapses

    @Test func normalTickFireRecordsListAndCount() async throws {
        let harness = Harness()
        harness.setIDs(["com.tick.a", "com.tick.b", "com.tick.c"])
        harness.setReturnCount(9)
        let run = await runEngine(
            harness,
            policy: SchedulePolicy(intervalMinutes: 60, skipOnBattery: false, onWakeCatchUp: true),
            state: ScheduleState(lastFireAt: Self.epoch.addingTimeInterval(-Self.minute))
        )
        defer { run.cancelIteration() }

        // Slot = (epoch-1min) + 60min = epoch+59min; advance exactly onto it.
        await step(harness, 59)
        #expect(await waitUntil(harness.fireCount == 1))

        #expect(harness.fireArguments == [["com.tick.a", "com.tick.b", "com.tick.c"]])
        #expect(harness.fireTimes == [Self.epoch.addingTimeInterval(59 * Self.minute)])

        let post = try #require(run.collector.states.last?.state)
        #expect(post.lastFireAppsChecked == 9)
        #expect(post.lastFireAt == Self.epoch.addingTimeInterval(59 * Self.minute))
        #expect(post.lastFireWasCatchUp == false)
        #expect(post.lastFireError == nil)
    }

    // MARK: decision-lock — an empty opted-in set is forwarded as nil

    @Test func fireReceivesNilForEmptyList() async throws {
        let harness = Harness()
        harness.setIDs([])
        let run = await runEngine(
            harness,
            policy: SchedulePolicy(intervalMinutes: 60, skipOnBattery: false, onWakeCatchUp: true),
            state: ScheduleState(lastFireAt: Self.epoch.addingTimeInterval(-Self.minute))
        )
        defer { run.cancelIteration() }

        await step(harness, 59)
        #expect(await waitUntil(harness.fireCount == 1))
        #expect(harness.fireArguments == [nil])
    }

    // MARK: (5) fire closure throwing → error recorded, cadence continues

    @Test func failedFireRecordsErrorAndContinues() async throws {
        let harness = Harness()
        // Pre-seeded count proves a failed fire leaves the field untouched.
        harness.setReturnCount(7)
        let run = await runEngine(
            harness,
            policy: SchedulePolicy(intervalMinutes: 60, skipOnBattery: false, onWakeCatchUp: true),
            state: ScheduleState(
                lastFireAt: Self.epoch.addingTimeInterval(-Self.minute),
                lastFireAppsChecked: 5)
        )
        defer { run.cancelIteration() }

        harness.setShouldThrow(TestError.boom)
        await step(harness, 59)
        #expect(await waitUntil(harness.fireCount == 1))

        let failed = try #require(run.collector.states.last?.state)
        #expect(failed.lastFireError == String(describing: TestError.boom))
        #expect(failed.lastFireAppsChecked == 5) // untouched by the failure
        #expect(failed.lastFireAt == Self.epoch.addingTimeInterval(59 * Self.minute)) // anchor advanced on failure too
        #expect(failed.lastFireWasCatchUp == false)

        // Cadence continues: the NEXT slot fires normally and clears the error.
        harness.setShouldThrow(nil)
        await step(harness, 60) // next slot = (epoch+59min) + 60min
        #expect(await waitUntil(harness.fireCount == 2))
        let recovered = try #require(run.collector.states.last?.state)
        #expect(recovered.lastFireError == nil)
        #expect(recovered.lastFireAppsChecked == 7)
    }

    // MARK: (4) battery defer (no fire/no record), then fires after the flip

    @Test func batteryDeferSkipsAndFiresAfterToggle() async throws {
        let harness = Harness()
        harness.setBattery(true)
        let run = await runEngine(
            harness,
            policy: SchedulePolicy(intervalMinutes: 60, skipOnBattery: true, onWakeCatchUp: true),
            state: ScheduleState(lastFireAt: Self.epoch.addingTimeInterval(-45 * Self.minute))
        )
        defer { run.cancelIteration() }

        // Slot (epoch+15min) arrives while on battery → deferred honestly:
        // no fire, no snapshot, NO state record of any kind.
        await step(harness, 60)
        #expect(await waitUntil(harness.fireCount == 1, within: 0.5) == false)
        #expect(harness.fireCount == 0)
        #expect(run.collector.states.count == 1) // only the policy-load snapshot

        // Probe flips false → the deferred grid slot (skip + one interval = +75min)
        // fires as a NORMAL tick (a battery skip is a policy skip, never a miss).
        harness.setBattery(false)
        await step(harness, 70) // now = epoch+130min ≥ wake (epoch+75min)
        #expect(await waitUntil(harness.fireCount == 1))

        #expect(run.collector.states.count == 2)
        let post = try #require(run.collector.states.last?.state)
        #expect(post.lastFireAppsChecked == harness.currentReturnCount)
        #expect(post.lastFireWasCatchUp == false)
        #expect(post.lastFireError == nil)
        #expect(post.lastFireAt == Self.epoch.addingTimeInterval(130 * Self.minute))
    }

    /// Battery policy suppresses catch-up too: overdue start + skipOnBattery +
    /// on battery → NO catch-up fire; after the flip the earliest grid fire is a
    /// normal tick, never mislabeled as catch-up.
    @Test func batterySuppressesCatchUp() async throws {
        let harness = Harness()
        harness.setBattery(true)
        let run = await runEngine(
            harness,
            policy: SchedulePolicy(intervalMinutes: 60, skipOnBattery: true, onWakeCatchUp: true),
            state: ScheduleState(lastFireAt: Self.epoch.addingTimeInterval(-30 * Self.minute))
        )
        defer { run.cancelIteration() }

        #expect(await waitUntil(harness.fireCount == 1, within: 0.3) == false)
        #expect(run.collector.states.count == 1)

        harness.setBattery(false)
        await step(harness, 60) // deferred grid slot = epoch+60min
        #expect(await waitUntil(harness.fireCount == 1))
        let post = try #require(run.collector.states.last?.state)
        #expect(post.lastFireWasCatchUp == false)
    }

    // MARK: onWakeCatchUp == false → missed slots skipped, grid preserved

    @Test func noCatchUpSkipsGridAndKeepsCadence() async throws {
        let harness = Harness()
        let run = await runEngine(
            harness,
            policy: SchedulePolicy(intervalMinutes: 15, skipOnBattery: false, onWakeCatchUp: false),
            state: ScheduleState(lastFireAt: Self.epoch.addingTimeInterval(-45 * Self.minute))
        )
        defer { run.cancelIteration() }

        // Overdue start with catch-up OFF: no retroactive fire; the loop jumps to
        // the first strictly-future grid point (2 missed slots → epoch+15min).
        #expect(await waitUntil(harness.fireCount == 1, within: 0.3) == false)
        #expect(harness.fireCount == 0)

        await step(harness, 15)
        #expect(await waitUntil(harness.fireCount == 1))
        #expect(harness.fireTimes == [Self.epoch.addingTimeInterval(15 * Self.minute)])
        let post = try #require(run.collector.states.last?.state)
        #expect(post.lastFireWasCatchUp == false)
    }

    // MARK: interval <= 0 → scheduling off

    @Test func schedulingOffFinishesStream() async throws {
        let harness = Harness()
        let run = await runEngine(
            harness,
            policy: SchedulePolicy(intervalMinutes: 0),
            state: ScheduleState(lastFireAt: Self.epoch.addingTimeInterval(-10 * Self.minute))
        )

        // The policy-load snapshot yields, then the stream finishes right away.
        #expect(await waitUntil(run.collector.ended, within: 1))
        #expect(run.collector.states.count == 1)
        #expect(run.collector.states[0].policy.intervalMinutes == 0)
        #expect(run.collector.states[0].state.lastFireAt == Self.epoch.addingTimeInterval(-10 * Self.minute))
        #expect(harness.fireCount == 0)
    }

    // MARK: (6) cancellation → stream completes without an extra fire

    @Test func cancellationEndsStreamWithoutExtraFire() async throws {
        let harness = Harness()
        let run = await runEngine(
            harness,
            policy: SchedulePolicy(intervalMinutes: 60, skipOnBattery: false, onWakeCatchUp: true),
            state: ScheduleState(lastFireAt: Self.epoch.addingTimeInterval(-Self.minute))
        )
        // Loop parked sleeping until epoch+59min — nothing will fire on its own.
        #expect(await waitUntil(run.collector.states.count == 1)) // policy-load snapshot
        #expect(await waitUntil(harness.isParked, within: 1)) // parked sleeping until +59min

        run.cancelIteration() // terminates the stream → runner cancelled via onTermination
        #expect(await waitUntil(run.collector.ended, within: 1))
        #expect(run.collector.states.count == 1) // no post-fire snapshot appeared
        #expect(harness.fireCount == 0)
    }

    // MARK: (7) snapshot yields: initial + after each state change

    @Test func snapshotsYieldInitialAndPostFire() async throws {
        let harness = Harness()
        let policy = SchedulePolicy(intervalMinutes: 60, skipOnBattery: true, onWakeCatchUp: false)
        let persisted = ScheduleState(
            lastFireAt: Self.epoch.addingTimeInterval(-Self.minute),
            lastFireAppsChecked: 3,
            lastFireWasCatchUp: true,
            lastFireError: "previous failure")
        let run = await runEngine(harness, policy: policy, state: persisted)
        defer { run.cancelIteration() }

        #expect(await waitUntil(run.collector.states.count >= 1))
        let initial = try #require(run.collector.states.first)
        #expect(initial.policy == policy) // policy echoed verbatim at load
        #expect(initial.state == persisted) // state echoed verbatim before any action

        await step(harness, 59)
        #expect(await waitUntil(run.collector.states.count >= 2))
        let post = try #require(run.collector.states.dropFirst().first)
        #expect(post.policy == policy)
        #expect(post.state.lastFireAt == Self.epoch.addingTimeInterval(59 * Self.minute))
        #expect(post.state.lastFireError == nil) // success clears a previous error
        #expect(post.state.lastFireWasCatchUp == false)
    }

    // MARK: - Harness (fake clock + parked sleeps + fake battery/fire)

    private static let defaultIDs = ["com.example.first", "com.example.second"]

    /// One-engine-per-harness orchestrator. `advance(by:)` is the only way the
    /// fake clock moves: it bumps `now` and resumes every parked sleeper whose
    /// wake time has arrived, so the loop's next `clock()` reads advanced time.
    /// Sleep parks an in-flight continuation; cancellation marks the sleeper and
    /// resumes it exactly once with CancellationError (mark-before-register and
    /// register-before-mark interleaves are both safe).
    private final class Harness: @unchecked Sendable {

        /// NOT Sendable by design: SleeperEntry state is guarded by the harness
        /// lock, never accessed from multiple threads directly. Marked here only
        /// so the @Sendable onCancel closure may capture it (still only ever
        /// mutated under the lock).
        final class SleeperEntry: @unchecked Sendable {
            var wakeAt = Date.distantFuture
            var cancelled = false
            var resumed = false
            var continuation: CheckedContinuation<Void, any Error>?
        }

        private let lock = NSLock()
        private var now = ScheduleEngineTests.epoch
        private var sleepers: [SleeperEntry] = []
        private var batteryOn = false
        private var throwing: (any Error)?
        private var returnCount = 42
        private var ids = ScheduleEngineTests.defaultIDs
        private var arguments: [[String]?] = []
        private var times: [Date] = []

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body()
        }

        func currentTime() -> Date { withLock { now } }
        func currentIsOnBattery() -> Bool { withLock { batteryOn } }
        func setBattery(_ on: Bool) { withLock { batteryOn = on } }
        func setIDs(_ newIDs: [String]) { withLock { ids = newIDs } }
        func autoCheckIDs() -> [String] { withLock { ids } }
        func setReturnCount(_ count: Int) { withLock { returnCount = count } }
        var currentReturnCount: Int { withLock { returnCount } }
        func setShouldThrow(_ error: (any Error)?) { withLock { throwing = error } }
        var fireCount: Int { withLock { arguments.count } }
        var fireArguments: [[String]?] { withLock { arguments } }
        var fireTimes: [Date] { withLock { times } }
        var isParked: Bool {
            withLock { sleepers.contains { !$0.resumed } }
        }

        func fireSeam(_ list: [String]?) async throws -> Int {
            let (shouldThrow, count) = withLock {
                arguments.append(list)
                times.append(now)
                return (throwing, returnCount)
            }
            if let shouldThrow { throw shouldThrow }
            return count
        }

        /// The injected engine sleep: parks until `advance` (or cancellation).
        func injectedSleep(_ duration: Duration) async throws {
            let entry = SleeperEntry()
            func seconds() -> TimeInterval {
                Double(duration.components.seconds)
                    + Double(duration.components.attoseconds) * 1e-18
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                    lock.lock()
                    if entry.cancelled || Task.isCancelled {
                        entry.resumed = true
                        lock.unlock()
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    entry.wakeAt = now.addingTimeInterval(seconds())
                    entry.continuation = cont
                    sleepers.append(entry)
                    lock.unlock()
                }
            } onCancel: {
                markCancelled(entry)
            }
        }

        private func markCancelled(_ entry: SleeperEntry) {
            lock.lock()
            guard !entry.resumed else { lock.unlock(); return }
            entry.cancelled = true
            entry.resumed = true
            let cont = entry.continuation
            entry.continuation = nil
            lock.unlock()
            cont?.resume(throwing: CancellationError())
        }

        /// Moves the fake clock and resumes all due sleepers (collect under the
        /// lock, resume outside it). A big advance spanning several intervals
        /// collapses to a single wake at the advanced time — same as real sleeping.
        func advance(by duration: Duration) {
            let delta = Double(duration.components.seconds)
                + Double(duration.components.attoseconds) * 1e-18
            var due: [CheckedContinuation<Void, any Error>] = []
            withLock {
                now = now.addingTimeInterval(delta)
                for entry in sleepers where !entry.resumed && entry.wakeAt <= now {
                    entry.resumed = true
                    if let cont = entry.continuation {
                        entry.continuation = nil
                        due.append(cont)
                    }
                }
            }
            for cont in due { cont.resume() }
        }
    }

    // MARK: - Engine wiring + snapshot collector plumbing

    private final class SnapCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [ScheduleSnapshot] = []
        private var done = false

        var states: [ScheduleSnapshot] {
            lock.lock(); defer { lock.unlock() }
            return collected
        }
        var ended: Bool {
            lock.lock(); defer { lock.unlock() }
            return done
        }
        func add(_ snapshot: ScheduleSnapshot) {
            lock.lock(); collected.append(snapshot); lock.unlock()
        }
        func markEnded() {
            lock.lock(); done = true; lock.unlock()
        }
    }

    /// One engine run: detached-iteration task + its snapshot collector.
    /// `cancelIteration()` cancels the consuming iteration, which cancels the
    /// engine runner through the stream's onTermination and finishes the stream.
    private final class EngineRun: @unchecked Sendable {
        let collector: SnapCollector
        private let iteration: Task<Void, Never>

        init(collector: SnapCollector, iteration: Task<Void, Never>) {
            self.collector = collector
            self.iteration = iteration
        }

        func cancelIteration() {
            iteration.cancel()
        }
    }

    /// Builds the fully-hermetic engine (every seam from `harness`) and starts
    /// `start(...)` with a collecting iteration over its stream.
    private func runEngine(
        _ harness: Harness,
        policy: SchedulePolicy,
        state: ScheduleState
    ) async -> EngineRun {
        let engine = ScheduleEngine(
            clock: { harness.currentTime() },
            sleep: { duration in try await harness.injectedSleep(duration) },
            isOnBattery: { harness.currentIsOnBattery() },
            fire: { list in try await harness.fireSeam(list) }
        )
        let stream = await engine.start(
            policy: policy,
            state: state,
            autoCheckBundleIDs: { harness.autoCheckIDs() }
        )
        let collector = SnapCollector()
        let iteration = Task {
            for await snapshot in stream {
                collector.add(snapshot)
            }
            collector.markEnded()
        }
        return EngineRun(collector: collector, iteration: iteration)
    }

    /// Park-synchronized clock advance: waits until the engine loop has parked
    /// in its next sleep, THEN moves the fake clock. This kills the start-race
    /// where an advance landing before the runner's first sleep registration
    /// would make the loop evaluate "already due at start" and mislabel the tick
    /// as catch-up. Every advance-driven test must step through this.
    private func step(_ harness: Harness, _ minutes: Double) async {
        #expect(await waitUntil(harness.isParked, within: 1))
        harness.advance(by: Self.mins(minutes))
    }

    /// Bounded real-time poll for a completion condition (returns false on
    /// timeout). The harness clock only moves via explicit advances — this never
    /// couples an assertion to the fake clock, it only waits for flags.
    private func waitUntil(
        _ condition: @autoclosure @escaping @Sendable () -> Bool,
        within seconds: TimeInterval = 2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
    }
}
