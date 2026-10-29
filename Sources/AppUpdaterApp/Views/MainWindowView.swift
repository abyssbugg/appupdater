import SwiftUI
import AppKit
import AppUpdaterCore

// MARK: - Shared visual language (status colors, pills, icons)

/// One verdict → one color, one symbol, everywhere in the app.
enum VerdictStyle {
    static func color(for verdict: String?) -> Color {
        switch verdict {
        case "update": return .orange
        case "current": return .green
        case "failed": return .red
        default: return .gray
        }
    }

    static func symbol(for verdict: String?) -> String {
        switch verdict {
        case "update": return "arrow.up.circle.fill"
        case "current": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.triangle.fill"
        default: return "questionmark.circle"
        }
    }

    static func label(for verdict: String?) -> String {
        switch verdict {
        case "update": return "Update"
        case "current": return "Current"
        case "failed": return "Failed"
        case "unknown": return "Unknown"
        case nil: return "Not checked"
        default: return verdict ?? "?"
        }
    }
}

/// Rounded status pill used in list rows and the detail header.
/// Update / current / failed get the full colored capsule; unknown / not
/// checked get a quiet tertiary form so 80 unchecked rows don't shout.
struct StatusPill: View {
    let verdict: String?

    var body: some View {
        let color = VerdictStyle.color(for: verdict)
        let loud = verdict == "update" || verdict == "current" || verdict == "failed"
        let base = HStack(spacing: 4) {
            Image(systemName: VerdictStyle.symbol(for: verdict))
                .font(.caption2)
            Text(VerdictStyle.label(for: verdict))
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(loud ? color : Color.secondary.opacity(0.7))

        if loud {
            base
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(color.opacity(0.14)))
        } else {
            base.padding(.horizontal, 8)
        }
    }
}

/// Real app icon from disk — the single biggest visual upgrade over the old
/// text-only rows (MacUpdater's look starts here).
struct AppIconView: View {
    let path: String
    var size: CGFloat = 36

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
    }
}

