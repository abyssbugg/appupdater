import SwiftUI

@main
struct AppUpdaterApp: App {
    // Glue-wiring: the read-only engine panels' app-scoped model, bound to
    // the SAME ProxySessionController AppState owns (one source of truth for
    // the proxy sheet and the engines' session) and to the SAME Application
    // Support home AppState's disk-backed stores use (the brew formula-index
    // store reads/writes its cache there). Both are built in init because
    // each binding needs appState's instance.
    @StateObject private var appState: AppState
    @StateObject private var glue: GluePanelsModel
    @State private var selfUpdate = SelfUpdateCoordinator()
    @Environment(\.openWindow) private var openWindow

    init() {
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        _glue = StateObject(wrappedValue: GluePanelsModel(
            proxySession: state.proxySession,
            brewIndexDirectory: state.appSupportDirectory))
    }

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
                .environmentObject(glue)
        }
        // ONE minimum, owned by MainWindowView (940×560). The old scene-level
        // 640pt min + 820pt default let the window shrink below the content
        // minimum, so SwiftUI centered the wider content and clipped both
        // edges (live-capture finding 2026-10-30).
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 720)
    }
}
