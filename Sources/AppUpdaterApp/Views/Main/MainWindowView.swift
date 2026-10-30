import SwiftUI
import AppKit
import AppUpdaterCore

/// Updatest's two toolbar tabs. "Ignored" lives in the Filter menu.
enum MainTab: Hashable {
    case updates
    case installed
}

/// Main window — Updatest layout: centered tab capsule + search in the
/// toolbar, app list on the left, details on the right, status footer.
struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    // Glue-wiring: security/brew/proxy panels' model; re-injected into the
    // detail column (same pattern the old inspector needed).
    @EnvironmentObject private var glue: GluePanelsModel

    @State private var sheet: SettingsSheet?
    @State private var errorDismissed = false
    @State private var isRefreshing = false
    @State private var sourceFilter: SourceFilter = .all
    @State private var compactRows = false
    @State private var didApplyLaunchDefaults = false
    /// When THIS window's own check last finished — `list.refresh()` stamps
    /// neither `checkedAt` nor the schedule state, so without it the footer
    /// showed the previous scheduled fire after a fresh check (live finding).
    @State private var lastWindowCheckAt: Date?

    private var list: ListViewModel { appState.list }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            AppListPane(sourceFilter: $sourceFilter, compact: $compactRows, onRefresh: refreshNow)
                .navigationSplitViewColumnWidth(min: 360, ideal: 430, max: 600)
                .safeAreaInset(edge: .bottom, spacing: 0) { footer }
                .overlay(alignment: .top) { errorBanner }
                .toolbar(removing: .sidebarToggle)
        } detail: {
            AppDetailPane(row: selectedRow)
                .environmentObject(appState)
                .environmentObject(glue)
                .safeAreaInset(edge: .bottom, spacing: 0) { detailFooter }
        }
        .toolbar { toolbarContent }
        .searchable(
            text: Binding(get: { list.query }, set: { list.setQuery($0) }),
            placement: .toolbar,
            prompt: "Search")
        .navigationTitle("")
        .sheet(item: $sheet) { which in sheetContent(which) }
        .onChange(of: list.lastError) { _, _ in errorDismissed = false }
        // A dismissed banner must not suppress FUTURE refusals.
        .onChange(of: appState.actionError) { _, _ in errorDismissed = false }
        .onAppear(perform: applyLaunchDefaults)
        .frame(minWidth: 940, minHeight: 560)
    }

    private var selectedRow: AppRow? {
        list.selection.flatMap { list.row(for: $0) }
    }

    private func applyLaunchDefaults() {
        if !didApplyLaunchDefaults {
            didApplyLaunchDefaults = true
            // Updatest opens on the Updates tab, updates-first ordering. The
            // user's own choices win the moment they change them.
            if list.sort == .name, list.query.isEmpty { list.setSort(.updateFirst) }
            if list.filter == .all { list.setFilter(.pendingOnly) }
        }
        // An empty list means nothing was scanned this launch — refresh
        // instead of showing a void.
        if list.rows.isEmpty { refreshNow() }
    }

    // MARK: toolbar (centered tab capsule)

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: Binding(
                get: { list.filter == .pendingOnly ? MainTab.updates : MainTab.installed },
                set: { list.setFilter($0 == .updates ? .pendingOnly : .all) })) {
                Label("Updates (\(list.stats.pending))", systemImage: "arrow.down.circle")
                    .tag(MainTab.updates)
                Label("Installed", systemImage: "square.grid.2x2")
                    .tag(MainTab.installed)
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .fixedSize()
            .accessibilityLabel("Show updates or installed apps")
        }
    }

    // MARK: footer (honest last/next check)

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Button(action: refreshNow) {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.rotate, isActive: isRefreshing)
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .help("Refresh and check all apps now")
                .accessibilityLabel("Check for Updates")
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .background(.bar)
    }

    private var footerText: String {
        if isRefreshing { return "Checking…" }
        let lastRowCheck = list.rows.compactMap(\.app.checkedAt).max()
        let lastFire = appState.schedule.state.lastFireAt
        guard let last = [lastRowCheck, lastFire, lastWindowCheckAt].compactMap({ $0 }).max() else {
            return "Not checked yet"
        }
        var text = RelativeText.string(for: last)
        let interval = appState.schedule.policy.intervalMinutes
        if interval > 0, let fire = lastFire {
            let next = fire.addingTimeInterval(TimeInterval(interval * 60))
            text += next > Date() ? ", next \(RelativeText.string(for: next))" : ", next check due"
        }
        return text
    }

    private var detailFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Spacer()
                Menu {
                    ForEach(SettingsSheet.allCases) { which in
                        Button(which.title) { sheet = which }
                    }
                } label: {
                    Image(systemName: "wrench.and.screwdriver")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Settings and tools")
                .accessibilityLabel("Settings and tools")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    // MARK: banner + refresh

    @ViewBuilder
    private var errorBanner: some View {
        if let message = list.lastError ?? appState.actionError, !errorDismissed {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.callout).multilineTextAlignment(.leading)
                Spacer()
                Button("Dismiss") { errorDismissed = true }.font(.caption)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.15)))
            .padding(.horizontal, 10)
            .padding(.top, 44)
        }
    }

    private func refreshNow() {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorDismissed = false
        Task {
            await list.refresh()
            lastWindowCheckAt = Date()
            isRefreshing = false
        }
    }

    // MARK: settings sheets

    @ViewBuilder
    private func sheetContent(_ which: SettingsSheet) -> some View {
        switch which {
        case .schedule:
            ScheduleSettingsView(onClose: { sheet = nil })
        case .locations:
            LocationSettingsHost().frame(minWidth: 460, minHeight: 340)
        case .manual:
            ManualSourceHost().frame(minWidth: 470, minHeight: 380)
        case .brew:
            BrewPinsSheet(onClose: { sheet = nil })
        case .proxy:
            ProxySettingsSheet(onClose: { sheet = nil })
        }
    }
}

enum SettingsSheet: String, CaseIterable, Identifiable {
    case schedule, locations, manual, brew, proxy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .schedule: return "Schedule & Notifications…"
        case .locations: return "Scan Locations…"
        case .manual: return "Manual Sources…"
        case .brew: return "Homebrew Pins & Doctor…"
        case .proxy: return "Proxy…"
        }
    }
}

/// Host wrapper for ManualSourceSheet: after a pin change, refresh the
/// INVENTORY scan-only — a pin change never triggers checks by itself.
private struct ManualSourceHost: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        var view = ManualSourceSheet(
            store: appState.manualSourceStore,
            apps: appState.list.rows.map { $0.app })
        view.onChange = { Task { await appState.refreshInventoryOnly() } }
        return view
    }
}

/// Host wrapper so LocationSettingsView's settable `onChange` seam reaches
/// AppState's scan-only refresh.
private struct LocationSettingsHost: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        var view = LocationSettingsView(store: appState.scanLocationStore)
        view.onChange = { Task { await appState.scanLocationsDidChange() } }
        return view
    }
}
