// RuleStore.swift — per-app ignore/version/auto-check rules with honest persistence.
// Phase 4 Lane 2 (Rules + persistence). Reads the FROZEN interchange types in
// Model/ScheduleStore.swift (IgnoreRule / RuleKind / RuleDecision / AppRow /
// SchedulePolicy) — that file is coordinator-owned and never edited here.
//
// Persistence layout (documents the contract asserted by RuleStoreTests):
//   Directory:  default ~/Library/Application Support/AppUpdater  (or init seam)
//   File:       rules.json — JSONEncoder [.prettyPrinted, .sortedKeys], default
//               date strategy (secondsSinceReferenceDate, full-precision round-trip)
//
// Honest-behavior rules:
//   - A read-only environment must never create directories: init and load()
//     touch nothing on disk; the directory is created lazily on FIRST save only.
//   - Missing rules.json            → load returns [] (absence is honest).
//   - Unparseable rules.json        → load returns [], logs, and the next save
//     replaces the file's bytes with the canonical encoding (never a crash,
//     never a partial parse — JSONDecoder decodes all-or-nothing).
//   - Sanitization happens on every load and save: duplicates on the identity
//     (kind, bundleIdentifier, version) collapse keeping the OLDEST createdAt;
//     the list is capped at 500 rules dropping the OLDEST beyond the cap;
//     ordering is canonical (kind rawValue ascending, then bundleIdentifier,
//     then version, nil sorted first, then createdAt). Every drop and every
//     unparseable replacement is logged — never silent.
//   - Log surface: os.Logger subsystem "io.appupdater.AppUpdater", category
//     "rules". Documented lines:
//       "rules.json unparseable (<reason>) — treating as empty; next save replaces it"
//       "rules dedupe: collapsed N duplicate rule(s)"
//       "rules cap: dropped N oldest rule(s) beyond the 500 limit"
//       "rules load failed: <error>" (batch evaluate path only)
//   - Writes are atomic: staging file in the target directory written through
//     FileManager.createFile + FileHandle, then swapped in with
//     FileManager.replaceItemAt (target exists) or moveItem (first write).
//     A failed write never corrupts the previous good file.
//   - Mutation API is save-through: every mutation persists immediately and
//     returns the resulting (sanitized) set for UI binding. Persistence
//     failures throw — a rule the user asked to set MUST surface its failure,
//     not vanish silently into memory-only state.

import Foundation
import os

/// Per-app rule store: ignoreBundle / ignoreVersion / autoCheck rules over the
/// frozen `IgnoreRule` shape, persisted to a single `rules.json` file.
/// `Sendable` by construction: all state is immutable after init; every method
/// re-derives from disk so concurrent UI callers always see one truth.
public struct RuleStore: Sendable {
    /// Number of rules the sanitizer keeps. Oldest `createdAt` rows are dropped
    /// beyond this cap (documented + logged, never silent).
    static let ruleLimit = 500
    /// Filename inside the store directory (fixed by Model/ScheduleStore.swift's
    /// layout comment; schedule.json belongs to the engine lane, this file doesn't).
    private static let rulesFileName = "rules.json"

    private static let log = Logger(subsystem: "io.appupdater.AppUpdater", category: "rules")

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    /// Store directory — the ONLY test seam (real temp directories in tests,
    /// no URLProtocol / no filesystem protocol indirection).
    public let directory: URL

    private var rulesFileURL: URL { directory.appendingPathComponent(Self.rulesFileName) }

