// FileSystemMonitor.swift — debounced FSEvents re-discovery monitor for scan roots.
// Gap-closure sprint · lane fsevents (GAP-ANALYSIS #17) · exclusive file of this lane.
//
// REQUIREMENTS EVIDENCE (never committed, read-only docs): UPDATEST-FINDINGS.md
// §3.1 — "[confirmed] Filesystem watching: FileSystemMonitor + FSEventStream
// imports → live re-discovery when apps are added/removed." GAP-ANALYSIS.md #17
// — "FSEvents live monitoring of /Applications (instant re-scan on
// install/uninstall)".
//
// CONSENT BOUNDARY (LOCKED, repo-wide — read before wiring):
//   An FS event may trigger an INVENTORY re-scan only. It must NEVER trigger an
//   automatic source check, an automatic update decision, or any install —
//   whether scheduled auto-apply exists or not. The monitor ENCODES this by
//   construction: its only output is `events` — batches of POSIX path strings —
//   and the coordinator consumes those to decide "scan these roots again".
//   Nothing in this file can name a check, a source, or an installer. Whoever
//   wires `events` into AppState re-affirms the boundary in writing at the
//   wiring site.
//
// DESIGN (the debounced event → one re-scan primitive):
//   Every raw FSEvents callback batch is stamped (injected clock) and parked.
//   The emission loop anchors a debounce window at the FIRST undrained batch,
//   waits out `debounceInterval`, then merges EVERY batch stamped within the
//   window into ONE FileSystemEvent (paths = union in first-seen order,
//   occurredAt = latest stamp, batchesCoalesced = honest merge count), emits, and
//   re-arms. Never watch anything — the loop holds no scan state.
//
// SEAMS (injected, all `Sendable` — ScheduleEngine-style so tests are
// deterministic with ZERO real time and ZERO real FSEvents):
//   - `factory` — the FSEvents stream construction seam (default: `live`).
//   - `clock` — "now" for every stamp and window boundary (default `Date()`).
//   - `sleep` — the quiescence primitive (default `Task.sleep`).
//   - `debounceInterval` — the merge window, seconds (default 2.0).
//
// FAILURE + CANCELLATION HONESTY:
//   - Factory returns nil → `start` records nothing, `isRunning` stays false,
//     and the events stream FINISHES (an instance whose factory refused is
//     retired; create a fresh monitor — SwiftPM-style one-channel semantics).
//   - Empty `rootPaths` → the start is REFUSED before the factory is ever
//     called (`isRunning` false, no events, no stream). Unlike a failed
//     factory the channel stays OPEN: a later valid start on the same monitor
//     starts normally. Refusal is not failure.
//   - Stop (or a consumer terminating the events stream) tears down the real
//     stream (intake first — late callbacks are DROPPED, never crash), then
//     finishes the channel. An in-flight debounce window is DISCARDED: the
//     window never closed, so there is nothing honest to emit.
//   - A burst arriving after the window closed (clock overshoot) anchors the
//     NEXT event — deterministic by stamp, never merged backward.
//   - Cancellation surfaces at the loop's sleep (its one suspension point that
//     honors it): the loop exits — no zombie, no dropped-but-unsaved window.
//
// HONESTY NOTE ON EMPTY BATCHES: an intake batch carrying no paths is dropped
// (nothing to re-scan; counting it would fabricate diagnostic noise). A window
// therefore never emits an empty event.
//
// PATH FORMAT HONESTY: POSIX strings exactly as the framework delivers them,
// verbatim — FSEvents may hand back the watched root itself with a trailing
// slash (observed in a live probe). Path normalization is the scan layer's
// domain (Scanner.swift documents the canonical-location rule); the monitor
// would otherwise invent a filesystem opinion inside a trigger.
//
// Sendability JUDGMENT (recorded, per lane brief — not silent): the class is
// `final … : @unchecked Sendable`. All mutable lifecycle state lives in
// `LifecycleState`, all mutable pending-batch state in `PendingBatches`, and
// both confine their fields behind an NSLock (never held across a suspension
// point); everything the class stores itself is `let` value/seam data plus one
// Sendable `AsyncStream` pair. If a future toolchain rejects the explicit
// conformance, the honest fallback is splitting the locked state into an
// actor — never a silent removal of the judgment text.

