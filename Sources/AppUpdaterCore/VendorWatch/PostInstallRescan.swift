// PostInstallRescan.swift — poll-based directory watch for the vendor-installer
// flow (GAP #13, lane vendor-rules). Concept source: MACUPDATER-FINDINGS.md
// §5 step 9 — after `open`-ing a vendor installer, MacUpdater marks the app
// waiting-for-installer and `watchForExternalUpdateOfApp:` observes the old
// path, auto-rescanning once the user runs the vendor installer. We adapt the
// CONCEPT with our own semantics:
//
//   • POLL-BASED, no FSEvents. FileSystemMonitor (GAP #17) already covers the
//     scan roots and is governed by LOCKED decision 13 (FS events = inventory
//     re-scan only, never installs/checks/schedules). This module therefore
//     uses NO event system at all: a caller-driven poll loop with an
//     injectable clock and an injectable async wait.
//   • NO TIMERS STARTED HERE. The module is pure functions over injected
//     seams: `clock: () -> Date` reads time, `wait: (TimeInterval) async -> Void`
//     sleeps between polls, `probe` looks at the filesystem. Callers (and
//     tests) supply all three; nothing is scheduled in the background.
//   • HONEST OUTCOMES ONLY. "App appeared" is reported with the matched
//     bundle's path + claimed identifier; "not yet" expires into a timeout
//     report carrying the last probe's verbatim notes; a probe that cannot
//     run (missing/unreadable directory) is reported IMMEDIATELY as a
//     probe failure — never silently retried into a timeout, because a
//     broken probe must not be laundered into "the app never appeared".
//     The coordinator decides what a rescan trigger does; this module only
//     reports what it saw.
//   • Matching is by bundle IDENTIFIER (the expected bundle's Info.plist
//     CFBundleIdentifier read from each `.app` bundle directly inside the
//     expected directory — one level, no recursion). The expected app NAME is
//     a display hint only: vendor installers may rename the bundle.
//
// Pure by construction: read-only probes, no processes, no network, no
// writes, no timers. Hermetic by design: every seam is injectable, so tests
// drive the loop with fake clocks and stateful fake probes.

import Foundation

// MARK: - Watch target

/// What the watch looks for: a bundle with `expectedBundleIdentifier`
/// appearing (directly) inside `expectedDirectory`. Codable + Hashable — the
/// vendor-installer staging embeds one, and a coordinator may persist the
/// pair for a later rescan trigger.
public struct PostInstallWatchTarget: Codable, Hashable, Sendable {
    /// Directory the app is EXPECTED to appear in (an expectation, not a
    /// guarantee — the watch reports honestly what it sees).
    public let expectedDirectory: String
    /// The bundle identifier expected after the vendor install (typically
    /// the currently installed app's — some vendors change it; a changed BID
    /// simply reports "not yet" honestly until timeout).
    public let expectedBundleIdentifier: String
    /// Display hint only (e.g. "Foo.app"); matching never uses it.
    public let expectedAppBundleName: String

    public init(expectedDirectory: String,
                expectedBundleIdentifier: String,
                expectedAppBundleName: String) {
        self.expectedDirectory = expectedDirectory
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.expectedAppBundleName = expectedAppBundleName
    }
}

// MARK: - Probe seam

/// One probe observation. `found` carries the matched bundle's path and its
/// claimed identifier; `notFound` carries verbatim notes about what WAS seen;
/// `failed` means the probe could not run at all (directory missing/unreadable)
/// — an honest terminal state, never a guess and never a silent retry.
public enum PostInstallProbeOutcome: Hashable, Sendable {
    case found(bundlePath: String, bundleIdentifier: String)
    case notFound(notes: [String])
    case failed(reason: String)
}

// MARK: - Watch report

