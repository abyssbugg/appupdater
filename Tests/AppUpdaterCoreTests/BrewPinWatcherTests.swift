// BrewPinWatcher tests — the pinned-file mtime watcher. Hermetic: injected
// file URLs under per-test UUID temp dirs (never any real prefix, never
// /var/homebrew) + a ScheduleEngine-style fake clock + parked sleeper (ZERO
// real poll time — the loop only moves via explicit harness advances; mtimes
// are pinned to exact chosen instants instead of racing the filesystem).
// Swift Testing only (XCTest discovery is broken on this toolchain).
// CONSENT BOUNDARY: the watcher only stats two files — it never runs brew.

import Foundation
import Testing
@testable import AppUpdaterCore

// MARK: - Watcher harness (ScheduleEngine-style: fake clock + parked sleeper)

/// Drives the watcher loop deterministically: the injected sleep parks until
/// `advance()` moves the fake clock by one interval and resumes every parked
/// sleeper. Cancellation wakes the parked sleeper (with CancellationError) so
/// the loop exits instead of leaking.
private final class PinWatchHarness: @unchecked Sendable {

    final class SleeperEntry: @unchecked Sendable {
        var wakeAt = Date.distantFuture
        var cancelled = false
        var resumed = false
        var continuation: CheckedContinuation<Void, any Error>?
    }

    private let lock = NSLock()
    private var now: Date
    private let interval: TimeInterval
    private var sleepers: [SleeperEntry] = []

