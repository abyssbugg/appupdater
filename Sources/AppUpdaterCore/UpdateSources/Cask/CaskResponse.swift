// Decoding models for Homebrew's public cask JSON API, plus the matching policy.
// Shape evidence: docs/evidence/ff.json (live `api/cask/firefox.json`, generated 2026-10-26).
//
// The API's JSON shape has drifted across cask-schema versions — most notably
// `sha256` as a plain string vs. a {"string": "..."} object, and `name` as a
// string vs. an array of strings. Fields that vary decode through tolerant
// wrappers so one odd field can never void the whole document. Unknown keys are
// ignored (synthesized Codable behavior), so new API additions don't break us.

import Foundation

// MARK: - Tolerant JSON value

/// Any JSON value in the cask document. Used only where the real shape varies
/// (`name`, `artifacts`); everything else is typed directly.
enum CaskJSONValue: Decodable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([CaskJSONValue])
    case object([String: CaskJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) { self = .bool(bool); return }
        if let int = try? container.decode(Int.self) { self = .int(int); return }
        if let double = try? container.decode(Double.self) { self = .double(double); return }
        if let string = try? container.decode(String.self) { self = .string(string); return }
        if let array = try? container.decode([CaskJSONValue].self) { self = .array(array); return }
        if let object = try? container.decode([String: CaskJSONValue].self) { self = .object(object); return }
        if container.decodeNil() { self = .null; return }
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Unrecognized JSON value in cask document"
        ))
    }

    /// Recursively collect every string below `value` (handles ["A.app"],
    /// [["A.app", "B.app"]], bare strings, …) in order.
    static func collectStrings(from value: CaskJSONValue, into out: inout [String]) {
        switch value {
        case .string(let string):
            out.append(string)
        case .array(let items):
            for item in items { collectStrings(from: item, into: &out) }
        default:
            break
        }
    }
}

// MARK: - sha256 (string vs. {"string": …} object — both shapes occur)

enum CaskSHA256Value: Decodable, Sendable {
    case string(String)
    case object(hex: String?)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let hex = try? container.decode(String.self) { self = .string(hex); return }
        if let object = try? container.decode(SHA256ObjectShape.self) { self = .object(hex: object.string); return }
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Unrecognized sha256 value shape (expected string or {\"string\": …})"
        ))
    }

    var hex: String? {
        switch self {
        case .string(let hex): return hex
        case .object(let hex): return hex
        }
    }
}

private struct SHA256ObjectShape: Decodable {
    let string: String?
}

// MARK: - Cask document

struct CaskRecord: Decodable, Sendable {
    let token: String?
    let name: CaskJSONValue?
    let desc: String?
    let homepage: String?
    let url: String?
    let version: String?
    let sha256: CaskSHA256Value?
    let artifacts: CaskJSONValue?

    /// First non-empty name (cask `name` is an array in the live shape, a string in older shapes).
    var displayName: String? {
        switch name {
        case .string(let string): return string.isEmpty ? nil : string
        case .array(let items):
            for item in items {
                if case .string(let string) = item, !string.isEmpty { return string }
            }
            return nil
        default: return nil
        }
    }

    /// `app` artifact values of this cask — the `.app` bundles it installs
    /// (aliasing/rename artifacts included via recursive flattening). Deliberately
    /// NOT read from `uninstall`/`zap`, whose path strings are cleanup targets.
    var artifactAppNames: [String] {
        var names: [String] = []
        guard case .array(let directives) = artifacts else { return names }
        for directive in directives {
            guard case .object(let keys) = directive, let app = keys["app"] else { continue }
            CaskJSONValue.collectStrings(from: app, into: &names)
        }
        return names
    }

    /// `pkg` artifact values of this cask — the `.pkg` installers it claims to
    /// hand to installer(8). Mirror of `artifactAppNames`' walk (same recursive
    /// flattening of nested arrays/bare strings). Deliberately NOT read from
    /// `uninstall`/`zap`, whose path strings are cleanup targets, not installs.
    /// These names feed ONLY the strictly-gated pkg-only evidence class
    /// (CaskMatching.pkgArtifactsMatchInstalledApp) behind the staged
    /// owner-command flow — they can never satisfy the app-artifact validator.
    var pkgArtifactNames: [String] {
        var names: [String] = []
        guard case .array(let directives) = artifacts else { return names }
        for directive in directives {
            guard case .object(let keys) = directive, let pkg = keys["pkg"] else { continue }
            CaskJSONValue.collectStrings(from: pkg, into: &names)
        }
        return names
    }
}

// MARK: - Matching policy (honest boundary)

