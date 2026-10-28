// Brew tier: Homebrew PIN AWARENESS — the pinned-set parser + the pinned-file
// watcher (GAP-ANALYSIS #2 remainder; the adopt half shipped in MASAdopt.swift).
//
// EVIDENCE (docs/reverse/UPDATEST-FINDINGS.md §3.2, [confirmed] literals):
// Updatest keeps `pinnedFormulae` / `pinnedCasks` sets and watches the pinned
// location ("Detected pin change: ", `pinWatcherTasks`, `ignoredPinned`); the
// watch paths it hardcodes are `/var/homebrew/pinned` and
// `/var/homebrew/pinned_casks` — flagged **[unverified]** Workbrew-specific
// (§5 note 8), so THIS lane does NOT hardcode that prefix. The prefix is
// resolved at runtime through the injected process-runner seam running
// `brew --prefix`, and the pin files are prefix-relative (`<prefix>/pinned` for
// formulae, `<prefix>/pinned_casks` for casks — the Updatest layout with the
// prefix substituted; standard OSS Homebrew simply has no such files, and a
// missing file observes as "no pins", never an error).
//
// CONSENT BOUNDARY (LOCKED, repo-wide): pins are READ-ONLY. The parser is pure
// text → sets; the watcher only stat()s file mtimes and fires a callback.
// NEITHER ever executes brew, mas, or any install/update — command execution
// stays with the owner, and the ONLY sanctioned execution path in this repo is
// MASAdopt's staged-command pattern (which stages a string, never runs it).
// Whoever consumes the watcher's callback re-affirms this boundary in writing
// at the wiring site (FileSystemMonitor precedent).
//
// PARSER CONTRACT: the input is captured `brew list --pinned` output (the
// documented command string). OSS brew prints bare pinned-formula names, one
// per line, with NO section headers; the Workbrew/Updatest layout separates
// formulae from casks. Both shapes parse:
//   - a `==> <name>` line is a SECTION header: `Formulae` (or `Formula`)
//     routes the following lines to the formulae set, `Casks` to the cask
//     set; any other header is noted and does NOT switch the current section.
//   - headerless lines land in the formulae set (OSS shape).
//   - a pin NAME is a single whitespace-free token (brew token charset:
//     letters, digits, @ + . _ - and `/` for tap-qualified forms). Anything
//     else (warnings, binary junk, prose) is SKIPPED with a note — never
//     guessed into a pin. Input that yields no names at all yields honest
//     empty sets + the notes that say why.
//
// WATCHER SEAMS (ScheduleEngine-style, injected, all Sendable — deterministic
// tests with ZERO real time):
//   - `formulaePinsURL` / `casksPinsURL` — the pinned file locations (the
//     injected file-URL seam; production builds them from `brew --prefix`).
//   - `clock` — "now" stamped on every observation (default `Date()`).
//   - `sleep` — the poll-interval quiescence primitive (default `Task.sleep`).
// The initial mtime pair is recorded at start WITHOUT firing: a change is a
// DELTA of the two mtimes from the last observation (the observedAt stamp is
// never part of that comparison — every poll carries a fresh stamp by
// definition), so a freshly started watcher reports
// nothing until something actually moves. Cancellation surfaces at the sleep
// (the loop's one suspension point that honors it) and the loop exits.

import Foundation

// MARK: - Pin sets (the parsed currency)

/// The pinned sets, exactly as brew reported them (verbatim names, no
/// normalization — honesty about what the output said). `Hashable` so a
/// watcher can compare observations and a coordinator can diff snapshots.
public struct BrewPins: Sendable, Hashable {
    /// Pinned formula names (from the formulae section / headerless lines).
    public var formulae: Set<String>
    /// Pinned cask tokens (from the casks section; empty for plain OSS output,
    /// which never carries a cask section).
    public var casks: Set<String>

    public init(formulae: Set<String> = [], casks: Set<String> = []) {
        self.formulae = formulae
        self.casks = casks
    }

    /// True when neither set holds a pin.
    public var isEmpty: Bool { formulae.isEmpty && casks.isEmpty }
}

/// One parse outcome: the sets PLUS the honest notes (what was skipped and
/// why). Notes make "malformed input" observable instead of silently eaten.
public struct BrewPinsParseResult: Sendable, Hashable {
    public let pins: BrewPins
    public let notes: [String]

    public init(pins: BrewPins, notes: [String] = []) {
        self.pins = pins
        self.notes = notes
    }
}

// MARK: - Parser (pure)

public enum BrewPinsParser {

    /// Parses captured `brew list --pinned` output into pinned sets. Total:
    /// never throws, never traps — every line is either a header, a name, a
    /// blank, or a noted-and-skipped non-name.
    public static func parse(_ output: String) -> BrewPinsParseResult {
        var pins = BrewPins()
        var notes: [String] = []
        var section: Section = .formulae // OSS shape: headerless lines are pinned formulae
        var sawName = false

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("==>"),
               let header = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
               .split(separator: " ").first.map(String.init) {
                let parsed = Self.section(for: header)
                switch parsed {
                case .formulae, .casks:
                    section = parsed
                case .other:
                    // An unrecognized header does not switch sections (its
                    // lines would be misrouted) — noted, lines still parsed
                    // into the current section as best-effort names.
                    notes.append("ignored unrecognized section header '\(header)'")
                }
                continue
            }

            guard Self.isValidPinName(line) else {
                notes.append("skipped non-pin line '\(line)'")
                continue
            }
            sawName = true
            switch section {
            case .formulae: pins.formulae.insert(line)
            case .casks: pins.casks.insert(line)
            case .other: break // unreachable: switch above never assigns .other
            }
        }