    init(epoch: Date, interval: TimeInterval) {
        self.now = epoch
        self.interval = interval
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    func currentTime() -> Date { withLock { now } }
    var isParked: Bool { withLock { sleepers.contains { !$0.resumed } } }

    /// The injected watcher sleep: parks until the next advance (or cancel).
    func injectedSleep(_ seconds: TimeInterval) async throws {
        let entry = SleeperEntry()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if entry.cancelled || Task.isCancelled {
                    entry.resumed = true
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                    return
                }
                entry.wakeAt = now.addingTimeInterval(seconds)
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

    /// Moves the fake clock one interval and resumes every parked sleeper
    /// (collect under the lock, resume outside it).
    func advance() {
        var due: [CheckedContinuation<Void, any Error>] = []
        withLock {
            now = now.addingTimeInterval(interval)
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

/// Thread-safe callback collection (an independent copy so this file stays
/// self-contained against merge drift).
private final class PinCallbackBox: @unchecked Sendable {
    private let lock = NSLock()
    private var observations: [BrewPinsObservation] = []

    func add(_ observation: BrewPinsObservation) {
        lock.lock(); observations.append(observation); lock.unlock()
    }
    var all: [BrewPinsObservation] {
        lock.lock(); defer { lock.unlock() }
        return observations
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return observations.count
    }
}

// MARK: - Watcher tests

@Suite(.serialized)
struct BrewPinWatcherTests {

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private static let interval: TimeInterval = 60

    /// Unique per-test pinned locations (never any real prefix, never
    /// /var/homebrew — that path is unverified and not ours to touch).
    private struct PinnedLocations {
        let directory: URL
        let formulae: URL
        let casks: URL
    }

    private func makePinnedURLs() throws -> PinnedLocations {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("brew-pins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return PinnedLocations(
            directory: dir,
            formulae: dir.appendingPathComponent("pinned"),
            casks: dir.appendingPathComponent("pinned_casks"))
    }

    /// Writes (or rewrites) a pinned file AND pins its mtime to an exact
    /// chosen instant — the mtime is the watched signal, so tests control it
    /// instead of racing the filesystem's own timestamps.
    private func writePinnedFile(
        _ url: URL, names: String, mtime: Date
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(names.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: mtime], ofItemAtPath: url.path)
    }

    private func makeWatcher(
        _ urls: PinnedLocations,
        _ harness: PinWatchHarness
    ) -> BrewPinWatcher {
        BrewPinWatcher(
            interval: Self.interval,
            formulaePinsURL: urls.formulae,
            casksPinsURL: urls.casks,
            clock: { harness.currentTime() },
            sleep: { seconds in try await harness.injectedSleep(seconds) })
    }

    /// Bounded real-time poll for async flags (ScheduleEngine pattern — waits
    /// on flags only, never couples assertions to the fake clock).
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

    // (11) Touch + advance → exactly one callback carrying the NEW mtime and
    // the advanced fake-clock stamp.
    @Test func touchedFileFiresCallbackOnAdvance() async throws {
        let urls = try makePinnedURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let baseline = Self.epoch.addingTimeInterval(-1_000)
        try writePinnedFile(urls.formulae, names: "wget\n", mtime: baseline)

        let harness = PinWatchHarness(epoch: Self.epoch, interval: Self.interval)
        let box = PinCallbackBox()
        let task = makeWatcher(urls, harness).start { box.add($0) }
        defer { task.cancel() }

        #expect(await waitUntil(harness.isParked)) // baseline recorded, loop parked

        let changed = Self.epoch.addingTimeInterval(500)
        try writePinnedFile(urls.formulae, names: "wget\nnode@20\n", mtime: changed)
        harness.advance()

        #expect(await waitUntil(box.count == 1))
        let observation = try #require(box.all.first)
        #expect(observation.formulaeMtime == changed)
        #expect(observation.casksMtime == nil)
        #expect(observation.observedAt == Self.epoch.addingTimeInterval(Self.interval))
    }

    // (12) No file change + advance → parked again, ZERO callbacks (a quiet
    // poll is silent — no callback noise on an unchanged location).
    @Test func unchangedFileFiresNoCallback() async throws {
        let urls = try makePinnedURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        try writePinnedFile(urls.formulae, names: "wget\n", mtime: Self.epoch)

        let harness = PinWatchHarness(epoch: Self.epoch, interval: Self.interval)
        let box = PinCallbackBox()
        let task = makeWatcher(urls, harness).start { box.add($0) }
        defer { task.cancel() }

        #expect(await waitUntil(harness.isParked))
        harness.advance()
        #expect(await waitUntil(harness.isParked)) // loop re-parked = cycle done
        #expect(box.all.isEmpty)

        harness.advance()
        #expect(await waitUntil(harness.isParked))
        #expect(box.all.isEmpty) // still nothing: mtimes never moved
    }

    // (13) The INITIAL observation is a baseline, not a change: a file that
    // already exists at start fires nothing until it actually moves.
    @Test func initialObservationIsBaselineNotChange() async throws {
        let urls = try makePinnedURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let baseline = Self.epoch.addingTimeInterval(-60)
        try writePinnedFile(urls.casks, names: "google-chrome\n", mtime: baseline)

        let harness = PinWatchHarness(epoch: Self.epoch, interval: Self.interval)
        let box = PinCallbackBox()
        let task = makeWatcher(urls, harness).start { box.add($0) }
        defer { task.cancel() }

        #expect(await waitUntil(harness.isParked))
        harness.advance()
        #expect(await waitUntil(harness.isParked))
        #expect(box.all.isEmpty) // pre-existing file: baseline, no callback

        let changed = Self.epoch.addingTimeInterval(120)
        try writePinnedFile(urls.casks, names: "google-chrome\nfirefox\n", mtime: changed)
        harness.advance()
        #expect(await waitUntil(box.count == 1))
        let observation = try #require(box.all.first)
        #expect(observation.casksMtime == changed)
        #expect(observation.formulaeMtime == nil) // the formulae file never existed
    }

    // (14) A file APPEARING later (created after start) is a change: nil mtime
    // → real mtime, and the nil side is an honest "no pins recorded".
    @Test func fileAppearanceIsAChange() async throws {
        let urls = try makePinnedURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }

        let harness = PinWatchHarness(epoch: Self.epoch, interval: Self.interval)
        let box = PinCallbackBox()
        let task = makeWatcher(urls, harness).start { box.add($0) }
        defer { task.cancel() }

        #expect(await waitUntil(harness.isParked))
        #expect(box.all.isEmpty) // both locations absent: silent baseline

        let created = Self.epoch.addingTimeInterval(90)
        try writePinnedFile(urls.formulae, names: "openssl@3\n", mtime: created)
        harness.advance()
        #expect(await waitUntil(box.count == 1))
        let observation = try #require(box.all.first)
        #expect(observation.formulaeMtime == created)
        #expect(observation.casksMtime == nil) // the casks location still absent
    }

    // (15) Either location delta fires: a CASKS-only move is detected exactly
    // like a formulae move (both mtimes ride in one observation).
    @Test func casksOnlyMoveFiresWithFormulaeUnchanged() async throws {
        let urls = try makePinnedURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let baseline = Self.epoch.addingTimeInterval(-30)
        try writePinnedFile(urls.formulae, names: "wget\n", mtime: baseline)

        let harness = PinWatchHarness(epoch: Self.epoch, interval: Self.interval)
        let box = PinCallbackBox()
        let task = makeWatcher(urls, harness).start { box.add($0) }
        defer { task.cancel() }

        #expect(await waitUntil(harness.isParked))
        let changed = Self.epoch.addingTimeInterval(75)
        try writePinnedFile(urls.casks, names: "firefox\n", mtime: changed)
        harness.advance()

        #expect(await waitUntil(box.count == 1))
        let observation = try #require(box.all.first)
        #expect(observation.casksMtime == changed)
        #expect(observation.formulaeMtime == baseline) // unchanged side carries its mtime verbatim
    }

    // (16) Cancellation exits the loop: after cancel + advance the parked
    // sleeper wakes with CancellationError, the task finishes, nothing fires.
    @Test func cancellationExitsLoopWithoutCallback() async throws {
        let urls = try makePinnedURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        try writePinnedFile(urls.formulae, names: "wget\n", mtime: Self.epoch)

        let harness = PinWatchHarness(epoch: Self.epoch, interval: Self.interval)
        let box = PinCallbackBox()
        let task = makeWatcher(urls, harness).start { box.add($0) }
        #expect(await waitUntil(harness.isParked))

        task.cancel()
        harness.advance() // would fire a change if the loop were still alive — it must not
        _ = await task.value // returns ONLY when the loop exited (sleep woke with CancellationError)
        #expect(box.all.isEmpty)
    }
}
