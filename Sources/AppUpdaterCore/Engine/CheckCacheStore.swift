// CheckCacheStore.swift — last-check persistence (checks-cache.json).
//
// Why: verdicts lived only in memory, so every relaunch showed "Not Checked
// Yet" until the next fire — and on battery (skipOnBattery) that could be
// hours. Updatest/MacUpdater show the last results immediately.
//
// Honesty contract:
//   - The payload is the last REAL check pass verbatim (apps + checks, each
//     check carrying its own `checkedAt`), wrapped in a versioned envelope.
//   - Missing / unparseable / other-schema file → nil (callers start empty,
//     exactly as before). Never a crash, never a partial parse.
//   - Restored checks are NEVER shown as-is: the caller must pass them
//     through `CheckCarryOver.carry` against a FRESH scan, so an app that was
//     updated, moved, or removed since the cache was written loses its stale
//     verdict (LOCKED decision 13: restoring consults no source).
//   - Writes are atomic (`Data.write(options: .atomic)`): a failed write
//     never corrupts the previous good file.

import Foundation

public struct CheckCacheStore: Sendable {

    public static let fileName = "checks-cache.json"
    public static let schemaVersion = 1

    struct Envelope: Codable {
        let schemaVersion: Int
        let savedAt: Date
        let apps: [InstalledApp]
        let checks: [UpdateCheck]
    }

    public struct Snapshot: Equatable, Sendable {
        public let savedAt: Date
        public let apps: [InstalledApp]
        public let checks: [UpdateCheck]
    }

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    public init(directory: URL) {
        self.directory = directory
    }

    /// The last saved pass, or nil when there is none worth trusting.
    public func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
              envelope.schemaVersion == Self.schemaVersion,
              envelope.apps.count == envelope.checks.count else { return nil }
        return Snapshot(savedAt: envelope.savedAt, apps: envelope.apps, checks: envelope.checks)
    }

    /// Persists one pass. `apps` and `checks` must be index-aligned (the
    /// engine's `checkAll` contract); a misaligned pair is refused.
    public func save(apps: [InstalledApp], checks: [UpdateCheck], now: Date = Date()) throws {
        guard apps.count == checks.count else { throw CacheError.misaligned(apps: apps.count, checks: checks.count) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            Envelope(schemaVersion: Self.schemaVersion, savedAt: now, apps: apps, checks: checks))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    public enum CacheError: Error, Equatable {
        case misaligned(apps: Int, checks: Int)
    }
}
