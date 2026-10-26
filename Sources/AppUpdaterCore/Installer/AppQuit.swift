// AppQuit.swift — graceful quit + relaunch executors for the frozen installer steps
// (`InstallStep.quitRunningApp`, `InstallStep.relaunch`). Lane quitlaunch only.
//
// EVIDENCE-BASED DESIGN (docs/MACUPDATER-BREAKDOWN.md):
// - §1.5 point 1: MacUpdater's decompiled flow is `ensureAppIsntRunning`
//   (AppQuitHelper → AppleScript quit → terminate → force-kill; handles App
//   Translocation) before touching the bundle on disk.
// - §1.5 point 7: post-install relaunch happens through a dedicated relaunch
//   helper (`LaunchUpdaterHelper` / tiny `MacUpdaterInstallHelper.app` owning a
//   URL scheme). In THIS project the relaunch request is a plain
//   `NSWorkspace.openApplication` call: the installer process itself asks
//   LaunchServices to launch the swapped bundle — no helper app needed for the
//   user-space v1 install path.
//
// FROZEN CONTRACT (Sources/AppUpdaterCore/Installer/InstallModels.swift —
// coordinator-owned; never edited by this lane):
//   `InstallStep.quitRunningApp` / `InstallStep.relaunch` name the steps,
//   `InstallerError.quitTimedOut(app:foundRunning:)` is the honest timeout error.

import Foundation
import AppKit

/// Value-type currency of the quit seams. A tiny, Sendable projection of one
/// running instance. NSRunningApplication itself is NOT Sendable and is never
/// stored in, or passed across, these seams: instances stay on the MainActor
/// inside the default closures; only refs (a bundle id, a value) cross.
public struct RunningRef: Sendable, Equatable, Hashable {
    public let bundleIdentifier: String

