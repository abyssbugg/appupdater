import Foundation

/// Homebrew cask `version` semantics: the part before the first comma is the
/// marketing version; anything after is a build/commit/extra token
/// (`"3.11.234,92c83011d1"`, `"0.21.2,088d292d364f"`). Only the marketing
/// part is ever compared against Info.plist (`CFBundleShortVersionString`) —
/// comparing the raw string made an INSTALLED 3.11.234 look older than
/// `"3.11.234,92c8…"` (false-positive update, found live 2026-10-30).
public enum CaskVersion {
    /// `(marketing, build)`; `build` is nil when absent or empty.
    public static func split(_ raw: String) -> (marketing: String, build: String?) {
        let parts = raw.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        let marketing = stripStableChannel(String(parts[0]).trimmingCharacters(in: .whitespaces))
        let build = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        return (marketing, build.isEmpty ? nil : build)
    }

    /// Warp-class decoration: casks spell the release CHANNEL inside a dot
    /// component (`0.2026.10.21.08.25.stable_02`) while the app's Info.plist
    /// carries the plain number (`0.2026.10.21.08.25.02`) — the SAME release
    /// (false positive found live 2026-10-30). Only the `stable` label is
    /// stripped (`stable_02` / `stable-02` / `stable02` → `02`): it is the
    /// plain-release channel. Prerelease labels (beta, rc, nightly, preview)
    /// order differently and are never touched.
    static func stripStableChannel(_ version: String) -> String {
        version.split(separator: ".", omittingEmptySubsequences: false).map { component -> String in
            let lower = component.lowercased()
            guard lower.hasPrefix("stable") else { return String(component) }
            var rest = lower.dropFirst("stable".count)
            if rest.first == "_" || rest.first == "-" { rest = rest.dropFirst() }
            guard !rest.isEmpty, rest.allSatisfy(\.isASCII), rest.allSatisfy(\.isNumber) else {
                return String(component)
            }
            return String(rest)
        }.joined(separator: ".")
    }
}
