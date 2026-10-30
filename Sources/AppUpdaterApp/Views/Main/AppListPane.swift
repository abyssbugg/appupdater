import SwiftUI
import AppKit
import AppUpdaterCore

/// Updatest's Source menu: All, one entry per source kind, No Source.
enum SourceFilter: Hashable {
    case all
    case kind(SourceKind)
    case noSource

    func admits(_ row: AppRow) -> Bool {
        switch self {
        case .all: return true
        case .kind(let kind): return row.check?.resolved?.source == kind
        case .noSource: return row.check?.resolved == nil
        }
    }
}

/// Left pane: header "Available (N)" / "Installed (N)", Filter · Sort · Source
/// menus, compact toggle, and the app rows.
struct AppListPane: View {
    @EnvironmentObject private var appState: AppState
    @Binding var sourceFilter: SourceFilter
    @Binding var compact: Bool
    let onRefresh: () -> Void

    private var list: ListViewModel { appState.list }

    /// The tab filter (Updates / Installed / Ignored) composed with Source.
    var visibleRows: [AppRow] {
        list.filteredRows.filter { sourceFilter.admits($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            controlsBar
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)
            header
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
            if visibleRows.isEmpty {
                emptyState
            } else {
                rowsList
            }
        }
    }

    // MARK: controls (Filter · Sort · Source · compact)

