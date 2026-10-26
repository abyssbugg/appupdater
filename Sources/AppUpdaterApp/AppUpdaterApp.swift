import SwiftUI

@main
struct AppUpdaterApp: App {
    @StateObject private var appState = AppState()
    @State private var selfUpdate = SelfUpdateCoordinator()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra(appState.menuBarTitle, systemImage: "arrow.triangle.2.circlepath") {
            MenuBarView(showMainWindow: {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }, checkForSelfUpdate: {
                selfUpdate.checkForUpdates()
            })
            .environmentObject(appState)
            .buttonStyle(.borderless)
        }

        Window("AppUpdater", id: "main") {
            MainWindowView()
                .environmentObject(appState)
                .frame(minWidth: 640, minHeight: 380)
        }
        .defaultSize(width: 820, height: 520)
    }
}
