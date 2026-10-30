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
    @State private var searchExpanded = false
    @FocusState private var searchFocused: Bool

    private var list: ListViewModel { appState.list }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: .constant(.all)) {
                AppListPane(sourceFilter: $sourceFilter, compact: $compactRows, onRefresh: refreshNow)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(alignment: .top) { errorBanner }
                    .toolbar(removing: .sidebarToggle)
                    // OUTERMOST on purpose: wrapped inside other modifiers it
                    // was ignored live (column came out ~270pt, rows wrapped).
                    .navigationSplitViewColumnWidth(min: 400, ideal: 560, max: 760)
            } detail: {
                AppDetailPane(row: selectedRow)
                    .environmentObject(appState)
                    .environmentObject(glue)
                    .background(Color(nsColor: .textBackgroundColor))
            }
            footer
        }
        .toolbar { toolbarContent }
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

    /// Updatest's single centered capsule: [Updates (N) | Installed | 🔍].
    /// The magnifier expands an inline search field inside the capsule.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 2) {
                tabButton(.updates, title: "Updates (\(list.stats.pending))")
                tabButton(.installed, title: "Installed")
                if searchExpanded {
                    TextField("Search", text: Binding(get: { list.query }, set: { list.setQuery($0) }))
                        .textFieldStyle(.plain)
                        .frame(width: 150)
                        .focused($searchFocused)
                        .onSubmit { searchFocused = false }
                        .onExitCommand { closeSearch() }
                }
                Button {
                    if searchExpanded { closeSearch() } else { searchExpanded = true; searchFocused = true }
                } label: {
                    Image(systemName: searchExpanded ? "xmark.circle.fill" : "magnifyingglass")
                        .frame(width: 30, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(searchExpanded ? "Clear search" : "Search apps")
                .accessibilityLabel(searchExpanded ? "Clear search" : "Search")
            }
            .padding(3)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Show updates or installed apps")
        }
    }

    private var currentTab: MainTab { list.filter == .pendingOnly ? .updates : .installed }

    private func tabButton(_ tab: MainTab, title: String) -> some View {
        let active = currentTab == tab
        return Button {
            list.setFilter(tab == .updates ? .pendingOnly : .all)
        } label: {
            Text(title)
                .font(.callout.weight(active ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Capsule().fill(active ? Color.primary.opacity(0.14) : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? .primary : .secondary)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func closeSearch() {
        list.setQuery("")
        searchExpanded = false
        searchFocused = false
    }

    // MARK: footer (honest last/next check)

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Button(action: refreshNow) {
                    // Re-render every 30 s so "just now" ages honestly.
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                    let footerText = footerText(now: context.date)
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise")
                            .symbolEffect(.rotate, isActive: isRefreshing)
                            .foregroundStyle(Color.accentColor)
                        (Text(footerText.primary).foregroundStyle(Color.accentColor)
                            + Text(footerText.tail ?? "").foregroundStyle(.secondary))
                    }
                    .font(.caption)
                    .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRefreshing)
                .help("Refresh and check all apps now")
                .accessibilityLabel("Check for Updates")
                Spacer(minLength: 0)
                toolsMenu
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }

    private var toolsMenu: some View {
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

    /// ("1 hour ago", ", next in 6 hours") — Updatest's blue time + gray tail.
    private func footerText(now: Date) -> (primary: String, tail: String?) {
        if isRefreshing { return ("Checking…", nil) }
        let lastRowCheck = list.rows.compactMap(\.app.checkedAt).max()
        let lastFire = appState.schedule.state.lastFireAt
        guard let last = [lastRowCheck, lastFire, lastWindowCheckAt].compactMap({ $0 }).max() else {
            return ("Not checked yet", nil)
        }
        let policy = appState.schedule.policy
        let primary = RelativeText.string(for: last, relativeTo: now)
        guard policy.intervalMinutes > 0 else { return (primary, ", automatic checks off") }
        // The schedule engine counts from its own last fire; a window check
        // does not move the schedule.
        let next = (lastFire ?? last).addingTimeInterval(TimeInterval(policy.intervalMinutes * 60))
        if next > now { return (primary, ", next \(RelativeText.string(for: next, relativeTo: now))") }
        // Overdue: say WHY instead of a bare "due" (the engine's own gates,
        // probed the same way AppState+Decision14 does).
        let probe = ScheduleEngine(fire: { _ in 0 })
        if policy.skipOnBattery && probe.isOnBattery() { return (primary, ", automatic checks paused on battery") }
        if policy.deferWhenOffline && !probe.isOnline() { return (primary, ", waiting for network") }
        return (primary, ", next check due")
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