import Foundation
import CoreServices

/// One debounced burst of filesystem activity over the monitored roots — the
/// sole currency the monitor emits, and the exact shape a coordinator needs to
/// decide "these roots may need an inventory re-scan".
///
/// A `FileSystemEvent` merges every raw callback batch that was stamped inside
/// one debounce window:
/// - ``paths`` — POSIX strings, union across the merged batches, FIRST-SEEN
///   order preserved (stable for diffing against an existing inventory).
/// - ``occurredAt`` — the LATEST stamp inside the window (the moment the last
///   observed change happened — the correct "as of" for a follow-up scan).
/// - ``batchesCoalesced`` — how many raw callback batches were merged. A
///   diagnostic the coordinator can log; 1 means the burst was quiet (a single
///   callback), >1 means the window caught a genuine Install-storm.
public struct FileSystemEvent: Sendable, Hashable {
    /// Moment the LAST batch inside the window was stamped (injected clock).
    public let occurredAt: Date
    /// POSIX paths, union across merged batches, first-seen order, no dedupe
    /// beyond per-window equality.
    public let paths: [String]
    /// Raw callback batches merged into this event (honest diagnostics: 5
    /// bursts in one window → 5, never silently inflated or deflated).
    public let batchesCoalesced: Int

    public init(occurredAt: Date, paths: [String], batchesCoalesced: Int) {
        self.occurredAt = occurredAt
        self.paths = paths
        self.batchesCoalesced = batchesCoalesced
    }
}

/// A live FSEvents stream handle — everything the monitor needs to tear the
/// native stream down without knowing it exists.
public struct StreamHandle: Sendable {
    /// Synchronously stops, invalidates (unschedules), and releases the native
    /// stream. Safe to call exactly once per stream (the monitor consumes its
    /// handle during teardown and never keeps a second copy).
    public let invalidate: @Sendable () -> Void

    public init(invalidate: @escaping @Sendable () -> Void) {
        self.invalidate = invalidate
    }
}

/// The FSEvents construction seam: a closure bundle (struct of one `let`) so a
/// test can stage deterministic streams and a production wiring stays one
/// object. Parameters, in order: the root paths to watch (verbatim, never
/// reordered), the latency in seconds (the monitor forwards its own
/// `debounceInterval` — see the one-knob policy note on ``FileSystemMonitor``),
/// and the intake callback that receives POSIX path strings from the real
/// stream. Returning nil = honest "cannot watch": creation or start failed.
public struct FSEventStreamFactory: Sendable {
    public let makeStream: @Sendable ([String], Double, @escaping @Sendable ([String]) -> Void) -> StreamHandle?

    public init(makeStream: @escaping @Sendable ([String], Double, @escaping @Sendable ([String]) -> Void) -> StreamHandle?) {
        self.makeStream = makeStream
    }

    /// The real FSEvents binding. Every choice documented next to its line;
    /// the compile- and runtime-proven facts come from a live probe on this
    /// machine (2026-10-27): create → dispatch queue → start → event delivery
    /// (CFArray of POSIX strings) → teardown → post-teardown callback dropped.
    public static let live: FSEventStreamFactory = FSEventStreamFactory(
        makeStream: makeLiveStream)
}

/// Boxes the intake closure so it can ride through the C-callback context
/// pointer. `@unchecked Sendable`: the single field is an immutable `@Sendable`
/// closure — no locking needed, judgment matches ListViewModel's.
private final class CallbackBox: @unchecked Sendable {
    let invoke: @Sendable ([String]) -> Void
    init(_ f: @escaping @Sendable ([String]) -> Void) { invoke = f }
}

