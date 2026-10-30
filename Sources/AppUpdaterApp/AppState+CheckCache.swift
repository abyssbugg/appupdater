import AppUpdaterCore
import Foundation
import os

/// Last-check persistence (checks-cache.json): rows populate at launch from
/// the previous real pass instead of "Not Checked Yet" — but only through
/// `CheckCarryOver` against a fresh scan, so changed apps never show stale
/// verdicts. Restoring consults no source (LOCKED decision 13).
extension AppState {

    var checkCacheStore: CheckCacheStore { CheckCacheStore(directory: appSupportDirectory) }

    private static let cacheLog = Logger(subsystem: "io.appupdater.AppUpdater", category: "check-cache")

    /// Called after every REAL check pass (scheduled fire with targets,
    /// manual Check Now). A failed save is logged verbatim, never fatal: the
    /// in-memory verdicts are unaffected; only the next launch starts empty.
    func persistLastChecks() {
        do {
            try checkCacheStore.save(apps: lastApps, checks: lastChecks)
        } catch {
            Self.cacheLog.error("checks-cache.json save failed — \(String(describing: error), privacy: .public)")
        }
    }

    /// After any apply (manual Update… or auto-apply): remember the
    /// shortfall case so the same claim stops re-offering (VerifiedInstallLedger).
    func recordVerifiedInstall(_ outcome: InstallOutcome) {
        do {
            try VerifiedInstallLedger(directory: appSupportDirectory).recordIfShortfall(outcome)
        } catch {
            Self.cacheLog.error("verified-installs.json save failed — \(String(describing: error), privacy: .public)")
        }
    }

    /// Launch restore: load the cache, re-scan, carry. A real check that
    /// completed meanwhile wins (its results are never overwritten).
    func restoreLastChecks() {
        guard let cached = checkCacheStore.load() else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let apps = try? await ProductionAppScanner().scan(directoryURLs: self.effectiveScanDirectories())
            else { return }
            guard self.lastChecks.isEmpty else { return }
            let carried = CheckCarryOver.carry(
                previousChecks: cached.checks, previousApps: cached.apps, newApps: apps)
            let ledger = VerifiedInstallLedger(directory: self.appSupportDirectory)
            let checks = zip(apps, carried).map { app, check in
                check.map { ledger.apply(to: $0) } ?? UpdateCheck(app: app, candidates: [], resolved: nil)
            }
            self.lastApps = apps
            self.lastChecks = checks
            let evaluated = await self.rules.evaluate(apps: apps, checks: checks)
            guard self.lastChecks == checks else { return }
            await self.list.setRows(evaluated)
        }
    }
}
