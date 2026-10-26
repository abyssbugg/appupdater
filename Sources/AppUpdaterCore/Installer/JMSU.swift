// JMSU.swift — Deploy lane (H): JMSUPlainInstaller-style atomic user-space swap.
//
// Mirrors MacUpdater's user-space installer (docs/MACUPDATER-BREAKDOWN.md §1.5.6:
// "make-permissions-movable fix → release quarantine → chown to match old app →
// preserve times → move old app to temp → move new app in → final destination;
// atomically") with the following DOCUMENTED DIVERGENCES — same order elsewhere:
//
// 1. NO CHOWN (requires root — user-space policy): JMSU chowns the new app's
//    owner/group to match the old app's (the privileged helper can). This lane is
//    strictly user-space (project security floor: nothing shells out to sudo); the
//    installing user already owns the staged tree and the rename destinations, so a
//    user-space chown has nothing to accomplish. SKIPPED, not approximated.
// 2. QUARANTINE RELEASED ONLY WHEN PRESENT: JMSU unquarantines unconditionally.
//    Here the com.apple.quarantine xattr is probed first (`xattr -p`) and only then
//    removed (`xattr -d -r`) — probe-first avoids failing an honestly unflagged
//    artifact (xattr removal returns nonzero when the attribute is absent). End
//    state is identical: the installed bundle carries no quarantine.
// 3. MTIME PRESERVATION AT ROOT ONLY: after the move-in, the new bundle's ROOT
//    modificationDate is set to the OLD root's (FileManager.setAttributes — the
//    Foundation equivalent of `touch -t`). Deeper timestamps need no fixup: the
//    staged tree's mtimes were preserved end to end by ditto (deploy) and by pure
//    renames here (rename preserves every timestamp).
// 4. OLD-COPY RETENTION PATH: JMSU/Sparkle dispose of the moved-aside old app right
//    after success. Policy here RETAINS it at `originalPath + "~~~appupdater-old~~~"`
//    — deletion/trash is the Integration lane's coordinator step. SwapResult
//    reports the exact path (SwapResult.oldAppMovedTo).
//
// Hard semantics kept from JMSU: identity is a precondition — a staged app whose
// CFBundleIdentifier differs from the installed app's is REFUSED before anything on
// disk moves (Sparkle-family bundle-id change guard). STEP 5 failure triggers an
// immediate hard rollback (old app moved back); every failing step before the first
// rename leaves both apps untouched. NOTHING shells out to sudo.
//
// Sub-lane note: plist reading mirrors Scan's InfoProbe style inline
// (PropertyListSerialization, no Bundle cache) instead of calling across lanes —
// lane-ownership rule; deliberate small duplication.

import Foundation

/// Swap: staged app bundle → final destination path, JMSU semantics.
public enum AppSwapper {
    /// Old-copy suffix (lane brief): `originalPath + "~~~appupdater-old~~~"`.
    private static let oldCopySuffix = "~~~appupdater-old~~~"

