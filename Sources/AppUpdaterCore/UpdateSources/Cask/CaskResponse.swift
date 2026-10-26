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
}
