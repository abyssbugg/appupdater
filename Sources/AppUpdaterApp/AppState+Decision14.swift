// AppState+Decision14.swift — the LOCKED decision-14 surfaces (auto-apply +
// Terminal typing), extracted from AppState.swift for file-length lint while
// keeping one cohesive home for the amended consent boundary. Access note:
// these members are internal; the main-file call sites assign the published
// receipts / error surfaces (private(set) setters stay in the class body).

import AppKit
import Foundation
import AppUpdaterCore

extension AppState {

    // MARK: Decision-14 auto-apply (opt-in per-app, user-space only)

    /// The amended consent boundary in code (LOCKED decision 14): the master
    /// switch defaults OFF and per-app opt-in defaults OFF — with both off
    /// (the shipped state) this pass reads one settings file and returns.
    /// Gate-cleared apps run the SAME verified chain the CLI --apply uses
    /// (backup → quit → swap → postScan, receipts verbatim); the gate refuses
    /// pkg/vendor/MAS/ignored artifacts before any planning, so the
    /// privileged staged-command path is unreachable from here by
    /// construction. Serialized on purpose (installs are heavy); relaunch is
    /// NEVER automatic — the receipt notes the app was swapped and closed.
    /// Returns the pass receipt (the class body publishes it).
    func runAutoApplyPass(evaluated: [AppRow]) async -> AutoApplyRunReceipt {
        let settings = (try? await autoApplySettingsStore.load()) ?? AutoApplySettings()
        guard settings.autoApplyEnabled else {
            return AutoApplyRunReceipt(startedAt: Date(), finishedAt: Date(), outcomes: [])
        }   // master OFF: zero work
        let engineProbe = ScheduleEngine(fire: { _ in 0 })
        let onBattery = engineProbe.isOnBattery()
        let isOnline = engineProbe.isOnline()
        let running = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        let planner = InstallPlanner()
        let fm = FileManager.default
        let stagingRoot = appSupportDirectory.appendingPathComponent("staging", isDirectory: true)
        let backupsRoot = appSupportDirectory.appendingPathComponent("backups", isDirectory: true)
        try? fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: backupsRoot, withIntermediateDirectories: true)

        let passStartedAt = Date()
        var outcomes: [AutoApplyOutcome] = []
        for row in evaluated {
            guard let check = row.check else { continue }
            let input = AutoApplyGateInput(
                app: row.app,
                check: check,
                autoApplyEnabled: settings.autoApplyEnabled,
                perAppOptIn: settings.isOptedIn(bundleIdentifier: row.app.bundleIdentifier),
                policy: schedule.policy,
                onBattery: onBattery,
                isOnline: isOnline,
                runningBundleIdentifiers: running,
                ruleDecision: row.decision)
            let decidedAt = Date()
            switch AutoApplyGate.decide(input) {
            case .skip(let skip):
                outcomes.append(AutoApplyOutcome(
                    app: row.app, decidedAt: decidedAt, decision: .skip(skip)))
            case .apply:
                guard let update = check.resolved else { continue }
                do {
                    let plan = try planner.plan(app: row.app, update: update)
                    let installOutcome = try await InstallCoordinator().run(
                        plan, stagingRoot: stagingRoot, backupsRoot: backupsRoot,
                        relaunchRequested: false)
                    outcomes.append(AutoApplyOutcome(
                        app: row.app, decidedAt: decidedAt, decision: .apply,
                        installOutcome: installOutcome))
                } catch {
                    // Planning/apply failure = an honest receipt, never a crash
                    // and never a silent skip (decision .apply with the note).
                    outcomes.append(AutoApplyOutcome(
                        app: row.app, decidedAt: decidedAt, decision: .apply,
                        installOutcome: nil, planningNote: String(describing: error)))
                }
            }
        }
        return AutoApplyRunReceipt(
            startedAt: passStartedAt, finishedAt: Date(), outcomes: outcomes)
    }

    // MARK: Terminal typing (GAP #25 wiring — per-use consent)

    /// Runs a staged owner-command in the owner's default terminal via the
    /// Terminal-typing module. THE CLICK IS THE CONSENT
    /// (`userApprovedTyping: true` — nothing types without a deliberate
    /// button press; CopyPaste remains the default surface). The script runs
    /// via NSAppleScript; the first use triggers macOS's automation
    /// permission prompt (Terminal/iTerm2), which the owner approves or
    /// denies — both honest outcomes. Returns the verbatim error for the
    /// action banner, or nil on success (the class body publishes it).
    func terminalTypingError(for command: String) -> String? {
        do {
            let store = TerminalEmulatorStore(directory: appSupportDirectory)
            let emulator = (try store.loadDefault()) ?? .terminal
            let script = try TerminalScriptBuilder.typingScript(
                command: command, emulator: emulator, userApprovedTyping: true)
            var errorInfo: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
            if let errorInfo {
                return "Terminal automation failed: \(errorInfo)"
            }
            return nil
        } catch {
            return "Terminal automation refused: \(error)"
        }
    }
}
