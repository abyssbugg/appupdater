// AppQuitTests — hermetic: SEAM-INJECTED ONLY. The real NSWorkspace wiring is
// exercised solely on the "none running" smoke path (reading the session's
// running-app list is safe from a CLI test process); the default RELAUNCH
// opener is NEVER invoked from any test — opening a real app on the user's
// machine from a test run is forbidden by this lane's brief. Swift Testing
// only: XCTest discovery is broken on this toolchain (Xcode 27 beta).
// Planned wall-clock: every timeout path caps at ~0.3 s.

import Foundation
import Testing
@testable import AppUpdaterCore

// Reuses the test-target's LockedBox (defined in CaskSourceTests.swift —
// existing cross-test-file pattern) for thread-safe seam bookkeeping.

@Suite(.serialized)
struct AppQuitTests {

    private let ghostID = "io.appupdater.tests.never-running"
    private let sampleID = "io.appupdater.tests.sample-app"

    private func makeTerminator(
        running: @escaping @MainActor @Sendable () -> [RunningRef],
        terminate: @escaping @MainActor @Sendable (RunningRef) -> Bool = { _ in true },
        opener: @escaping @MainActor @Sendable (URL) async throws -> Bool = { _ in true },
        pollInterval: Duration = .milliseconds(10)
    ) -> AppTerminator {
        AppTerminator(running: running, terminate: terminate, opener: opener, pollInterval: pollInterval)
    }

    private func recorded(_ box: LockedBox<[RunningRef]>) -> [RunningRef] {
        box.with { $0 }
    }

    // MARK: - quit / none-running path

    // (1) Provider returns [] → quit returns false and NEVER issues a
    // terminate request (counted via the terminate seam).
    @Test func quitReturnsFalseWhenNothingRunningAndNeverSignalsTerminate() async throws {
        let requests = LockedBox<[RunningRef]>([])
        let terminator = makeTerminator(
            running: { [] },
            terminate: { ref in requests.with { list in list.append(ref); return true } }
        )

        let result = try await terminator.quit(bundleIdentifier: ghostID, timeout: 5)

        #expect(result == false)
        #expect(recorded(requests).isEmpty)  // no terminate on the none-running path
    }

    // MARK: - quit / graceful success path

    // (2) Found on the first read, gone right after the terminate request →
    // true after ONE absence poll; terminate delivered exactly once.
    @Test func quitGracefullyWhenAppExitsAfterTerminateRequest() async throws {
        let target = RunningRef(bundleIdentifier: sampleID)
        let polls = LockedBox<Int>(0)
        let requests = LockedBox<[RunningRef]>([])
        let terminator = makeTerminator(
            running: {
                // Call 1 (quit's first probe) sees the app; every poll after
                // the terminate sees it gone.
                let n = polls.with { count in count += 1; return count }
                return n >= 2 ? [] : [target]
            },
            terminate: { ref in requests.with { list in list.append(ref); return true } },
            pollInterval: .milliseconds(1)
        )

        let result = try await terminator.quit(bundleIdentifier: sampleID, timeout: 5)

        #expect(result == true)
        #expect(recorded(requests) == [target])  // one request, the matching ref
    }

    // (3) Terminate request REFUSED (false handshake) but the app exits
    // anyway → still true: the absence poll, not the handshake, is the truth.
    @Test func quitTrustsAbsencePollOverRefusedTerminateHandshake() async throws {
        let target = RunningRef(bundleIdentifier: sampleID)
        let polls = LockedBox<Int>(0)
        let terminator = makeTerminator(
            running: {
                let n = polls.with { count in count += 1; return count }
                return n >= 2 ? [] : [target]
            },
            terminate: { _ in false },  // refused (e.g. instance vanished first)
            pollInterval: .milliseconds(1)
        )

        let result = try await terminator.quit(bundleIdentifier: sampleID, timeout: 5)

        #expect(result == true)
    }

    // (4) Three instances where only the later two match → terminate is asked
    // for the FIRST MATCHING bundle id, exactly once (first-match policy; the
    // non-matching instance is untouched). Absence is scripted after the
    // request (the brief's success-path simulation), so quit returns true.
    @Test func terminateInvokedForFirstMatchingBundleIdOnly() async throws {
        let nonMatching = RunningRef(bundleIdentifier: "io.appupdater.tests.bdifferent")
        let first = RunningRef(bundleIdentifier: sampleID)
        let second = RunningRef(bundleIdentifier: sampleID)
        let polls = LockedBox<Int>(0)
        let requests = LockedBox<[RunningRef]>([])
        let terminator = makeTerminator(
            running: {
                let n = polls.with { count in count += 1; return count }
                return n >= 2 ? [] : [nonMatching, first, second]
            },
            terminate: { ref in requests.with { list in list.append(ref); return true } },
            pollInterval: .milliseconds(1)
        )

        let result = try await terminator.quit(bundleIdentifier: sampleID, timeout: 5)

        #expect(result == true)
        #expect(recorded(requests) == [first])  // first matching id, never the others
    }

