// VendorWatchTests.swift — hermetic tests for the vendor-installer flow and
// the post-install rescan watch (GAP #13, lane vendor-rules).
//
// Swift Testing ONLY (XCTest discovery is broken on this toolchain — AGENTS.md
// gotcha ledger); Foundation imported separately (Swift Testing does not
// re-export it).
//
// Hermeticity: no network, no subprocesses, no launched installers — the
// vendor-installer flow is STAGED STRINGS and the watch is a poll loop over
// injected seams (fake clock, counting wait, scripted probes). File fixtures
// live in fresh per-test UUID temp roots (the per-process-unique-root rule:
// never a shared wiped constant). Mach-O fixtures for the Electron detector
// are constructed byte-by-byte, as in CandidateFilterTests. No force unwraps
// anywhere (the lint gate errors on force_unwrapping, tests included).

import Foundation
import Testing
@testable import AppUpdaterCore

@Suite
struct VendorWatchTests {

    // MARK: - Fixtures

    private let fm = FileManager.default

    private func newRoot() throws -> URL {
        let url = fm.temporaryDirectory
            .appendingPathComponent("vendorwatch-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A minimal .app bundle shell with an Info.plist carrying (or omitting)
    /// a CFBundleIdentifier — read-only probe fodder, nothing executable.
    private func makeAppBundle(named name: String,
                               bundleIdentifier: String?,
                               in root: URL,
                               nestedUnder: String? = nil) throws -> URL {
        var bundleURL = root
        if let nested = nestedUnder {
            bundleURL = bundleURL.appendingPathComponent(nested, isDirectory: true)
        }
        bundleURL = bundleURL.appendingPathComponent(name, isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        if let bundleIdentifier {
            let plist: [String: Any] = ["CFBundleIdentifier": bundleIdentifier, "CFBundleName": name]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        return bundleURL
    }

    private func writeFile(_ name: String, bytes: [UInt8], in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func makePlan(app: InstalledApp, kind: InstallKind = .dmg) -> InstallPlan {
        InstallPlan(
            app: app,
            update: UpdateInfo(source: .cask, newestShortVersion: "2.0"),
            kind: kind,
            steps: [.download, .verifySha256],
            warnings: [])
    }

    private func makeApp(path: String, bundleID: String = "com.example.foo") -> InstalledApp {
        InstalledApp(bundleIdentifier: bundleID, name: "Foo", path: path)
    }

    /// Thin 64-bit Mach-O header (magic MH_MAGIC_64 LE + cputype LE +
    /// subtype/filetype + zero tail) — enough for MachOArchParser.
    private func thinMachO(cputype: UInt32) -> [UInt8] {
        func le(_ value: UInt32) -> [UInt8] {
            [UInt8(truncatingIfNeeded: value),
             UInt8(truncatingIfNeeded: value >> 8),
             UInt8(truncatingIfNeeded: value >> 16),
             UInt8(truncatingIfNeeded: value >> 24)]
        }
        return le(0xFEED_FACF) + le(cputype) + le(0) + le(2) + [UInt8](repeating: 0, count: 8)
    }

    // MARK: - Thread-safe counters (wait/probe call tracking)

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }
        var current: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// Fake clock: hand-advanced, handed to the watch as the clock seam.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var now: Date
        init(start: Date) { now = start }
        var time: Date {
            lock.lock()
            defer { lock.unlock() }
            return now
        }
        func advance(_ interval: TimeInterval) {
            lock.lock()
            now = now.addingTimeInterval(interval)
            lock.unlock()
        }
    }

    /// Scripted probe: plays back queued outcomes, then repeats the last.
    private final class ScriptedProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [PostInstallProbeOutcome]
        init(_ outcomes: [PostInstallProbeOutcome]) { queue = outcomes }
        func probe(_ target: PostInstallWatchTarget) -> PostInstallProbeOutcome {
            lock.lock()
            defer { lock.unlock() }
            if queue.count > 1 { return queue.removeFirst() }
            return queue.first ?? .notFound(notes: ["script exhausted"])
        }
    }

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: VendorInstallerFlow — classification + staging

    @Test
    func installerBundleNameRejectStagesOwnerRunFlow() throws {
        let root = try newRoot()
        let installer = try makeAppBundle(named: "Click_to_install.app", bundleIdentifier: "com.vendor.installer", in: root)
        let app = makeApp(path: "/Applications/Foo.app")
        let outcome = VendorInstallerFlow.stageOwnerRunInstall(plan: makePlan(app: app), stagedInstallerURL: installer)

        guard case .staged = outcome.classification else {
            Issue.record("expected .staged, got \(outcome.classification.rawValue); notes: \(outcome.notes)")
            return
        }
        let staging = try #require(outcome.staging)
        #expect(staging.launchCommand == "open \"\(installer.path)\"")
        #expect(staging.installerPath == installer.path)
        #expect(staging.expectedInstallDirectory == "/Applications")
        #expect(staging.expectedAppBundleName == "Foo.app")
        #expect(staging.watch.expectedDirectory == "/Applications")
        #expect(staging.watch.expectedBundleIdentifier == "com.example.foo")
        #expect(staging.classificationReason.contains("installer-bundle name"))
        // The filter report travels verbatim and its installer detector is the classifier.
        let report = try #require(outcome.filterReport)
        #expect(report.installerBundle.outcome == .reject)
        #expect(staging.notes.contains { $0.contains("NOTHING is executed by AppUpdater") })
        #expect(staging.notes.contains { $0.contains("security floor") })
        #expect(staging.notes.contains { $0.contains("EXPECTATION") })
    }

    @Test
    func installBuilderMarkerRejectStagesOwnerRunFlow() throws {
        let root = try newRoot()
        let installer = try makeAppBundle(named: "VendorApp.app", bundleIdentifier: "com.vendor.app", in: root)
        try fm.createDirectory(at: installer.appendingPathComponent("Contents/MacOS", isDirectory: true),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: installer.appendingPathComponent("Contents/Resources", isDirectory: true),
                               withIntermediateDirectories: true)
        let marker = installer.appendingPathComponent("Contents/Resources/installer.dat")
        try Data([0x00]).write(to: marker)
        let app = makeApp(path: "/Applications/VendorApp.app", bundleID: "com.vendor.app")
        let outcome = VendorInstallerFlow.stageOwnerRunInstall(plan: makePlan(app: app), stagedInstallerURL: installer)

        guard case .staged = outcome.classification else {
            Issue.record("expected .staged, got \(outcome.classification.rawValue)")
            return
        }
        let report = try #require(outcome.filterReport)
        #expect(report.installBuilder.outcome == .reject)
        #expect(report.installerBundle.outcome == .accept) // name check passed; the MARKER classified it
        let staging = try #require(outcome.staging)
        #expect(staging.classificationReason.contains("InstallBuilder"))
    }

    @Test
    func electronWrongArchRejectIsNeverAnInstallerClassification() throws {
        let root = try newRoot()
        // A bundle named like a normal app whose Electron payload declares
        // x86_64 only: on an arm64 host the documented wrongOCTag check
        // rejects it; on an x86_64 host the payload is runnable and the
        // filter accepts. NEITHER verdict is an installer classification,
        // so the flow must refuse to stage on every host.
        let payloadHost = try makeAppBundle(named: "ElectronApp.app", bundleIdentifier: "com.electron.app", in: root)
        try fm.createDirectory(at: payloadHost.appendingPathComponent("Contents/MacOS", isDirectory: true),
                               withIntermediateDirectories: true)
        _ = try writeFile("osx_x86_64", bytes: thinMachO(cputype: 0x0100_0007), in: payloadHost.appendingPathComponent("Contents/MacOS"))
        let app = makeApp(path: "/Applications/ElectronApp.app", bundleID: "com.electron.app")
        let outcome = VendorInstallerFlow.stageOwnerRunInstall(plan: makePlan(app: app), stagedInstallerURL: payloadHost)

        #expect(outcome.classification == .notAnInstallerCandidate)
        #expect(outcome.staging == nil)
        let report = try #require(outcome.filterReport)
        let hostArch = try #require(CandidateFilter.runningMachineArch)
        if hostArch == .arm64 {
            #expect(report.electronWrongArch.outcome == .reject)
        } else {
            #expect(report.electronWrongArch.outcome == .accept)
        }
        #expect(report.installerBundle.outcome == .accept)
        #expect(report.installBuilder.outcome == .accept)
    }

    @Test
    func unfilterableArtifactIsHonestUnproven() throws {
        let root = try newRoot()
        let ghost = root.appendingPathComponent("does-not-exist.app")
        let outcome = VendorInstallerFlow.stageOwnerRunInstall(
            plan: makePlan(app: makeApp(path: "/Applications/Foo.app")),
            stagedInstallerURL: ghost)
        #expect(outcome.classification == .unproven)
        #expect(outcome.staging == nil)
        let report = try #require(outcome.filterReport)
        #expect(report.overall.outcome == .unknown)
    }

    @Test
    func normalAppUpdateCandidateIsNotStaged() throws {
        let root = try newRoot()
        let plainBundle = try makeAppBundle(named: "Foo.app", bundleIdentifier: "com.example.foo", in: root)
        let outcome = VendorInstallerFlow.stageOwnerRunInstall(
            plan: makePlan(app: makeApp(path: "/Applications/Foo.app")),
            stagedInstallerURL: plainBundle)
        #expect(outcome.classification == .notAnInstallerCandidate)
        #expect(outcome.staging == nil)
        #expect(outcome.notes.contains { $0.contains("not staged as a vendor installer") })
    }

    @Test
    func pkgPlanIsRefusedToTheStagedPkgFlow() throws {
        let root = try newRoot()
        let installer = try makeAppBundle(named: "installer.app", bundleIdentifier: nil, in: root)
        let outcome = VendorInstallerFlow.stageOwnerRunInstall(
            plan: makePlan(app: makeApp(path: "/Applications/Foo.app"), kind: .pkg),
            stagedInstallerURL: installer)
        #expect(outcome.classification == .refusedPkgPlan)
        #expect(outcome.staging == nil)
        #expect(outcome.filterReport == nil)
        #expect(outcome.notes.contains { $0.contains("GAP #11") })
    }

    @Test
    func emptyPlanInputIsInvalidAndNeverStaged() throws {
        let outcome = VendorInstallerFlow.stageOwnerRunInstall(
            plan: makePlan(app: makeApp(path: "   ")),
            stagedInstallerURL: URL(fileURLWithPath: "/tmp/whatever.app"))
        #expect(outcome.classification == .invalidInput)
        #expect(outcome.staging == nil)
        #expect(outcome.filterReport == nil)
    }

    @Test
    func expectedDirectoryOverrideIsHonoredEverywhere() throws {
        let root = try newRoot()
        let installer = try makeAppBundle(named: "setup.app", bundleIdentifier: nil, in: root)
        let override = URL(fileURLWithPath: "/Volumes/Custom/Apps")
        let outcome = VendorInstallerFlow.stageOwnerRunInstall(
            plan: makePlan(app: makeApp(path: "/Applications/Foo.app")),
            stagedInstallerURL: installer,
            expectedInstallDirectory: override)
        let staging = try #require(outcome.staging)
        #expect(staging.expectedInstallDirectory == "/Volumes/Custom/Apps")
        #expect(staging.watch.expectedDirectory == "/Volumes/Custom/Apps")
    }

    @Test
    func launchCommandShellQuotesHostilePaths() throws {
        #expect(VendorInstallerFlow.shellQuoted("/tmp/a b.app") == "\"/tmp/a b.app\"")
        #expect(VendorInstallerFlow.shellQuoted("/tmp/a\"b.app") == "\"/tmp/a\\\"b.app\"")
        #expect(VendorInstallerFlow.shellQuoted("/tmp/a$b`c\\d.app") == "\"/tmp/a\\$b\\`c\\\\d.app\"")
        let root = try newRoot()
        let hostile = try makeAppBundle(named: "My Installer.app", bundleIdentifier: nil, in: root)
        // "My Installer.app" matches NO documented name — the marker check is
        // what classifies it, so give it the documented InstallBuilder marker.
        try fm.createDirectory(at: hostile.appendingPathComponent("Contents/Resources", isDirectory: true),
                               withIntermediateDirectories: true)
        try Data([0x00]).write(to: hostile.appendingPathComponent("Contents/Resources/installer.dat"))
        let outcome = VendorInstallerFlow.stageOwnerRunInstall(
            plan: makePlan(app: makeApp(path: "/Applications/Foo.app")),
            stagedInstallerURL: hostile)
        let staging = try #require(outcome.staging)
        #expect(staging.launchCommand == "open \"\(hostile.path)\"")
    }

    @Test
    func stagedOutcomeCodableRoundTrips() throws {
        let root = try newRoot()
        let installer = try makeAppBundle(named: "installer.app", bundleIdentifier: "com.vendor.installer", in: root)
        let outcome = VendorInstallerFlow.stageOwnerRunInstall(
            plan: makePlan(app: makeApp(path: "/Applications/Foo.app")),
            stagedInstallerURL: installer)
        let data = try JSONEncoder().encode(outcome)
        let decoded = try JSONDecoder().decode(VendorFlowOutcome.self, from: data)
        #expect(decoded == outcome)
    }

    // MARK: PostInstallRescan — loop semantics over injected seams

    @Test
    func watchReportsAppearedOnFirstProbe() async {
        let target = PostInstallWatchTarget(expectedDirectory: "/Applications",
                                            expectedBundleIdentifier: "com.example.foo",
                                            expectedAppBundleName: "Foo.app")
        let waits = LockedCounter()
        let clock = FakeClock(start: Self.epoch)
        let report = await PostInstallRescan.watch(
            target: target,
            pollInterval: 1,
            timeout: 10,
            clock: { clock.time },
            wait: { _ in waits.increment() },
            probe: { _ in .found(bundlePath: "/Applications/Foo.app", bundleIdentifier: "com.example.foo") })
        guard case .appeared(let path, let bid) = report.outcome else {
            Issue.record("expected appeared, got \(report.outcome)")
            return
        }
        #expect(path == "/Applications/Foo.app")
        #expect(bid == "com.example.foo")
        #expect(report.pollsCompleted == 1)
        #expect(waits.current == 0)
        #expect(report.startedAt == Self.epoch)
        #expect(report.endedAt == Self.epoch)
        #expect(report.notes.isEmpty)
    }

    @Test
    func watchPollsUntilAppearanceAndCountsWaits() async {
        let target = PostInstallWatchTarget(expectedDirectory: "/Applications",
                                            expectedBundleIdentifier: "com.example.foo",
                                            expectedAppBundleName: "Foo.app")
        let probe = ScriptedProbe([
            .notFound(notes: ["nothing yet"]),
            .notFound(notes: ["still nothing"]),
            .found(bundlePath: "/Applications/Renamed.app", bundleIdentifier: "com.example.foo"),
        ])
        let waits = LockedCounter()
        let clock = FakeClock(start: Self.epoch)
        let report = await PostInstallRescan.watch(
            target: target,
            pollInterval: 30,
            timeout: 600,
            clock: { clock.time },
            wait: { interval in
                waits.increment()
                clock.advance(interval)
            },
            probe: { probe.probe($0) })
        guard case .appeared(let path, _) = report.outcome else {
            Issue.record("expected appeared, got \(report.outcome)")
            return
        }
        #expect(path == "/Applications/Renamed.app") // renamed bundle still matches by BID
        #expect(report.pollsCompleted == 3)
        #expect(waits.current == 2)
        #expect(report.endedAt.timeIntervalSince(report.startedAt) == 60) // fake clock advanced 2×30s
    }

    @Test
    func watchTimesOutHonestWithLastNotes() async {
        let target = PostInstallWatchTarget(expectedDirectory: "/Applications",
                                            expectedBundleIdentifier: "com.example.foo",
                                            expectedAppBundleName: "Foo.app")
        let probe = ScriptedProbe([.notFound(notes: ["only Bar.app here"])])
        let waits = LockedCounter()
        let clock = FakeClock(start: Self.epoch)
        let report = await PostInstallRescan.watch(
            target: target,
            pollInterval: 1,
            timeout: 3,
            clock: { clock.time },
            wait: { interval in
                waits.increment()
                clock.advance(interval)
            },
            probe: { probe.probe($0) })
        guard case .timedOut(let notes) = report.outcome else {
            Issue.record("expected timedOut, got \(report.outcome)")
            return
        }
        #expect(notes == ["only Bar.app here"]) // last probe's notes travel verbatim
        #expect(report.pollsCompleted == 4) // probes at t=0,1,2,3 (deadline check AFTER each probe)
        #expect(waits.current == 3)
        #expect(report.notes.contains { $0.contains("deadline reached") })
    }

    @Test
    func watchReportsProbeFailureImmediatelyWithoutRetry() async {
        let target = PostInstallWatchTarget(expectedDirectory: "/Applications",
                                            expectedBundleIdentifier: "com.example.foo",
                                            expectedAppBundleName: "Foo.app")
        let probe = ScriptedProbe([.failed(reason: "could not enumerate '/Applications': boom")])
        let waits = LockedCounter()
        let clock = FakeClock(start: Self.epoch)
        let report = await PostInstallRescan.watch(
            target: target,
            pollInterval: 1,
            timeout: 100,
            clock: { clock.time },
            wait: { _ in waits.increment() },
            probe: { probe.probe($0) })
        guard case .probeFailed(let reason) = report.outcome else {
            Issue.record("expected probeFailed, got \(report.outcome)")
            return
        }
        #expect(reason.contains("could not enumerate"))
        #expect(report.pollsCompleted == 1)
        #expect(waits.current == 0)
        #expect(report.notes.contains { $0.contains("not be laundered into a timeout") })
    }

    @Test
    func watchZeroTimeoutMeansExactlyOneProbe() async {
        let target = PostInstallWatchTarget(expectedDirectory: "/Applications",
                                            expectedBundleIdentifier: "com.example.foo",
                                            expectedAppBundleName: "Foo.app")
        let probes = LockedCounter()
        let clock = FakeClock(start: Self.epoch)
        let report = await PostInstallRescan.watch(
            target: target,
            pollInterval: 5,
            timeout: 0,
            clock: { clock.time },
            wait: { _ in probes.increment() }, // must never be called
            probe: { _ in
                probes.increment()
                return .notFound(notes: [])
            })
        guard case .timedOut = report.outcome else {
            Issue.record("expected timedOut, got \(report.outcome)")
            return
        }
        #expect(report.pollsCompleted == 1)
        #expect(probes.current == 1) // the wait seam was never invoked
        #expect(report.notes.contains { $0.contains("single-check") })
    }

    @Test
    func watchZeroPollIntervalIsBusyPollingWithNote() async {
        let target = PostInstallWatchTarget(expectedDirectory: "/Applications",
                                            expectedBundleIdentifier: "com.example.foo",
                                            expectedAppBundleName: "Foo.app")
        let probe = ScriptedProbe([
            .notFound(notes: ["1"]),
            .notFound(notes: ["2"]),
            .found(bundlePath: "/Applications/Foo.app", bundleIdentifier: "com.example.foo"),
        ])
        let clock = FakeClock(start: Self.epoch)
        let report = await PostInstallRescan.watch(
            target: target,
            pollInterval: 0,
            timeout: 60,
            clock: { clock.time },
            wait: { _ in }, // no-op wait seam; the timeout clock never advances
            probe: { probe.probe($0) })
        guard case .appeared = report.outcome else {
            Issue.record("expected appeared, got \(report.outcome)")
            return
        }
        #expect(report.pollsCompleted == 3)
        #expect(report.notes.contains { $0.contains("busy polling") })
    }

    @Test
    func watchReportCodableRoundTrips() async throws {
        let target = PostInstallWatchTarget(expectedDirectory: "/Applications",
                                            expectedBundleIdentifier: "com.example.foo",
                                            expectedAppBundleName: "Foo.app")
        let report = await PostInstallRescan.watch(
            target: target,
            pollInterval: 1,
            timeout: 1,
            clock: { Self.epoch },
            wait: { _ in },
            probe: { _ in .found(bundlePath: "/Applications/Foo.app", bundleIdentifier: "com.example.foo") })
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(PostInstallWatchReport.self, from: data)
        #expect(decoded == report)
    }

    // MARK: PostInstallRescan — the default (real-file) probe

    @Test
    func defaultProbeFindsBundleByIdentifierAmongSiblings() throws {
        let root = try newRoot()
        _ = try makeAppBundle(named: "Foo.app", bundleIdentifier: "com.example.foo", in: root)
        _ = try makeAppBundle(named: "Bar.app", bundleIdentifier: "com.example.bar", in: root)
        _ = try writeFile("notes.txt", bytes: Array("hello".utf8), in: root)
        let target = PostInstallWatchTarget(expectedDirectory: root.path,
                                            expectedBundleIdentifier: "com.example.foo",
                                            expectedAppBundleName: "Foo.app")
        guard case .found(let path, let bid) = PostInstallRescan.defaultDirectoryProbe(target) else {
            Issue.record("expected found")
            return
        }
        // Path compared by final component: FileManager may resolve /var →
        // /private/var symlinks under temporaryDirectory.
        #expect(URL(fileURLWithPath: path).lastPathComponent == "Foo.app")
        #expect(bid == "com.example.foo")
    }

    @Test
    func defaultProbeDoesNotRecurse() throws {
        let root = try newRoot()
        _ = try makeAppBundle(named: "Deep.app", bundleIdentifier: "com.example.foo", in: root, nestedUnder: "Sub")
        let target = PostInstallWatchTarget(expectedDirectory: root.path,
                                            expectedBundleIdentifier: "com.example.foo",
                                            expectedAppBundleName: "Deep.app")
        guard case .notFound = PostInstallRescan.defaultDirectoryProbe(target) else {
            Issue.record("expected notFound (nested bundles are outside the documented one-level watch)")
            return
        }
    }

    @Test
    func defaultProbeNamesUnreadableBundlesVerbatim() throws {
        let root = try newRoot()
        let broken = root.appendingPathComponent("Broken.app/Contents", isDirectory: true)
        try fm.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x00]).write(to: broken.appendingPathComponent("Info.plist"))
        _ = try makeAppBundle(named: "Good.app", bundleIdentifier: "com.other", in: root)
        let target = PostInstallWatchTarget(expectedDirectory: root.path,
                                            expectedBundleIdentifier: "com.example.foo",
                                            expectedAppBundleName: "Foo.app")
        guard case .notFound(let notes) = PostInstallRescan.defaultDirectoryProbe(target) else {
            Issue.record("expected notFound")
            return
        }
        // The broken bundle is NAMED verbatim (it could not be matched), and
        // the readable sibling's mismatch is also visible.
        #expect(notes.contains { $0.contains("Broken.app") })
        #expect(notes.contains { $0.contains("unreadable") || $0.contains("unparseable") || $0.contains("not a dictionary") })
        #expect(notes.contains { $0.contains("com.other") })
    }

