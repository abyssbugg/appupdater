import Foundation
import Testing
@testable import AppUpdaterCore

struct CheckCarryOverTests {
    /// Helper to build a test InstalledApp.
    private func app(
        id: String,
        path: String = "/Applications/Test.app",
        shortVersion: String? = "1.0",
        bundleVersion: String? = "100"
    ) -> InstalledApp {
        InstalledApp(
            bundleIdentifier: id,
            name: "Test App",
            path: path,
            shortVersion: shortVersion,
            bundleVersion: bundleVersion
        )
    }

    /// Helper to build a test UpdateCheck with a specific verdict.
    /// - "update": resolved != nil (e.g., a candidate that beats installed version)
    /// - "current": candidates exist but none beat installed version
    /// - "unknown": no candidates and no failures
    /// - "failed": no candidates but there were failures
    private func check(app: InstalledApp, verdict: String) -> UpdateCheck {
        switch verdict {
        case "update":
            // Resolved claim exists (update available)
            let info = UpdateInfo(
                source: .cask,
                newestShortVersion: "2.0",
                confidence: .high
            )
            return UpdateCheck(app: app, candidates: [info], resolved: info)
        case "current":
            // Candidates exist but none beat installed (current version)
            let info = UpdateInfo(
                source: .cask,
                newestShortVersion: "1.0",
                confidence: .high
            )
            return UpdateCheck(app: app, candidates: [info], resolved: nil)
        case "failed":
            // No candidates, but a failure was recorded
            return UpdateCheck(app: app, candidates: [], failures: [CheckSourceFailure(kind: .cask, message: "network error")], resolved: nil)
        case "unknown":
            // No candidates, no failures
            return UpdateCheck(app: app, candidates: [], resolved: nil)
        default:
            return UpdateCheck(app: app, candidates: [], resolved: nil)
        }
    }

    @Test("unchanged app keeps check")
    func unchangedAppKeepsCheck() {
        let app1 = app(id: "com.test.app1")
        let prev = [check(app: app1, verdict: "update")]

        let result = CheckCarryOver.carry(
            previousChecks: prev,
            previousApps: [app1],
            newApps: [app1]
        )

        #expect(result.count == 1)
        #expect(result[0] != nil)
        #expect(result[0]?.verdict == "update")
    }

    @Test("version changed drops check")
    func versionChangedDropsCheck() {
        let app1v1 = app(id: "com.test.app1", shortVersion: "1.0", bundleVersion: "100")
        let app1v2 = app(id: "com.test.app1", shortVersion: "2.0", bundleVersion: "200")
        let prev = [check(app: app1v1, verdict: "update")]

        let result = CheckCarryOver.carry(
            previousChecks: prev,
            previousApps: [app1v1],
            newApps: [app1v2]
        )

        #expect(result.count == 1)
        #expect(result[0] == nil)
    }

    @Test("build version changed drops check")
    func buildVersionChangedDropsCheck() {
        let app1build1 = app(id: "com.test.app1", shortVersion: "1.0", bundleVersion: "100")
        let app1build2 = app(id: "com.test.app1", shortVersion: "1.0", bundleVersion: "101")
        let prev = [check(app: app1build1, verdict: "current")]

        let result = CheckCarryOver.carry(
            previousChecks: prev,
            previousApps: [app1build1],
            newApps: [app1build2]
        )

        #expect(result.count == 1)
        #expect(result[0] == nil)
    }

    @Test("path changed drops check")
    func pathChangedDropsCheck() {
        let app1old = app(id: "com.test.app1", path: "/Applications/Old.app")
        let app1new = app(id: "com.test.app1", path: "/Applications/New.app")
        let prev = [check(app: app1old, verdict: "current")]

        let result = CheckCarryOver.carry(
            previousChecks: prev,
            previousApps: [app1old],
            newApps: [app1new]
        )

        #expect(result.count == 1)
        #expect(result[0] == nil)
    }

    @Test("vanished app has no check")
    func vanishedAppHasNoCheck() {
        let app1 = app(id: "com.test.app1")
        let app2 = app(id: "com.test.app2")
        let prev = [check(app: app1, verdict: "update"), check(app: app2, verdict: "current")]

        let result = CheckCarryOver.carry(
            previousChecks: prev,
            previousApps: [app1, app2],
            newApps: [app2]
        )

        #expect(result.count == 1)
        #expect(result[0] != nil)
        #expect(result[0]?.verdict == "current")
    }

    @Test("new app has no check")
    func newAppHasNoCheck() {
        let app1 = app(id: "com.test.app1")
        let app2 = app(id: "com.test.app2")
        let prev = [check(app: app1, verdict: "update")]

        let result = CheckCarryOver.carry(
            previousChecks: prev,
            previousApps: [app1],
            newApps: [app1, app2]
        )

        #expect(result.count == 2)
        #expect(result[0] != nil)
        #expect(result[0]?.verdict == "update")
        #expect(result[1] == nil)
    }

    @Test("nil versions match")
    func nilVersionsMatch() {
        let app1no = app(id: "com.test.app1", shortVersion: nil, bundleVersion: nil)
        let prev = [check(app: app1no, verdict: "unknown")]

        let result = CheckCarryOver.carry(
            previousChecks: prev,
            previousApps: [app1no],
            newApps: [app1no]
        )

        #expect(result.count == 1)
        #expect(result[0] != nil)
        #expect(result[0]?.verdict == "unknown")
    }

    @Test("shortVersion nil but bundleVersion present changes drop check")
    func shortVersionNilMismatchDropsCheck() {
        let app1 = app(id: "com.test.app1", shortVersion: nil, bundleVersion: "100")
        let app2 = app(id: "com.test.app1", shortVersion: nil, bundleVersion: "101")
        let prev = [check(app: app1, verdict: "current")]

        let result = CheckCarryOver.carry(
            previousChecks: prev,
            previousApps: [app1],
            newApps: [app2]
        )

        #expect(result.count == 1)
        #expect(result[0] == nil)
    }

    @Test("order follows newApps")
    func orderFollowsNewApps() {
        let app1 = app(id: "com.test.app1")
        let app2 = app(id: "com.test.app2")
        let app3 = app(id: "com.test.app3")
        let prev = [
            check(app: app1, verdict: "update"),
            check(app: app2, verdict: "current"),
            check(app: app3, verdict: "unknown")
        ]

        // Reorder: app2, app1, app3
        let result = CheckCarryOver.carry(
            previousChecks: prev,
            previousApps: [app1, app2, app3],
            newApps: [app2, app1, app3]
        )

        #expect(result.count == 3)
        #expect(result[0]?.verdict == "current")
        #expect(result[1]?.verdict == "update")
        #expect(result[2]?.verdict == "unknown")
    }
}
