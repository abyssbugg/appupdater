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
/// - MANUAL-OVER-BUILTIN (owner-locked gap-sprint decision): when the optional
///   `manualSource` resolver yields a source for an app, that pin is an owner
///   attestation and that source is the ONLY one consulted for the app —
///   built-ins are not queried (no surprise network traffic), the claim still
///   passes the standard strictly-greater gate at resolve time, and a pinned
///   source's throw is recorded verbatim in `failures`.
public struct UpdateCheckEngine: Sendable {
    /// Sources in precedence order (sorted from `VersionOracle.sourcePrecedence`).
    public let sortedSources: [any UpdateSource]

    /// Per-app manual pin seam (nil = no manual behavior; built-ins run as before).
    public let manualSource: ManualSourceResolver?

    /// Build an engine. Sources are automatically sorted into precedence order;
    /// unknown-kind sources are kept last (still attempted, winners recorded honestly).
    public init(sources: [any UpdateSource], manualSource: ManualSourceResolver? = nil) {
        let precedence = VersionOracle.sourcePrecedence
        let rank: (SourceKind) -> Int = { kind in
            precedence.firstIndex(of: kind) ?? precedence.count
        }
        self.sortedSources = sources.sorted { rank($0.kindValue) < rank($1.kindValue) }
        self.manualSource = manualSource
    }

    /// Run one source for one app, appending its claim (or verbatim failure).
    private func attempt(
        _ source: any UpdateSource,
        app: InstalledApp,
        into candidates: inout [UpdateInfo],
        failures: inout [CheckSourceFailure]
    ) async {
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

    /// Run every source for one app and resolve a verdict. Network errors are captured,
    /// not thrown, so a dead cask network still lets sparkle/MAS produce claims.
    public func check(app: InstalledApp) async -> UpdateCheck {
        var candidates: [UpdateInfo] = []
        var failures: [CheckSourceFailure] = []

        if let manualSource, let pinned = await manualSource.resolve(app) {
            // Manual pin: the pinned source is the ONLY source consulted for
            // this app (see header policy). Built-ins stay silent.
            await attempt(pinned, app: app, into: &candidates, failures: &failures)
        } else {
            for source in sortedSources {
                await attempt(source, app: app, into: &candidates, failures: &failures)
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

// MARK: - Manual-source resolver seam

/// Per-app manual source pin seam (coordinator-owned; the manual-sources wave
/// plugs its store in here). Given one app, yield the ONE `UpdateSource` that
/// must exclusively be consulted for it, or nil when the app has no pin.
///
/// Semantics (owner-locked manual-over-builtin): a pin is an owner attestation
/// — the engine runs ONLY the pinned source for that app (built-ins are never
/// queried for it), and the resulting claim still goes through the standard
/// strictly-greater comparison at resolve time, so pinning never manufactures
/// an update that the installed version refutes.
public struct ManualSourceResolver: Sendable {
    public typealias Resolve = @Sendable (InstalledApp) async -> (any UpdateSource)?
    public let resolve: Resolve

    public init(_ resolve: @escaping Resolve) {
        self.resolve = resolve
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
