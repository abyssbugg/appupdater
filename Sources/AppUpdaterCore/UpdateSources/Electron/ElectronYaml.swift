// Minimal flat-key YAML reader for the two electron-builder metadata documents
// this lane consumes (UPDATEST-FINDINGS §3.7 / GAP-ANALYSIS #4):
//
//   1. `app-update.yml` — Electron's own update configuration, shipped inside
//      app bundles at `Contents/Resources/app-update.yml`. Real-world shapes on
//      this machine (read-only survey 2026-10-27, see the lane evidence file):
//
//          provider: generic
//          url: 'https://desktop-release.notion-static.com'
//          channel: arm64
//          updaterCacheDirName: notion-updater
//
//          owner: granola-inc
//          repo: granola-electron
//          provider: github
//
//          provider: s3
//          bucket: bionic-updaters
//          endpoint: https://…r2.cloudflarestorage.com
//
//          provider: custom
//          bucket: termius.desktop.autoupdate
//          …
//
//      v1 consumes exactly the flat keys the brief locks: `provider`, `owner`,
//      `repo`, `url`, `channel` (channel captured but unused — the yml archive
//      variants below are skipped for v1). `s3` and `custom` providers carry no
//      resolvable `url` for the generic latest-mac.yml route, so they fall
//      through to the asar pipeline by design (documented limitation).
//
//   2. `latest-mac.yml` — electron-builder's release metadata (the artifact
//      electron-updater itself downloads; shape grammar:
//      https://www.electron.build/configuration and live sample
//      https://d1lfowv2t69uz0.cloudfront.net/stable/latest-mac.yml, read-only
//      probe 2026-10-27):
//
//          version: 0.6.0
//          files:
//            - url: Capy-0.6.0-x64.zip
//              sha512: QMkiwb8eMHxkYlvp7…
//              size: 167158770
//            - url: Capy-0.6.0-arm64.dmg
//              sha512: RwfrorQn…
//              size: 162487855
//          path: Capy-0.6.0-x64.zip
//          sha512: QMkiwb8eMHxkYlvp7…
//          releaseDate: '2026-10-27T20:29:20.738Z'
//
//      `releaseName` is also accepted (newer electron-builder adds it; some
//      feeds omit it). Integrity here is SHA-512 ONLY — no SHA-256 exists
//      upstream (Updatest finding §3.7 contract). This parser therefore never
//      produces a `sha256Hex`; see ElectronSource's sourceDetail honesty note.
//
// The parser is deliberately NOT a YAML engine: it reads the flat two-space
// indented documents electron-builder emits hand-tuned for these two shapes —
// anything unrecognizable is skipped, and a missing required field makes the
// caller treat the document honestly as unusable (nil), never a guess.

import Foundation

/// Flat `key: value` reader for `app-update.yml` (Electron's own config).
struct ElectronUpdateYml {
    var provider: String?
    var owner: String?
    var repo: String?
    var url: String?
    var channel: String?
}

/// Parsed shape of electron-builder's `latest-mac.yml` release metadata.
struct LatestMacYml {
    /// Top-level `version` — REQUIRED upstream for any claim; never synthesized.
    var version: String?
    /// File artifacts, in document order (`files:` list entries).
    var files: [LatestMacYmlFile]
    /// Top-level `path` / `sha512` (the primary artifact electron-updater picks).
    var path: String?
    var sha512: String?
    /// Human release label when the feed provides it (optional upstream).
    var releaseName: String?
    /// Raw `releaseDate` string; date conversion is done by the caller.
    var releaseDate: String?
}

/// One `files:` entry of `latest-mac.yml`: `{url, sha512, size}`.
struct LatestMacYmlFile {
    var url: String?
    var sha512: String?
    var size: Int?
}

enum ElectronYaml {
    /// Parse a flat-key `app-update.yml`. Only the keys this lane routes on are
    /// extracted; everything else (bucket/endpoint/acl/updaterCacheDirName/…)
    /// is ignored honestly. Quoted values (`'x'` / `"x"`) are stripped.
    static func parseAppUpdateYml(_ data: Data) -> ElectronUpdateYml {
        let keys = flatKeys(from: data, maxKeys: 64)
        var result = ElectronUpdateYml()
        result.provider = keys["provider"]
        result.owner = keys["owner"]
        result.repo = keys["repo"]
        result.url = keys["url"]
        result.channel = keys["channel"]
        return result
    }