/// Boxes the pointer bundle the tear-down closure needs (the raw stream ref
/// and the boxed-callback context pointer). `@unchecked Sendable` with the
/// same judgment as CallbackBox: both fields are immutable C pointer values,
/// and the bundle is consumed EXACTLY ONCE by `makeLiveStream`'s single
/// invalidation path — no locking applies by construction.
private final class TeardownBundle: @unchecked Sendable {
    let ref: FSEventStreamRef
    let info: UnsafeMutableRawPointer
    init(ref: FSEventStreamRef, info: UnsafeMutableRawPointer) {
        self.ref = ref
        self.info = info
    }
}

/// `static let live`'s body, hoisted so the flag choice lives next to its
/// documentation, not inside a closure literal.
private func makeLiveStream(
    rootPaths: [String], latency: Double,
    callback: @escaping @Sendable ([String]) -> Void) -> StreamHandle? {
    // The factory never fabricates a stream over zero roots (the monitor
    // refuses empty starts before ever calling the factory — this is the
    // belt-and-braces copy of that rule inside the C-layer seam).
    guard !rootPaths.isEmpty else { return nil }

    // Heap box for the callback: unretained-context lifetime is managed by the
    // explicit passes below (passRetained at creation, exactly one release at
    // teardown or failure — never double, never leaked).
    let intake = CallbackBox(callback)
    let info = Unmanaged.passRetained(intake).toOpaque()

    // The C callback. Flag choices, each with its evidence:
    // - kFSEventStreamCreateFlagUseCFTypes — REQUIRED for the CFArray
    //   translation below. FSEvents.h's own contract: WITHOUT it the
    //   `eventPaths` payload is "a raw C array of raw C strings" (NOT a
    //   CFArray — translating it as one is a live crash, caught by probe), and
    //   WITH it the payload is "a CFArrayRef containing CFStringRef objects …
    //   ownership follows the Get rule, released by the framework after your
    //   callback returns". No other create flags (no FileEvents — the monitor
    //   watches directories, matching scan-root semantics; no IgnoreSelf —
    //   nothing here writes files; no history flags).
    // - sinceWhen = kFSEventStreamEventIdSinceNow — FUTURE events only: no
    //   history replay at start. (FSEvents.h: historical events are sent only
    //   when a concrete sinceWhen is supplied; SinceNow starts contemporary.)
    //   A replay would fabricate a "storm" of historical activity into the
    //   debounce window and could delay the first honest re-scan — refused by
    //   construction.
    let cCallback: FSEventStreamCallback = { _, clientInfo, _, eventPaths, _, _ in
        guard let clientInfo else { return }
        let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        var paths: [String] = []
        let count = CFArrayGetCount(cfArray)
        for index in 0 ..< count {
            guard let element = CFArrayGetValueAtIndex(cfArray, index) else { continue }
            paths.append(Unmanaged<CFString>.fromOpaque(element).takeUnretainedValue() as String)
        }
        Unmanaged<CallbackBox>.fromOpaque(clientInfo).takeUnretainedValue().invoke(paths)
    }

    var context = FSEventStreamContext(
        version: 0, info: info, retain: nil, release: nil, copyDescription: nil)
    guard let ref = FSEventStreamCreate(
        kCFAllocatorDefault, cCallback, &context, rootPaths as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes))
    else {
        // Create failed: the retained token was never handed to FSEvents —
        // release it here, return nil (the monitor's honest-failure branch).
        Unmanaged<CallbackBox>.fromOpaque(info).release()
        return nil
    }

    // The stream is serviced on a PRIVATE serial dispatch queue: callbacks
    // never fight the client's own queue, and teardown can synchronize against
    // any in-flight callback (FSEvents.h lifecycle: Stop → Invalidate →
    // Release; Stop "ensures the client's callback will not be called again").
    let queue = DispatchQueue(label: "io.appupdater.fsevents.monitor")
    FSEventStreamSetDispatchQueue(ref, queue)

    guard FSEventStreamStart(ref) else {
        // Created but never started: per FSEvents.h the stream still exists —
        // release it (release = refcount decrement to zero = deallocated) and
        // the retained token. A never-started stream needs no Stop/Invalidate:
        // nothing was scheduled or running.
        Unmanaged<CallbackBox>.fromOpaque(info).release()
        FSEventStreamRelease(ref)
        return nil
    }

    let bundle = TeardownBundle(ref: ref, info: info)
    return StreamHandle(invalidate: { [queue, bundle] in
        // Teardown runs ON the private queue so it serializes after any
        // in-flight callback; intake-liveness (monitor side) has ALREADY been
        // closed by then, so any callback racing teardown that somehow ran
        // would be dropped — never crash. Stop + Invalidate + Release in the
        // FSEvents.h-prescribed order; finally the retained intake token.
        // (The ref/info pointers ride inside `bundle`: raw C pointer types
        // carry no available Sendable conformance on this toolchain — Swift 6
        // reports the capture as an error — so the bundle boxes them with the
        // same documented judgment as CallbackBox.)
        queue.sync {
            FSEventStreamStop(bundle.ref)
            FSEventStreamInvalidate(bundle.ref)
            FSEventStreamRelease(bundle.ref)
            Unmanaged<CallbackBox>.fromOpaque(bundle.info).release()
        }
    })
}

