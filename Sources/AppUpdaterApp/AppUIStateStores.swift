// AppUIStateStores.swift — GAP #26, persisted app-target UI state. Lane
// polish · exclusive app-target files of this lane (Sources/AppUpdaterApp/**).
//
// TWO tiny stores over the SHARED app-support settings directory (the same
// home the core stores use — both filenames are registered in the core
// SettingsMigration envelope, Sources/AppUpdaterCore/Migration/):
//
//   display_settings.json  {"showInDock": Bool}
//     The "Show in: Menu Bar / Menu Bar + Dock" choice. `showInDock` models
//     DOCK PRESENCE; the pending-updates badge is a consequence of presence
//     (a badge on a nonexistent dock icon is meaningless). Schema versioning
//     is owned by the core migration envelope, not a per-file field.
//
//   welcome_state.json     {"tourShown": Bool}
//     The welcome-tour exactly-once flag. Default false = the tour HAS NOT
//     been shown; any dismissal (Get Started or window close) writes true.
//
// CONTRACT (the house pattern, adapted honestly — sync surface because the
// coordinator reads BOTH at AppState.init, before any window exists; the
// load contract is AutoApplySettingsStore's, the write contract is
// TerminalEmulatorStore's):
//   - Disk is the single source of truth; instances hold NO state.
//   - load() NEVER throws and NEVER creates anything:
//     missing file → defaults; unparseable bytes → defaults + documented
//     log line; the next save honestly replaces the garbage (fail-open to
//     defaults is the right failure mode for low-stakes display prefs — the
//     worst case is the tour showing once more, never a launch blocker).
//   - save() throws on failure and is atomic: staging file in the target
//     directory + replaceItemAt/moveItem swap — a failed write never
//     corrupts the previous good file.
//   - Log surface: os.Logger "io.appupdater.AppUpdater/app-ui-state".
//   - `directory` is REQUIRED at init (TerminalEmulatorStore convention):
//     production wires the app-support home, the coordinator owns that
//     wiring, this file never hardcodes a path.

import Foundation
import os

// MARK: - Display (dock presence)

/// The launch-time display decision (GAP #26 item 1). The default is
/// menu-bar-only — the app's shipped LSUIElement shape; dock presence is
/// strictly opt-in.
public enum DisplayMode: String, Codable, Hashable, Sendable {
    case menuBarOnly
    case menuBarAndDock

    /// The persisted boolean the settings picker binds to (`false` =
    /// menu-bar-only default). Unknown raw values fail decode → the store
    /// falls back to defaults, which is this case — never a dock surprise.
    public var showInDock: Bool { self == .menuBarAndDock }

    public static func from(showInDock: Bool) -> DisplayMode {
        showInDock ? .menuBarAndDock : .menuBarOnly
    }
}

/// The persisted display settings record.
struct DisplaySettings: Codable, Hashable, Sendable {
    /// Dock presence + pending-updates badge. Default OFF (menu-bar-only).
    var showInDock: Bool = false

    var mode: DisplayMode { DisplayMode.from(showInDock: showInDock) }
}

/// Persistence for ``DisplaySettings`` (contract in the file header).
struct DisplaySettingsStore: Sendable {

    private static let fileName = "display_settings.json"
    private static let log = Logger(subsystem: "io.appupdater.AppUpdater", category: "app-ui-state")

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    let directory: URL

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    init(directory: URL) {
        self.directory = directory
    }

    /// Missing/unparseable file → defaults (+ log on the corrupt case).
    /// Never throws, never creates anything.
    func load() -> DisplaySettings {
        guard let data = try? Data(contentsOf: fileURL) else {
            return DisplaySettings()
        }
        do {
            return try Self.decoder.decode(DisplaySettings.self, from: data)
        } catch {
            Self.log.error(
                "display_settings.json unparseable (\(String(describing: error), privacy: .public)) — treating as defaults; next save replaces it"
            )
            return DisplaySettings()
        }
    }

    /// Persists atomically; throws on failure so the settings surface can
    /// show the verbatim reason (never a silent "saved").
    func save(_ settings: DisplaySettings) throws {
        let data = try Self.encoder.encode(settings)
        try AppUIStateWrite.writeBytesAtomically(
            data, to: fileURL, fileName: Self.fileName, log: Self.log)
    }
}

// MARK: - Welcome tour exactly-once flag

/// The persisted welcome-tour state (GAP #26 item 2).
struct WelcomeTourState: Codable, Hashable, Sendable {
    /// true = the tour has been SHOWN once (any dismissal counts) and must
    /// never show again. Default false = not shown yet.
    var tourShown: Bool = false
}

/// Persistence for ``WelcomeTourState`` (contract in the file header).
struct WelcomeTourStateStore: Sendable {

    private static let fileName = "welcome_state.json"
    private static let log = Logger(subsystem: "io.appupdater.AppUpdater", category: "app-ui-state")

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
    private static let decoder = JSONDecoder()

    let directory: URL

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    init(directory: URL) {
        self.directory = directory
    }

    /// Missing/unparseable file → not-shown-yet (+ log on the corrupt case).
    /// Never throws, never creates anything.
    func load() -> WelcomeTourState {
        guard let data = try? Data(contentsOf: fileURL) else {
            return WelcomeTourState()
        }
        do {
            return try Self.decoder.decode(WelcomeTourState.self, from: data)
        } catch {
            Self.log.error(
                "welcome_state.json unparseable (\(String(describing: error), privacy: .public)) — treating as defaults; next save replaces it"
            )
            return WelcomeTourState()
        }
    }

    /// Marks the tour shown (idempotent). Throws on failure — the caller
    /// logs it and honestly accepts the degradation: the tour will show
    /// again on the next launch.
    func markShown() throws {
        let data = try Self.encoder.encode(WelcomeTourState(tourShown: true))
        try AppUIStateWrite.writeBytesAtomically(
            data, to: fileURL, fileName: Self.fileName, log: Self.log)
    }
}

// MARK: - Shared atomic write (file-local house mirror)

/// The staging + atomic-swap write shared by both stores in this file
/// (ProxySettingsStore/RuleStore/AutoApplySettingsStore mirror: the staging
/// file lives in the target directory so the final rename is same-volume,
/// and a failure anywhere before the swap leaves the previous good file
/// untouched).
private enum AppUIStateWrite {
    static func writeBytesAtomically(
        _ data: Data, to target: URL, fileName: String, log: Logger
    ) throws {
        let dir = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let staging = dir.appendingPathComponent(
            ".\(fileName)-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: staging) }

        guard FileManager.default.createFile(atPath: staging.path, contents: data) else {
            throw AppUIStateWriteFailure(
                fileName: fileName, reason: "could not stage the write in \(dir.path)")
        }
        do {
            let handle = try FileHandle(forWritingTo: staging)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
        } catch {
            throw AppUIStateWriteFailure(
                fileName: fileName, reason: "staging write failed: \(String(describing: error))")
        }

        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: target)
        }
    }
}

/// Honest persistence failure (house failure-shape: verbatim reason text the
/// settings surface can show unchanged).
struct AppUIStateWriteFailure: LocalizedError, Sendable {
    let fileName: String
    let reason: String
    var errorDescription: String? { "\(fileName) write failed: \(reason)" }
}