    /// Builds a store rooted at `directory`. Passing nil selects the shared,
    /// user-visible default directory; the directory itself is NOT touched here —
    /// it is created lazily on first save so read-only environments never grow
    /// Application Support state just by being loaded.
    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    /// `~/Library/Application Support/AppUpdater` (with a home-relative
    /// fallback if the service lookup yields nothing, which should not happen
    /// on macOS but keeps the fallback honest instead of crashing later).
    static var defaultDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("AppUpdater", isDirectory: true)
    }

    // MARK: Load / save (filesystem part)

    /// Reads the persisted rule set. Robust by contract:
    /// - missing/unreadable file → `[]` (nothing is created);
    /// - unparseable bytes → `[]` + documented log line; the next save
    ///   honestly replaces the garbage file (see `save(_:)`).
    /// The returned set is sanitized (dedupe → cap → canonical order), so
    /// callers and tests always observe the canonical shape.
    public func load() async throws -> [IgnoreRule] {
        guard let data = try? Data(contentsOf: rulesFileURL) else {
            // Honest absence: no crash, no directory creation, no partial parse.
            return []
        }
        do {
            let decoded = try Self.decoder.decode([IgnoreRule].self, from: data)
            return Self.sanitized(decoded)
        } catch {
            Self.log.error(
                "rules.json unparseable (\(String(describing: error), privacy: .public)) — treating as empty; next save replaces it"
            )
            return []
        }
    }

    /// Persists `rules` atomically as canonical JSON (sanitized: dedupe, cap,
    /// canonical order). Creates the store directory lazily first.
    public func save(_ rules: [IgnoreRule]) async throws {
        _ = try persist(rules)
    }

    /// Internal save-through verb shared by every mutation: sanitize → encode →
    /// atomic swap → return the exact set that was persisted, so UI bindings
    /// and tests display/verify the real state, never a pre-sanitize draft.
    @discardableResult
    private func persist(_ rules: [IgnoreRule]) throws -> [IgnoreRule] {
        let clean = Self.sanitized(rules)
        let data = try Self.encoder.encode(clean)
        try writeBytesAtomically(data, to: rulesFileURL)
        return clean
    }

    /// Staging + atomic swap. The staging file lives in the target directory so
    /// the final `replaceItemAt`/`moveItem` is a same-volume rename (atomic on
    /// APFS/HFS+); a failure anywhere before the swap leaves the previous file
    /// untouched.
    private func writeBytesAtomically(_ data: Data, to target: URL) throws {
        let dir = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        let staging = dir.appendingPathComponent(
            ".\(target.lastPathComponent)-\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: staging) }

        guard FileManager.default.createFile(atPath: staging.path, contents: Data()) else {
            throw RuleStoreWriteFailure(reason: "could not stage rules.json write in \(dir.path)")
        }
        do {
            let handle = try FileHandle(forWritingTo: staging)
            defer { try? handle.close() }
            try handle.write(data)
        } catch {
            throw RuleStoreWriteFailure(
                reason: "staging rules.json write failed: \(String(describing: error))"
            )
        }

        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: target)
        }
    }

    // MARK: Mutations (save-through; each returns the resulting set)

    /// Marks `bundleID` as never-surface-as-update. Idempotent: an existing
    /// .ignoreBundle rule for the bundle is kept verbatim (its OLDER createdAt
    /// wins — re-ignoring must not refresh the age of an old decision).
    @discardableResult
    public func ignoreBundle(_ bundleID: String, at date: Date = Date()) async throws -> [IgnoreRule] {
        var rules = try await load()
        if !rules.contains(where: {
            $0.kind == .ignoreBundle && $0.bundleIdentifier == bundleID
        }) {
            rules.append(
                IgnoreRule(kind: .ignoreBundle, bundleIdentifier: bundleID, createdAt: date)
            )
        }
        return try persist(rules)
    }

    /// Ignores this exact claimed version of `bundleID` (same-major-happy WIP:
    /// matching is EXACT string equality against the claim, decided by the
    /// evaluator — never fuzzy). Idempotent like `ignoreBundle`.
    @discardableResult
    public func ignoreVersion(
        _ bundleID: String, version: String, at date: Date = Date()
    ) async throws -> [IgnoreRule] {
        var rules = try await load()
        if !rules.contains(where: {
            $0.kind == .ignoreVersion && $0.bundleIdentifier == bundleID && $0.version == version
        }) {
            rules.append(
                IgnoreRule(kind: .ignoreVersion, bundleIdentifier: bundleID, version: version, createdAt: date)
            )
        }
        return try persist(rules)
    }

    /// Includes (true) or excludes (false) `bundleID` from automatic timed
    /// checks. ON is the default, so true removes any .noAutoCheck (and
    /// legacy .autoCheck) rules for the bundle; false persists one explicit
    /// .noAutoCheck rule and drops contradictory legacy .autoCheck rules for
    /// the same bundle. Other rule kinds are untouched either way.
    @discardableResult
    public func setAutoCheck(
        _ bundleID: String, _ enabled: Bool, at date: Date = Date()
    ) async throws -> [IgnoreRule] {
        var rules = try await load()
        if enabled {
            rules.removeAll {
                $0.bundleIdentifier == bundleID
                    && ($0.kind == .noAutoCheck || $0.kind == .autoCheck)
            }
        } else {
            rules.removeAll {
                $0.bundleIdentifier == bundleID
                    && ($0.kind == .noAutoCheck || $0.kind == .autoCheck)
            }
            rules.append(
                IgnoreRule(kind: .noAutoCheck, bundleIdentifier: bundleID, createdAt: date)
            )
        }
        return try persist(rules)
    }

    /// Removes the rule matching `rule`'s identity (kind + bundleIdentifier +
    /// version; createdAt is not part of the identity). Unknown rules are an
    /// honest no-op returning the current set.
    @discardableResult
    public func remove(rule: IgnoreRule) async throws -> [IgnoreRule] {
        var rules = try await load()
        let identity = Self.identity(of: rule)
        rules.removeAll { Self.identity(of: $0) == identity }
        return try persist(rules)
    }

    /// Removes every rule (any kind) for one bundle.
    @discardableResult
    public func removeBundleRules(_ bundleID: String) async throws -> [IgnoreRule] {
        var rules = try await load()
        rules.removeAll { $0.bundleIdentifier == bundleID }
        return try persist(rules)
    }

    // MARK: Evaluation

    /// Evaluates the persisted rules for one app + one candidate claim.
    /// Throwing surface: a load failure is surfaced to the caller.
    public func evaluate(
        bundleIdentifier: String, claimVersion: String?
    ) async throws -> RuleDecision {
        let rules = try await load()
        return Self.evaluate(
            rules: rules, bundleIdentifier: bundleIdentifier, version: claimVersion
        )
    }

    /// PURE logic core (static, internal — tests hit it directly through
    /// @testable): merge every rule for `bundleIdentifier` into one decision.
    /// - .ignoreBundle → ignoredBundle = true (the app never surfaces as
    ///   pending, regardless of any claim).
    /// - .ignoreVersion → ignoredVersion = true ONLY when the rule's version
    ///   string equals `version` EXACTLY; a nil claim never matches a version
    ///   rule (no version known ⇒ nothing can be ignored), and a rule with a
    ///   nil version (malformed input) never matches anything.
    /// - Automatic checks default ON (read-only source lookups — the app's
    ///   core promise must not be inert out of the box); .noAutoCheck is the
    ///   explicit opt-out. .autoCheck is the legacy opt-IN marker from the v1
    ///   default-OFF era and keeps meaning ON for persisted old files.
    static func evaluate(
        rules: [IgnoreRule], bundleIdentifier: String, version: String?
    ) -> RuleDecision {
        var decision = RuleDecision()
        for rule in rules where rule.bundleIdentifier == bundleIdentifier {
            switch rule.kind {
            case .ignoreBundle:
                decision.ignoredBundle = true
            case .ignoreVersion:
                if let ruleVersion = rule.version, ruleVersion == version {
                    decision.ignoredVersion = true
                }
            case .autoCheck:
                decision.autoCheck = true
            case .noAutoCheck:
                decision.autoCheck = false
            }
        }
        return decision
    }

    /// Batch form for the UI lanes: merges every InstalledApp with its UpdateCheck
    /// into frozen AppRow values.
    ///
    /// Matching policy (documented):
    /// - A check matches an app by `app.bundleIdentifier` ONLY — display names
    ///   are never used for matching (they collide across unrelated apps).
    /// - When several checks share a bundle id (duplicate installs are tracked
    ///   separately per MacUpdater policy), the FIRST in `checks` input order
    ///   wins for every app with that bundle id — a claim describes the
    ///   software, not an install location.
    /// - Checks whose bundle matches no app are dropped; apps without a check
    ///   get decision-only rows (`check == nil`, frozen `updateAvailable` false).
    /// - Non-throwing on purpose: an unreadable rule store renders HONESTLY as
    ///   "no rules known" (default decisions) with a log line, instead of
    ///   aborting the whole UI render; the single-app `evaluate` throws instead.
    public func evaluate(apps: [InstalledApp], checks: [UpdateCheck]) async -> [AppRow] {
        let rules: [IgnoreRule]
        do {
            rules = try await load()
        } catch {
            Self.log.error(
                "rules load failed: \(String(describing: error), privacy: .public)"
            )
            rules = []
        }
        return apps.map { inventoryApp in
            let check = checks.first { $0.app.bundleIdentifier == inventoryApp.bundleIdentifier }
            // The row shows the INVENTORY app (fresh disk truth) but must keep
            // the check's timestamp — otherwise every row reads "never checked".
            var app = inventoryApp
            if let stamp = check?.app.checkedAt { app.checkedAt = stamp }
            let decision = Self.evaluate(
                rules: rules,
                bundleIdentifier: app.bundleIdentifier,
                version: check?.resolved?.newestShortVersion
            )
            return AppRow(app: app, check: check, decision: decision)
        }
    }

    // MARK: Policy clamping (loader sanitization, engine-agnostic)

    /// Clamps a loaded SchedulePolicy per the frozen ScheduleStore contract:
    ///   intervalMinutes <= 0 → 0        (negative normalized to the explicit
    ///                                    "scheduled off" state; 0 stays 0)
    ///   1...14              → 15        (under-floor values coerce up to the floor)
    ///   >= 15               → unchanged
    ///   deferWhenOffline    → unchanged (Bool has no invalid state)
    ///   active window       → carried VERBATIM when valid; an INVALID window
    ///                         (one endpoint nil, start == end, start > end,
    ///                         out of 0...1439) is normalized to nil/nil —
    ///                         no restriction — so the settings pane (which
    ///                         reads the snapshot's policy) always shows what
    ///                         is actually enforced. Same validity rule the
    ///                         engine enforces (`ScheduleEngine.activeWindow`);
    ///                         the duplication is the window analog of the
    ///                         interval floor's loader+engine double protection.
    /// Lives here because the persistence lane owns load sanitization; the
    /// engine lane applies it to whatever it loads from schedule.json.
    public static func clamped(_ policy: SchedulePolicy) -> SchedulePolicy {
        var clamped = policy
        if policy.intervalMinutes <= 0 {
            clamped.intervalMinutes = 0   // negative coerced to the explicit off state
        } else if policy.intervalMinutes < 15 {
            clamped.intervalMinutes = 15  // under-floor values coerce up to the floor
        }
        let windowIsValid: Bool
        if let start = policy.activeWindowStartMinute, let end = policy.activeWindowEndMinute {
            windowIsValid = (0...1_439).contains(start)
                && (0...1_439).contains(end) && start < end
        } else {
            windowIsValid = false
        }
        if !windowIsValid {
            clamped.activeWindowStartMinute = nil
            clamped.activeWindowEndMinute = nil
        }
        return clamped
    }

    // MARK: Sanitizer (dedupe → cap → canonical order)

    static func sanitized(_ rules: [IgnoreRule]) -> [IgnoreRule] {
        // 1) Collapse duplicates on identity (kind, bundle, version), keeping the
        //    OLDEST createdAt — the first time a user decided something is the
        //    decision that should survive, and re-adding must not reset its age.
        var byIdentity: [RuleIdentity: IgnoreRule] = [:]
        for rule in rules {
            let identity = Self.identity(of: rule)
            if let existing = byIdentity[identity], existing.createdAt <= rule.createdAt {
                continue
            }
            byIdentity[identity] = rule
        }
        if byIdentity.count < rules.count, !rules.isEmpty {
            Self.log.notice(
                "rules dedupe: collapsed \(rules.count - byIdentity.count, privacy: .public) duplicate rule(s)"
            )
        }
        var survivors = Array(byIdentity.values)

        // 2) Cap at ruleLimit, dropping the OLDEST rows beyond the cap (honest,
        //    logged — the user's newest decisions always keep priority).
        if survivors.count > Self.ruleLimit {
            let dropped = survivors.count - Self.ruleLimit
            let oldestFirst = survivors.sorted { $0.createdAt < $1.createdAt }
            let keep = Set(oldestFirst.dropFirst(dropped))
            survivors.removeAll { !keep.contains($0) }
            Self.log.notice(
                "rules cap: dropped \(dropped, privacy: .public) oldest rule(s) beyond the \(Self.ruleLimit, privacy: .public) limit"
            )
        }

        // 3) Canonical deterministic order for stable persisted bytes + stable UI.
        return Self.canonicalSort(survivors)
    }

    private static func identity(of rule: IgnoreRule) -> RuleIdentity {
        RuleIdentity(
            kind: rule.kind,
            bundleIdentifier: rule.bundleIdentifier,
            version: rule.version
        )
    }

    private static func canonicalSort(_ rules: [IgnoreRule]) -> [IgnoreRule] {
        rules.sorted { a, b in
            if a.kind.rawValue != b.kind.rawValue {
                return a.kind.rawValue < b.kind.rawValue
            }
            if a.bundleIdentifier != b.bundleIdentifier {
                return a.bundleIdentifier < b.bundleIdentifier
            }
            switch (a.version, b.version) {
            case (nil, _): return true    // nil sorts first (deterministic)
            case (_, nil): return false
            case (let va?, let vb?):
                if va != vb { return va < vb }
            }
            return a.createdAt < b.createdAt
        }
    }

    /// Rule identity: everything that makes two rules the same decision.
    /// createdAt is deliberately excluded (dedupe keeps the oldest).
    private struct RuleIdentity: Hashable {
        let kind: RuleKind
        let bundleIdentifier: String
        let version: String?
    }
}

/// Honest persistence failure (never swallowed; UI and CLI can render it).
public struct RuleStoreWriteFailure: LocalizedError, Sendable {
    public let reason: String
    public var errorDescription: String? { "RuleStore write failed: \(reason)" }
    public init(reason: String) { self.reason = reason }
}