/// Debounced FSEvents re-discovery monitor for the scan roots. See the file
/// header for the consent boundary, the design, and the honesty rules — this
/// doc comment holds only the public-surface contract.
///
/// Public surface a coordinator uses:
/// - `start(rootPaths:)` — begins watching (empty roots refused honesly; a
///   second start while running is a documented no-op, never a second stream).
/// - `stop()` — full teardown; idempotent; the monitor instance retires after
///   its channel finishes (one monitor = one channel lifetime).
/// - `events` — the debounced FileSystemEvent stream (unbounded buffering, so
///   a slow consumer never loses a burst; see the single-consumer note there).
/// - `isRunning` — lock-backed honest state; false before start, after stop,
///   after a failed factory, and after consumer termination.
///
/// The events stream is SINGLE-CONSUMER by design (the coordinator holds ONE
/// monitor per app lifetime and iterates `events` exactly once). Consumed to
/// completion, a SECOND iteration of the same stream yields zero events and
/// terminates immediately — the probe-proven AsyncStream successor semantics,
/// documented here as the honest contract instead of left implicit.
public final class FileSystemMonitor: @unchecked Sendable {

    /// The FSEvents construction seam. `live` in production; fakes in tests.
    public let factory: FSEventStreamFactory

    /// Wall-clock source: stamps every intake batch and window boundary.
    public let clock: @Sendable () -> Date

    /// Quiescence primitive: waits out one debounce window. The loop treats
    /// this seam as the one suspension point that honors cancellation.
    public let sleep: @Sendable (TimeInterval) async throws -> Void

    /// Debounce window in seconds. NON-POSITIVE values are clamped to zero at
    /// init: zero means "no debounce" — each raw batch anchors a window that
    /// closes immediately, so batches still land one-per-window rather than
    /// crashing or hanging. Production wiring keeps the 2.0 default; the clamp
    /// is documented honesty, not a silent fix-up of caller math.
    public let debounceInterval: TimeInterval

    /// Lock-backed honest running state. A stored Bool would be a plain data
    /// race across the intake/emission/stop domains — the value lives in
    /// `LifecycleState` behind the NSLock and every read traverses it.
    public var isRunning: Bool { lifecycle.isRunning() }

    /// The debounced event stream. Unbounded buffering: a burst emitted while
    /// the consumer is doing anything never drops. Single consumer (see the
    /// class doc); re-iterating a consumed stream terminates immediately.
    public private(set) var events: AsyncStream<FileSystemEvent>
    private let eventsContinuation: AsyncStream<FileSystemEvent>.Continuation

    private let pending: PendingBatches
    private let lifecycle = LifecycleState()

