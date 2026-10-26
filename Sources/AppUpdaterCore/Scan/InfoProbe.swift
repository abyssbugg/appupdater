// InfoProbe.swift — reads an app bundle's Info.plist and extracts the values the scanner needs.
// Scan lane only (Scanner.swift / InfoProbe.swift / ScannerTests.swift).

import Foundation

enum InfoProbe {
    /// Parses `<bundle>/Contents/Info.plist` and returns its root dictionary, or an empty
    /// dictionary when the file is missing, unreadable, or not a dictionary.
    ///
    /// Reads with `PropertyListSerialization` directly instead of `Bundle(url:)` so results
    /// are never served from Bundle's process-wide cache — a re-scanned (reinstalled) bundle
    /// is always re-read from disk, and hermetic test bundles need no bundle structure beyond
    /// `Contents/Info.plist`. Handles both XML and binary plists.
    ///
    /// macOS `.app` bundles have been `Contents`-based since 10.1, so the flat (single-file)
    /// legacy format is not consulted.
    static func infoDictionary(appBundleURL url: URL) -> [String: Any] {
        let infoURL = url
            .appendingPathComponent("Contents")
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL) else { return [:] }
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let root = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: &format)
        else { return [:] }
        return root as? [String: Any] ?? [:]
    }

    /// First key present in `plist` whose value is a String (used as-is)
    /// or an NSNumber (coerced via `stringValue` — plists in the wild sometimes store
    /// numeric build versions); all other value types are skipped.
    static func string(for keys: [String], in plist: [String: Any]) -> String? {
        for key in keys {
            guard let value = plist[key] else { continue }
            switch value {
            case let string as String:
                return string
            case let number as NSNumber:
                return number.stringValue
            default:
                continue
            }
        }
        return nil
    }
}
