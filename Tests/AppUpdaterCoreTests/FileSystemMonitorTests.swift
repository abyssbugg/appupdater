// FileSystemMonitorTests.swift — hermetic FileSystemMonitor tests (lane fsevents).
// Swift Testing ONLY — XCTest discovery is broken on this toolchain (AGENTS.md
// gotcha ledger); Swift Testing does not re-export Foundation, so `import
// Foundation` is required here.
//
// Hermetic design, per lane brief: ZERO real FSEvents, ZERO real time, and
// nothing is ever truly watched — real root paths appear only as inert strings
// the float fake factory receives and records. Every seam is harness-injected
// (mirror of ScheduleEngineTests); bursts are injected by CALLING the captured
// intake callback directly (stamped at the frozen fake clock), the debounce
// window elapses by resuming the parked fake sleeper after the loop has parked,
// and assertions wait on bounded real-time polls for completion flags only.
//
// The committed suite is fake-ONLY by policy: the real-FSEvents proof is the
// separate live smoke (evidence file), never a suite member.

import Testing
import Foundation
@testable import AppUpdaterCore

@Suite(.serialized)
struct FileSystemMonitorTests {

    /// Arbitrary exact double-precision instant; every fake-clock stamp is
    /// derived from it (whole seconds — exact in binary floating point).
    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private static let window: TimeInterval = 2.0
    /// Inert string root the harness's fake factory watches (never touched).
    private static let root = "/private/var/folders/fsevents-tests-root"

    // MARK: (1) five bursts inside one window → ONE unioned event

