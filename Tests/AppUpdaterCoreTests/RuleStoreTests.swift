// RuleStoreTests.swift — Phase 4 Lane 2 (rules + persistence).
// Covers the documented persistence contract of RuleStore.swift:
// load robustness (missing/garbage/empty files), exact-byte round-trips,
// save-through mutations, pure evaluation, frozen AppRow surfaces, and the
// SchedulePolicy clamping ladder.
// Hermetic: real temp directories under FileManager.default.temporaryDirectory,
// wiped per test init (IntegrationTests init pattern). Swift Testing only
// (XCTest collects 0 tests on this toolchain — gotcha ledger).

import Foundation
import Testing
@testable import AppUpdaterCore

@Suite(.serialized)
struct RuleStoreTests {
    private var root: URL

    /// Per-process unique workspace NAME (static = computed once): concurrent
    /// `swift test` runners each own their directory, so one runner's init
    /// wipe can never delete another's live fixtures — fixed shared roots
    /// used to do exactly that (the Phase-4 cross-process flake; see
    /// AGENTS.md gotcha ledger).
    private static let processRoot: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("appupdater-rulestore-\(UUID().uuidString)", isDirectory: true)

    init() {
        // Recycled per-run workspace: wiped at each init so garbage from a
        // previous run never leaks into assertions.
        let restored = Self.processRoot
        try? FileManager.default.removeItem(at: restored)
        try? FileManager.default.createDirectory(at: restored, withIntermediateDirectories: true)
        root = restored
    }

    // MARK: Helpers