/// The watch's terminal report. Codable + Hashable for receipt persistence.
public struct PostInstallWatchReport: Codable, Hashable, Sendable {
    /// Terminal outcome. Codable is compiler-synthesized (Swift enum with
    /// associated values): each case encodes as a keyed entry named after the
    /// case, e.g. {"appeared": {"matchedBundlePath": …, "matchedBundleIdentifier": …}}.
    public enum Terminal: Codable, Hashable, Sendable {
        /// The expected bundle appeared inside the expected directory.
        case appeared(matchedBundlePath: String, matchedBundleIdentifier: String)
        /// Polls ran out before the app appeared; the last probe's notes
        /// travel verbatim.
        case timedOut(lastProbeNotes: [String])
        /// The probe could not run; reported immediately (no retry), reason
        /// verbatim.
        case probeFailed(reason: String)
    }

    /// The target as watched (verbatim from the caller).
    public let target: PostInstallWatchTarget
    /// Terminal outcome.
    public let outcome: Terminal
    /// How many probes actually ran.
    public let pollsCompleted: Int
    /// Clock-injected start/end stamps (production clock: real time; tests:
    /// whatever the fake says).
    public let startedAt: Date
    public let endedAt: Date
    /// The poll interval and timeout exactly as the caller set them.
    public let pollInterval: TimeInterval
    public let timeout: TimeInterval
    /// Honesty notes about the loop itself (e.g. clamped/zero intervals).
    public let notes: [String]

    public init(target: PostInstallWatchTarget,
                outcome: Terminal,
                pollsCompleted: Int,
                startedAt: Date,
                endedAt: Date,
                pollInterval: TimeInterval,
                timeout: TimeInterval,
                notes: [String]) {
        self.target = target
        self.outcome = outcome
        self.pollsCompleted = pollsCompleted
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.notes = notes
    }
}

// MARK: - The watch

public enum PostInstallRescan {

