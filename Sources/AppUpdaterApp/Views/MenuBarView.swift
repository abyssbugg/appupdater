import SwiftUI
import AppKit
import AppUpdaterCore

/// Menu-bar surface: compact, status-first. Same contract as before —
/// MenuData supplies Sections+IDs; the shell maps IDs to handlers exactly once.
struct MenuBarView: View {
    let showMainWindow: () -> Void
    let checkForSelfUpdate: () -> Void
    @EnvironmentObject private var appState: AppState

    /// Updatest's native menu, in its order:
    ///   App Updates (N) ▸ · Refresh · Open AppUpdater… · Settings… ·
    ///   Check for Updates… (self-update) · Quit (exactly once).
    /// Every action still routes through MenuData IDs → `handle(_:)`.
    var body: some View {
        let menu = appState.menuData
        let pending = menu.pendingSection.updates
        Group {
            Menu("App Updates (\(pending.count))") {
                if pending.isEmpty {
                    Text(checkedCount == 0 ? "Not Checked Yet" : "No Updates Available")
                } else {
                    ForEach(pending) { row in
                        Button(rowTitle(row)) { handle(.viewDetails(bundleID: row.app.bundleIdentifier)) }
                    }
                }
            }

            Divider()

            ForEach(menu.headline.filter { isCheckAction($0.id) }, id: \.id.stableID) { _ in
                Button("Refresh") { handle(.checkNow) }
            }
            // Honest last-check status (MenuData's schedule lines), read-only.
            if let status = menu.scheduleSection.first {
                Text(status)
            }

            Divider()

            ForEach(menu.headline.filter { isOpenAction($0.id) }, id: \.id.stableID) { _ in
                Button("Open AppUpdater…") { handle(.openMainWindow) }
            }

            Divider()

            Button("Settings…") { handle(.openSettings) }
            Button("Check for Updates…") { checkForSelfUpdate() }

            Divider()

            ForEach(menu.headline.filter { isQuitAction($0.id) }, id: \.id.stableID) { _ in
                Button("Quit") { handle(.quit) }
                    .keyboardShortcut("q")
            }
        }
        .onAppear {
            // Coordinator wiring for the notify-actions lane's opener seam:
            // this surface owns a working openWindow closure, so the "Open
            // AppUpdater" notification action can also RE-CREATE the main
            // window after the user closed it (not just activate one).
            appState.mainWindowOpener = showMainWindow
        }
    }

    // MARK: pieces

    /// Rows that actually carry check results ("No Updates Available" is
    /// only claimable when checks have run).
    private var checkedCount: Int {
        appState.list.rows.filter { $0.check != nil }.count
    }

    /// "Hermes  0.0.0 → 0.21.2"
    private func rowTitle(_ row: AppRow) -> String {
        guard let new = row.check?.resolved?.newestShortVersion else { return row.app.name }
        return "\(row.app.name)  \(row.app.shortVersion ?? "?") → \(new)"
    }

    // MARK: handler map (unchanged contract)

    private func handle(_ id: MenuAction.ID) {
        switch id {
        case .checkNow:
            Task { await appState.list.refresh() }
        case .openMainWindow:
            showMainWindow()
        case .openSettings:
            showMainWindow()
        case .quit:
            NSApplication.shared.terminate(nil)
        case .installNow(let bundleID):
            Task { await appState.requestInstall(bundleID: bundleID) }
        case .viewDetails(let bundleID):
            appState.showDetails(bundleID: bundleID)
            showMainWindow()
        }
    }

    // MARK: action predicates

    private func isQuitAction(_ id: MenuAction.ID) -> Bool {
        if case .quit = id { return true }
        return false
    }

    private func isCheckAction(_ id: MenuAction.ID) -> Bool {
        if case .checkNow = id { return true }
        return false
    }

    private func isOpenAction(_ id: MenuAction.ID) -> Bool {
        if case .openMainWindow = id { return true }
        return false
    }
}
