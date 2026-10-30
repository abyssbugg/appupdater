// VerifiedInstallLedger.swift — verified-install memory (verified-installs.json).
//
// Why (live 2026-10-30, owner decision "remember verified install"): cmux's
// v0.65.2.2 dmg still declares CFBundleShortVersionString 0.65.2. A fully
// verified apply (HTTPS + sha256, swap, post-scan) therefore reads back as
// 0.65.2 and every later check re-offers 0.65.2.2 forever.
//
// Contract:
//   - A record is written ONLY after a fully green apply (no aborted step)
//     whose post-scan version is still BELOW the claim — i.e. exactly the
//     shortfall case. Normal applies never touch the ledger.
//   - A record suppresses a resolved claim ONLY on an exact match of ALL of:
//     bundle id, path, claimed short version, installed short version, and the
//     SHA-256 of the bundle's main executable taken at record time. Any vendor
//     change to the bundle (new bytes) or a NEWER claim ends the suppression.
//   - Suppression is never silent: the check carries `verifiedInstallNote`.
//   - Missing/unparseable file → empty ledger (behavior exactly as before).

import Foundation

public struct VerifiedInstallLedger: Sendable {

    public static let fileName = "verified-installs.json"

    public struct Record: Codable, Hashable, Sendable {
        public let bundleIdentifier: String
        public let path: String
        public let claimedShortVersion: String
        public let installedShortVersion: String
        public let executableSHA256: String
        public let recordedAt: Date

        public init(bundleIdentifier: String, path: String, claimedShortVersion: String,
                    installedShortVersion: String, executableSHA256: String, recordedAt: Date) {
            self.bundleIdentifier = bundleIdentifier
            self.path = path
            self.claimedShortVersion = claimedShortVersion
            self.installedShortVersion = installedShortVersion
            self.executableSHA256 = executableSHA256
            self.recordedAt = recordedAt
        }
    }

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    public init(directory: URL) {
        self.directory = directory
    }

    public func load() -> [Record] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Record].self, from: data)) ?? []
    }

    /// Upsert keyed by (bundle id, path): one live record per installed app.
    public func save(_ record: Record) throws {
        var records = load().filter { !($0.bundleIdentifier == record.bundleIdentifier && $0.path == record.path) }
        records.append(record)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(records).write(to: fileURL, options: .atomic)
    }

    /// Records the shortfall case of a finished apply; returns the record
    /// written, or nil when the outcome does not qualify (not green, claim
    /// reached, version unreadable, or executable unhashable).
    @discardableResult
    public func recordIfShortfall(_ outcome: InstallOutcome, now: Date = Date()) throws -> Record? {
        guard outcome.abortedStep == nil,
              let installed = outcome.finalInstalledShortVersion else { return nil }
        let bundleID = outcome.plan.app.bundleIdentifier
        let claimed = outcome.plan.update.newestShortVersion
        guard VersionOracle().isUpdateAvailable(installed: installed, available: claimed),
              let hash = Self.executableSHA256(appPath: outcome.plan.app.path) else { return nil }
        let record = Record(bundleIdentifier: bundleID, path: outcome.plan.app.path,
                            claimedShortVersion: claimed, installedShortVersion: installed,
                            executableSHA256: hash,
                            // Whole seconds: the ISO-8601 file format drops fractions, so the
                            // returned record equals exactly what a later load() reads.
                            recordedAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)))
        try save(record)
        return record
    }

    /// The record that vouches for `app` already holding `claimedVersion`, or nil.
    public func matchingRecord(
        for app: InstalledApp,
        claimedVersion: String,
        executableHash: (String) -> String? = Self.executableSHA256(appPath:)
    ) -> Record? {
        let candidates = load().filter {
            $0.bundleIdentifier == app.bundleIdentifier && $0.path == app.path
                && $0.claimedShortVersion == claimedVersion && $0.installedShortVersion == app.shortVersion
        }
        guard let record = candidates.last, executableHash(app.path) == record.executableSHA256 else { return nil }
        return record
    }

    /// THE one suppression rule, shared by the engine (fresh checks) and the
    /// launch cache restore (cached checks written before a record existed) —
    /// one resolver per decision, so no path can skip it.
    public func apply(
        to check: UpdateCheck,
        executableHash: (String) -> String? = Self.executableSHA256(appPath:)
    ) -> UpdateCheck {
        guard let claim = check.resolved,
              let record = matchingRecord(for: check.app, claimedVersion: claim.newestShortVersion,
                                          executableHash: executableHash) else { return check }
        var suppressed = UpdateCheck(app: check.app, candidates: check.candidates,
                                     failures: check.failures, resolved: nil)
        suppressed.verifiedInstallNote = "\(claim.newestShortVersion) was installed and verified on "
            + "\(record.recordedAt.formatted(.iso8601)); the vendor's bundle declares "
            + "\(record.installedShortVersion), so the claim is treated as current until the bundle changes"
        return suppressed
    }

    /// SHA-256 of the bundle's main executable (CFBundleExecutable), or nil.
    public static func executableSHA256(appPath: String) -> String? {
        let bundle = URL(fileURLWithPath: appPath)
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              case let executable = (info["CFBundleExecutable"] as? String)
                ?? bundle.deletingPathExtension().lastPathComponent,
              !executable.isEmpty, !executable.contains("/") else { return nil }
        return try? Checksum.sha256Hex(ofFile: bundle.appendingPathComponent("Contents/MacOS/\(executable)"))
    }
}