    @Test
    func defaultProbeNotesBundleWithoutBundleIdentifier() throws {
        let root = try newRoot()
        let empty = try makeAppBundle(named: "Empty.app", bundleIdentifier: nil, in: root)
        // Give it a plist WITHOUT CFBundleIdentifier.
        let plist: [String: Any] = ["CFBundleName": "Empty"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: empty.appendingPathComponent("Contents/Info.plist"))
        let target = PostInstallWatchTarget(expectedDirectory: root.path,
                                            expectedBundleIdentifier: "com.example.foo",
                                            expectedAppBundleName: "Empty.app")
        guard case .notFound(let notes) = PostInstallRescan.defaultDirectoryProbe(target) else {
            Issue.record("expected notFound")
            return
        }
        #expect(notes.contains { $0.contains("declares no CFBundleIdentifier") })
    }

    @Test
    func defaultProbeFailsHonestlyOnMissingDirectory() throws {
        let missing = fm.temporaryDirectory
            .appendingPathComponent("vendorwatch-ghost-\(UUID().uuidString)", isDirectory: true)
        let target = PostInstallWatchTarget(expectedDirectory: missing.path,
                                            expectedBundleIdentifier: "com.example.foo",
                                            expectedAppBundleName: "Foo.app")
        guard case .failed(let reason) = PostInstallRescan.defaultDirectoryProbe(target) else {
            Issue.record("expected failed")
            return
        }
        #expect(reason.contains("could not enumerate"))
        #expect(reason.contains(missing.path))
    }
}
