import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            appTable
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "arrow.triangle.2.circlepath").font(.title3)
            Text("AppUpdater").font(.headline)
            Spacer()
            Button {
                appState.scanNow()
            } label: { Label("Scan Now", systemImage: "magnifyingglass") }
                .disabled(true)   // wires up in Phase 2 lane merger
        }.padding(12)
    }

    private var appTable: some View {
        Group {
            if appState.apps.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray").foregroundStyle(.secondary).font(.largeTitle)
                    Text(emptyTitle).foregroundStyle(.primary)
                    Text(emptySubtitle).foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                List(appState.apps) { app in
                    HStack {
                        Text(app.name).bold()
                        Spacer()
                        Text(app.path).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Text(statusFooter).font(.caption).foregroundStyle(.secondary)
        }.padding(8)
    }

    private var emptyTitle: String {
        appState.phase == .scanning ? "Scanning…" : "No apps loaded yet"
    }
    private var emptySubtitle: String {
        appState.phase == .scanning
            ? "The scanner engine is being wired (Phase 2)."
            : "Engine under construction — nothing is being faked."
    }
    private var statusFooter: String {
        "Phase 1 shell · both menu-bar and window surfaces live · scanning arrives with Phase 2"
    }
}