enum CaskMatching {
    /// Candidate cask token from an installed app's display name:
    /// lowercased, every run of non-alphanumeric characters becomes "-", trimmed.
    /// "Firefox" → "firefox"; "Google Chrome" → "google-chrome"; "Fantastical 2" → "fantastical-2".
    static func candidateToken(from appName: String) -> String? {
        var token = ""
        var pendingDash = true // suppresses leading dashes
        for scalar in appName.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                token.unicodeScalars.append(scalar)
                pendingDash = false
            } else if !pendingDash {
                token.unicodeScalars.append("-")
                pendingDash = true
            }
        }
        while token.hasSuffix("-") { token.removeLast() }
        return token.isEmpty ? nil : token
    }

    /// Validation is evidence-based: the cask must visibly install an app whose
    /// normalized name matches the installed app's display name OR bundle path
    /// basename (case-insensitive, ".app" suffix ignored). Anything else is a
    /// different app — never a match.
    static func caskMatchesInstalledApp(_ record: CaskRecord, for app: InstalledApp) -> Bool {
        let pathBasename = (app.path as NSString).lastPathComponent
        let installed = Set([normalizeBundleName(app.name), normalizeBundleName(pathBasename)])
        return record.artifactAppNames.contains { installed.contains(normalizeBundleName($0)) }
    }

    /// Case-insensitive comparison form; ".app" suffix dropped.
    static func normalizeBundleName(_ raw: String) -> String {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.lowercased().hasSuffix(".app") { base.removeLast(4) }
        return base.lowercased()
    }

    // MARK: - pkg-only evidence class (staged owner-command flow)

    /// Platform/build tokens that say nothing about WHICH app a pkg belongs to;
    /// never allowed to survive into a derived match name.
    private static let platformAndBuildTokens: Set<String> = [
        "macos", "mac", "osx", "apple", "silicon", "intel", "arm64", "aarch64",
        "x86_64", "x64", "universal", "installer", "install", "setup", "release",
        "stable", "latest", "final",
    ]

    /// Candidate app name derived from a pkg FILENAME, for the strictly-gated
    /// pkg-only evidence class. Deliberately conservative — a wrong derivation
    /// would stage the WRONG pkg for a sudo install, so this refuses to answer
    /// unless the leftovers unambiguously name one app:
    ///   - strip ".pkg" (input lowercased first), split on "-", "_" and spaces;
    ///   - drop version-shaped tokens (^v?[0-9]+([._-]?[0-9]+)*$, e.g. 1.104.4, v2, 4);
    ///   - drop pure-hex tokens of length ≥ 8 (build hashes);
    ///   - drop the platform/build token set (macos, arm64, universal, installer, …);
    ///   - nil when nothing survives OR any survivor contains a digit.
    /// "Tailscale-1.104.4-macos.pkg" → "tailscale"; "Sublime-Text-4.pkg" → "sublime-text".
    static func pkgDerivedMatchName(fromPkgFilename filename: String) -> String? {
        let base = filename.lowercased()
        let stem = base.hasSuffix(".pkg") ? String(base.dropLast(4)) : base
        let survivors = stem
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .filter { token in
                let token = String(token)
                return !looksLikeVersionToken(token)
                    && !looksLikeHexToken(token)
                    && !platformAndBuildTokens.contains(token)
            }
        guard !survivors.isEmpty else { return nil }
        // Conservative floor: a surviving token with a digit voids the derivation.
        let digitSurvives = survivors.contains { token in
            token.contains { ("0"..."9").contains($0) }
        }
        guard !digitSurvives else { return nil }
        return survivors.joined(separator: "-")
    }

    /// Version-shaped token: ^v?[0-9]+([._-]?[0-9]+)*$ — hand-rolled as an exact
    /// split-based equivalent of that regex (each separator-separated group must
    /// be non-empty and all-digits; adjacent separators produce an empty group
    /// and fail, matching the regex's single-separator rule). A runtime-regex
    /// failure mode must never silently change the drop policy.
    private static func looksLikeVersionToken(_ token: String) -> Bool {
        let body = token.hasPrefix("v") ? String(token.dropFirst()) : token
        if body.isEmpty { return false }
        let groups = body.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
        return groups.allSatisfy { group in
            !group.isEmpty && group.allSatisfy { ("0"..."9").contains($0) }
        }
    }

    /// Pure-hex token of length ≥ 8 — reads as a build/hash artifact, not a name.
    private static func looksLikeHexToken(_ token: String) -> Bool {
        token.count >= 8 && token.allSatisfy(\.isHexDigit)
    }

    /// The strictly-gated pkg-only match, reached ONLY when zero app-artifact
    /// matches exist (CaskIndexStore.resolvedMatch contract). A pkg-only cask
    /// validates the installed app iff ALL floors hold:
    ///   1. a derived pkg name equals the installed app's name or bundle-path
    ///      basename (same normalized comparison as the app-artifact validator);
    ///   2. the record carries a sha256 hex — a pkg claim without a checksum is
    ///      worthless (the staged flow verifies it; nothing may claim without it);
    ///   3. the record's `url` path extension (lowercased) is "pkg" — a pkg
    ///      artifact listed under a dmg/zip url is misleading evidence.
    static func pkgArtifactsMatchInstalledApp(record: CaskRecord, for app: InstalledApp) -> Bool {
        guard let hex = record.sha256?.hex?
            .trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty else { return false }
        // NSString pathExtension (not URL(string:)) so a literal-space url still
        // reads its extension — the same space-bearing urls the downstream
        // planner accepts through the source's percent-encoding fallback.
        guard let urlString = record.url, !urlString.isEmpty,
              (urlString as NSString).pathExtension.lowercased() == "pkg" else { return false }
        let pathBasename = (app.path as NSString).lastPathComponent
        let installed = Set([
            normalizeBundleName(app.name),
            normalizeBundleName(pathBasename),
        ])
        return record.pkgArtifactNames.contains { artifact in
            guard let derived = pkgDerivedMatchName(fromPkgFilename: artifact) else { return false }
            return installed.contains(derived)
        }
    }
}
