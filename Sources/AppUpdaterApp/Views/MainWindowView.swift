import SwiftUI
import AppUpdaterCore

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState

    @State private var showSettingsSheet = false
    @State private var errorDismissed = false

    private var list: ListViewModel { appState.list }

    var body: some View {
        VStack(spacing: 0) {
            errorBanner
            header
            Divider()
            HSplitView {
                listPane
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let selected = selectedRow {
                    detailPane(selected)
                        .padding(12)
                        .frame(maxWidth: 320)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 420)
        .sheet(isPresented: $showSettingsSheet) {
            ScheduleSettingsView(onClose: { showSettingsSheet = false })
        }
        .onChange(of: list.lastError) { _, _ in errorDismissed = false }
    }

    private var selectedRow: AppRow? {
        list.selection.flatMap { list.row(for: $0) }
    }

    /// Honest version line: short version + build when present, "?" when
    /// the bundle carries neither (the scanner stores what the disk has).
    private func versionLine(_ app: InstalledApp) -> String {
        let short = app.shortVersion ?? "?"
        let build = app.bundleVersion.map { " (build \($0))" } ?? ""
        return short + build
    }

    // MARK: header / footer

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.title3)
            Text("AppUpdater").font(.headline)
            Spacer()
            Button {
                Task { await list.refresh() }
            } label: { Label("Check Now", systemImage: "arrow.clockwise") }
            Button {
                showSettingsSheet = true
            } label: { Label("Schedule", systemImage: "clock") }
        }
        .padding(10)
    }

    private var footer: some View {
        let stats = list.stats
        return HStack {
            Text("\(stats.pending) pending · \(stats.ignored) ignored · \(stats.total) inventoried")
                .font(.caption)
            Spacer()
            Text(appState.menuData.scheduleSection.first ?? "Automatic checks: off")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
    }

    // MARK: honest error banner (no alert API — nothing here can force-dismiss

    @ViewBuilder
    private var errorBanner: some View {
        // The list VM's lastError (seam-backed actions).
        if let vmError = list.lastError, !errorDismissed {
            bannerRow(text: vmError)
        }
        // Direct-action failures (auto-check toggle, rule cleanup).
        else if let actionError = appState.actionError, !errorDismissed {
            bannerRow(text: actionError)
        }
    }

    private func bannerRow(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.caption).multilineTextAlignment(.leading)
            Spacer()
            Button("Dismiss") { errorDismissed = true }
                .font(.caption)
        }
        .padding(6)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: list pane

    private var listPane: some View {
        VStack(spacing: 6) {
            HStack {
                TextField(
                    "Search apps or bundle IDs…",
                    text: Binding(
                        get: { list.query },
                        set: { list.setQuery($0) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                Picker("Sort", selection: Binding(
                    get: { list.sort },
                    set: { list.setSort($0) }
                )) {
                    ForEach(SortKey.allCases, id: \.self) { key in
                        Text(sortLabel(key)).tag(key)
                    }
                }
                .fixedSize()
                Picker("Show", selection: Binding(
                    get: { list.filter },
                    set: { list.setFilter($0) }
                )) {
                    ForEach(ListFilter.allCases, id: \.self) { mode in
                        Text(filterLabel(mode)).tag(mode)
                    }
                }
                .fixedSize()
            }
            listContent
        }
    }

    @ViewBuilder
    private var listContent: some View {
        let rows = list.filteredRows
        if rows.isEmpty {
            emptyState
        } else {
            List {
                ForEach(rows) { row in
                    rowView(row)
                        .contentShape(Rectangle())
                        .onTapGesture { list.select(row.id) }
                        .background(
                            row.id == list.selection
                                ? Color.accentColor.opacity(0.14)
                                : Color.clear
                        )
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray").font(.largeTitle).foregroundStyle(.secondary)
            Text("No rows in this view")
                .font(.headline)
            Text("Check Now scans /Applications and asks every source; nothing is faked meanwhile.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rowView(_ row: AppRow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.app.name).bold()
                Text(row.app.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if row.app.isMacAppStore {
                Image(systemName: "app.badge")
                    .foregroundStyle(.secondary)
                    .help("Mac App Store app")
            }
            if row.decision.ignoredBundle {
                Text("ignored")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(verdictLabel(row))
                .font(.caption)
                .foregroundStyle(verdictColor(row))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(verdictColor(row).opacity(0.12))
                )
        }
        .padding(.vertical, 2)
    }

    // MARK: detail pane

    private func detailPane(_ row: AppRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.app.name).font(.title3).bold()

            LabeledRow(label: "Bundle ID", value: row.app.bundleIdentifier)
            LabeledRow(label: "Path", value: row.app.path)
            LabeledRow(label: "Installed", value: versionLine(row.app))
            LabeledRow(
                label: "Verdict",
                value: "\(verdictLabel(row))\(claimSuffix(row))")
            if row.app.isMacAppStore {
                Label(
                    "Mac App Store app — updates happen in the Store; the installer never touches it here.",
                    systemImage: "app.badge")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()
            installerSection(row)
            Divider()
            rulesSection(row)
            Spacer()
        }
    }

    private func installerSection(_ row: AppRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Install")
                .font(.headline)
            if row.updateAvailable && !row.app.isMacAppStore {
                Text("Install Now never applies from the UI — the owner runs the CLI by hand (LOCKED boundary).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Stage owner-run CLI command") {
                    appState.requestInstall(bundleID: row.app.bundleIdentifier)
                }
                if let command = appState.lastInstallCommand,
                   command.contains("--apps \(row.app.name)") {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Copied to the clipboard — nothing has run.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if row.updateAvailable && row.app.isMacAppStore {
                Text("Update available in the Mac App Store (App Store app handles it).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Nothing to install — the verdict above is the truth the app stands behind.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func rulesSection(_ row: AppRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rules")
                .font(.headline)
            Toggle(
                "Include in automatic checks",
                isOn: Binding(
                    get: { row.decision.autoCheck },
                    set: { enabled in
                        Task { await appState.setAutoCheck(row.app.bundleIdentifier, enabled) }
                    }
                )
            )
            HStack {
                Button("Ignore All Updates") {
                    Task { await list.ignoreBundle(row.app.bundleIdentifier) }
                }
                if let claim = row.check?.resolved?.newestShortVersion {
                    Button("Ignore This Version (\(claim))") {
                        Task { await list.ignoreVersion(row.app.bundleIdentifier, claim) }
                    }
                }
                if row.decision.ignoredBundle || row.decision.ignoredVersion
                    || row.decision.autoCheck {
                    Button("Remove All Rules") {
                        Task { await appState.removeRules(for: row.app.bundleIdentifier) }
                    }
                }
            }
        }
    }

    // MARK: small helpers

    private func verdictLabel(_ row: AppRow) -> String {
        switch row.check?.verdict {
        case "update": return row.updateAvailable ? "update" : "update (muted)"
        case "current": return "current"
        case "failed": return "sources failed"
        case "unknown": return "unknown"
        case nil: return "never checked"
        default: return row.check?.verdict ?? "?"
        }
    }

    private func verdictColor(_ row: AppRow) -> Color {
        switch row.check?.verdict {
        case "update": return row.updateAvailable ? .orange : .secondary
        case "current": return .green
        default: return .secondary
        }
    }

    private func claimSuffix(_ row: AppRow) -> String {
        if let claim = row.check?.resolved?.newestShortVersion {
            return " → newest claim \(claim)"
        }
        return ""
    }

    private func sortLabel(_ key: SortKey) -> String {
        switch key {
        case .name: return "Name"
        case .updateFirst: return "Updates first"
        case .recentlyChecked: return "Recently checked"
        }
    }

    private func filterLabel(_ mode: ListFilter) -> String {
        switch mode {
        case .all: return "All"
        case .pendingOnly: return "Pending"
        case .ignoredOnly: return "Ignored"
        }
    }
}

/// Compact "Label: value" row for the detail pane.
private struct LabeledRow: View {
    let label: String
    let value: String

    init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }
}
