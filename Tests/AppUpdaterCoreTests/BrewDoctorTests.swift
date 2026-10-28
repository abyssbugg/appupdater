// BrewDoctor tests — the `brew doctor` probe + its classification + the
// environment hardening. Hermetic: the doctor runs through the INJECTED
// BrewProcessRunner seam (a stub that records the launch path, arguments and
// the environment it was handed — no real brew is ever executed in tests; the
// consent boundary forbids it). One live-spawn test exercises the PRODUCTION
// runner against /usr/bin/env itself (a trivial always-present system binary,
// same discipline as DeployTests' live ditto/hdiutil runs) to prove the
// Deploy-mirrored spawn + environment injection actually work. Swift Testing
// only (XCTest discovery is broken on this toolchain).

import Foundation
import Testing
@testable import AppUpdaterCore

// MARK: - Stub runner (records the spawn shape it is handed)

/// Captures every (launchPath, arguments, environment) triple and answers with
/// a pre-programmed outcome (a run, or a thrown spawn failure).
private final class DoctorStubRunner: @unchecked Sendable {

    struct Call: Sendable {
        let launchPath: String
        let arguments: [String]
        let environment: [String: String]
    }

    private struct SpawnFailure: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private var exitStatus: Int32 = 0
    private var stdout = ""
    private var stderr = ""
    private var thrown: (any Error)?

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    func program(exitStatus: Int32, stdout: String, stderr: String) {
        withLock {
            self.exitStatus = exitStatus
            self.stdout = stdout
            self.stderr = stderr
            self.thrown = nil
        }
    }

    func programSpawnFailure(_ reason: String) {
        withLock {
            self.thrown = SpawnFailure(reason: reason)
        }
    }

    var recordedCalls: [Call] { withLock { calls } }

    var runner: BrewProcessRunner {
        BrewProcessRunner { [self] launchPath, arguments, environment in
            let failure: (any Error)? = withLock {
                calls.append(Call(launchPath: launchPath, arguments: arguments, environment: environment))
                return thrown
            }
            if let failure { throw failure }
            let (status, out, err) = withLock { (exitStatus, stdout, stderr) }
            return BrewProcessRun(stdout: out, stderr: err, exitStatus: status)
        }
    }
}

// MARK: - Doctor tests

@Suite(.serialized)
struct BrewDoctorTests {

    // (1) Exit 0 → clean. Output is carried verbatim as DATA (the verdict is
    // the exit code; brew's success prose is never parsed into the verdict).
    @Test func exitZeroClassifiesClean() async {
        let stub = DoctorStubRunner()
        stub.program(exitStatus: 0, stdout: "Your system is ready to brew.\n", stderr: "")
        let result = await BrewDoctorCheck(runner: stub.runner).run()

        #expect(result.verdict == .clean)
        #expect(result.exitStatus == 0)
        #expect(result.stdout == "Your system is ready to brew.\n")
        #expect(result.stderr == "")
        #expect(result.note == nil)
    }

    // (2) Exit 0 with EMPTY output → still clean (some brew builds print
    // nothing when healthy).
    @Test func exitZeroSilentIsClean() async {
        let stub = DoctorStubRunner()
        stub.program(exitStatus: 0, stdout: "", stderr: "")
        let result = await BrewDoctorCheck(runner: stub.runner).run()

        #expect(result.verdict == .clean)
        #expect(result.exitStatus == 0)
    }

    // (3) Non-zero exit → issues, with stdout AND stderr verbatim (the
    // warnings live in the output; this module never parses the prose).
    @Test func nonZeroClassifiesIssuesWithVerbatimOutput() async {
        let stub = DoctorStubRunner()
        stub.program(
            exitStatus: 1,
            stdout: "Warning: Some installed formulae are deprecated.\n",
            stderr: "Error: another complaint\n")
        let result = await BrewDoctorCheck(runner: stub.runner).run()

        #expect(result.verdict == .issues)
        #expect(result.exitStatus == 1)
        #expect(result.stdout == "Warning: Some installed formulae are deprecated.\n")
        #expect(result.stderr == "Error: another complaint\n")
        #expect(result.note == nil)
    }

    // (4) Exit 127 through /usr/bin/env → brewMissing (the documented
    // "command not found" code), NEVER conflated with "issues found".
    @Test func exit127ClassifiesBrewMissing() async {
        let stub = DoctorStubRunner()
        stub.program(exitStatus: 127, stdout: "", stderr: "env: brew: No such file or directory\n")
        let result = await BrewDoctorCheck(runner: stub.runner).run()

        #expect(result.verdict == .brewMissing)
        #expect(result.exitStatus == 127)
        #expect(result.stderr == "env: brew: No such file or directory\n")
        #expect(result.note?.contains("not found on PATH") == true)
    }

