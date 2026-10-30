import Foundation

/// Utility to preserve check verdicts across inventory-only rescans.
///
/// LOCK DECISION 13 (LOCKED 2026-10-27): FSEvents on /Applications trigger
/// inventory refreshes only, never source lookups, notification posts, schedule
/// mutations, or installs. But refreshInventoryOnly() must NOT discard previous
/// check verdicts — only vanished or version-changed apps lose their checks.
///
/// A check is kept ONLY when:
/// - The same bundleIdentifier exists in the new scan
/// - At the same path
/// - With the same shortVersion AND bundleVersion (both nil or both equal)
///
/// All other cases: the check is dropped (app vanished, self-updated, or user moved it).
public enum CheckCarryOver {
    /// Carry over previous checks to a rescanned app list, preserving verdicts for
    /// unchanged apps and dropping checks for vanished or version-changed ones.
    ///
    /// - Parameters:
    ///   - previousChecks: The prior check results (from UpdateCheckEngine.checkAll).
    ///   - previousApps: The prior app scan (from a prior scan()).
    ///   - newApps: The current app scan (from the latest scan()).
    ///
    /// - Returns: A parallel-indexed array of checks matching newApps:
    ///   - Entries for apps that match (same bundleIdentifier, path, and versions) retain
    ///     their previous check verdicts.
    ///   - Entries for new or changed apps are nil (no check yet).
    ///   - Order follows newApps.
    public static func carry(
        previousChecks: [UpdateCheck],
        previousApps: [InstalledApp],
        newApps: [InstalledApp]
    ) -> [UpdateCheck?] {
        // Build a lookup map from the previous run, keyed by (bundleIdentifier, path).
        // We store the check with its matched app so we can verify version consistency.
        var prior: [String: (app: InstalledApp, check: UpdateCheck)] = [:]
        for (index, app) in previousApps.enumerated() {
            guard index < previousChecks.count else { break }
            let key = checksumKey(app)
            prior[key] = (app, previousChecks[index])
        }

        // For each new app, attempt to find its prior check.
        return newApps.map { newApp in
            let key = checksumKey(newApp)
            guard let (prevApp, prevCheck) = prior[key] else {
                // New app or path changed: no carried check.
                return nil
            }

            // Verify version consistency before carrying the check.
            if prevApp.shortVersion == newApp.shortVersion &&
               prevApp.bundleVersion == newApp.bundleVersion {
                // Versions match: this is the same app, carry the check.
                return prevCheck
            }

            // Versions changed (self-update): discard and let a new check run next.
            return nil
        }
    }

    /// Compute a stable lookup key for an app: (bundleIdentifier, path).
    /// Two apps with the same key are considered "the same app" for carry-over purposes.
    private static func checksumKey(_ app: InstalledApp) -> String {
        "\(app.bundleIdentifier)|\(app.path)"
    }
}
