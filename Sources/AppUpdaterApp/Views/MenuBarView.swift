import SwiftUI
import Combine

struct MenuBarView: View {
    let showMainWindow: () -> Void
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack {
            Button("Open AppUpdater") { showMainWindow() }
            Divider()
            Button("Scan Now") { appState.scanNow() }
            Divider()
            Text(statusLine).foregroundStyle(.secondary)
            Divider()
            Button("Quit AppUpdater") { NSApplication.shared.terminate(nil) }
        }
    }

    private var statusLine: String {
        switch appState.phase {
        case .idle: "Engine phase 2 pending — scanner not wired yet."
        case .scanning: "Scanning…"
        case .loaded(let n): "\(n) apps"
        case .failed(let m): "Failed: \(m)"
        }
    }
}