    private var controlsBar: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            filterMenu
            sortMenu
            sourceMenu
            Button {
                compact.toggle()
            } label: {
                Image(systemName: compact
                      ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
            }
            .buttonStyle(.borderless)
            .help(compact ? "Show large rows" : "Show compact rows")
            .accessibilityLabel("Toggle compact rows")
        }
        .font(.callout)
    }

    private var filterMenu: some View {
        let rows = list.rows
        let ignored = list.stats.ignored
        let muted = rows.filter(\.isMutedUpdate).count
        return Menu {
            Picker("Filter", selection: Binding(
                get: { list.filter }, set: { list.setFilter($0) })) {
                Text("All (\(rows.count))").tag(ListFilter.all)
                Text("Updates (\(list.stats.pending))").tag(ListFilter.pendingOnly)
                Text("Ignored: All (\(ignored))").tag(ListFilter.ignoredOnly)
            }
            .pickerStyle(.inline)
            if muted > 0 {
                Divider()
                Text("Skipped Updates (\(muted))")
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Filter apps")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: Binding(
                get: { list.sort }, set: { list.setSort($0) })) {
                Text("Default").tag(SortKey.updateFirst)
                Text("Name: A–Z").tag(SortKey.name)
                Text("Recently Checked").tag(SortKey.recentlyChecked)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "line.3.horizontal")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Sort apps")
    }

    private var sourceMenu: some View {
        let base = list.filteredRows
        return Menu {
            Picker("Source", selection: $sourceFilter) {
                Text("All (\(base.count))").tag(SourceFilter.all)
                ForEach(SourceStyle.menuOrder, id: \.self) { kind in
                    let count = base.filter { SourceFilter.kind(kind).admits($0) }.count
                    Text("\(SourceStyle.label(for: kind)) (\(count))")
                        .tag(SourceFilter.kind(kind))
                }
                let none = base.filter { SourceFilter.noSource.admits($0) }.count
                Text("No Source (\(none))").tag(SourceFilter.noSource)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Source", systemImage: "square.on.square")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Filter by update source")
    }

    // MARK: header

    private var header: some View {
        let title: String = switch list.filter {
        case .pendingOnly: "Available"
        case .all: "Installed"
        case .ignoredOnly: "Ignored"
        }
        let updatable = visibleRows.filter(\.canUpdateInApp)
        return HStack {
            Text("\(title) (\(visibleRows.count))")
                .font(.headline)
            Spacer()
            if list.filter == .pendingOnly, updatable.count > 1 {
                Button("Update All") {
                    let ids = updatable.map(\.app.bundleIdentifier)
                    Task {
                        // Serial on purpose: the guarded in-app chain runs one
                        // update at a time; each awaits its own receipt.
                        for id in ids { await appState.requestInstall(bundleID: id) }
                    }
                }
                .controlSize(.small)
                .disabled(appState.installInFlightBundleID != nil)
                .help("Runs each update in turn through the verified chain")
            }
        }
    }

    // MARK: rows

    private var rowsList: some View {
        List(selection: Binding(get: { list.selection }, set: { list.select($0) })) {
            ForEach(visibleRows) { row in
                AppRowView(row: row, compact: compact)
                    .tag(row.id)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: list.filter == .pendingOnly
                  ? "checkmark.circle" : "sparkle.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(emptyTitle)
                .font(.title3.weight(.semibold))
            Text(emptyMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Check for Updates", action: onRefresh)
                .padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if list.rows.isEmpty { return "No Apps Yet" }
        if list.filter == .pendingOnly {
            let checked = list.rows.filter { $0.check != nil }.count
            return checked == 0 ? "Not Checked Yet" : "No Updates Available"
        }
        return "Nothing to Show"
    }

    private var emptyMessage: String {
        if list.rows.isEmpty { return "Check for updates to scan your Applications folders." }
        if list.filter == .pendingOnly {
            let checked = list.rows.filter { $0.check != nil }.count
            if checked == 0 { return "\(list.rows.count) apps found — run a check to ask their sources." }
            return "\(checked) of \(list.rows.count) apps checked — nothing newer was found."
        }
        return "No apps match the current filter."
    }
}

// MARK: - Row (Updatest layout)

struct AppRowView: View {
    let row: AppRow
    var compact: Bool = false
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 3) {
                AppIconView(path: row.app.path, size: compact ? 32 : 52)
                Circle()
                    .fill(row.isRunning ? Color.secondary : Color.clear)
                    .frame(width: 4, height: 4)
                    .help(row.isRunning ? "Running" : "")
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(row.app.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if row.app.isMacAppStore {
                        Image(systemName: "app.badge")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Mac App Store app")
                    }
                    if row.decision.ignoredBundle || row.decision.ignoredVersion {
                        Image(systemName: "eye.slash")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help("Ignored by a rule")
                    }
                }
                versionLine
                if !compact { sourceLine }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, compact ? 2 : 5)
    }

    @ViewBuilder
    private var versionLine: some View {
        if row.check?.verdict == "update", let info = row.check?.resolved {
            HStack(spacing: 4) {
                Text(row.app.shortVersion ?? "?")
                Text("→")
                Text(VersionText.newest(info))
                    .foregroundStyle(row.updateAvailable ? Color.accentColor : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            .help("\(row.app.shortVersion ?? "?") → \(VersionText.newest(info))")
        } else {
            Text(VersionText.installed(row.app))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var sourceLine: some View {
        if let source = row.check?.resolved?.source {
            Text(SourceStyle.label(for: source))
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else if let verdict = row.check?.verdict {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(verdict == "failed" ? "Check failed" : "No Source")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .help(verdict == "failed"
                  ? "The sources could not answer — nothing is guessed"
                  : "This app doesn't expose an update feed any source could verify")
        } else {
            Text("Not checked")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if row.canUpdateInApp {
            VStack(spacing: 2) {
                if appState.installInFlightBundleID == row.app.bundleIdentifier {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Update…") {
                        appState.showDetails(bundleID: row.app.bundleIdentifier)
                        Task { await appState.requestInstall(bundleID: row.app.bundleIdentifier) }
                    }
                    .controlSize(.small)
                    .disabled(appState.installInFlightBundleID != nil)
                    .help(appState.installInFlightBundleID != nil
                          ? "Another update is running — updates run one at a time"
                          : "Download → verify (HTTPS + SHA-256) → back up → replace")
                }
                if !compact {
                    Button("Open App") { openApp() }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else if row.updateAvailable && row.app.isMacAppStore {
            Button("App Store") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/App Store.app"))
            }
            .controlSize(.small)
            .help("Mac App Store apps update through the App Store")
        }
    }

    private func openApp() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: row.app.path),
            configuration: NSWorkspace.OpenConfiguration())
    }
}
