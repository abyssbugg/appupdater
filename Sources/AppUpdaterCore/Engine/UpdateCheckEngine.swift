import Foundation

/// Orchestrates one app's update check across the configured sources and resolves the
/// result with the owner-locked precedence (`VersionOracle.sourcePrecedence`:
/// cask > sparkle > mas > github; unknown never wins while others exist).
///
/// Policies (v1, documented):
/// - Sources are attempted in precedence order; every source that produces a claim is
///   recorded as a candidate (ordering preserved), so a report manifest can show the full
///   truth of what was learned, not just the winner.
/// - A source that THROWS does not abort the check for the app: its kind and error
///   message are recorded in `failures` and the remaining sources still run. Honesty
///   over silence — a failed lookup is visible in the report.
/// - Resolution is VersionOracle's verdict, including its "strongest source's verdict
///   is final (no fall-through)" rule: if cask (strongest source attempted) says the
///   install is current, a newer sparkle claim does NOT override it.
/// - This engine performs NO writes and NO downloads. It only produces claims.
public struct UpdateCheckEngine: Sendable {
    /// Sources in precedence order (sorted from `VersionOracle.sourcePrecedence`).
    public let sortedSources: [any UpdateSource]

    /// Build an engine. Sources are automatically sorted into precedence order;
    /// unknown-kind sources are kept last (still attempted, winners recorded honestly).
    public init(sources: [any UpdateSource]) {
        let precedence = VersionOracle.sourcePrecedence
        let rank: (SourceKind) -> Int = { kind in
            precedence.firstIndex(of: kind) ?? precedence.count
        }
        self.sortedSources = sources.sorted { rank($0.kindValue) < rank($1.kindValue) }
    }

    /// Run every source for one app and resolve a verdict. Network errors are captured,
    /// not thrown, so a dead cask network still lets sparkle/MAS produce claims.
    public func check(app: InstalledApp) async -> UpdateCheck {
        var candidates: [UpdateInfo] = []
        var failures: [CheckSourceFailure] = []

        for source in sortedSources {
            do {
                if let info = try await source.fetchUpdateInfo(for: app) {
                    candidates.append(info)
                }
            } catch {
                failures.append(
                    CheckSourceFailure(
                        kind: source.kindValue,
                        message: String(describing: error)
                    )
                )
            }
        }

        let resolved = VersionOracle().resolve(
            candidates: candidates,
            installedShortVersion: app.shortVersion
        )
        return UpdateCheck(
            app: app,
            candidates: candidates,
            failures: failures,
            resolved: resolved
        )
    }

    /// Check many apps concurrently (TaskGroup), returning results in INPUT order so
    /// reports stay deterministic regardless of completion order.
    public func checkAll(apps: [InstalledApp]) async -> [UpdateCheck] {
        var landing: [UpdateCheck?] = Array(repeating: nil, count: apps.count)
        await withTaskGroup(of: (Int, UpdateCheck).self) { group in
            for (index, app) in apps.enumerated() {
                group.addTask { [self] in (index, await check(app: app)) }
            }
            for await (index, check) in group {
                landing[index] = check
            }
        }
        // The group guarantees every index lands; the nil-fallback keeps the mapping total
        // even if a task were cancelled mid-flight, and shows up honestly as "unknown".
        return landing.enumerated().map { index, check in
            check ?? UpdateCheck(app: apps[index], candidates: [], failures: [], resolved: nil)
        }
    }
}

extension UpdateSource {
    /// Access a source's declared kind through the existential protocol value
    /// (the frozen protocol declares `kind` as `static`, so this is the portal).
    var kindValue: SourceKind { type(of: self).kind }
}

/// Honest failure record for one source attempt on one app.
public struct CheckSourceFailure: Codable, Hashable, Sendable {
    public var kind: SourceKind
    public var message: String

    public init(kind: SourceKind, message: String) {
        self.kind = kind
        self.message = message
    }
}

/// Per-app result of an orchestrated check.
public struct UpdateCheck: Codable, Hashable, Sendable {
    public var app: InstalledApp
    /// Every claim produced, in the order sources were attempted (precedence order).
    public var candidates: [UpdateInfo]
    /// Sources that threw during lookup, with their error text.
    public var failures: [CheckSourceFailure]
    /// VersionOracle's verdict — nil means "no update claim survives the comparison".
    public var resolved: UpdateInfo?
    /// Machine-readable verdict, stored so JSON reports carry it verbatim.
    /// Honest strings, never "success" theater:
    /// - "update": a resolved claim exists
    /// - "current": sources produced claims but none beat the installed version
    /// - "failed": every source either failed or produced nothing, so nothing is known
    /// - "unknown": sources succeeded but produced no claims for this app identity
    public var verdict: String

    public init(app: InstalledApp, candidates: [UpdateInfo], failures: [CheckSourceFailure] = [], resolved: UpdateInfo?) {
        self.app = app
        self.candidates = candidates
        self.failures = failures
        self.resolved = resolved
        self.verdict = Self.computeVerdict(
            resolved: resolved,
            candidates: candidates,
            failures: failures
        )
    }

    private static func computeVerdict(resolved: UpdateInfo?, candidates: [UpdateInfo], failures: [CheckSourceFailure]) -> String {
        if resolved != nil { return "update" }
        if candidates.isEmpty {
            return failures.isEmpty ? "unknown" : "failed"
        }
        return "current"
    }
}