    /// Store over a directory the TEST creates first. Used where the scenario
    /// is "a store whose state already exists on disk" (corrupt file fixtures).
    private func makeStore(_ leaf: String) throws -> (store: RuleStore, dir: URL, fileURL: URL) {
        let dir = root.appendingPathComponent(leaf, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = RuleStore(directory: dir)
        return (store, dir, dir.appendingPathComponent("rules.json"))
    }

    /// Store over an UNTOUCHED directory. Used where the scenario is the
    /// store's own lazy-create promise: nothing on disk until first save.
    private func freshStore(_ leaf: String) throws -> (store: RuleStore, dir: URL, fileURL: URL) {
        let dir = root.appendingPathComponent(leaf, isDirectory: true)
        return (RuleStore(directory: dir), dir, dir.appendingPathComponent("rules.json"))
    }

    /// Byte-for-byte mirror of the store's JSONWriter shape, used to prove the
    /// persisted file is exactly a canonical encoding (no drift, no leftovers).
    private func mirrorEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private let baseDate = Date(timeIntervalSinceReferenceDate: 750_000_000)

    private func rule(_ kind: RuleKind, _ bundleID: String, version: String? = nil, at t: Date? = nil) -> IgnoreRule {
        IgnoreRule(kind: kind, bundleIdentifier: bundleID, version: version, createdAt: t ?? baseDate)
    }

    /// An InstalledApp + an "update available" check (resolved claim present ⇒
    /// UpdateCheck.verdict == "update").
    private func appAndCheck(_ bundleID: String, name: String, claim: String) -> (InstalledApp, UpdateCheck) {
        let app = InstalledApp(
            bundleIdentifier: bundleID, name: name,
            path: "/Applications/\(name).app", shortVersion: "1.0"
        )
        let claimInfo = UpdateInfo(source: .cask, newestShortVersion: claim)
        let check = UpdateCheck(app: app, candidates: [claimInfo], resolved: claimInfo)
        return (app, check)
    }

    // MARK: (1) Load missing / save → load round-trip

    @Test func loadWhenFileMissingReturnsEmptyAndCreatesNothing() async throws {
        let (store, dir, _) = try freshStore("load-missing")
        let loaded = try await store.load()
        #expect(loaded.isEmpty)
        // Read-only promise: loading never creates directories or files.
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func saveLoadRoundTripIsIdenticalIncludingJSONBytes() async throws {
        let (store, dir, fileURL) = try freshStore("roundtrip")
        // Deliberately NOT in canonical order; canonical order is
        // kind rawValue ascending (autoCheck < ignoreBundle < ignoreVersion).
        let scrambled: [IgnoreRule] = [
            rule(.ignoreVersion, "org.zzz", version: "1.2.3", at: baseDate.addingTimeInterval(3)),
            rule(.ignoreBundle, "com.aaa", at: baseDate.addingTimeInterval(2)),
            rule(.autoCheck, "com.mmm", at: baseDate.addingTimeInterval(1)),
        ]
        try await store.save(scrambled)

        // Save created the directory lazily (it did not exist before).
        #expect(FileManager.default.fileExists(atPath: dir.path))

        let loaded = try await store.load()
        let canonical = [scrambled[2], scrambled[1], scrambled[0]]
        #expect(loaded == canonical)

        // JSON equality: the file's bytes are exactly a canonical re-encoding
        // (prettyPrinted + sortedKeys + deterministic ordering, full-precision dates).
        let fileBytes = try Data(contentsOf: fileURL)
        let mirrored = try mirrorEncoder().encode(loaded)
        #expect(mirrored == fileBytes)
    }

    // MARK: (2) Unparseable file → [] then honestly replaced on next save

    @Test func unparseableFileLoadsAsEmptyAndIsReplacedOnNextSave() async throws {
        let (store, _, fileURL) = try makeStore("garbage")
        let garbage = Data("not json {{{ \u{1}\u{2} refuse to parse".utf8)
        try garbage.write(to: fileURL)

        // No crash, honest empty, nothing created by the loader itself.
        let loaded = try await store.load()
        #expect(loaded.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fileURL.path)) // loader does not proactively delete

        // Next save replaces the garbage bytes with canonical JSON — verified
        // by byte-equality against a fresh encoding of what load() returns.
        let replacement = [rule(.ignoreBundle, "com.recovered", at: baseDate)]
        try await store.save(replacement)
        let bytesAfterSave = try Data(contentsOf: fileURL)
        let secondLoad = try await store.load()
        #expect(try mirrorEncoder().encode(secondLoad) == bytesAfterSave)
        let text = String(decoding: bytesAfterSave, as: UTF8.self)
        #expect(!text.contains("refuse to parse"))   // garbage fully gone, not appended to
        #expect(secondLoad == replacement)
    }

    @Test func emptyFileLoadsAsEmptyWithoutCrash() async throws {
        let (store, _, fileURL) = try makeStore("empty-file")
        try Data().write(to: fileURL)
        let loaded = try await store.load()
        #expect(loaded.isEmpty)
    }

    // MARK: (3) ignoreBundle idempotent, oldest createdAt wins

    @Test func ignoreBundleIsIdempotentWithOldestCreatedAt() async throws {
        let (store, dir, _) = try makeStore("bundle-idempotent")
        let early = baseDate
        let late = baseDate.addingTimeInterval(60)

        let first = try await store.ignoreBundle("com.kim", at: early)
        #expect(first.count == 1)
        #expect(first[0].kind == .ignoreBundle)
        #expect(first[0].createdAt == early)

        let second = try await store.ignoreBundle("com.kim", at: late)
        #expect(second.count == 1)
        #expect(second[0].createdAt == early)   // re-ignore must NOT refresh the date
        #expect(second[0].bundleIdentifier == "com.kim")

        // A different bundle makes a second, distinct rule.
        let third = try await store.ignoreBundle("com.other", at: late)
        #expect(third.count == 2)

        // Save-through: a fresh store instance over the same directory sees it.
        let persisted = try await RuleStore(directory: dir).load()
        #expect(persisted.count == 2)
        #expect(persisted.first { $0.bundleIdentifier == "com.kim" }?.createdAt == early)
    }

    // MARK: (4) Version rule: exact claim match only

    @Test func versionRuleMatchesOnlyExactClaimVersion() async throws {
        let (store, _, _) = try makeStore("version-exact")
        _ = try await store.ignoreVersion("com.tenor", version: "1.2.3", at: baseDate)

        let exact = try await store.evaluate(bundleIdentifier: "com.tenor", claimVersion: "1.2.3")
        #expect(exact.ignoredVersion)
        #expect(!exact.ignoredBundle)
        #expect(!exact.autoCheck)

        let different = try await store.evaluate(bundleIdentifier: "com.tenor", claimVersion: "1.2.4")
        #expect(!different.ignoredVersion)

        // A nil claim can never match a version rule — no version known means
        // nothing is ignorable.
        let nilClaim = try await store.evaluate(bundleIdentifier: "com.tenor", claimVersion: nil)
        #expect(!nilClaim.ignoredVersion)

        // An app with no rules gets the all-default decision.
        let unbound = try await store.evaluate(bundleIdentifier: "com.nobody", claimVersion: "1.2.3")
        #expect(unbound == RuleDecision())

        // The static pure evaluator returns the same answers directly.
        let rules = [
            rule(.ignoreVersion, "com.tenor", version: "1.2.3"),
        ]
        #expect(RuleStore.evaluate(rules: rules, bundleIdentifier: "com.tenor", version: "1.2.3") == RuleDecision(ignoredVersion: true))
        #expect(RuleStore.evaluate(rules: rules, bundleIdentifier: "com.tenor", version: "9.0.0").ignoredVersion == false)
        #expect(RuleStore.evaluate(rules: rules, bundleIdentifier: "com.tenor", version: nil).ignoredVersion == false)
    }

    // MARK: (5) ignoreBundle + ignoreVersion combine; bundle wins on the frozen row

    @Test func bundleVersionRulesCombineAndBundleWinsOnRow() async throws {
        let (store, _, _) = try makeStore("combine")
        _ = try await store.ignoreBundle("com.duet", at: baseDate)
        _ = try await store.ignoreVersion("com.duet", version: "9.9", at: baseDate)

        let decision = try await store.evaluate(bundleIdentifier: "com.duet", claimVersion: "9.9")
        #expect(decision == RuleDecision(ignoredBundle: true, ignoredVersion: true))

        // Frozen AppRow.updateAvailable: both flags must zero the verdict.
        let (app, check) = appAndCheck("com.duet", name: "Duet", claim: "9.9")
        let rows = await store.evaluate(apps: [app], checks: [check])
        let row = try #require(rows.first)
        #expect(row.decision == decision)
        #expect(!row.updateAvailable)

        // Version rule alone also zeroes the row (frozen property honors
        // ignoredVersion, not just ignoredBundle).
        _ = try await store.ignoreVersion("com.solo", version: "2.0", at: baseDate)
        let (soloApp, soloCheck) = appAndCheck("com.solo", name: "Solo", claim: "2.0")
        let soloRows = await store.evaluate(apps: [soloApp], checks: [soloCheck])
        let soloRow = try #require(soloRows.first)
        #expect(soloRow.decision.ignoredVersion)
        #expect(soloRow.decision.ignoredBundle == false)
        #expect(!soloRow.updateAvailable)

        // Sanity: with NO rules at all the same shape of row stays available.
        let (openApp, openCheck) = appAndCheck("com.openworld", name: "Openworld", claim: "7.7")
        let openRows = await store.evaluate(apps: [openApp], checks: [openCheck])
        #expect(try #require(openRows.first).updateAvailable)
    }

    // MARK: (6) setAutoCheck true adds once, false removes, siblings survive

    @Test func setAutoCheckAddsOnceAndFalseRemoves() async throws {
        let (store, dir, _) = try makeStore("autocheck-toggle")
        let initial = try await store.evaluate(bundleIdentifier: "com.zeta", claimVersion: nil)
        #expect(initial.autoCheck == false)   // default OFF per app in v1

        let once = try await store.setAutoCheck("com.zeta", true, at: baseDate)
        #expect(once.count == 1)
        #expect(once[0].kind == .autoCheck)
        #expect(once[0].bundleIdentifier == "com.zeta")

        // Second true is a no-op on the identity level (no duplicate).
        let twice = try await store.setAutoCheck("com.zeta", true, at: baseDate.addingTimeInterval(30))
        #expect(twice.count == 1)

        let after = try await store.evaluate(bundleIdentifier: "com.zeta", claimVersion: nil)
        #expect(after.autoCheck)

        // A sibling rule must survive the toggle in both directions.
        _ = try await store.ignoreBundle("com.zeta", at: baseDate)

        let off = try await store.setAutoCheck("com.zeta", false, at: baseDate)
        #expect(off.count == 1)
        #expect(off[0].kind == .ignoreBundle)   // autoCheck removed, ignoreBundle kept

        let final = try await store.evaluate(bundleIdentifier: "com.zeta", claimVersion: nil)
        #expect(final.autoCheck == false)
        #expect(final.ignoredBundle)

        // False on a bundle with no autoCheck rule is an honest no-op — the
        // autoCheck row is already gone from the statement above, so only the
        // sibling ignoreBundle remains.
        let untouched = try await store.setAutoCheck("com.stranger", false, at: baseDate)
        #expect(untouched.count == 1)
        #expect(untouched[0].kind == .ignoreBundle)
        // Re-enable adds the autoCheck rule back exactly once.
        let restored = try await store.setAutoCheck("com.zeta", true, at: baseDate)
        #expect(restored.count == 2)
        #expect(restored.filter { $0.kind == .autoCheck }.count == 1)
        // Persisted truth agrees with all of it.
        let state = try await RuleStore(directory: dir).load()
        #expect(state.count == 2)
    }

    // MARK: (7) SchedulePolicy clamping ladder

    @Test func scheduleClampingFollowsLockedLadder() {
        func interval(_ minutes: Int) -> Int {
            RuleStore.clamped(SchedulePolicy(intervalMinutes: minutes)).intervalMinutes
        }
        #expect(interval(5) == 15)
        #expect(interval(14) == 15)
        #expect(interval(15) == 15)
        #expect(interval(60) == 60)
        #expect(interval(0) == 0)      // explicit "scheduled off"
        #expect(interval(-1) == 0)     // negative coerced to explicit off
        #expect(interval(-600) == 0)

        // Non-interval fields pass through untouched.
        let policy = SchedulePolicy(intervalMinutes: 90, skipOnBattery: false, onWakeCatchUp: false)
        let clamped = RuleStore.clamped(policy)
        #expect(clamped.intervalMinutes == 90)
        #expect(clamped.skipOnBattery == false)
        #expect(clamped.onWakeCatchUp == false)
    }

    // MARK: (7b) SchedulePolicy clamping — offline + active-window fields

    /// The sched-depth deferral fields through the loader clamp: deferWhenOffline
    /// passes through verbatim (Bool has no invalid state); a VALID window is
    /// carried verbatim; an INVALID window (one endpoint nil, start == end,
    /// start > end, out of 0...1439) normalizes to nil/nil — no restriction —
    /// so the settings pane (which reads the snapshot's policy) can never show
    /// a restriction the engine does not enforce. The interval ladder is
    /// untouched by the new fields.
    @Test func clampedCarriesDeferralFieldsHonesty() {
        // deferWhenOffline passthrough, both directions.
        #expect(RuleStore.clamped(
            SchedulePolicy(intervalMinutes: 60, deferWhenOffline: true)).deferWhenOffline)
        #expect(!RuleStore.clamped(SchedulePolicy(intervalMinutes: 60)).deferWhenOffline)

        // A valid window is carried verbatim.
        let valid = RuleStore.clamped(
            SchedulePolicy(
                intervalMinutes: 60,
                activeWindowStartMinute: 480, activeWindowEndMinute: 1_020))
        #expect(valid.activeWindowStartMinute == 480)
        #expect(valid.activeWindowEndMinute == 1_020)

        // Invalid shapes → no restriction (nil/nil), matching the engine's
        // independent validation (ScheduleEngine.activeWindow).
        let shapes: [(String, Int?, Int?)] = [
            ("start only", 480, nil),
            ("end only", nil, 1_020),
            ("degenerate start == end", 500, 500),
            ("inverted start > end", 1_200, 100),
            ("out-of-range start", -1, 100),
            ("out-of-range end", 0, 1_440),
        ]
        for (name, start, end) in shapes {
            let clampedShape = RuleStore.clamped(
                SchedulePolicy(
                    intervalMinutes: 60,
                    activeWindowStartMinute: start, activeWindowEndMinute: end))
            #expect(clampedShape.activeWindowStartMinute == nil, "start: \(name)")
            #expect(clampedShape.activeWindowEndMinute == nil, "end: \(name)")
        }

        // The nil-window default stays nil (normalization is a no-op) and the
        // interval ladder still applies with the new fields present.
        let combined = RuleStore.clamped(
            SchedulePolicy(
                intervalMinutes: 5, deferWhenOffline: true,
                activeWindowStartMinute: 480, activeWindowEndMinute: 1_020))
        #expect(combined.intervalMinutes == 15)
        #expect(combined.deferWhenOffline == true)
        #expect(combined.activeWindowStartMinute == 480)
        #expect(combined.activeWindowEndMinute == 1_020)
        let off = RuleStore.clamped(
            SchedulePolicy(
                intervalMinutes: -3, deferWhenOffline: true,
                activeWindowStartMinute: 480, activeWindowEndMinute: 1_020))
        #expect(off.intervalMinutes == 0)
        #expect(off.deferWhenOffline == true)
        #expect(off.activeWindowStartMinute == 480)
    }