    /// Full-injection init (tests / hermetic environments). Defaults are the
    /// production seams — `.live` factory, real clock/sleep, 2 s window.
    /// Swift 6.4 public-init gotcha honored: no default references an internal
    /// member; every closure literal is written inline with its `@Sendable`
    /// type (an explicit constant instead of a ternary — per the gotcha ledger).
    public init(
        factory: FSEventStreamFactory = .live,
        clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { interval in
            try await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
        },
        debounceInterval: TimeInterval = 2.0
    ) {
        self.factory = factory
        self.clock = clock
        self.sleep = sleep
        self.debounceInterval = max(0, debounceInterval)
        let made = AsyncStream.makeStream(of: FileSystemEvent.self, bufferingPolicy: .unbounded)
        self.events = made.stream
        self.eventsContinuation = made.continuation
        self.pending = PendingBatches()
        // Consumer termination (cancel or ordinary end) retires the monitor —
        // the channel's lifetime IS the monitor's lifetime. Wake the parked
        // emitter immediately so the loop never outlives its audience, and do
        // the heavy teardown (FSEvents queue sync) detached. The handler sits
        // on the CONTINUATION (like ScheduleEngine's stream), not on the
        // stream value — that is where AsyncStream exposes termination.
        eventsContinuation.onTermination = { [self] _ in
            lifecycle.peekRunner()?.cancel()
            pending.finish()
            Task.detached(priority: .utility) { self.orderlyStop() }
        }
    }

    // MARK: - Start / stop

    /// Starts watching the given roots and spawns the emission loop. Empty
    /// root lists are refused BEFORE the factory is consulted (honest: not a
    /// failure, no stream finished); a factory nil finishes the channel and
    /// retires the instance; a concurrent stop loses the commit race and the
    /// freshly built handle is disposed immediately — never leaked, never a
    /// zombie stream. `async` for the coordinator's ergonomics; the fast paths
    /// of the body never suspend.
    public func start(rootPaths: [String]) async {
        guard !rootPaths.isEmpty else { return } // refusal: see file header honesty table
        guard lifecycle.claimStart() else { return }

        let intake: @Sendable ([String]) -> Void = { [pending, lifecycle, clock] paths in
            guard lifecycle.intakeIsOpen() else { return } // post-stop: dropped, never crash
            guard !paths.isEmpty else { return } // empty batches: nothing to re-scan
            pending.append(paths: paths, stamp: clock())
        }

        guard let handle = factory.makeStream(rootPaths, debounceInterval, intake) else {
            lifecycle.abandonStart() // isRunning stays false; instance retires
            eventsContinuation.finish() // honest failing start: iterator finishes
            return
        }

        let runner = Task.detached(priority: .utility) { [self] in
            await runEmissionLoop()
        }
        let stale = lifecycle.commitStart(handle: handle, runner: runner)
        if let stale = stale {
            // orderlyStop won the race during construction: dispose instantly.
            stale.invalidate()
            runner.cancel()
        }
    }

    /// Full teardown: intake closed first (late callbacks dropped), the native
    /// stream invalidated, the events channel finished (in-flight window
    /// discarded — it never became quiet, so nothing honest to emit),
    /// `isRunning` false. Idempotent.
    public func stop() async {
        orderlyStop()
    }

    private func orderlyStop() {
        guard let ended = lifecycle.beginOrderlyStop() else { return }
        ended.runner?.cancel()
        pending.finish() // wakes the parked emitter; future intake dropped
        if ended.finishChannel {
            eventsContinuation.finish() // no-op-safe even post-termination (probe)
        }
        ended.handle?.invalidate()
    }

    // MARK: - Emission loop

