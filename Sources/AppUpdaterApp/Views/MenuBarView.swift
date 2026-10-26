import SwiftUI
import AppKit
import AppUpdaterCore

struct MenuBarView: View {
    let showMainWindow: () -> Void
    let checkForSelfUpdate: () -> Void
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let menu = appState.menuData
        VStack(alignment: .leading, spacing: 2) {
            // headline block — contract order: Check / Open / Quit.
            ForEach(menu.headline, id: \.id.stableID) { action in
                Button {
                    handle(action.id)
                } label: {
                    Text(action.label)
                }
            }

            Divider().padding(.vertical, 3)

            // pending surface — MenuData's own honesty: only rows the rules
            // let through; MAS rows carry the Store note instead of an
            // install affordance.
            if menu.pendingSection.updates.isEmpty {
                Text("No pending updates")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(menu.pendingSection.updates) { row in
                    ForEach(MenuData.actions(for: row), id: \.id.stableID) { action in
                        Button {
                            handle(action.id)
                        } label: {
                            Text(action.label)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
                Text("Install Now stages the owner-run CLI command (⌘ copies); the app never applies it itself.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 3)

            // Self-update (Phase 5): the ONLY automatic code-update path in this
            // app, gated on the owner's explicit click (auto-checks stay off).
            Button("Check for Self-Update…") {
                checkForSelfUpdate()
            }

            Divider().padding(.vertical, 3)

            // the coordinator-owned `.currentApps` count + schedule lines
            Text("\(appState.upToDateCount) apps up to date")
                .font(.caption)
            ForEach(menu.scheduleSection, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 3)
            Text("\(menu.counts.total) apps inventoried")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .frame(minWidth: 290)
    }

    /// The coordinator's MenuAction → handler binding (MenuData's doc
    /// contract: the data layer supplies Sections+IDs; the app shell maps
    /// IDs to real handlers exactly once, here).
    private func handle(_ id: MenuAction.ID) {
        switch id {
        case .checkNow:
            Task { await appState.list.refresh() }
        case .openMainWindow:
            showMainWindow()
        case .openSettings:
            // v1: the settings/schedule pane lives in the window as a sheet.
            showMainWindow()
        case .quit:
            NSApplication.shared.terminate(nil)
        case .installNow(let bundleID):
            appState.requestInstall(bundleID: bundleID)
        case .viewDetails(let bundleID):
            appState.showDetails(bundleID: bundleID)
            showMainWindow()
        }
    }
}
