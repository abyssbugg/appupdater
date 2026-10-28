// SetappSupport.swift — Setapp membership classification (GAP #10).
//
// Contract (UPDATEST-FINDINGS.md §3.1 [confirmed]; MACUPDATER-FINDINGS.md §3.1):
//   Updatest scans `/Applications/Setapp/` as a documented discovery root and
//   flags Setapp apps via `isSetapp` / `ignoredSetapp` — they are SHOWN but
//   not updatable: "Setapp apps are updated through the Setapp app" /
//   "No Setapp apps were found." MacUpdater keeps the parallel skip-class
//   `isIgnoredSetappApp` in its vendor-autoupdater skip-list.
//
// DOCUMENTED signals — exactly one: the install path under the documented
//   Setapp root `/Applications/Setapp/`. NEITHER teardown documents any
//   plist/entitlement marker for Setapp membership, so none is implemented:
//   a bundle outside that root classifies as `notMember` with that honest
//   note, never a heuristic. Membership therefore also says what the
//   documented handling is: shown, not updatable — Setapp updates itself.
//
// PURE path classification: no filesystem reads, no network, no privilege.
//   The root is injectable so tests can point it at fixture directories; the
//   default is the documented absolute root. Whether the bundle actually
//   exists is the scanner's concern — that glue is owned by the coordinator,
//   not wired here.
//
// No MAS automation and no Setapp automation here (future assistant work):
//   this is the documented DATA layer only.

import Foundation

// MARK: - Result type

/// Setapp membership verdict with honest provenance. `unknown` is first-class
/// (e.g. empty/meaningless input), never collapsed into `notMember`.
public struct SetappInfo: Equatable, Sendable {

    public enum Verdict: Equatable, Sendable {
        /// Bundle path sits under the documented Setapp root.
        case member
        /// Path is decidable but outside the documented Setapp root (and no
        /// other documented signal exists — see header).
        case notMember
        /// Input not classifiable (empty path, path equals the root itself).
        case unknown
    }

    public let verdict: Verdict

    /// Documented-marker findings (paths, doc section references).
    public let evidence: [String]

    /// Provenance/honesty note; for members it carries the documented
    /// shown-but-not-updatable handling verbatim.
    public let note: String

    public init(verdict: Verdict, evidence: [String], note: String) {
        self.verdict = verdict
        self.evidence = evidence
        self.note = note
    }
}

// MARK: - Classifier

public enum SetappSupport {

    /// The documented Setapp discovery root (UPDATEST-FINDINGS §3.1:
    /// "Scans /Applications, /Applications/Utilities, /Applications/Setapp/").
    public static let documentedRoot = "/Applications/Setapp"

    /// Classifies `bundlePath` against `root`. Matching is on STANDARDIZED,
    /// case-insensitive paths (macOS default filesystems are
    /// case-insensitive; a case-different path component must not flip the
    /// verdict). No filesystem access happens here.
    public static func classify(bundlePath: String, root: String = documentedRoot) -> SetappInfo {
        let trimmedPath = bundlePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return SetappInfo(
                verdict: .unknown,
                evidence: [],
                note: "no bundle path given — nothing to classify against the documented Setapp root "
                    + "(the ONLY documented signal: install path under /Applications/Setapp/)")
        }

        let trimmedRoot = root.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRoot.isEmpty else {
            return SetappInfo(
                verdict: .unknown,
                evidence: [],
                note: "empty Setapp root given — classification withheld (unknown), never guessed")
        }

        let path = standardizedLowercased(trimmedPath)
        let setappRoot = standardizedLowercased(trimmedRoot)

        if path == setappRoot {
            return SetappInfo(
                verdict: .unknown,
                evidence: [],
                note: "path equals the documented Setapp root (\(trimmedRoot)) itself, not a bundle — "
                    + "verdict withheld (unknown)")
        }

        guard path.hasPrefix(setappRoot + "/") else {
            return SetappInfo(
                verdict: .notMember,
                evidence: [],
                note: "path is outside the documented Setapp root \(trimmedRoot); no plist/entitlement "
                    + "marker for Setapp membership is documented in either teardown "
                    + "(UPDATEST-FINDINGS §3.1, MACUPDATER-FINDINGS §3.1), so no other documented "
                    + "signal exists")
        }

        return SetappInfo(
            verdict: .member,
            evidence: [
                "bundle path \(trimmedPath) is under the documented Setapp discovery root "
                    + "\(trimmedRoot) (UPDATEST-FINDINGS §3.1: scan root /Applications/Setapp/)",
            ],
            note: "documented handling (Updatest): Setapp apps are shown but not updatable — "
                + "\"Setapp apps are updated through the Setapp app\"; MacUpdater parallel: "
                + "isIgnoredSetappApp skip-class")
    }

    // MARK: - Path helpers

    private static func standardizedLowercased(_ path: String) -> String {
        (path as NSString).standardizingPath.lowercased()
    }
}
