// Brew tier: `brew doctor` HEALTH PROBE (GAP-ANALYSIS #2 remainder).
//
// EVIDENCE (docs/reverse/UPDATEST-FINDINGS.md):
//   §3.2 line 108 — `brew doctor` is a documented command literal (Updatest
//   runs it in Terminal; here it is run as a captured child process instead —
//   see the consent boundary below).
//   §3.2 line 109 — "[confirmed] Environment hardening for child processes:
//   HOMEBREW_NO_AUTO_UPDATE, HOMEBREW_NO_ENV_HINTS, HOMEBREW_NO_INSTALL_CLEANUP".
//   Applied here EXACTLY (values "1"), merged OVER the inherited environment
//   so the owner's PATH and other settings survive into the child.
//   §3.14 — the health surface: "No Homebrew Warnings", "Fix any issues
//   reported by brew doctor, then click Try Again below." — the classification
//   below feeds exactly that shape of UI decision later (coordinator glue).
//
// CONSENT BOUNDARY (LOCKED, repo-wide): `brew doctor` is a READ-ONLY probe
// (it diagnoses, it never installs, upgrades, or removes anything). Running it
// here is sanctioned as a read-only child process; NOTHING in this file ever
// runs with sudo, and no install/update command is ever executed — command
// EXECUTION stays with the owner (MASAdopt's staged-command pattern remains
// the only sanctioned path for mutating brew operations).
//
// RUNNER SEAM: mirrors Installer/Deploy.swift's `runProcess` (Process created,
// drained, waited and read entirely inside one dispatch closure so no
// non-Sendable state crosses the Swift 6 boundary; pipes drained to EOF before
// waitUntilExit) — copied into THIS file per the lane brief (Deploy.swift is
// not modified), extended with the environment parameter the doctor needs.
// `brew` resolves through the inherited PATH via /usr/bin/env: no hardcoded
// install root (the /var/homebrew literal is unverified Workbrew-specific and
// is deliberately absent everywhere in Brew/).
//
// CLASSIFICATION (honest, exit-code-driven):
//   .clean       — exit 0. Captured output is carried verbatim regardless
//                  (brew prints "Your system is ready to brew." on success on
//                  some versions; the verdict is the EXIT CODE, output is data).
//   .issues      — any other exit EXCEPT 127, with stdout/stderr verbatim.
//                  (brew doctor signals warnings by non-zero exit; the output
//                  carries them — this module does not parse the prose.)
//   .brewMissing — exit 127 (the env/shell "command not found" code) OR the
//                  spawn itself throwing (e.g. ENOENT). Recorded with the
//                  verbatim error; never conflated with "issues found".

import Foundation

// MARK: - Process-run currency + runner seam (shared by BrewPins/BrewDoctor)

/// One finished child process: captured output + exit status (Deploy's
/// ProcessRun shape, re-declared here so Brew/ owns its seam without touching
/// the installer lane's file).
public struct BrewProcessRun: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitStatus: Int32
    public var succeeded: Bool { exitStatus == 0 }

    public init(stdout: String, stderr: String, exitStatus: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitStatus = exitStatus
    }
}

/// The injected process-runner seam. Tests stub `run` (capturing launch path,
/// arguments and the environment actually handed to the spawn); production
/// uses `live` (the Deploy-mirrored implementation below).
public struct BrewProcessRunner: Sendable {

    /// `/usr/bin/env` — the PATH-resolution trampoline for `brew …`. Present on
    /// every macOS system; the only launch path this tier hardcodes.
    public static let envLaunchPath = "/usr/bin/env"

    public typealias Run = @Sendable (
        _ launchPath: String,
        _ arguments: [String],
        _ environment: [String: String]
    ) async throws -> BrewProcessRun

    public let run: Run

    public init(_ run: @escaping Run) {
        self.run = run
    }