    // MARK: (7c) SchedulePolicy Codable — additive round-trip + legacy decode

    /// New fields survive an encode → decode round trip and are always written
    /// (encoding stays synthesized: every key present).
    @Test func policyCodableRoundTripKeepsDeferralFields() throws {
        let policy = SchedulePolicy(
            intervalMinutes: 30, skipOnBattery: false, onWakeCatchUp: false,
            deferWhenOffline: true, activeWindowStartMinute: 480, activeWindowEndMinute: 1_020)
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(SchedulePolicy.self, from: data)
        #expect(decoded == policy)

        let object = try JSONSerialization.jsonObject(with: data)
        let dict = try #require(object as? [String: Any])
        #expect(dict["deferWhenOffline"] as? Bool == true)
        #expect(dict["activeWindowStartMinute"] as? Int == 480)
        #expect(dict["activeWindowEndMinute"] as? Int == 1_020)
    }

    /// Decode tolerance — THE backward-compatibility contract: a policy encoded
    /// by older builds (three original keys, nothing else) decodes cleanly with
    /// the new fields at their defaults. The three original keys stay REQUIRED
    /// (a file missing them was already garbage → loader defaults, unchanged).
    @Test func policyDecodesLegacyJSONWithoutDeferralFields() throws {
        let legacy = Data(
            #"{"intervalMinutes":90,"skipOnBattery":false,"onWakeCatchUp":true}"#.utf8)
        let decoded = try JSONDecoder().decode(SchedulePolicy.self, from: legacy)
        #expect(decoded.intervalMinutes == 90)
        #expect(decoded.skipOnBattery == false)
        #expect(decoded.onWakeCatchUp == true)
        #expect(decoded.deferWhenOffline == false)
        #expect(decoded.activeWindowStartMinute == nil)
        #expect(decoded.activeWindowEndMinute == nil)
    }

    // MARK: (8) Batch evaluate: matching by bundle id, decision-only rows

    @Test func batchEvaluateMatchesChecksByBundleIdentifierNotName() async {
        // Names deliberately cross-swap the bundle ids so name-matching would fail: anything matched by NAME here is a bug.
        let alpha = InstalledApp(
            bundleIdentifier: "com.alpha", name: "Delta Prim",
            path: "/Applications/Delta Prim.app", shortVersion: "1.0"
        )
        let beta = InstalledApp(
            bundleIdentifier: "com.beta", name: "Alpha Nova",
            path: "/Applications/Alpha Nova.app", shortVersion: "2.0"
        )
        let gamma = InstalledApp(
            bundleIdentifier: "com.gamma", name: "Gamma", path: "/Applications/Gamma.app"
        )
        let alphaClaim = UpdateInfo(source: .cask, newestShortVersion: "3.0")
        let alphaCheck = UpdateCheck(app: alpha, candidates: [alphaClaim], resolved: alphaClaim) // verdict "update"
        let betaClaim = UpdateInfo(source: .github, newestShortVersion: "1.5")
        let betaCheck = UpdateCheck(app: beta, candidates: [betaClaim], resolved: nil)           // verdict "current"

        let store = RuleStore(directory: root.appendingPathComponent("batch-names", isDirectory: true))
        let rows = await store.evaluate(apps: [alpha, beta, gamma], checks: [alphaCheck, betaCheck])

        #expect(rows.count == 3)
        // Input order preserved (UI lists stay deterministic).
        #expect(rows.map(\.id) == [alpha.id, beta.id, gamma.id])
        // Matched by bundle id — the check paired with com.alpha carries com.alpha's app, not a name match.
        #expect(rows[0].app.bundleIdentifier == "com.alpha")
        #expect(rows[0].check?.app.bundleIdentifier == "com.alpha")
        #expect(rows[0].updateAvailable)        // verdict "update" + no rules ⇒ surfacable
        #expect(rows[1].app.bundleIdentifier == "com.beta")
        #expect(rows[1].check?.app.bundleIdentifier == "com.beta")
        #expect(!rows[1].updateAvailable)       // verdict "current"
        // App missing from checks: decision-only row.
        #expect(rows[2].check == nil)
        #expect(rows[2].decision == RuleDecision())
        #expect(!rows[2].updateAvailable)
    }

    // MARK: (9) Batch evaluate applies persisted rules; unmatched stays decision-only

    @Test func batchEvaluateAppliesPersistedRulesAndLeavesUnmatchedAppsDecisionOnly() async throws {
        let (store, _, _) = try makeStore("batch-rules")
        _ = try await store.ignoreBundle("com.alpha", at: baseDate)
        _ = try await store.ignoreVersion("com.beta", version: "9.9", at: baseDate)

        let (alpha, alphaCheck) = appAndCheck("com.alpha", name: "Alpha", claim: "9.9")
        let (beta, betaCheck) = appAndCheck("com.beta", name: "Beta", claim: "9.9")
        let gamma = InstalledApp(
            bundleIdentifier: "com.gamma", name: "Gamma", path: "/Applications/Gamma.app"
        )

        let rows = await store.evaluate(apps: [alpha, beta, gamma], checks: [alphaCheck, betaCheck])
        #expect(rows.count == 3)
        #expect(rows[0].decision.ignoredBundle)
        #expect(!rows[0].updateAvailable)        // bundle rule wins over the "update" verdict
        #expect(rows[1].decision.ignoredVersion) // fed from check.resolved.newestShortVersion
        #expect(!rows[1].updateAvailable)
        #expect(rows[2].check == nil)
        #expect(rows[2].decision == RuleDecision())  // no rule exists for com.gamma
        #expect(!rows[2].updateAvailable)
    }

    // MARK: (10) Load-side sanitizer: duplicates collapse, oldest kept

    @Test func loadSanitizesDuplicatesAndKeepsOldest() async throws {
        let (store, _, fileURL) = try makeStore("load-dedupe")
        let dupAt = baseDate
        let dupLater = baseDate.addingTimeInterval(10)
        let raw: [IgnoreRule] = [
            rule(.ignoreBundle, "com.dup", at: dupLater),
            rule(.ignoreBundle, "com.aard", at: dupAt),
            rule(.ignoreBundle, "com.dup", at: dupAt),
            rule(.ignoreVersion, "org.zed", version: "4.4", at: dupLater),
        ]
        // Raw bytes written directly (test-side encoder) — the loader must
        // tolerate any encoding shape and still sanitize.
        try mirrorEncoder().encode(raw).write(to: fileURL)

        let loaded = try await store.load()
        #expect(loaded.count == 3)
        // Identity (kind, bundle, version) collapsed to one row, OLDEST createdAt kept.
        let dup = try #require(loaded.first { $0.bundleIdentifier == "com.dup" })
        #expect(dup.createdAt == dupAt)
        // Canonical order: com.aard < com.dup (ignoreBundle), org.zed last (ignoreVersion).
        #expect(loaded.map(\.bundleIdentifier) == ["com.aard", "com.dup", "org.zed"])
    }

    // MARK: (11) 500-rule cap: oldest dropped, file reflects the cap

    @Test func ruleCapAtFiveHundredDropsOldestAndPersists() async throws {
        let (store, _, fileURL) = try makeStore("cap-500")
        var lastMutation: [IgnoreRule] = []
        for index in 0..<502 {
            lastMutation = try await store.ignoreVersion(
                "com.cap.\(index)", version: "1.0",
                at: baseDate.addingTimeInterval(Double(index))
            )
        }

        // The last mutation's returned set is already capped.
        #expect(lastMutation.count == 500)
        #expect(lastMutation.first { $0.bundleIdentifier == "com.cap.0" } == nil)
        #expect(lastMutation.first { $0.bundleIdentifier == "com.cap.1" } == nil)
        #expect(lastMutation.first { $0.bundleIdentifier == "com.cap.501" } != nil)

        // A fresh load over the file agrees.
        let loaded = try await store.load()
        #expect(loaded.count == 500)
        #expect(loaded.first { $0.bundleIdentifier == "com.cap.0" } == nil)
        #expect(loaded.first { $0.bundleIdentifier == "com.cap.501" } != nil)

        // And the persisted bytes themselves hold exactly 500 rules.
        let decoded = try JSONDecoder().decode(
            [IgnoreRule].self, from: Data(contentsOf: fileURL)
        )
        #expect(decoded.count == 500)
    }
}

