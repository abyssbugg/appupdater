// The version ORACLE: Sparkle-style ordering + the owner-locked source
// precedence policy. Pure logic — zero networking, zero side effects.
//
// Resolver policy (owner-locked v1, per Model/UpdateSource.swift):
// cask > sparkle > mas > github-optional; `unknown` always last and never
// auto-selectable while any known source has candidates.
//
// Honesty rules implemented here (deliberate, tested):
// - The HIGHEST-precedence group that exists decides alone. A cask "1.2"
//   claim beats a fresher sparkle "1.9" claim, and if that top group has no
//   version greater than the installed one we return nil — we do NOT fall
//   through to weaker sources (falling through would surface a less-trusted
//   claim over the best source's judgment, e.g. a stale-but-authoritative
//   cask index suppressing a risky vendor guess).
// - Confidence only breaks ties WITHIN one source kind (high > medium > low).
// - Duplicate versions within one kind: first candidate wins (stable).
// - An unparseable installed version is treated like no installed version
//   (we cannot disprove an update claim we cannot rank).
// - An unknown-only candidate list is surfaced to the caller (the caller
//   decides what to show); unknowns are never chosen over any known source.

import Foundation

public struct VersionOracle: Sendable {
    public init() {}

    /// Owner-locked v1 source precedence (Index 0 = strongest). `unknown` is
    /// deliberately absent: it never participates in precedence — it is only
    /// ever chosen when NO other source exists (see `resolve`).
    public static let sourcePrecedence: [SourceKind] = [.cask, .sparkle, .mas, .github]

    /// Sparkle-style comparison. `greater` ⇔ the FIRST string is newer.
    ///
    /// Never crashes; malformed/garbage input yields the documented
    /// deterministic lexicographic fallback (see `AppVersion` doc header).
    public func compare(_ lhs: String, _ rhs: String) -> VersionOrder {
        AppVersion(lhs).compare(to: AppVersion(rhs))
    }

    /// Whether `available` should be surfaced as an update over `installed`.
    ///
    /// - `available == nil` or unparseable → false (never claim what we can't
    ///   rank honestly).
    /// - `installed == nil` (or unparseable) → true iff `available` parses.
    /// - Otherwise → true iff `available` compares GREATER than `installed`.
    public func isUpdateAvailable(installed: String?, available: String?) -> Bool {
        guard let available else { return false }
        let availableVersion = AppVersion(available)
        guard availableVersion.isParseable else { return false }
        guard let installed else { return true }
        let installedVersion = AppVersion(installed)
        guard installedVersion.isParseable else { return true } // ≈ no installed version
        return availableVersion.compare(to: installedVersion) == .greater
    }

    /// Picks what the UI should show for an app among all source claims.
    ///
    /// Ranking: candidates are grouped by `SourceKind`; the strongest group
    /// present (per `sourcePrecedence`) decides exclusively. Within it, only
    /// versions GREATER than `installedShortVersion` are eligible (installed
    /// nil → everything eligible); the greatest wins, equal versions are
    /// tie-broken by confidence, then by input order (stable). If none is
    /// greater → nil: no update, no weaker-source substitution.
    ///
    /// Unknown claims are only returned when the list is unknown-only — the
    /// caller decides what to show.
    public func resolve(candidates: [UpdateInfo], installedShortVersion: String?) -> UpdateInfo? {
        guard !candidates.isEmpty else { return nil }

        var groups: [SourceKind: [UpdateInfo]] = [:]
        for candidate in candidates {
            groups[candidate.source, default: []].append(candidate)
        }

        for kind in Self.sourcePrecedence + [.unknown] {
            guard let group = groups[kind], !group.isEmpty else { continue }

            if kind == .unknown {
                // Reached only when no known source produced candidates at all.
                // Surface the (least-trusted) claim for the caller to judge;
                // do not attempt versionGreater gating — unknown versions are
                // usually garbage anyway. First wins (stable).
                return group.first
            }

            // Unparseable installed version ≈ no installed version (documented).
            let installed: AppVersion? = {
                guard let installedShortVersion else { return nil }
                let parsed = AppVersion(installedShortVersion)
                return parsed.isParseable ? parsed : nil
            }()

            var best: UpdateInfo?
            var bestVersion: AppVersion?
            var bestConfidence = Int.min

            for candidate in group {
                let version = AppVersion(candidate.newestShortVersion)
                if let installed, version.compare(to: installed) != .greater {
                    continue // only strictly-greater claims are eligible
                }
                guard let current = best else {
                    best = candidate
                    bestVersion = version
                    bestConfidence = Self.confidenceRank(candidate.confidence)
                    continue
                }
                let order = version.compare(to: current.version(for: bestVersion))
                if order == .greater {
                    best = candidate
                    bestVersion = version
                    bestConfidence = Self.confidenceRank(candidate.confidence)
                } else if order == .equal,
                          Self.confidenceRank(candidate.confidence) > bestConfidence {
                    best = candidate
                    bestConfidence = Self.confidenceRank(candidate.confidence)
                }
                // order == .less, or equal with lower/equal confidence → keep
                // current (stable: first candidate wins duplicates).
            }
            return best // nil when no candidate is greater than installed
        }
        return nil // unreachable: .unknown matches any nonempty group not claimed earlier
    }

    static func confidenceRank(_ confidence: UpdateConfidence) -> Int {
        switch confidence {
        case .high: 3
        case .medium: 2
        case .low: 1
        }
    }
}

private extension UpdateInfo {
    /// Internal helper keeping the resolver loop tidy: the version we cached
    /// for the current best candidate (`bestVersion` is non-nil exactly when
    /// `best` is, so this never crashes and never invents data).
    func version(for cached: AppVersion?) -> AppVersion {
        cached ?? AppVersion(newestShortVersion)
    }
}
