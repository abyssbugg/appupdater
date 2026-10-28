// ManualSourceResolver.swift — the manual-sources wave's half of the
// coordinator-authored engine seam (gap #2): reads pins from
// ManualSourceStore and manufactures the ONE UpdateSource a pinned app must
// consult, exclusively, instead of every auto-detected sink.
//
// Split of responsibilities (frozen by the coordinator's already-landed
// Engine/UpdateCheckEngine.swift — study its header before changing here):
//   - THIS file decides WHICH source exists for an app (the pin acts as the
//     owner attestation) and constructs it fresh per call.
//   - THE ENGINE decides how it is run: when `ManualSourceResolver.resolve`
//     yields a source, that source is the ONLY one consulted for the app —
//     built-ins are NEVER queried for it (no surprise network traffic), the
//     resulting claim still passes the standard strictly-greater gate at
//     resolve time (a pin never manufactures an update the installed version
//     refutes), and a pinned source's throw is recorded verbatim in
//     `UpdateCheck.failures` with no silent built-in fallback.
//
// Matching identity: a pin matches an `InstalledApp` when
// `pin.bundleID == app.bundleIdentifier` EXACTLY (string equality; no case
// folding, no prefix matching, no path involvement). The store refuses a
// second same-kind pin per bundle id, so the pick below is unambiguous.
//
// Honest caveat, documented because the engine has NO failure channel for the
// resolver itself: `source(for:)` is a nil-outcome API. A corrupt store file
// therefore reads as "no pin for this app" — built-ins would run again for it.
// That is the smallest honest degradation available inside the frozen seam,
// and the sheet (ManualSourceSheet.swift) surfaces store corruption verbatim
// where a UI error channel exists. Production mitigation lives in the wiring
// notes of docs/evidence/gap-manual-sources-2026-10-27.txt.
//
// A manual cask pin deliberately does NOT manufacture claims: a 404 /
// no-result cask lookup is an honest nil (the engine then reports "unknown"),
// never a synthesized version and never a fallback to built-ins — the owner's
// attestation stands even when it currently answers nothing.

import Foundation

// MARK: - Resolver service

/// Per-app manual pin service: stateless by construction (nothing is cached —
/// pins are re-read from disk per call, sources are constructed per call), so
/// a wind of concurrent sheet mutations between two checks can never serve a
/// stale source. Sendable: every stored property is an immutable `let` whose
/// type is itself Sendable (`ManualSourceStore` — serial-locked disk-backed;
/// nothing else is stored).
public final class ManualSourceResolverService: Sendable {

    /// The pin store this service reads — REQUIRED explicitly at init. The
    /// exact signature (instead of the brief's bare `init()`): the service
    /// must read pins SOMEWHERE, and the store is the only honest carrier —
    /// a bare init could never know the persistence directory without
    /// violating the "never touch the real directory here" lane rule (the
    /// coordinator owns the real-directory wiring; see
    /// docs/evidence/gap-manual-sources-2026-10-27.txt, integration notes).
    /// Sharing the SHEET's store instance is the intended wiring (one store,
    /// exclusivity preserved by the store's serial lock — sheet mutations
    /// are visible to the next check's read, never mid-file).
    public let store: ManualSourceStore

    public init(store: ManualSourceStore) {
        self.store = store
    }

    /// The ONE source to consult exclusively for `app`, or nil when the app
    /// has no pin (or the store read failed — the honest caveat above).
    ///
    /// Lookup: ALL pins whose `bundleID` equals `app.bundleIdentifier`
    /// exactly, taking the FIRST in the store's canonical sort order
    /// (bundleID → kind → createdAt; with both kinds pinned, cask sorts
    /// first — documented on the store). Construction per kind:
    ///   - .github → `GithubSource(pinnedOwner:pinnedRepo:directory:session:)`
    ///     AS-IS: the pinned-init repo is the production-validated single-
    ///     candidate path with its own rate-limit honesty, ETag cache and
    ///     asset pick; `githubCacheDirectory` hosts that cache (tests give
    ///     unique temp dirs; the coordinator supplies the real one).
    ///   - .cask → `ManualCaskSource(token:session:)` below.
    public func source(for app: InstalledApp, session: URLSession, githubCacheDirectory: URL) async -> (any UpdateSource)? {
        let pins: [ManualSource]
        do {
            pins = try store.pins()
        } catch {
            // Honest nil (header caveat): the engine seam has no error
            // channel for the resolver itself.
            return nil
        }
        guard let pin = pins.first(where: { $0.bundleID == app.bundleIdentifier }) else {
            return nil // no attestation for this app → built-ins run as before
        }
        switch pin.kind {
        case .github:
            guard let owner = pin.owner, let repo = pin.repo else { return nil }
            // Never reachable from store-added pins (slugs validated at add
            // time) — the guard keeps decode-side strangers honest too.
            guard RepoRef.validated(owner: owner, repo: repo) != nil else { return nil }
            return GithubSource(
                pinnedOwner: owner,
                pinnedRepo: repo,
                directory: githubCacheDirectory,
                session: session
            )
        case .cask:
            guard let token = pin.token else { return nil }
            return ManualCaskSource(token: token, session: session)
        }
    }

    /// The portal the coordinator installs on the engine:
    /// `UpdateCheckEngine(sources: …, manualSource: service.engineResolver(
    /// session:realSession, githubCacheDirectory:realCacheDirectory))`.
    /// The closure is `@Sendable`/async per the frozen `ManualSourceResolver`
    /// shape and delegates to `source(for:session:githubCacheDirectory:)`.
    public func engineResolver(session: URLSession, githubCacheDirectory: URL) -> ManualSourceResolver {
        ManualSourceResolver { app in
            await self.source(for: app, session: session, githubCacheDirectory: githubCacheDirectory)
        }
    }
}

// MARK: - Manual cask source

/// The UpdateSource a cask token pin resolves to. Deliberately a thin
/// wrapper: the fetch/decode/validate pipeline is REPLICATED through
/// `CaskDocumentClient.lookup` (the public single-token primitive whose
/// behavior matches `CaskSource.lookup` exactly — same endpoint, same
/// status branching, same tolerant decode, same artifact validation), with
/// exactly two contributions of this lane's own:
///   1. sourceDetail honesty — the claim names the pin that produced it
///      ("manual cask pin '<token>'"), so a report shows the claim came from
///      the owner's attestation, not an auto-detected token.
///   2. the miss contract — `.notFound`/`.noResult` are an honest nil. A
///      manual pin does NOT manufacture claims: a bad token answers "failed"
///      (throw path) or "unknown" (miss path) for the app, never a guess,
///      and the engine never falls back to built-ins for a pinned app.
public struct ManualCaskSource: UpdateSource, Sendable {
    public static var kind: SourceKind { .cask }

    /// The attested cask token, exactly as validated and stored.
    private let token: String
    private let session: URLSession

    /// Injectable session throughout (hermetic tests stub URLs through
    /// URLProtocol; production passes the shared session at integration).
    public init(token: String, session: URLSession) {
        self.token = token
        self.session = session
    }

    public func fetchUpdateInfo(for app: InstalledApp) async throws -> UpdateInfo? {
        let outcome = try await CaskDocumentClient(session: session).lookup(token: token, for: app)
        switch outcome {
        case .info(let info):
            var claim = info
            let prefix = claim.sourceDetail.map { $0 + "; " } ?? ""
            claim.sourceDetail = prefix + "manual cask pin '\(token)'"
            return claim
        case .notFound, .noResult:
            return nil // honest miss — the pin stands, it just answers nothing today
        }
    }
}