    /// Production wait seam: async sleep between polls. Negative intervals
    /// are a no-op (the caller may legitimately pass 0); absurdly large ones
    /// are capped at one hour per poll to keep the nanosecond conversion
    /// overflow-free.
    public static let defaultWait: @Sendable (TimeInterval) async -> Void = { interval in
        let clamped = min(max(interval, 0), 3600)
        guard clamped > 0 else { return }
        let nanoseconds = UInt64(clamped * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    /// Production probe seam: read-only directory scan (see
    /// `defaultDirectoryProbe`).
    public static let defaultProbe: @Sendable (PostInstallWatchTarget) -> PostInstallProbeOutcome = { target in
        Self.defaultDirectoryProbe(target)
    }

    /// Poll until the expected bundle appears, the probe fails, or the
    /// timeout expires. Semantics, exactly:
    ///
    ///   1. `startedAt = clock()`; deadline = startedAt + timeout.
    ///   2. Probe FIRST (a zero/negative timeout still probes exactly once —
    ///      "timeout ≤ 0" means "single check", documented).
    ///   3. found → terminal `.appeared`. failed → terminal `.probeFailed`
    ///      IMMEDIATELY (a broken probe is never laundered into a timeout).
    ///   4. notFound → if `clock() >= deadline`, terminal `.timedOut` with the
    ///      last notes; otherwise `await wait(pollInterval)` and poll again.
    ///
    /// A non-positive `pollInterval` is honored as "no wait between polls"
    /// (busy-polling is the caller's choice) and recorded in `notes`.
    public static func watch(
        target: PostInstallWatchTarget,
        pollInterval: TimeInterval,
        timeout: TimeInterval,
        clock: @escaping @Sendable () -> Date = { Date() },
        wait: @escaping @Sendable (TimeInterval) async -> Void = PostInstallRescan.defaultWait,
        probe: @escaping @Sendable (PostInstallWatchTarget) -> PostInstallProbeOutcome = PostInstallRescan.defaultProbe
    ) async -> PostInstallWatchReport {
        var notes: [String] = []
        if pollInterval <= 0 {
            notes.append("pollInterval \(pollInterval) ≤ 0 — polls run back-to-back with no injected wait (caller-set busy polling)")
        }
        if timeout <= 0 {
            notes.append("timeout \(timeout) ≤ 0 — exactly one probe will run (single-check semantics, documented)")
        }

        let startedAt = clock()
        let deadline = startedAt.addingTimeInterval(timeout)
        var polls = 0
        var lastNotes: [String] = []

        while true {
            polls += 1
            let observation = probe(target)
            switch observation {
            case .found(let path, let bid):
                return PostInstallWatchReport(
                    target: target,
                    outcome: .appeared(matchedBundlePath: path, matchedBundleIdentifier: bid),
                    pollsCompleted: polls,
                    startedAt: startedAt,
                    endedAt: clock(),
                    pollInterval: pollInterval,
                    timeout: timeout,
                    notes: notes)
            case .failed(let reason):
                notes.append("probe failed on poll \(polls) — reported immediately, not retried (a broken probe must not "
                    + "be laundered into a timeout)")
                return PostInstallWatchReport(
                    target: target,
                    outcome: .probeFailed(reason: reason),
                    pollsCompleted: polls,
                    startedAt: startedAt,
                    endedAt: clock(),
                    pollInterval: pollInterval,
                    timeout: timeout,
                    notes: notes)
            case .notFound(let foundNotes):
                lastNotes = foundNotes
                if clock() >= deadline {
                    notes.append("deadline reached after \(polls) probe(s) without the expected bundle appearing")
                    return PostInstallWatchReport(
                        target: target,
                        outcome: .timedOut(lastProbeNotes: lastNotes),
                        pollsCompleted: polls,
                        startedAt: startedAt,
                        endedAt: clock(),
                        pollInterval: pollInterval,
                        timeout: timeout,
                        notes: notes)
                }
                await wait(pollInterval)
            }
        }
    }

    // MARK: - Default probe

    /// The production probe: enumerate the DIRECT children of the expected
    /// directory whose names end in ".app", read each bundle's
    /// `Contents/Info.plist` CFBundleIdentifier, and match against the
    /// target's expected identifier. One level, no recursion — a vendor
    /// installer writes the app directly into the directory. Unreadable
    /// bundles/mini-plists are skipped but NAMED verbatim in the notes
    /// (honesty: what could not be read must be visible). A directory that
    /// cannot be enumerated is a `failed` with the verbatim reason.
    public static func defaultDirectoryProbe(_ target: PostInstallWatchTarget) -> PostInstallProbeOutcome {
        let directory = URL(fileURLWithPath: target.expectedDirectory)
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [])
        } catch {
            return .failed(reason: "could not enumerate expected directory '\(target.expectedDirectory)': \(error)")
        }
        var notes: [String] = []
        for entry in entries {
            guard entry.pathExtension.lowercased() == "app" else { continue }
            let plistURL = entry.appendingPathComponent("Contents/Info.plist")
            let data: Data
            do {
                data = try Data(contentsOf: plistURL)
            } catch {
                notes.append("bundle '\(entry.lastPathComponent)' unreadable at Info.plist: \(error)")
                continue
            }
            let plist: [String: Any]
            do {
                var format: PropertyListSerialization.PropertyListFormat = .binary
                let raw = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
                guard let dict = raw as? [String: Any] else {
                    notes.append("bundle '\(entry.lastPathComponent)' Info.plist is not a dictionary — skipped, unmatchable")
                    continue
                }
                plist = dict
            } catch {
                notes.append("bundle '\(entry.lastPathComponent)' Info.plist unparseable: \(error)")
                continue
            }
            let claimed = plist["CFBundleIdentifier"] as? String
            guard let claimed, !claimed.isEmpty else {
                notes.append("bundle '\(entry.lastPathComponent)' declares no CFBundleIdentifier — skipped, unmatchable")
                continue
            }
            if claimed == target.expectedBundleIdentifier {
                return .found(bundlePath: entry.path, bundleIdentifier: claimed)
            }
            notes.append("bundle '\(entry.lastPathComponent)' claims '\(claimed)' ≠ expected '\(target.expectedBundleIdentifier)'")
        }
        return .notFound(notes: notes)
    }
}
