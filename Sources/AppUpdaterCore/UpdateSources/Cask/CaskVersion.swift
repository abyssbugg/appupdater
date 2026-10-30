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
        let marketing = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let build = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        return (marketing, build.isEmpty ? nil : build)
    }
}
