import SwiftUI
import AppUpdaterCore

/// Shared observable bridge between the menu-bar surface and the main window.
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case loaded(Int)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var apps: [InstalledApp] = []

    func scanNow() {
        // PHASE 1 SHELL: no engine yet — honest empty state. Phase 2 lanes wire the scanner.
        phase = .idle
        apps = []
    }
}