    public init(bundleIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Detects running instances of a bundle and quits them gracefully, then can
/// request the relaunch of the swapped bundle after the install.
///
/// # Seam design (why closures, why value refs)
/// Testing cannot construct an `NSRunningApplication` without launching a real
/// app, so the type is built entirely from injected closures; the shipped
/// `init()` wires the real AppKit behavior. Two seams for quit, one for
/// relaunch:
/// - `running: () -> [RunningRef]` — the current set of running instances,
///   projected to value refs.
/// - `terminate: (RunningRef) -> Bool` — request one instance to quit. Crash
///   path is a return value, not an error: the absence poll below decides the
///   outcome honestly.
/// - `opener: (URL) async throws -> Bool` — the relaunch request channel.
///
/// # GRACEFUL-ONLY POLICY (deliberate, v1)
/// This type never force-kills: no `kill()`, no `NSRunningApplication
/// .terminate(force:)`, no escalation ladder. `terminate` is a *request*; the
/// quit step waits for the app to actually exit (polling the provider) and
/// reports `InstallerError.quitTimedOut` honestly if it never does — the
/// operator decides what happens next. A target app that refuses to quit
/// (e.g. wants a save dialog acknowledged) therefore surfaces as a timeout,
/// never as a silent kill. WHERE FORCE COULD FIT, NEVER SILENTLY: as a later,
/// explicitly user-opted escalation step (MacUpdater exposes
/// `--force-quit-running-apps` for exactly this, MACUPDATER-BREAKDOWN §3 line
/// 206) — ordering would be AppleScript quit → `terminate()` →
/// `forceTerminate()`/`kill()`, with the chosen escalation recorded in the
/// step receipt's detail. None of that ships in v1.
///
/// # Multi-instance policy
/// Only the FIRST matching instance is asked to quit (deterministic, mirrors
/// the test contract). A second parallel instance of the same bundle id is
/// covered incidentally by the real `terminate` re-resolving by bundle id at
/// request time, and the absence poll only returns true when NO instance of
/// the id remains — but a multi-instance sweep is not a v1 guarantee.
///
/// # REALITY CHECK (honesty notes, per brief)
/// - **CLI processes**: `NSWorkspace` (and `openApplication`) are legitimate
///   from a non-GUI/CLI process on macOS; neither requires `NSApp` or an app
///   bundle around the caller. `NSWorkspace.shared.runningApplications` reads
///   the current login session's list. [confirmed by published AppKit
///   signatures + common updater precedent]
/// - **TCC / Apple Events**: the Apple Events permission prompt
///   (`kTCCServiceAppleEvents`, "…wants to control …") applies to driving
///   other apps via AppleScript/osascript. `NSWorkspace.openApplication` goes
///   through LaunchServices, not Apple Events — no Apple Events TCC prompt.
///   `NSRunningApplication.terminate()` is AppKit's own quit-request channel
///   (Sparkle stands on it without TCC prompts in the wild) [suspected — not
///   verified against every macOS version]; a *refused* request returns false
///   from the API, which this design surfaces honestly as a timeout rather
///   than swallowing.
/// - **App Translocation**: quitting by bundle id (not by on-disk path) is
///   translocation-safe — the running instance is found wherever the OS
///   staged it.
/// - **Relaunch under CLI**: the DEFAULT opener (`openApplication(at:
///   configuration:completionHandler:)` wrapped in
///   `withCheckedThrowingContinuation`) must be verified manually — real
///   launch semantics (activation policy, session context, quarantine) cannot
///   be asserted hermetically, and no test in this lane ever invokes the
///   default opener. Tests exercise only the injected opener handshake.
///
/// # Sendable discipline (Swift 6.4)
/// All NSWorkspace/NSRunningApplication touches are confined to the MainActor
/// by the seam closures' own `@MainActor @Sendable` annotation (explicit,
/// reasoned choice: `NSWorkspace.shared` is MainActor-isolated in the macOS 15
/// SDK, and a *sync* `@Sendable` closure may not hop actors — isolation on the
/// closure type is the only reflective tool available). Callers hop with
/// `await` inside the async entry points; `NSRunningApplication` values never
/// outlive their MainActor closure bodies here (`runningInstance` hands one to
/// the caller synchronously and is documented accordingly).
public struct AppTerminator: Sendable {

    /// The current running-instance set, as value refs. MainActor-confined
    /// (the default implementation reads `NSWorkspace.shared`).
    public let running: @MainActor @Sendable () -> [RunningRef]

    /// Sends a graceful quit request to one instance; `true` when the request
    /// was delivered (NOT a promise of exit). MainActor-confined (the default
    /// implementation re-resolves the instance via `NSWorkspace.shared` and
    /// calls `NSRunningApplication.terminate()`).
    public let terminate: @MainActor @Sendable (RunningRef) -> Bool

    /// Launches the app at the given URL; `true` when the launch request was
    /// dispatched successfully. MainActor-confined (the default touches
    /// `NSWorkspace.shared.openApplication`).
    public let opener: @MainActor @Sendable (URL) async throws -> Bool

    /// Poll cadence of the absence check (public default is 200 ms; the
    /// internal init takes a shorter interval for hermetic tests so test
    /// wall-clock stays tiny).
    private let pollInterval: Duration

    private static let defaultPollInterval = Duration.milliseconds(200)

    /// Shipped wiring: real workspace reads/graceful terminal request/LaunchServices
    /// relaunch. No force-kill anywhere (see policy above).
    public init() {
        let runningSeam: @MainActor @Sendable () -> [RunningRef] = {
            NSWorkspace.shared.runningApplications.compactMap { app in
                app.bundleIdentifier.map(RunningRef.init(bundleIdentifier:))
            }
        }
        let terminateSeam: @MainActor @Sendable (RunningRef) -> Bool = { ref in
            // Re-resolve by bundle id at request time instead of parking an
            // NSRunningApplication: the instance may have exited between the
            // discovery poll and this call; stale references are dropped, and
            // any remaining same-id instance is targeted (documented above).
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == ref.bundleIdentifier }?
                .terminate() ?? false
        }
        let openerSeam: @MainActor @Sendable (URL) async throws -> Bool = { url in
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Bool, any Error>) in
                NSWorkspace.shared.openApplication(
                    at: url,
                    configuration: NSWorkspace.OpenConfiguration(),
                    completionHandler: { _ /* app (not Sendable; never held) */, error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: true)
                        }
                    }
                )
            }
        }
        self.running = runningSeam
        self.terminate = terminateSeam
        self.opener = openerSeam
        self.pollInterval = Self.defaultPollInterval
    }

    /// Injectable seams + poll cadence. Internal: the public surface keeps the
    /// brief's shape (`AppTerminator()` + protocol methods); tests open this
    /// via `@testable`. The standing test contract — the DEFAULT opener is
    /// never called from tests.
    internal init(
        running: @escaping @MainActor @Sendable () -> [RunningRef],
        terminate: @escaping @MainActor @Sendable (RunningRef) -> Bool,
        opener: @escaping @MainActor @Sendable (URL) async throws -> Bool,
        pollInterval: Duration
    ) {
        self.running = running
        self.terminate = terminate
        self.opener = opener
        self.pollInterval = pollInterval
    }

    /// First running instance with the bundle id, or nil. Diagnostic helper
    /// (e.g. to show which app the quit step is about to touch); reads the
    /// real workspace, bypassing the `running` seam on purpose — the seam
    /// currency is `RunningRef`, which cannot be projected back to an
    /// NSRunningApplication. Synchronous, MainActor-confined: the returned
    /// instance never crosses an await boundary inside this type.
    @MainActor
    public func runningInstance(bundleIdentifier: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleIdentifier }
    }

    /// Gracefully quits the running instance of `bundleIdentifier`.
    ///
    /// Outcome contract (frozen by this lane's brief):
    /// - `false` — nothing was running. The caller (install executor) decides
    ///   what step receipt that means; no `terminate` request is made.
    /// - `true` — an instance was found, asked to quit, and observed GONE
    ///   (absence poll) within `timeout` seconds.
    /// - throws `InstallerError.quitTimedOut(app:foundRunning:)` with
    ///   `foundRunning: true` — an instance was found but did not exit within
    ///   `timeout`. Also propagates `CancellationError` if the task is
    ///   cancelled mid-poll (honest cancellation; no swallow).
    ///
    /// Absence polling (every 200 ms) is the truth source: `terminate`'s
    /// return value is only the request handshake, not proof of exit.
    public func quit(bundleIdentifier: String, timeout: TimeInterval = 10) async throws -> Bool {
        let candidates = await running()
        guard let target = candidates.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            // None running: step receipt is the caller's decision — the brief
            // pins "false WITHOUT calling terminate".
            return false
        }

        _ = await terminate(target)
        // Deliberate: a `false` handshake (refusal, stale instance, race) is
        // NOT fabricated into an error — the absence poll still runs and
        // reports the real outcome (app gone anyway -> true; still there ->
        // quitTimedOut). Nothing is silently assumed.

        let absent = try await awaitAbsence(of: bundleIdentifier, running: running, timeout: timeout)
        guard absent else {
            throw InstallerError.quitTimedOut(app: bundleIdentifier, foundRunning: true)
        }
        return true
    }

    /// Polls the `running` seam until no instance with the bundle id remains.
    /// Returns `true` (absent) or `false` (deadline hit first); the caller
    /// turns `false` into the frozen error. Polls BEFORE each sleep so a fast
    /// exit costs one poll, not one pollInterval.
    private func awaitAbsence(
        of bundleIdentifier: String,
        running: @MainActor @Sendable () -> [RunningRef],
        timeout: TimeInterval
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let instances = await running()
            if !instances.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
                return true
            }
            guard Date() < deadline else { return false }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// Requests the relaunch of the app at `appPath` (the SWAPPED bundle, i.e.
    /// normally the exact path that was just installed).
    ///
    /// Returns `true` when the launch REQUEST was dispatched successfully —
    /// LaunchServices accepted it. Failure surfaces honestly: the thrown error
    /// carries the underlying workspace error verbatim (its message; no
    /// re-wrapping that could hide the cause). Note there is no
    /// `InstallerError` case for relaunch refusal in the FROZEN error set, so
    /// the original error is rethrown as-is rather than shoehorned into an
    /// unrelated case.
    ///
    /// Path semantics: `URL(fileURLWithPath:)` never throws — it percent-
    /// encodes characters that are legal in paths but not in URLs (spaces →
    /// %20, …). A truly invalid *target* (not an app, not present) shows up as
    /// an error from the opener itself, which is exactly what propagates.
    public func requestRelaunch(at appPath: String) async throws -> Bool {
        try await opener(URL(fileURLWithPath: appPath))
    }
}
