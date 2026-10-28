// MigrationTests — GAP #26, SettingsMigrationService honesty. Swift Testing
// only (XCTest discovery broken here). Hermetic: directory-injected service
// over a per-PROCESS unique temp root with per-TEST subdirectories (the
// Phase-4 cross-process flake rule — see AGENTS.md gotcha ledger; no fixed
// shared names, ever).

import Foundation
import Testing
@testable import AppUpdaterCore

@Suite(.serialized)
struct MigrationTests {

    private static let processRoot: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "appupdater-migration-\(UUID().uuidString)", isDirectory: true)

    private var root: URL

    init() {
        // Each test gets its own fresh subdirectory — no wipes, no shared
        // fixed names (the flake rule).
        root = Self.processRoot.appendingPathComponent(
            "test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: helpers

    private var stateURL: URL { root.appendingPathComponent("settings_migration_state.json") }

    private func readStateFileData() throws -> Data {
        try Data(contentsOf: stateURL)
    }

    /// Fabricates an "older build's" envelope using the public state type —
    /// the same bytes a previous registry generation would have written.
    private func writeEnvelope(version: Int, recordedFiles: [String: Int] = [:]) throws {
        let state = SettingsMigrationState(
            settingsSchemaVersion: version, recordedFiles: recordedFiles, migratedAt: nil)
        try JSONEncoder().encode(state).write(to: stateURL)
    }

    /// A step that appends its letter to step-order.txt — proves execution
    /// ORDER and WHETHER a step ran at all.
    private static func letterStep(
        _ letter: String, from: Int, to: Int
    ) -> SettingsMigrationStep {
        SettingsMigrationStep(fromVersion: from, toVersion: to, label: "step \(letter)") { dir in
            let marker = dir.appendingPathComponent("step-order.txt")
            let existing = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
            try "\(existing)\(letter)".write(to: marker, atomically: true, encoding: .utf8)
        }
    }

    // MARK: v1 identity behavior

    @Test func freshDirectoryStampsEnvelopeAndCreatesNoSettingsFiles() throws {
        let outcome = try SettingsMigrationService(directory: root).runIfNeeded()

        #expect(outcome == .freshEnvelope)
        let envelope = try JSONDecoder().decode(
            SettingsMigrationState.self, from: try readStateFileData())
        #expect(envelope.settingsSchemaVersion == SettingsMigrationService.currentSchemaVersion)
        #expect(envelope.migratedAt != nil)
        // Every registered file is recorded at the current version.
        #expect(envelope.recordedFiles.count == SettingsMigrationService.registeredFiles.count)
        #expect(envelope.recordedFiles.values.allSatisfy {
            $0 == SettingsMigrationService.currentSchemaVersion
        })
        // Recording the shapes never CREATES the settings files.
        for name in SettingsMigrationService.registeredFiles {
            #expect(!FileManager.default.fileExists(
                atPath: root.appendingPathComponent(name).path))
        }
    }

    @Test func existingSettingsFilesSurviveByteIdentical() throws {
        // Real settings bytes from a hypothetical older build: the v1
        // identity migration must leave every byte exactly as it was.
        let files: [String: String] = [
            "rules.json": "{\"rules\":[],\"schema\":null}",
            "schedule.json": "{\"policy\":{\"intervalMinutes\":240}}",
            "proxy_settings.json": "{\"enabled\":false}",
            "auto_apply_settings.json": "{\"autoApplyEnabled\":false}",
            "terminal_emulator.json": "{\"schemaVersion\":1,\"defaultEmulator\":\"terminal\"}",
            "scan_locations.json": "{\"locations\":[]}",
            "manual_sources.json": "{\"pins\":{}}",
            "display_settings.json": "{\"showInDock\":false}",
            "welcome_state.json": "{\"tourShown\":true}",
        ]
        for (name, bytes) in files {
            try Data(bytes.utf8).write(to: root.appendingPathComponent(name))
        }

        let outcome = try SettingsMigrationService(directory: root).runIfNeeded()
        #expect(outcome == .freshEnvelope)

        for (name, bytes) in files {
            let after = try Data(contentsOf: root.appendingPathComponent(name))
            #expect(after == Data(bytes.utf8), "\(name) must be byte-identical after identity migration")
        }
    }

    @Test func alreadyCurrentReturnsNoOpWithoutRewrite() throws {
        try SettingsMigrationService(directory: root).runIfNeeded()
        let firstBytes = try readStateFileData()

        let outcome = try SettingsMigrationService(directory: root).runIfNeeded()

        #expect(outcome == .alreadyCurrent)
        // A no-op must not rewrite the envelope (migratedAt preserved — the
        // bytes ARE the record).
        let secondBytes = try readStateFileData()
        #expect(firstBytes == secondBytes)
    }

    // MARK: registry mechanics (injected steps, the "proven for the future" half)

    @Test func freshEnvelopeSkipsSteps() throws {
        let service = SettingsMigrationService(
            directory: root,
            steps: [Self.letterStep("A", from: 0, to: 1), Self.letterStep("B", from: 1, to: 2)],
            targetVersion: 2)

        let outcome = try service.runIfNeeded()

        #expect(outcome == .freshEnvelope)
        // A fresh install runs NO transforms — its shapes are already current.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("step-order.txt").path))
        let envelope = try JSONDecoder().decode(
            SettingsMigrationState.self, from: try readStateFileData())
        #expect(envelope.settingsSchemaVersion == 2)
    }

    @Test func storedLowerVersionRunsChainedStepsInAscendingOrder() throws {
        // Declared OUT of order on purpose: the service must chain ascending.
        try writeEnvelope(version: 0)
        let service = SettingsMigrationService(
            directory: root,
            steps: [Self.letterStep("B", from: 1, to: 2), Self.letterStep("A", from: 0, to: 1)],
            targetVersion: 2)

        let outcome = try service.runIfNeeded()

        #expect(outcome == .migrated(from: 0, to: 2))
        let order = try String(contentsOf: root.appendingPathComponent("step-order.txt"), encoding: .utf8)
        #expect(order == "AB")
        let envelope = try JSONDecoder().decode(
            SettingsMigrationState.self, from: try readStateFileData())
        #expect(envelope.settingsSchemaVersion == 2)
        #expect(envelope.migratedAt != nil)
    }

    @Test func v1IdentityFromOlderEnvelopeStampsWithoutTransformation() throws {
        // An envelope from a pre-registry build, an empty v1 registry: the
        // honest identity migration — stamp the current shapes, transform
        // nothing, report the real from→to pair.
        try writeEnvelope(version: 0)
        try Data("untouched".utf8).write(to: root.appendingPathComponent("rules.json"))

        let outcome = try SettingsMigrationService(directory: root).runIfNeeded()

        #expect(outcome == .migrated(from: 0, to: 1))
        #expect(try Data(contentsOf: root.appendingPathComponent("rules.json")) == Data("untouched".utf8))
        let envelope = try JSONDecoder().decode(
            SettingsMigrationState.self, from: try readStateFileData())
        #expect(envelope.settingsSchemaVersion == 1)
    }

    // MARK: honest refusals

    @Test func futureEnvelopeRefusedAndUntouched() throws {
        try writeEnvelope(version: SettingsMigrationService.currentSchemaVersion + 5)
        let before = try readStateFileData()

        #expect(throws: SettingsMigrationError.self) {
            try SettingsMigrationService(directory: root).runIfNeeded()
        }
        #expect(try readStateFileData() == before)
    }

    @Test func corruptEnvelopeRefusedAndUntouched() throws {
        try Data("{not an envelope".utf8).write(to: stateURL)
        let before = try readStateFileData()

        #expect(throws: SettingsMigrationError.self) {
            try SettingsMigrationService(directory: root).runIfNeeded()
        }
        #expect(try readStateFileData() == before)
    }

    @Test func failingStepLeavesEnvelopeUnstamped() throws {
        try writeEnvelope(version: 0)
        let poison = SettingsMigrationStep(
            fromVersion: 0, toVersion: 1, label: "poison step") { _ in
                throw CocoaError(.fileNoSuchFile)
            }
        let service = SettingsMigrationService(
            directory: root, steps: [poison], targetVersion: 1)

        #expect(throws: SettingsMigrationError.self) {
            try service.runIfNeeded()
        }
        // The envelope still says 0: the next launch re-runs the chain.
        let envelope = try JSONDecoder().decode(
            SettingsMigrationState.self, from: try readStateFileData())
        #expect(envelope.settingsSchemaVersion == 0)
    }

    // MARK: static contract

    @Test func registeredFilesAreUniqueAndComplete() {
        let files = SettingsMigrationService.registeredFiles
        #expect(files.count == Set(files).count)
        // The mission-named five (already existing at gap time)…
        for name in ["rules.json", "schedule.json", "proxy_settings.json",
                     "auto_apply_settings.json", "terminal_emulator.json"] {
            #expect(files.contains(name))
        }
        // …the two further core stores in the same directory…
        #expect(files.contains("scan_locations.json"))
        #expect(files.contains("manual_sources.json"))
        // …and this lane's two app-target stores.
        #expect(files.contains("display_settings.json"))
        #expect(files.contains("welcome_state.json"))
    }

    @Test func runOnMissingDirectoryCreatesItAndStamps() throws {
        let neverMade = root.appendingPathComponent("deep-\(UUID().uuidString)", isDirectory: true)
        let outcome = try SettingsMigrationService(directory: neverMade).runIfNeeded()

        #expect(outcome == .freshEnvelope)
        #expect(FileManager.default.fileExists(
            atPath: neverMade.appendingPathComponent("settings_migration_state.json").path))
    }
}