    @Test func fiveBurstsInOneWindowEmitOneUnionedEvent() async throws {
        let harness = Harness()
        let monitor = harness.newMonitor()
        let run = await startMonitor(monitor)

        harness.fireBurst(["/Applications/Foo.app"])
        harness.fireBurst(["/Applications/Two.app", "/Applications/Foo.app"]) // dup: Foo
        harness.fireBurst(["/Applications/Three.app", "/Applications/Two.app"])
        harness.fireBurst(["/Applications/Four.app"])
        harness.fireBurst(["/Applications/Clean.app"]) // no dup, no overlap
        await step(harness)

        try #require(await waitUntil(run.collector.events.count == 1))
        let event = run.collector.events[0]
        // Paths: union across ALL merged batches, FIRST-SEEN order, dupes out.
        #expect(event.paths == [
            "/Applications/Foo.app", "/Applications/Two.app",
            "/Applications/Three.app", "/Applications/Four.app",
            "/Applications/Clean.app",
        ])
        // All stamps frozen at epoch (fake clock never advanced pre-window):
        // latest stamp = epoch.
        #expect(event.occurredAt == Self.epoch)
        // Honest diagnostics: 5 raw callback batches merged.
        #expect(event.batchesCoalesced == 5)
        // The channel is still open after an emission (no premature finish).
        #expect(run.collector.ended == false)
        await stopMonitor(monitor, run)
    }

    // MARK: (2) bursts in separate windows → separate events, order preserved

    @Test func burstsInSeparateWindowsEmitOrderedEvents() async throws {
        let harness = Harness()
        let monitor = harness.newMonitor()
        let run = await startMonitor(monitor)

        harness.fireBurst(["/Applications/A.app"])
        await step(harness)
        try #require(await waitUntil(run.collector.events.count == 1))

        harness.fireBurst(["/Applications/B.app"])
        await step(harness)
        try #require(await waitUntil(run.collector.events.count == 2))

        let events = run.collector.events
        #expect(events[0].paths == ["/Applications/A.app"])
        #expect(events[1].paths == ["/Applications/B.app"])
        #expect(events[0].occurredAt == Self.epoch)
        #expect(events[1].occurredAt == Self.epoch.addingTimeInterval(Self.window))
        #expect(events[0].batchesCoalesced == 1)
        #expect(events[1].batchesCoalesced == 1)
        await stopMonitor(monitor, run)
    }

    // MARK: (3) stop closes the stream; post-stop CALLBACK is dropped

    @Test func stopClosesStreamAndDropsLateBurst() async throws {
        let harness = Harness()
        let monitor = harness.newMonitor()
        let run = await startMonitor(monitor)
        harness.fireBurst(["/Applications/A.app"])
        await step(harness)
        try #require(await waitUntil(run.collector.events.count == 1))

        await monitor.stop()
        try #require(await waitUntil(run.collector.ended)) // channel finished
        try #require(await waitUntil(!monitor.isRunning))
        try #require(harness.invalidationCount == 1) // exactly one teardown

        // A callback after stop must be DROPPED — never crash, never emit.
        harness.fireBurst(["/Applications/Late.app"])
        #expect(run.collector.events.count == 1) // no second event
        #expect(run.collector.ended)             // channel stays closed
        // And a start after stop is refused (instance retired, documented).
        await monitor.start(rootPaths: [Self.root])
        #expect(!monitor.isRunning)
        try #require(harness.madeCallCount == 1)
    }

    // MARK: (4) factory refusing → isRunning false, iterator finished

    @Test func nilFactoryReportsHonestFailure() async throws {
        let harness = Harness()
        harness.stageResponses([nil])
        let monitor = harness.newMonitor()
        let run = await startMonitor(monitor)

        try #require(await waitUntil(run.collector.ended)) // stream finished fast
        #expect(!monitor.isRunning)
        #expect(run.collector.events.isEmpty) // no events, honest
        // The factory contract was exercised verbatim: roots verbatim, the
        // monitor's debounceInterval forwarded as the stream latency.
        let call = try #require(harness.lastCall)
        #expect(call.roots == [Self.root])
        #expect(call.latency == Self.window)
        #expect(harness.invalidationCount == 0) // never built: nothing to tear down
        // A restart after a refused factory is refused (channel finished).
        await monitor.start(rootPaths: [Self.root])
        #expect(!monitor.isRunning)
        try #require(harness.madeCallCount == 1)
    }

    // MARK: (5) empty rootPaths → honest refusal; a later valid start works

    @Test func emptyRootPathsRefusedHonestly() async throws {
        let harness = Harness()
        let monitor = harness.newMonitor()
        let run = await openCollector(on: monitor)

        await monitor.start(rootPaths: [])
        #expect(!monitor.isRunning)      // refused: isRunning stays false
        try #require(harness.madeCallCount == 0)  // factory never consulted
        #expect(harness.invalidationCount == 0)
        try #require(await waitUntil(run.collector.ended == false)) // channel open

        // A refusal is not a failure: a later VALID start starts normally.
        await monitor.start(rootPaths: [Self.root])
        try #require(await waitUntil(monitor.isRunning))
        harness.fireBurst(["/Applications/A.app"])
        await step(harness)
        try #require(await waitUntil(run.collector.events.count == 1))
        #expect(run.collector.events[0].batchesCoalesced == 1)
        await stopMonitor(monitor, run)
    }

    // MARK: (6) re-iterating a consumed stream → terminates immediately

    /// Documented honest contract (probe-proven AsyncStream semantics): the
    /// events stream is single-consumer; once fully consumed (channel finished
    /// by stop), a SECOND iteration of the same stream yields zero events and
    /// terminates immediately. Coordinator wiring holds ONE monitor per app
    /// lifetime — this behavior is the documented seam for misuse, not a
    /// supported flow.
    @Test func reiteratingConsumedStreamTerminatesImmediately() async throws {
        let harness = Harness()
        let monitor = harness.newMonitor()
        let run = await startMonitor(monitor)
        harness.fireBurst(["/Applications/A.app"])
        await step(harness)
        try #require(await waitUntil(run.collector.events.count == 1))

        await monitor.stop()
        try #require(await waitUntil(run.collector.ended))
        await run.awaitIteration() // STRICTLY sequential: first consumer done

        var secondSaw = 0
        for await _ in monitor.events { secondSaw += 1 }
        #expect(secondSaw == 0) // immediately finished, never replays
    }

    // MARK: (7) consumer cancelled mid-iteration → loop exits, no zombie

    @Test func consumerCancellationExitsLoopCleanly() async throws {
        let harness = Harness()
        let monitor = harness.newMonitor()
        let run = await startMonitor(monitor)
        harness.fireBurst(["/Applications/A.app"]) // window pending
        try #require(await waitUntil(harness.isParked)) // loop parked in window

        run.cancelIteration() // consumer cancels MID-iteration
        try #require(await waitUntil(!monitor.isRunning)) // teardown ran
        try #require(await waitUntil(run.collector.ended))
        try #require(harness.invalidationCount == 1) // stream torn down once
        // Zombie-free proof: a late burst is dropped safely; nothing crashes,
        // the channel reports end, and no withholding window fires later.
        harness.fireBurst(["/Applications/Late.app"])
        #expect(run.collector.events.isEmpty)
        #expect(run.collector.ended)
    }

    // MARK: (8) double start refused — one stream, one loop, no duplicates

    @Test func doubleStartIsRefusedWithOneStream() async throws {
        let harness = Harness()
        let monitor = harness.newMonitor()
        let run = await startMonitor(monitor)

        await monitor.start(rootPaths: [Self.root])
        try #require(harness.madeCallCount == 1) // second start refused
        try #require(await waitUntil(monitor.isRunning))

        harness.fireBurst(["/Applications/A.app"])
        await step(harness)
        try #require(await waitUntil(run.collector.events.count == 1))
        #expect(run.collector.events[0].batchesCoalesced == 1) // no dupes

        // The monitor forwards its debounceInterval as the stream latency
        // (single-knob policy, documented on FSEventStreamFactory).
        let call = try #require(harness.lastCall)
        #expect(call.latency == Self.window)
        await stopMonitor(monitor, run)
    }

    // MARK: (9) empty intake batches dropped — never fabricate an empty event

    @Test func emptyBurstsDroppedAtIntake() async throws {
        let harness = Harness()
        let monitor = harness.newMonitor()
        let run = await startMonitor(monitor)

        harness.fireBurst([])                    // carries nothing: dropped
        harness.fireBurst(["/Applications/A.app"])
        await step(harness)
        try #require(await waitUntil(run.collector.events.count == 1))
        // The dropped empty batch contributed neither paths nor diagnostics.
        #expect(run.collector.events[0].batchesCoalesced == 1)
        #expect(run.collector.events[0].paths == ["/Applications/A.app"])
        await stopMonitor(monitor, run)
    }

    // MARK: - Harness

    /// One test's fake factory + fake clock + fake sleep bookkeeping.
    /// `@unchecked Sendable` per the ScheduleEngineTests pattern: every field
    /// is confined behind an NSLock, and the lock is never held across a
    /// suspension point (continuation bodies install then unlock).
    private final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var now = FileSystemMonitorTests.epoch

        /// Staged factory responses, one per makeStream call. A test stages a
        /// refusal FIRST (test 4); everything else stages lazily (default:
        /// a live-fake handle whose invalidate is counted).
        private var responses: [StreamHandle?] = []
        private var responseCursor = 0

        private var invalidations = 0
        private var sleepers: [SleeperEntry] = []
        private var intake: (@Sendable ([String]) -> Void)?

        // The latest factory call record (read via the accessors below).
        private var lastMadeRecord: (roots: [String], latency: Double)?
        private var madeCountRecord = 0

        var isParked: Bool {
            lock.lock(); defer { lock.unlock() }
            return sleepers.contains { !$0.resumed }
        }
        var invalidationCount: Int {
            lock.lock(); defer { lock.unlock() }
            return invalidations
        }
        var lastCallback: (@Sendable ([String]) -> Void)? {
            lock.lock(); defer { lock.unlock() }
            return intake
        }
        var madeCallCount: Int {
            lock.lock(); defer { lock.unlock() }
            return madeCountRecord
        }
        var lastCall: (roots: [String], latency: Double)? {
            lock.lock(); defer { lock.unlock() }
            return lastMadeRecord
        }

        func newMonitor() -> FileSystemMonitor {
            FileSystemMonitor(
                factory: self.factory(),
                clock: { [self] in self.currentTime() },
                sleep: { [self] interval in try await self.injectedSleep(interval) },
                debounceInterval: FileSystemMonitorTests.window)
        }

        func stageResponses(_ values: [StreamHandle?]) {
            lock.lock()
            responses = values
            lock.unlock()
        }

        func currentTime() -> Date {
            lock.lock(); defer { lock.unlock() }
            return now
        }

        private func factory() -> FSEventStreamFactory {
            FSEventStreamFactory { [self] roots, latency, callback in
                lock.lock()
                let response: StreamHandle?
                if responseCursor < responses.count {
                    response = responses[responseCursor]
                    responseCursor += 1
                } else {
                    response = StreamHandle { [self] in self.recordInvalidation() }
                }
                intake = callback
                lastMadeRecord = (roots, latency)
                madeCountRecord += 1
                lock.unlock()
                return response
            }
        }

        func recordInvalidation() {
            lock.lock()
            invalidations += 1
            lock.unlock()
        }

        /// Injects one raw callback batch, stamped at the CURRENT fake clock
        /// (via the captured intake). Safe when nothing started: a nil intake
        /// means the burst never happened — a deterministic no-op.
        func fireBurst(_ paths: [String]) {
            let callback = lastCallback
            callback?(paths)
        }

        // MARK: sleep machinery (mirror of ScheduleEngineTests)

        private final class SleeperEntry: @unchecked Sendable {
            var resumed = false
            var wakeAt = Date.distantFuture
            var continuation: CheckedContinuation<Void, any Error>?
        }

        func injectedSleep(_ interval: TimeInterval) async throws {
            let entry = SleeperEntry()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                    lock.lock()
                    if entry.resumed || Task.isCancelled {
                        entry.resumed = true
                        lock.unlock()
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    entry.wakeAt = now.addingTimeInterval(interval)
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
            entry.resumed = true
            let cont = entry.continuation
            entry.continuation = nil
            sleepers.removeAll { $0 === entry }
            lock.unlock()
            cont?.resume(throwing: CancellationError())
        }

        /// Moves the fake clock and resumes all due sleepers (collect under
        /// the lock, resume outside it) — same as ScheduleEngineTests.
        func advance(by seconds: TimeInterval) {
            var due: [CheckedContinuation<Void, any Error>] = []
            lock.lock()
            now = now.addingTimeInterval(seconds)
            for entry in sleepers where !entry.resumed && entry.wakeAt <= now {
                entry.resumed = true
                if let cont = entry.continuation {
                    entry.continuation = nil
                    due.append(cont)
                }
            }
            lock.unlock()
            for cont in due { cont.resume() }
        }
    }

    // MARK: - Test plumbing

    private final class EventCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var collected: [FileSystemEvent] = []
        private var done = false

        var events: [FileSystemEvent] {
            lock.lock(); defer { lock.unlock() }
            return collected
        }
        var ended: Bool {
            lock.lock(); defer { lock.unlock() }
            return done
        }
        func add(_ event: FileSystemEvent) {
            lock.lock(); collected.append(event); lock.unlock()
        }
        func markEnded() {
            lock.lock(); done = true; lock.unlock()
        }
    }

    /// One consumer iteration over `monitor.events`, plus its collector. The
    /// monitor itself is passed through every helper call directly.
    private final class MonitorRun: @unchecked Sendable {
        let collector: EventCollector
        private let iteration: Task<Void, Never>

        init(collector: EventCollector, iteration: Task<Void, Never>) {
            self.collector = collector
            self.iteration = iteration
        }

        func cancelIteration() {
            iteration.cancel()
        }

        /// Fully awaits the consumer task (strictly sequential re-iteration).
        func awaitIteration() async {
            await iteration.value
        }
    }

    /// Creates the monitor, opens a collecting iteration FIRST (flags polled
    /// like ScheduleEngineTests), then starts it on the harness's default
    /// root; returns the run.
    private func startMonitor(_ monitor: FileSystemMonitor) async -> MonitorRun {
        let run = await openCollector(on: monitor)
        await monitor.start(rootPaths: [Self.root])
        return run
    }

    /// Opens the collecting iteration WITHOUT starting (refusal tests assert
    /// the factory-never-consulted contract first, then start validly).
    private func openCollector(on monitor: FileSystemMonitor) -> MonitorRun {
        let collector = EventCollector()
        let iteration = Task {
            for await event in monitor.events {
                collector.add(event)
            }
            collector.markEnded()
        }
        return MonitorRun(collector: collector, iteration: iteration)
    }

    private func stopMonitor(_ monitor: FileSystemMonitor, _ run: MonitorRun) async {
        run.cancelIteration()
        let closed = await waitUntil(run.collector.ended, within: 2)
        #expect(closed)
    }

    /// Park-synchronized window advance: waits until the loop has parked in
    /// its debounce sleep, THEN moves the fake clock (kills the start-race
    /// where an advance could land before the first sleep registration —
    /// which would mis-shift the window by one whole advance).
    private func step(_ harness: Harness) async {
        #expect(await waitUntil(harness.isParked, within: 2))
        harness.advance(by: Self.window)
    }

    /// Bounded real-time poll for a completion flag (false on timeout). The
    /// fake clock only moves via explicit advances — this never couples an
    /// assertion to the fake clock.
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