    /// The debounce loop (runs detached, utility priority — a background
    /// scheduler task with Sendable captures only, ScheduleEngine-style):
    ///
    /// 1. Wait for the first undrained batch (parks; wakes on intake or stop).
    /// 2. Anchor the window at that batch; merge it; compute the close time.
    /// 3. `sleep(debounceInterval)` — the honoree of cancellation; a throw
    ///    exits without emitting (in-flight window discarded, documented).
    /// 4. Drain every unconsumed batch stamped ≤ windowClose (later stamps
    ///    anchor the NEXT event — never merged backward).
    /// 5. Emit one FileSystemEvent (empty unions are impossible — intake drops
    ///    empty batches — but the guard is kept as a last-resort honesty net).
    private func runEmissionLoop() async {
        var consumed = 0
        while true {
            guard let first = await pending.waitNext(index: consumed) else { break }
            guard !Task.isCancelled else { break } // stop's cancel: window discarded
            consumed += 1

            var merged: [String] = []
            var mergeCount = 0
            var latest = first.stamp
            for path in first.paths where !merged.contains(path) {
                merged.append(path)
            }
            mergeCount += 1
            let windowClose = first.stamp.addingTimeInterval(debounceInterval)

            do {
                try await sleep(debounceInterval)
            } catch {
                break // cancelled mid-window: honest discard (file header)
            }

            while let next = pending.takeNext(matching: consumed, stampNotAfter: windowClose) {
                consumed += 1
                for path in next.paths where !merged.contains(path) {
                    merged.append(path)
                }
                mergeCount += 1
                if next.stamp > latest { latest = next.stamp }
            }

            guard !merged.isEmpty else { continue }
            eventsContinuation.yield(
                FileSystemEvent(occurredAt: latest, paths: merged, batchesCoalesced: mergeCount))
        }
    }
}

// MARK: - Pending batches (intake buffer + single-park waiter)

/// The intake log. A FIFO of stamped raw batches plus ONE park slot for the
/// emission loop's next-window wait. `@unchecked Sendable`: every field is
/// read/written only under `lock`, which is never held across a suspension
/// point; the parked continuation is installed and the lock released INSIDE
/// the (synchronous) continuation body so there is no lost-wake window.
private final class PendingBatches: @unchecked Sendable {
    struct Raw: Sendable {
        let stamp: Date
        let paths: [String]
    }

    private let lock = NSLock()
    private var batches: [Raw] = []
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?

    /// Appends a raw batch (stamped by the injected clock at intake time) and
    /// wakes a parked waiter if any. Dropped silently after `finish()` — the
    /// post-stop honesty rule.
    func append(paths: [String], stamp: Date) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        batches.append(Raw(stamp: stamp, paths: paths))
        let cont = waiter
        waiter = nil
        lock.unlock()
        cont?.resume()
    }

    /// Closes the intake: no more batches accepted, waiters woken.
    /// Idempotent — the two wake paths (stop, consumer termination) may both
    /// reach it.
    func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let cont = waiter
        waiter = nil
        lock.unlock()
        cont?.resume()
    }

    /// The emission loop's "wait for undrained data" primitive. Returns the
    /// batch at `index` without suspending when present; `nil` when the intake
    /// finished; otherwise parks ONCE and re-checks on wake. Single-consumer
    /// contract: only the emission loop calls this, so the waiter slot can
    /// never be contended (debug-asserted). NSLock is unavailable from async
    /// contexts (this SDK), so the async function touches the lock ONLY
    /// through synchronous helpers below.
    func waitNext(index: Int) async -> Raw? {
        while true {
            let immediate = immediateNext(index: index)
            if let value = immediate.value { return value }
            if immediate.finished { return nil }
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                park(cont: cont, index: index) // synchronous body
            }
            // Woken (or race-satisfied inside park): loop re-probes.
        }
    }

    /// Synchronous probe: data present → batch; finished; else wait.
    private struct Immediate {
        let value: Raw?
        let finished: Bool
    }

    private func immediateNext(index: Int) -> Immediate {
        lock.lock()
        defer { lock.unlock() }
        if index < batches.count {
            return Immediate(value: batches[index], finished: false)
        }
        return Immediate(value: nil, finished: finished)
    }

    /// Synchronous park body — no suspension inside, so the lock call is
    /// legal. Under ONE lock acquisition it re-checks the data state (covering
    /// the race window between the probe releasing the lock and this body
    /// re-acquiring it) and either resumes instantly or installs the waiter —
    /// no lost-wake window by construction.
    private func park(cont: CheckedContinuation<Void, Never>, index: Int) {
        lock.lock()
        defer { lock.unlock() }
        if index < batches.count || finished {
            cont.resume()
            return
        }
        assert(waiter == nil, "PendingBatches is single-consumer by contract")
        waiter = cont
    }

    /// Peek-and-consume for the window drain: returns the batch at `index` iff
    /// its stamp is inside the closing window, else nil (the NEXT window's
    /// problem). The CALLER owns advancing the consume index.
    func takeNext(matching index: Int, stampNotAfter close: Date) -> Raw? {
        lock.lock()
        defer { lock.unlock() }
        guard index < batches.count else { return nil }
        let candidate = batches[index]
        guard candidate.stamp <= close else { return nil }
        return candidate
    }
}

