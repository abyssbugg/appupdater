import SwiftUI
import AppKit
import AppUpdaterCore

/// Menu-bar surface: compact, status-first. Same contract as before —
/// MenuData supplies Sections+IDs; the shell maps IDs to handlers exactly once.
struct MenuBarView: View {
    let showMainWindow: () -> Void
    let checkForSelfUpdate: () -> Void
    @EnvironmentObject private var appState: AppState

    private let pendingRowLimit = 6

    var body: some View {
        let menu = appState.menuData
        VStack(alignment: .leading, spacing: 2) {
            statusHeader(menu)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            Divider().padding(.vertical, 3)

            ForEach(menu.headline, id: \.id.stableID) { action in
                menuButton(action, symbol: headlineSymbol(action.id))
            }

            Divider().padding(.vertical, 3)

            Button {
                checkForSelfUpdate()
            } label: {
                Label("Check for Self-Update…", systemImage: "arrow.triangle.2.circlepath")
            }
            .padding(.horizontal, 6)

            Divider().padding(.vertical, 3)

            if menu.pendingSection.updates.isEmpty {
                Label("No pending updates", systemImage: "checkmark.seal")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            } else {
                Text("UPDATES")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.top, 2)

                ForEach(Array(menu.pendingSection.updates.prefix(pendingRowLimit))) { row in
                    pendingRow(row)
                }

                if menu.pendingSection.updates.count > pendingRowLimit {
                    menuButton(
                        MenuAction(id: .openMainWindow, label: "See all \(menu.pendingSection.updates.count)…"),
                        symbol: "arrow.right.circle")
                }
            }

            Divider().padding(.vertical, 3)

            ForEach(menu.scheduleSection, id: \.self) { line in
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
            }

            Divider().padding(.vertical, 3)

            ForEach(menu.headline.filter { isQuitAction($0.id) }, id: \.id.stableID) { action in
                menuButton(action, symbol: "power")
            }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 260)
    }

    // MARK: pieces

    private func statusHeader(_ menu: MenuData) -> some View {
        let pending = menu.counts.pending
        return HStack(spacing: 8) {
            Image(systemName: pending > 0 ? "arrow.up.circle.fill" : "checkmark.seal.fill")
                .foregroundStyle(pending > 0 ? .orange : .green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 0) {
                Text(pending > 0 ? "\(pending) update\(pending == 1 ? "" : "s") available" : "All up to date")
                    .font(.callout.weight(.semibold))
                Text("\(menu.counts.total) apps watched")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func pendingRow(_ row: AppRow) -> some View {
        ForEach(MenuData.actions(for: row), id: \.id.stableID) { action in
            if isRowPrimaryAction(action.id) {
                Button {
                    handle(action.id)
                } label: {
                    HStack(spacing: 8) {
                        AppIconView(path: row.app.path, size: 18)
                        Text(row.app.name)
                            .font(.callout)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let new = row.check?.resolved?.newestShortVersion {
                            Text(new)
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
        }
    }

    private func menuButton(_ action: MenuAction, symbol: String) -> some View {
        Button {
            handle(action.id)
        } label: {
            Label {
                Text(action.label)
            } icon: {
                Image(systemName: symbol)
            }
        }
        .padding(.horizontal, 6)
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
            appState.requestInstall(bundleID: bundleID)
        case .viewDetails(let bundleID):
            appState.showDetails(bundleID: bundleID)
            showMainWindow()
        }
    }

    // MARK: symbol mapping

    private func headlineSymbol(_ id: MenuAction.ID) -> String {
        switch id {
        case .checkNow: return "arrow.clockwise"
        case .openMainWindow: return "macwindow"
        case .quit: return "power"
        default: return "circle"
        }
    }

    private func isQuitAction(_ id: MenuAction.ID) -> Bool {
        if case .quit = id { return true }
        return false
    }

    /// The menu row's PRIMARY action is viewing details; install staging stays
    /// in the window's detail pane (consent surface, not a flyout).
    private func isRowPrimaryAction(_ id: MenuAction.ID) -> Bool {
        if case .viewDetails = id { return true }
        return false
    }
}