    // MARK: - quit / timeout path

    // (5) Provider always reports the app running (refuses to exit) → throws
    // the frozen InstallerError.quitTimedOut(app:foundRunning: true), with the
    // app in the message; graceful-first means NO kill beyond the request.
    @Test func quitThrowsQuitTimedOutWhenAppNeverExits() async {
        let target = RunningRef(bundleIdentifier: sampleID)
        let terminator = makeTerminator(
            running: { [target] },  // always running, forever
            terminate: { _ in true },
            pollInterval: .milliseconds(20)
        )

        do {
            _ = try await terminator.quit(bundleIdentifier: sampleID, timeout: 0.3)
            Issue.record("expected InstallerError.quitTimedOut, got success")
        } catch let error as InstallerError {
            guard case .quitTimedOut(let app, let foundRunning) = error else {
                Issue.record("wrong error case: \(error)")
                return
            }
            #expect(app == sampleID)
            #expect(foundRunning == true)   // frozen honest detail: it WAS found
            #expect(error.description.contains(sampleID))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - shipped default wiring (smoke, still hermetic)

    // (6) `AppTerminator()` (real NSWorkspace seams) + a bundle id that cannot
    // exist → false, no app touched, no launch requested. Proves the real
    // MainActor-confined seams run from a CLI test process end to end.
    @Test func defaultTerminatorSeesNoGhostBundle() async throws {
        let terminator = AppTerminator()

        let result = try await terminator.quit(bundleIdentifier: ghostID, timeout: 2)

        #expect(result == false)
    }

    // MARK: - relaunch (injected opener only — never the default)

    // (7) Handshake success: opener receives the converted file URL (space →
    // %20 by URL(fileURLWithPath:), the documented Foundation behavior) and
    // the true return value travels through.
    @Test func relaunchRequestsOpenOfConvertedFileURL() async throws {
        let opened = LockedBox<[String]>([])
        let terminator = makeTerminator(
            running: { [] },
            terminate: { _ in false },
            opener: { url in
                opened.with { list in list.append(url.absoluteString) }
                return true
            }
        )

        let result = try await terminator.requestRelaunch(at: "/Applications/Some App.app")

        #expect(result == true)
        let openedPaths = opened.with { $0 }
        #expect(openedPaths.count == 1)
        #expect(openedPaths[0].hasPrefix("file://"))
        #expect(openedPaths[0].contains("%20"))  // spaces are percent-encoded, not dropped
    }

    // (8) Path oddities (newline in the path component) survive conversion:
    // Foundation percent-encodes them; the opener handshake still reports the
    // request as dispatched. (Honest reshaping of the brief's "invalid
    // characters → throws": URL(fileURLWithPath:) does not throw; real
    // refusals arrive as opener errors — covered by the next test.)
    @Test func relaunchConvertsOddCharactersIntoPercentEncodedURL() async throws {
        let opened = LockedBox<[String]>([])
        let terminator = makeTerminator(
            running: { [] },
            terminate: { _ in false },
            opener: { url in
                opened.with { list in list.append(url.absoluteString) }
                return true
            }
        )

        let result = try await terminator.requestRelaunch(at: "/Applications/bad\nname.app")

        #expect(result == true)
        let openedPaths = opened.with { $0 }
        #expect(openedPaths.count == 1)
        #expect(!openedPaths[0].contains("\n"))  // encoded into the URL, never raw
    }

    // (9) Honest failure: an opener error propagates with its underlying
    // message verbatim (the default opener rethrows the workspace error
    // as-is; here the same plumbing is verified with a typed fake).
    private struct RelaunchRejected: Error {
        let message: String
    }

    @Test func relaunchPropagatesOpenerRefusalMessageVerbatim() async {
        let terminator = makeTerminator(
            running: { [] },
            terminate: { _ in false },
            opener: { _ in throw RelaunchRejected(message: "workspace refused /bogus/path.app") }
        )

        do {
            _ = try await terminator.requestRelaunch(at: "/bogus/path.app")
            Issue.record("expected relaunch refusal to throw")
        } catch let error as RelaunchRejected {
            #expect(error.message.contains("workspace refused /bogus/path.app"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}