// MARK: - Lifecycle state (the locked slide of monitor truth)

/// Everything mutable about the monitor's existence, confined behind one NSLock:
/// the claim→commit/abandon start handshake (which makes concurrent `stop()`
/// races dispose the fresh handle instead of leaking it), the running/intake
/// flags, and the one-shot teardown bookkeeping. `@unchecked Sendable` with the
/// same judgment as `PendingBatches`: no field leaves the lock unprotected,
/// the lock is never held across a suspension point.
private final class LifecycleState: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false // start() in flight (claim → commit)
    private var running = false // isRunning read by the public property
    private var intakeOpen = false // guards the intake callback after stop
    private var channelFinished = false // events channel closed once, ever
    private var tearingDown = false // orderlyStop is one-shot
    private var handle: StreamHandle?
    private var runner: Task<Void, Never>?

    func isRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func intakeIsOpen() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return intakeOpen
    }

    /// Claims the start slot atomically. A second start while a claim is
    /// in flight — or into a tearing-down / retired instance — is refused.
    func claimStart() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !started, !tearingDown, !channelFinished else { return false }
        started = true
        return true
    }

    /// The factory refused: honest failure. `started` stays true (the instance
    /// retires — its channel is finished), `isRunning` was never true.
    func abandonStart() {
        lock.lock(); defer { lock.unlock() }
        channelFinished = true
    }

    /// Commits a successfully-built stream. Returns the handle BACK (for the
    /// caller to invalidate immediately) when a concurrent stop won the race —
    /// i.e. teardown started while the factory was constructing. The runner is
    /// cancelled here too; its loop then exits via the finished intake log.
    func commitStart(handle: StreamHandle, runner: Task<Void, Never>) -> StreamHandle? {
        lock.lock()
        guard !tearingDown, !channelFinished else {
            lock.unlock()
            runner.cancel()
            return handle
        }
        self.handle = handle
        self.runner = runner
        self.intakeOpen = true
        self.running = true
        lock.unlock()
        return nil
    }

    /// Runner read for consumer-termination (cancel before teardown wins).
    func peekRunner() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        return runner
    }

    /// One-shot teardown entry: consumes handle + runner, closes intake and
    /// running, and answers whether the CHANNEL still needs a finish (it does
    /// not if the channel was finished another way, e.g. failed factory).
    struct Stopped: Sendable {
        let handle: StreamHandle?
        let runner: Task<Void, Never>?
        let finishChannel: Bool
    }

    func beginOrderlyStop() -> Stopped? {
        lock.lock()
        guard !tearingDown else { lock.unlock(); return nil }
        tearingDown = true
        let stopped = Stopped(
            handle: handle,
            runner: runner,
            finishChannel: !channelFinished)
        handle = nil
        runner = nil
        intakeOpen = false
        running = false
        channelFinished = true
        lock.unlock()
        return stopped
    }
}