    /// Production runner: the Deploy.runProcess pattern + environment
    /// injection. The passed environment REPLACES the child's environment
    /// (callers merge over ProcessInfo.processInfo.environment — see
    /// BrewDoctorCheck.environment), so PATH survives by construction.
    public static func live() -> BrewProcessRunner {
        BrewProcessRunner { launchPath, arguments, environment in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BrewProcessRun, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: launchPath)
                    process.arguments = arguments
                    process.environment = environment
                    let out = Pipe()
                    let err = Pipe()
                    process.standardOutput = out
                    process.standardError = err
                    do { try process.run() } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = err.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: BrewProcessRun(
                        stdout: String(decoding: stdoutData, as: UTF8.self),
                        stderr: String(decoding: stderrData, as: UTF8.self),
                        exitStatus: process.terminationStatus))
                }
            }
        }
    }
}

// MARK: - Doctor

/// The `brew doctor` verdict. `stdout`/`stderr` are verbatim captures (data,
/// never parsed into the verdict); `exitStatus` is nil only when the spawn
/// itself failed; `note` carries the verbatim spawn failure for .brewMissing.
public struct BrewDoctorResult: Sendable, Hashable {
    public enum Verdict: Sendable, Hashable {
        /// Exit 0 — brew reports the system ready to brew.
        case clean
        /// Non-zero exit (127 excluded — that is brewMissing): warnings/issues,
        /// verbatim output attached.
        case issues
        /// `brew` could not be run at all: spawn threw, or exit 127
        /// ("command not found" through /usr/bin/env).
        case brewMissing
    }

    public let verdict: Verdict
    public let exitStatus: Int32?
    public let stdout: String
    public let stderr: String
    public let note: String?

    public init(
        verdict: Verdict,
        exitStatus: Int32?,
        stdout: String,
        stderr: String,
        note: String? = nil
    ) {
        self.verdict = verdict
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
        self.note = note
    }
}

public struct BrewDoctorCheck: Sendable {

    /// The documented environment hardening (§3.2 line 109), values exactly
    /// "1", merged OVER the inherited environment (owner's PATH survives).
    public static let hardening: [String: String] = [
        "HOMEBREW_NO_AUTO_UPDATE": "1",
        "HOMEBREW_NO_ENV_HINTS": "1",
        "HOMEBREW_NO_INSTALL_CLEANUP": "1",
    ]

    /// The child environment: inherited first, hardening wins on conflict.
    public static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in hardening { environment[key] = value }
        return environment
    }

    /// The launch shape — the documented command string routed through env for
    /// PATH resolution. Never prefixed with sudo (consent boundary: nothing in
    /// Brew/ ever elevates).
    public static let launchPath = BrewProcessRunner.envLaunchPath
    public static let arguments = ["brew", "doctor"]

    public let runner: BrewProcessRunner

    public init(runner: BrewProcessRunner) {
        self.runner = runner
    }

    /// Runs `brew doctor` and classifies the outcome. Read-only; never throws
    /// (a spawn failure IS the .brewMissing verdict, with the verbatim error).
    public func run() async -> BrewDoctorResult {
        let run: BrewProcessRun
        do {
            run = try await runner.run(Self.launchPath, Self.arguments, Self.environment())
        } catch {
            return BrewDoctorResult(
                verdict: .brewMissing,
                exitStatus: nil,
                stdout: "",
                stderr: "",
                note: String(describing: error))
        }
        switch run.exitStatus {
        case 0:
            return BrewDoctorResult(
                verdict: .clean,
                exitStatus: run.exitStatus,
                stdout: run.stdout,
                stderr: run.stderr)
        case 127:
            return BrewDoctorResult(
                verdict: .brewMissing,
                exitStatus: run.exitStatus,
                stdout: run.stdout,
                stderr: run.stderr,
                note: "exit 127 through \(Self.launchPath) — 'brew' not found on PATH")
        default:
            return BrewDoctorResult(
                verdict: .issues,
                exitStatus: run.exitStatus,
                stdout: run.stdout,
                stderr: run.stderr)
        }
    }
}