// MARK: - Main window

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState
    // Glue-wiring: the security/brew/proxy panels' model (injected by the
    // scene; re-injected into the inspector content below, matching the
    // appState pattern the inspector needed).
    @EnvironmentObject private var glue: GluePanelsModel

    @State private var showSettingsSheet = false
    @State private var showLocationsSheet = false
    @State private var showManualSheet = false
    @State private var showBrewSheet = false
    @State private var showProxySheet = false
    @State private var errorDismissed = false
    @State private var isRefreshing = false

    private var list: ListViewModel { appState.list }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            listColumn
        }
        .inspector(isPresented: Binding(
            get: { selectedRow != nil },
            set: { if !$0 { list.select(nil) } }
        )) {
            if let row = selectedRow {
                DetailInspector(row: row)
                    .environmentObject(appState)
                    .environmentObject(glue)
                    .inspectorColumnWidth(min: 300, ideal: 330, max: 380)
            }
        }
        .searchable(
            text: Binding(get: { list.query }, set: { list.setQuery($0) }),
            placement: .toolbar,
            prompt: "Search apps or bundle IDs")
        .toolbar { toolbarContent }
        .sheet(isPresented: $showSettingsSheet) {
            ScheduleSettingsView(onClose: { showSettingsSheet = false })
        }
        .sheet(isPresented: $showLocationsSheet) {
            LocationSettingsHost()
                .frame(minWidth: 460, minHeight: 340)
        }
        .sheet(isPresented: $showManualSheet) {
            ManualSourceHost()
                .frame(minWidth: 470, minHeight: 380)
        }
        .sheet(isPresented: $showBrewSheet) {
            BrewPinsSheet(onClose: { showBrewSheet = false })
        }
        .sheet(isPresented: $showProxySheet) {
            ProxySettingsSheet(onClose: { showProxySheet = false })
        }
        .onChange(of: list.lastError) { _, _ in errorDismissed = false }
        .onAppear {
            // Product-default: updates lead the list (MacUpdater behavior).
            // The user's own sort choice wins the moment they change it.
            if list.sort == .name, list.query.isEmpty {
                list.setSort(.updateFirst)
            }
            // An open window with zero rows means nothing has been scanned
            // this launch — refresh immediately instead of showing a void.
            if list.rows.isEmpty {
                refreshNow()
            }
        }
        .frame(minWidth: 940, minHeight: 540)
    }

    private var selectedRow: AppRow? {
        list.selection.flatMap { list.row(for: $0) }
    }

    // MARK: toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, isActive: isRefreshing)
            }
            .help("Check all apps against their sources now")

            Picker("Sort", selection: Binding(
                get: { list.sort }, set: { list.setSort($0) })) {
                ForEach(SortKey.allCases, id: \.self) { key in
                    Label(sortLabel(key), systemImage: sortSymbol(key)).tag(key)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Sort apps")

            Picker("Show", selection: Binding(
                get: { list.filter }, set: { list.setFilter($0) })) {
                ForEach(ListFilter.allCases, id: \.self) { mode in
                    Label(filterLabel(mode), systemImage: filterSymbol(mode)).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Filter apps")

            Button {
                showSettingsSheet = true
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Schedule & notifications")

            Button {
                showLocationsSheet = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("Custom scan locations")

            Button {
                showManualSheet = true
            } label: {
                Image(systemName: "pin")
            }
            .help("Manual source pins")

            Button {
                showBrewSheet = true
            } label: {
                Image(systemName: "pin.square")
            }
            .help("Homebrew pins & doctor")

            Button {
                showProxySheet = true
            } label: {
                Image(systemName: "network.badge.shield.half.filled")
            }
            .help("Proxy settings & system picture")
        }
    }

    // MARK: sidebar (status summary → filters)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brandHeader
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            filterCards
                .padding(.horizontal, 10)

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(appState.menuData.scheduleSection, id: \.self) { line in
                    Label {
                        Text(line).font(.caption)
                    } icon: {
                        Image(systemName: "clock").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .navigationTitle("AppUpdater")
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.orange, .pink],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .shadow(color: .orange.opacity(0.35), radius: 5, y: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text("AppUpdater").font(.title3.weight(.bold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        let stats = list.stats
        if stats.total == 0 { return "No apps yet — run a check" }
        if stats.pending > 0 { return "\(stats.pending) of \(stats.total) apps need updates" }
        return "All \(stats.total) apps up to date"
    }

    private var filterCards: some View {
        VStack(spacing: 6) {
            filterCard(.pendingOnly, symbol: "arrow.up.circle.fill", tint: .orange,
                       title: "Updates", count: list.stats.pending)
            filterCard(.all, symbol: "square.grid.2x2", tint: .accentColor,
                       title: "All Apps", count: list.stats.total)
            filterCard(.ignoredOnly, symbol: "eye.slash", tint: .gray,
                       title: "Ignored", count: list.stats.ignored)
        }
    }

    private func filterCard(_ mode: ListFilter, symbol: String, tint: Color,
                            title: String, count: Int) -> some View {
        let active = list.filter == mode
        return Button {
            list.setFilter(mode)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(active ? .white : tint)
                    .frame(width: 20)
                Text(title)
                    .font(.callout.weight(active ? .semibold : .regular))
                    .foregroundStyle(active ? .white : .primary)
                Spacer()
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(active ? .white.opacity(0.9) : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(active ? .white.opacity(0.25) : tint.opacity(0.12))
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(active ? tint.opacity(0.85) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: list column

    private var listColumn: some View {
        Group {
            if list.filteredRows.isEmpty {
                emptyState
            } else {
                appList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { errorBanner }
        .navigationTitle("Apps")
        .navigationSubtitle(subtitle)
    }

    private var appList: some View {
        List(selection: Binding(
            get: { list.selection },
            set: { list.select($0) }
        )) {
            ForEach(list.filteredRows) { row in
                AppRowView(row: row)
                    .tag(row.id)
            }
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("Nothing to show")
                .font(.title3.weight(.semibold))
            Text("Run a check to scan /Applications and ask every source.\nNothing is faked meanwhile.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                refreshNow()
            } label: {
                Label("Check Now", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let vmError = list.lastError, !errorDismissed {
            bannerRow(text: vmError)
        } else if let actionError = appState.actionError, !errorDismissed {
            bannerRow(text: actionError)
        }
    }

    private func bannerRow(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout).multilineTextAlignment(.leading)
            Spacer()
            Button("Dismiss") { errorDismissed = true }
                .font(.caption)
        }
        .padding(10)
        .background(.orange.opacity(0.12))
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    private func refreshNow() {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorDismissed = false
        Task {
            await list.refresh()
            isRefreshing = false
        }
    }

    private func sortLabel(_ key: SortKey) -> String {
        switch key {
        case .name: return "Name"
        case .updateFirst: return "Updates first"
        case .recentlyChecked: return "Recently checked"
        }
    }

    private func sortSymbol(_ key: SortKey) -> String {
        switch key {
        case .name: return "textformat.abc"
        case .updateFirst: return "arrow.up.circle"
        case .recentlyChecked: return "clock"
        }
    }

    private func filterLabel(_ mode: ListFilter) -> String {
        switch mode {
        case .all: return "All apps"
        case .pendingOnly: return "Updates only"
        case .ignoredOnly: return "Ignored"
        }
    }

    private func filterSymbol(_ mode: ListFilter) -> String {
        switch mode {
        case .all: return "square.grid.2x2"
        case .pendingOnly: return "arrow.up.circle"
        case .ignoredOnly: return "eye.slash"
        }
    }
}

// MARK: - List row

/// Host wrapper for ManualSourceSheet (same settable-seam pattern as the
/// locations host): after a pin change, refresh the INVENTORY scan-only —
/// a pin change never triggers checks by itself.
private struct ManualSourceHost: View {
    @EnvironmentObject private var appState: AppState

    private var pane: ManualSourceSheet {
        var view = ManualSourceSheet(
            store: appState.manualSourceStore,
            apps: appState.list.rows.map { $0.app })
        view.onChange = {
            Task { await appState.refreshInventoryOnly() }
        }
        return view
    }

    var body: some View {
        pane
    }
}

/// Host wrapper so LocationSettingsView's settable `onChange` seam (a plain
/// var — not a chaining modifier) reaches AppState's scan-only refresh
/// without editing the lane-owned view file.
private struct LocationSettingsHost: View {
    @EnvironmentObject private var appState: AppState

    private var pane: LocationSettingsView {
        var view = LocationSettingsView(store: appState.scanLocationStore)
        view.onChange = {
            Task { await appState.scanLocationsDidChange() }
        }
        return view
    }

    var body: some View {
        pane
    }
}

struct AppRowView: View {
    let row: AppRow

    var body: some View {
        HStack(spacing: 11) {
            AppIconView(path: row.app.path, size: 34)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(row.app.name)
                        .font(.body.weight(.medium))
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
                Text(row.app.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            versionBlock
            StatusPill(verdict: row.check?.verdict)
        }
        .padding(.vertical, 3)
    }

    /// Honest version display: a live transition "1.0 → 1.3.1" when an update
    /// is really available, a quiet single number otherwise. Long cask
    /// version strings (build-hash suffixes) truncate in the row — the full
    /// string lives in the detail pane and the tooltip.
    @ViewBuilder
    private var versionBlock: some View {
        if row.updateAvailable, let new = row.check?.resolved?.newestShortVersion {
            HStack(spacing: 5) {
                Text(row.app.shortVersion ?? "?")
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                Text(new)
                    .foregroundStyle(.orange)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.callout.monospacedDigit())
            .frame(maxWidth: 240, alignment: .trailing)
            .help("\(row.app.shortVersion ?? "?") → \(new)")
        } else if let v = row.app.shortVersion {
            Text(v)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 240, alignment: .trailing)
        } else {
            Text("—")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Detail inspector

private struct DetailInspector: View {
    let row: AppRow
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                versionCard
                if row.app.isMacAppStore {
                    storeNotice
                }
                SecurityPanelSection(row: row)
                installCard
                rulesCard
                metaCard
            }
            .padding(14)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                AppIconView(path: row.app.path, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.app.name)
                        .font(.title2.weight(.bold))
                        .lineLimit(2)
                    Text(row.app.bundleIdentifier)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                    StatusPill(verdict: row.check?.verdict)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The version card — the app's reason to exist, front and center.
    @ViewBuilder
    private var versionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Version", systemImage: "number")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if row.updateAvailable, let new = row.check?.resolved?.newestShortVersion {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Installed").font(.caption2).foregroundStyle(.secondary)
                        Text(row.app.shortVersion ?? "?")
                            .font(.title3.monospacedDigit())
                    }
                    Image(systemName: "arrow.right")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Available").font(.caption2).foregroundStyle(.orange)
                        Text(new)
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(.orange)
                            .fontWeight(.bold)
                    }
                }
                if row.check?.verdict == "update", !row.updateAvailable {
                    Text("Muted by one of your rules — shown for the record, not offered as an action.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if row.check?.verdict == "current" {
                Label {
                    Text("Up to date at \(row.app.shortVersion ?? "?")")
                        .font(.callout.weight(.medium))
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
            } else {
                Text(verdictExplanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quinary)
        )
    }

    private var verdictExplanation: String {
        switch row.check?.verdict {
        case "failed":
            return "Sources could not answer — nothing is guessed. Run a check again."
        case "unknown":
            return "No source could verify a newer version for this app honestly."
        case nil:
            return "This app has not been checked yet — run a check."
        default:
            return VerdictStyle.label(for: row.check?.verdict)
        }
    }

    private var storeNotice: some View {
        Label("Mac App Store app — updates happen in the Store; the installer never touches it here.",
              systemImage: "app.badge.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.1)))
    }

    @ViewBuilder
    private var installCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Install", systemImage: "square.and.arrow.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if row.updateAvailable && !row.app.isMacAppStore {
                Button {
                    appState.requestInstall(bundleID: row.app.bundleIdentifier)
                } label: {
                    Label("Stage Install Command", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                if let command = appState.lastInstallCommand,
                   command.contains("--apps \(row.app.name)") {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(.quinary))
                    HStack(spacing: 8) {
                        Label("Copied to the clipboard — nothing has run.", systemImage: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Type in Terminal…") {
                            if let command = appState.lastInstallCommand,
                               command.contains("--apps \(row.app.name)") {
                                appState.typeStagedCommandInTerminal(command)
                            }
                        }
                        .font(.caption)
                        .help("Opt-in: types the same command into your default terminal (you attend any password prompt)")
                    }
                } else {
                    Text("Stages the exact owner-run CLI command — the app never applies installs itself.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if row.updateAvailable && row.app.isMacAppStore {
                Text("Update available in the Mac App Store — the Store app handles it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Nothing to install — the status above is the truth this app stands behind.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Rules", systemImage: "slider.horizontal.3")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle("Include in automatic checks", isOn: Binding(
                get: { row.decision.autoCheck },
                set: { enabled in
                    Task { await appState.setAutoCheck(row.app.bundleIdentifier, enabled) }
                }
            ))

            HStack(spacing: 8) {
                Button("Ignore All Updates") {
                    Task { await appState.list.ignoreBundle(row.app.bundleIdentifier) }
                }
                if let claim = row.check?.resolved?.newestShortVersion {
                    Button("Ignore This Version") {
                        Task { await appState.list.ignoreVersion(row.app.bundleIdentifier, claim) }
                    }
                }
                if row.decision.ignoredBundle || row.decision.ignoredVersion
                    || row.decision.autoCheck {
                    Button("Clear") {
                        Task { await appState.removeRules(for: row.app.bundleIdentifier) }
                    }
                }
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metaCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Details", systemImage: "info.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let source = row.check?.resolved?.source {
                metaRow("Source", source.rawValue.capitalized)
            }
            if let failure = row.check?.failures.first {
                metaRow("Failure", failure.message)
            }
            HStack(alignment: .top, spacing: 6) {
                Text("Path").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
                Text(row.app.path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.app.path)])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value).font(.caption).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