        // Honest empty: non-empty input that produced zero names must SAY so,
        // not hand back a silently-empty verdict.
        if !sawName,
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notes.append("no pinned names found in the captured output")
        }
        return BrewPinsParseResult(pins: pins, notes: notes)
    }

    private enum Section { case formulae, casks, other }

    private static func section(for header: String) -> Section {
        let lowered = header.lowercased()
        if lowered == "formulae" || lowered == "formula" { return .formulae }
        if lowered == "casks" || lowered == "cask" { return .casks }
        return .other
    }

    /// A brew pin name: one whitespace-free token over the brew token charset
    /// (letters, digits, @ + . _ and `/` for tap-qualified forms). Anything
    /// else is prose/warnings/junk and is never parsed into a pin.
    static func isValidPinName(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@+._-/")
        return line.allSatisfy { allowed.contains($0) }
    }
}

// MARK: - Prefix resolution (runtime, never hardcoded)

/// Resolves the Homebrew prefix at runtime through the injected runner seam
/// running `brew --prefix` (PATH-resolved via /usr/bin/env — the owner's brew,
/// no hardcoded install root, no /var/homebrew). Returns nil on any failure:
/// brew missing, non-zero exit, or empty output — never a guessed prefix.
public struct BrewPrefixResolver: Sendable {

    public let runner: BrewProcessRunner

    public init(runner: BrewProcessRunner) {
        self.runner = runner
    }

    /// The prefix URL, or nil with the honest reason unavailable (callers that
    /// need a reason can run the seam themselves; this type's job is the
    /// location only). The runner's environment is passed through unchanged —
    /// prefix resolution carries no hardening (it is not a brew *operation*,
    /// just a path probe).
    public func resolve() async -> URL? {
        guard let run = try? await runner.run(
            BrewProcessRunner.envLaunchPath,
            ["brew", "--prefix"],
            ProcessInfo.processInfo.environment)
        else { return nil }
        guard run.exitStatus == 0 else { return nil }
        let trimmed = run.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    /// The prefix-relative pinned locations (the Updatest layout with the
    /// runtime-resolved prefix substituted — see header). Missing files are
    /// legal observations ("no pins"), not errors.
    public static func pinnedFileURLs(prefix: URL) -> (formulae: URL, casks: URL) {
        (prefix.appendingPathComponent("pinned"), prefix.appendingPathComponent("pinned_casks"))
    }
}

// MARK: - Watcher

/// What a pin poll observed at one instant: both pinned files' mtimes as of
/// `observedAt` (nil = the file does not exist — an honest "no pins recorded",
/// distinct from a zero date). Hashable so the loop can detect deltas.
public struct BrewPinsObservation: Sendable, Hashable {
    public let formulaeMtime: Date?
    public let casksMtime: Date?
    public let observedAt: Date

    public init(formulaeMtime: Date?, casksMtime: Date?, observedAt: Date) {
        self.formulaeMtime = formulaeMtime
        self.casksMtime = casksMtime
        self.observedAt = observedAt
    }
}

/// Polls the pinned files' mtimes on an interval and fires the change callback
/// on every DELTA (either file's mtime moved, or a file appeared/vanished).
/// Read-only to the bone: it stats two files and nothing else — it does not
/// parse, does not run brew, does not decide anything. The callback is the
/// sole output; whoever consumes it re-affirms the consent boundary in
/// writing at the wiring site.
public struct BrewPinWatcher: Sendable {

    /// Poll interval in seconds (the quiescence primitive's argument). No
    /// floor is enforced here — the caller owns the cadence decision; the
    /// documented Updatest behavior is event-driven watching with polling
    /// fallback, and the coordinator wiring picks a sane interval.
    public let interval: TimeInterval
    public let formulaePinsURL: URL
    public let casksPinsURL: URL
    public let clock: @Sendable () -> Date
    public let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        interval: TimeInterval,
        formulaePinsURL: URL,
        casksPinsURL: URL,
        clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.interval = interval
        self.formulaePinsURL = formulaePinsURL
        self.casksPinsURL = casksPinsURL
        self.clock = clock
        self.sleep = sleep
    }

    /// Starts the poll loop. The INITIAL observation is recorded silently
    /// (baseline, not a change); every later delta fires the callback. Cancel
    /// the returned task to stop — cancellation surfaces at the sleep and the
    /// loop exits without firing.
    public func start(
        onChange: @escaping @Sendable (BrewPinsObservation) -> Void
    ) -> Task<Void, Never> {
        Task { await self.loop(onChange: onChange) }
    }

    private func loop(onChange: @escaping @Sendable (BrewPinsObservation) -> Void) async {
        var last = observe()
        while true {
            do { try await sleep(interval) } catch { return } // cancelled → exit, nothing fired
            let current = observe()
            // The delta is the WATCHED STATE (the two mtimes) alone — the
            // observedAt stamp is never part of the comparison (every poll has
            // a new stamp by definition; comparing it would fire on every
            // quiet poll and fabricate "changes" out of clock time).
            guard current.formulaeMtime != last.formulaeMtime
                || current.casksMtime != last.casksMtime else { continue }
            last = current
            onChange(current)
        }
    }

    /// One mtime snapshot of both pinned locations (missing file → nil mtime).
    func observe() -> BrewPinsObservation {
        BrewPinsObservation(
            formulaeMtime: Self.mtime(of: formulaePinsURL),
            casksMtime: Self.mtime(of: casksPinsURL),
            observedAt: clock())
    }

    private static func mtime(of url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }
}
