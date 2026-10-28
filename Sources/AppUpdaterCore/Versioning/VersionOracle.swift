// The version ORACLE: Sparkle-style ordering + the owner-locked source
// precedence policy. Pure logic — zero networking, zero side effects.
//
// Resolver policy (owner-locked v1, per Model/UpdateSource.swift):
// cask > sparkle > mas > github-optional; `unknown` always last and never
// auto-selectable while any known source has candidates.
//
// AMENDMENT (2026-10-27, gap-closure sprint): `unknown` claims now pass the
// SAME strictly-greater-than gate as every other kind. Electron vendors
// republish the installed version verbatim and its probes can fall back to
// "0.0.0", so an equal or older least-trusted claim must never surface as an
// update. An unknown claim that IS strictly greater is still surfaced when the
// list is unknown-only (unknown never beats a known group — unchanged).
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
    /// Unknown claims are only returned when the list is unknown-only, and
    /// then only when strictly greater than the installed version (amendment
    /// 2026-10-27 in the file header) — an equal/older unknown claim surfaces
    /// nothing at all.
    public func resolve(candidates: [UpdateInfo], installedShortVersion: String?) -> UpdateInfo? {
        guard !candidates.isEmpty else { return nil }

        var groups: [SourceKind: [UpdateInfo]] = [:]
        for candidate in candidates {
            groups[candidate.source, default: []].append(candidate)
        }

        for kind in Self.sourcePrecedence + [.unknown] {
            guard let group = groups[kind], !group.isEmpty else { continue }

            // The SAME strictly-greater gate applies to the `.unknown` group
            // (file-header amendment): reached only when NO known source
            // produced candidates at all, and only claims strictly greater
            // than the installed version are eligible — Electron vendors
            // republish the installed version and probes can fall back to
            // "0.0.0", so an equal/older least-trusted claim never surfaces
            // as an update. Greatest eligible wins (confidence breaks ties
            // within the group; duplicates stay first-wins stable).

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