    /// Atomically swaps `staged` into `originalPath` (JMSUPlainInstaller semantics,
    /// divergences documented in the file header). Throws before the first rename
    /// leaves both apps untouched; a move-in failure rolls the old app back.
    public static func swap(staged bundle: DeployedBundle, into originalPath: String) async throws -> SwapResult {
        let stagedAppURL = bundle.stagedAppURL
        let oldAppURL = URL(fileURLWithPath: originalPath)
        let fm = FileManager.default
        var isDirectory = ObjCBool(false)

        // PRECONDITION — both sides exist as directories (honest refusal otherwise;
        // nothing has been touched yet).
        guard fm.fileExists(atPath: stagedAppURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw InstallerError.swapFailed(reason: "staged app missing or not a directory: \(stagedAppURL.path)")
        }
        guard fm.fileExists(atPath: originalPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw InstallerError.swapFailed(reason: "target app missing or not a directory: \(originalPath)")
        }

        // STEP 1 — make-permissions-movable: `chmod -R u+rwX` so later renames work
        // even if the artifact shipped read-only. Failure carries the "broken
        // permissions" detail (MacUpdater's reporting parity).
        let chmod = try await BundleDeployer.runProcess(
            launchPath: "/bin/chmod", arguments: ["-R", "u+rwX", stagedAppURL.path])
        guard chmod.succeeded else {
            throw InstallerError.swapFailed(
                reason: "broken permissions: chmod -R u+rwX failed (exit \(chmod.exitStatus)): \(chmod.stderr)")
        }

        // STEP 2 — identity guard: old vs staged CFBundleIdentifier, read BEFORE
        // anything moves. Unreadable identity = refuse (we would be replacing an app
        // we cannot vouch for); mismatch = identity hijack attempt = refuse.
        let oldInfo = IdentityProbe.infoDictionary(appBundleURL: oldAppURL)
        let newInfo = IdentityProbe.infoDictionary(appBundleURL: stagedAppURL)
        guard let oldID = IdentityProbe.string(for: ["CFBundleIdentifier"], in: oldInfo),
              !oldID.isEmpty else {
            throw InstallerError.swapFailed(
                reason: "cannot read installed CFBundleIdentifier at \(originalPath) — refusing swap")
        }
        guard let newID = IdentityProbe.string(for: ["CFBundleIdentifier"], in: newInfo),
              !newID.isEmpty else {
            throw InstallerError.swapFailed(
                reason: "cannot read staged CFBundleIdentifier at \(stagedAppURL.path) — refusing swap")
        }
        guard oldID == newID else {
            throw InstallerError.swapFailed(
                reason: "bundle identifier changed from \(oldID) to \(newID) — refusing identity hijack")
        }

        // STEP 2b — unquarantine, probe-first (divergence #2). Only the NEW app.
        let quarantineProbe = try await BundleDeployer.runProcess(
            launchPath: "/usr/bin/xattr",
            arguments: ["-p", "com.apple.quarantine", stagedAppURL.path])
        if quarantineProbe.succeeded {
            let release = try await BundleDeployer.runProcess(
                launchPath: "/usr/bin/xattr",
                arguments: ["-d", "-r", "com.apple.quarantine", stagedAppURL.path])
            guard release.succeeded else {
                throw InstallerError.swapFailed(
                    reason: "could not release quarantine on staged app (exit \(release.exitStatus)): \(release.stderr)")
            }
        }

        // mtime capture (needed by STEP 3; read before the old app moves aside).
        let oldAttributes = try? fm.attributesOfItem(atPath: originalPath)
        guard let oldMtime = oldAttributes?[.modificationDate] as? Date else {
            throw InstallerError.swapFailed(
                reason: "could not read old bundle modification date at \(originalPath) — refusing swap")
        }

        // STEP 4 — atomic move-aside: same-parent rename = same volume = atomic
        // (FileManager.moveItem uses rename(2) here). Destination must not exist —
        // moveItem fails if it does, which is an honest "previous residue" error.
        // Failure here is RAW: nothing has been touched yet, so nothing to roll back.
        let oldMovedToPath = originalPath + Self.oldCopySuffix
        let oldMovedToURL = URL(fileURLWithPath: oldMovedToPath)
        do {
            try fm.moveItem(at: oldAppURL, to: oldMovedToURL)
        } catch {
            throw InstallerError.swapFailed(
                reason: "could not move old app aside to \(oldMovedToPath) (nothing modified): \(error)")
        }

        // STEP 5 — move the new app in. On failure: hard rollback — the old app is
        // moved back FIRST and the original error rethrown; the user's app must NOT
        // be left missing. Nothing is ever deleted.
        do {
            try fm.moveItem(at: stagedAppURL, to: oldAppURL)
        } catch let moveInError {
            do {
                try fm.moveItem(at: oldMovedToURL, to: oldAppURL)
            } catch let rollbackError {
                throw InstallerError.swapFailed(
                    reason: "move of new app failed (\(moveInError)) AND rollback failed (\(rollbackError)) " +
                        "— old copy retained at \(oldMovedToPath); NOTHING was deleted")
            }
            throw InstallerError.swapFailed(
                reason: "could not move new app into place (rolled back to the original install): \(moveInError)")
        }

        // STEP 3 — preserve mtimes at the root (divergence #3). The brief numbers this
        // step third but its text is explicit: applied to the new bundle AFTER the
        // swap, at the final destination; rename already preserved everything deeper.
        do {
            try fm.setAttributes([.modificationDate: oldMtime], ofItemAtPath: originalPath)
        } catch {
            throw InstallerError.swapFailed(
                reason: "swap completed but mtime preservation failed: \(error)")
        }

        // STEP 6 — verify the installed bundle: Info.plist readable and the identity
        // STEP 2 promised is what's on disk now. Given STEP 2 + moves this cannot
        // legitimately mismatch — assert anyway (JMSU's final verification parity).
        let installedInfo = IdentityProbe.infoDictionary(appBundleURL: oldAppURL)
        guard !installedInfo.isEmpty else {
            throw InstallerError.swapFailed(
                reason: "post-swap verification failed: Info.plist unreadable at \(originalPath)")
        }
        guard let installedID = IdentityProbe.string(for: ["CFBundleIdentifier"], in: installedInfo),
              installedID == oldID else {
            throw InstallerError.swapFailed(
                reason: "post-swap verification failed: installed bundle identifier does not match expected \(oldID)")
        }
        // CFBundleShortVersionString is read for the record only — the frozen
        // InstallOutcome.finalInstalledShortVersion is filled by the coordinator's
        // post-scan step, so the swap returns no version surface.
        _ = IdentityProbe.string(for: ["CFBundleShortVersionString"], in: installedInfo)

        return SwapResult(oldAppMovedTo: oldMovedToPath)
    }

    /// Inline plist reading that mirrors Scan's InfoProbe (PropertyListSerialization,
    /// never Bundle's process-wide cache) — duplicated deliberately, not imported
    /// across lanes (lane ownership).
    private enum IdentityProbe {
        static func infoDictionary(appBundleURL url: URL) -> [String: Any] {
            let infoURL = url
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Info.plist", isDirectory: false)
            guard let data = try? Data(contentsOf: infoURL) else { return [:] }
            var format = PropertyListSerialization.PropertyListFormat.xml
            guard let root = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: &format)
            else { return [:] }
            return root as? [String: Any] ?? [:]
        }

        static func string(for keys: [String], in plist: [String: Any]) -> String? {
            for key in keys {
                switch plist[key] {
                case let string as String: return string
                case let number as NSNumber: return number.stringValue
                default: continue
                }
            }
            return nil
        }
    }
}