    /// Parse electron-builder's `latest-mac.yml`. Tolerant of the observed
    /// shapes (quoted scalar values, `size:` numeric or absent, `releaseName`
    /// present or absent). Malformed/unusable documents return a struct whose
    /// `version`/`files` stay empty — the CALLER enforces the required-field
    /// policy (`version` REQUIRED, files list usable) because different policy
    /// rules apply to the two reading paths.
    static func parseLatestMacYml(_ data: Data) -> LatestMacYml {
        guard let text = String(data: data, encoding: .utf8) else {
            return LatestMacYml(files: [])
        }

        var topLevel = LatestMacYml(files: [])
        // Work-in-progress `files:` entry. It is appended to `topLevel.files`
        // ONLY when the next entry / top-level key / end-of-document closes it,
        // so every continuation line can mutate the same accumulator value.
        var pendingEntry = LatestMacYmlFile()
        var entryIsOpen = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("#") { continue }

            let indent = leadingSpaces(in: line)
            if indent == 0 {
                // A new top-level key ends the files section and any entry.
                if entryIsOpen {
                    topLevel.files.append(pendingEntry)
                    entryIsOpen = false
                    pendingEntry = LatestMacYmlFile()
                }
                if let (key, value) = splitKeyValue(trimmed) {
                    switch key {
                    case "version": topLevel.version = value
                    case "path": topLevel.path = value
                    case "sha512": topLevel.sha512 = value
                    case "releaseName": topLevel.releaseName = value
                    case "releaseDate": topLevel.releaseDate = value
                    case "files": break // `files:` with a list on following lines
                    default: break
                    }
                }
            } else if let dashRest = dashItemRest(trimmed) {
                // `  - url: …` — a list item in the files section.
                if entryIsOpen {
                    topLevel.files.append(pendingEntry)
                }
                pendingEntry = LatestMacYmlFile()
                entryIsOpen = true
                if let (key, value) = splitKeyValue(dashRest) {
                    applyFileKey(key, value, to: &pendingEntry)
                }
            } else if entryIsOpen {
                // Continuation of the current entry (`    sha512: …`).
                if let (key, value) = splitKeyValue(trimmed) {
                    applyFileKey(key, value, to: &pendingEntry)
                }
            }
        }
        if entryIsOpen {
            topLevel.files.append(pendingEntry)
        }
        return topLevel
    }

    /// ISO8601-first tolerant releaseDate parsing.
    /// electron-builder emits JS `Date.toISOString()` output — always
    /// ISO-8601, with or without fractional seconds ('2026-10-27T20:29:20.738Z').
    /// Older/manual feeds sometimes carry RFC-822-ish or bare timestamps; the
    /// fallbacks below accept those instead of dropping an otherwise-good
    /// claim (the field is optional metadata; failure here costs the DATE only).
    static func parseReleaseDate(_ raw: String?) -> Date? {
        guard var trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }

        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFractional.date(from: trimmed), matchesISO8601(trimmed) {
            return date
        }
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: trimmed), matchesISO8601(trimmed) {
            return date
        }
        // Tolerant fallbacks (best-effort, still anchored formats):
        var tolerantFormatters: [DateFormatter] = []
        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            tolerantFormatters.append(formatter)
        }
        for formatter in tolerantFormatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    static func matchesISO8601(_ text: String) -> Bool {
        let pattern = #"^\d{4}-\d{2}-\d{2}[Tt]\d{2}:\d{2}:\d{2}"#
        return regexSearch(pattern: pattern, in: text) != nil
    }

    static func regexSearch(pattern: String, in text: String) -> Range<String.Index>? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.range.location != NSNotFound else {
            return nil
        }
        return Range(match.range, in: text)
    }

    // MARK: - Internals

    private static func applyFileKey(_ key: String, _ value: String, to entry: inout LatestMacYmlFile) {
        switch key {
        case "url": entry.url = value
        case "sha512": entry.sha512 = value
        case "size": entry.size = Int(value)
        default: break
        }
    }

    /// Reads flat `key: value` lines (zero-indent) into a dictionary, capped at
    /// `maxKeys` values for sanity on tiny config documents.
    private static func flatKeys(from data: Data, maxKeys: Int) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var keys: [String: String] = [:]
        var count = 0
        for rawLine in text.split(separator: "\n") {
            guard count < maxKeys else { break }
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            // Zero-indent requirement: app-update.yml keys are flat; a nested
            // line (indented) is skipped rather than misattributed.
            guard !(rawLine.first == " " || rawLine.first == "\t") else { continue }
            guard let (key, value) = splitKeyValue(trimmed) else { continue }
            if keys[key] == nil { count += 1 }
            keys[key] = value
        }
        return keys
    }

    /// Splits `key: value` and strips surrounding quoting on the value.
    /// Returns nil when the line is not a `key: value` pair.
    static func splitKeyValue(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            return nil
        }
        var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        // Tolerant trailing-comment strip: electron-builder does not emit
        // comments, but hand-edited configs might; only a SPACED hash after a
        // non-empty value is treated as one (avoids eating '#' inside URLs).
        if !value.isEmpty, let hash = value.range(of: " #") {
            value = String(value[value.startIndex..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return (key, stripQuotes(value))
    }

    /// Strip a matching pair of surrounding single/double quotes (real feeds
    /// quote values like `'https://…'`, `'2026-10-27T20:29:20.738Z'`,
    /// `'@granolaelectron-updater'`).
    static func stripQuotes(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
              first == last, first == "'" || first == "\"" else { return value }
        return String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    /// For `  - url: x` returns `url: x`, nil otherwise.
    private static func dashItemRest(_ trimmedLine: String) -> String? {
        guard trimmedLine.hasPrefix("-") else { return nil }
        let rest = String(trimmedLine.dropFirst()).trimmingCharacters(in: .whitespaces)
        return rest.contains(":") ? rest : nil
    }

    private static func leadingSpaces(in line: String) -> Int {
        var count = 0
        for ch in line {
            guard ch == " " else { break }
            count += 1
        }
        return count
    }
}