    // (5) The spawn itself failing (e.g. ENOENT on the launcher) → brewMissing
    // with the verbatim error; the doctor never throws.
    @Test func spawnThrowClassifiesBrewMissing() async {
        let stub = DoctorStubRunner()
        stub.programSpawnFailure("could not spawn /usr/bin/env (ENOENT)")
        let result = await BrewDoctorCheck(runner: stub.runner).run()

        #expect(result.verdict == .brewMissing)
        #expect(result.exitStatus == nil)
        #expect(result.stdout == "")
        #expect(result.stderr == "")
        #expect(result.note?.contains("could not spawn /usr/bin/env (ENOENT)") == true)
    }

    // (6) THE SPAWN SHAPE, pinned: `/usr/bin/env brew doctor` — the documented
    // command string routed through env for PATH resolution. Consent boundary
    // pin: no sudo anywhere in the launch shape (nothing in Brew/ elevates).
    @Test func launchShapeIsEnvBrewDoctorWithoutSudo() async throws {
        let stub = DoctorStubRunner()
        stub.program(exitStatus: 0, stdout: "", stderr: "")
        _ = await BrewDoctorCheck(runner: stub.runner).run()

        let call = try #require(stub.recordedCalls.first)
        #expect(call.launchPath == "/usr/bin/env")
        #expect(call.arguments == ["brew", "doctor"])
        #expect(call.arguments.contains("sudo") == false)
        #expect(call.launchPath.hasSuffix("sudo") == false)
        #expect(BrewDoctorCheck.launchPath == BrewProcessRunner.envLaunchPath)
        #expect(BrewDoctorCheck.arguments == ["brew", "doctor"])
    }

    // (7) THE ENVIRONMENT HARDENING, pinned: the child process is handed the
    // inherited environment with the three documented variables set to "1"
    // (captured from the stub — the seam sees exactly what the spawn gets).
    @Test func environmentHardeningIsSetOnSpawnedProcess() async throws {
        let stub = DoctorStubRunner()
        stub.program(exitStatus: 0, stdout: "", stderr: "")
        _ = await BrewDoctorCheck(runner: stub.runner).run()

        let call = try #require(stub.recordedCalls.first)
        let environment = call.environment
        #expect(environment["HOMEBREW_NO_AUTO_UPDATE"] == "1")
        #expect(environment["HOMEBREW_NO_ENV_HINTS"] == "1")
        #expect(environment["HOMEBREW_NO_INSTALL_CLEANUP"] == "1")
        // Inherited variables survive (merge OVER the inherited environment —
        // the owner's PATH must reach the child for `brew` to resolve).
        #expect(environment["PATH"] == ProcessInfo.processInfo.environment["PATH"])
        #expect(environment.count >= ProcessInfo.processInfo.environment.count)
    }

    // (8) LIVE runner (production seam): spawns /usr/bin/env for real and the
    // injected environment actually reaches the child process — the
    // Deploy-mirrored spawn path works end to end. Harmless system binary,
    // no brew involved.
    @Test func liveRunnerSpawnsAndInjectsEnvironment() async throws {
        let runner = BrewProcessRunner.live()
        let run = try await runner.run(
            "/usr/bin/env",
            [],
            ["HOMEBREW_NO_AUTO_UPDATE": "1", "PATH": "/usr/bin:/bin"])
        #expect(run.succeeded)
        #expect(run.stdout.contains("HOMEBREW_NO_AUTO_UPDATE=1"))
        #expect(run.exitStatus == 0)
    }

    // (9) LIVE runner through the doctor's classification path, with the
    // spawned arguments swapped for a name GUARANTEED absent (the real
    // `brew doctor` must never run in tests — hermetic discipline): env
    // answers "command not found" (127) or the spawn fails — both classify
    // .brewMissing honestly, with no real brew touched.
    @Test func liveRunnerMissingCommandClassifiesBrewMissing() async {
        let live = BrewProcessRunner.live()
        let missingArgumentsRunner = BrewProcessRunner { launchPath, _, environment in
            try await live.run(
                launchPath, ["brew-doctor-probe-binary-that-does-not-exist-xyz"], environment)
        }
        let result = await BrewDoctorCheck(runner: missingArgumentsRunner).run()
        #expect(result.verdict == .brewMissing)
        // Whatever env printed about the absence is carried verbatim.
        #expect(result.stderr.contains("brew-doctor-probe-binary-that-does-not-exist-xyz") || result.note != nil)
    }
}
