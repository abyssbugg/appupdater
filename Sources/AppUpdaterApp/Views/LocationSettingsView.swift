// LocationSettingsView.swift — standalone settings pane for the bookmark-backed
// custom scan-location store (gap #18: Updatest §3.1 customDiscoveryLocations).
// STANDALONE by design: the coordinator wires it into settings navigation and
// supplies the production store (~/Library/Application Support/AppUpdater);
// this file owns only the row list + add/remove UX.
//
// Honesty rules (mirrors docs/reverse/UPDATEST-FINDINGS.md §3.1):
//   - Every store refusal/failure surfaces VERBATIM via `localizedDescription`
//     (including the owner-approved "/Applications … cannot also be a custom
//     location" guard sentence) — never reworded or summarized.
//   - Empty state: "No custom locations — /Applications is always scanned."
//   - /Applications itself never appears in this list (the store refuses it);
//     it is scanned by the engine on its own, by construction.
//   - A custom folder that vanished STAYS LISTED with the gray dot — showing
//     the missing folder is the point; only the owner's Remove button unlists.
//   - Network-volume warning line carried over verbatim from the findings.
//   - @MainActor-only mutations (all store calls happen on the main thread);
//     no force unwrap anywhere; Swift 6 strict concurrency clean.

import SwiftUI
import AppKit
import AppUpdaterCore

/// One rendered pane row: the persisted location plus whether it currently
/// resolves to a real folder (`resolvedRoots()`'s `url == nil` = missing).
struct LocationRow: Identifiable {
    let location: ScanLocation
    let resolved: URL?
    var id: String { location.id }
}

/// Settings pane listing custom scan locations with Add/Remove and verbatim
/// honest state lines. The pane is fully functional on its own (it owns its
/// reload cycle); `onChange` is the coordinator seam.
public struct LocationSettingsView: View {
    /// The custom scan-location store this pane edits (explicit at init —
    /// the coordinator supplies the production location).
    private let store: ScanLocationStore

    /// Seam filled by the coordinator: called after every SUCCESSFUL mutation
    /// (add/remove) so the owning app can refresh whatever depends on the
    /// scan roots (e.g. trigger a re-scan). Called on the main thread.
    /// Usage: `var pane = LocationSettingsView(store:); pane.onChange = { … }`.
    public var onChange: (() -> Void)?

    public init(store: ScanLocationStore) {
        self.store = store
    }

    // MARK: State (all stores-into-view state refreshes through loadRows())

    @State private var rows: [LocationRow] = []
    @State private var errorLine: String?
    @State private var warningLine: String?

    public var body: some View {
        Form {
            Section("Custom Scan Locations") {
                if rows.isEmpty {
                    Text("No custom locations — /Applications is always scanned.")
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    rowView(row)
                }
                Button {
                    openAddPanel()
                } label: {
                    Label("Add Location…", systemImage: "plus")
                }
            }

            Section("Status") {
                if let errorLine {
                    Label {
                        Text(errorLine).textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.red)
                }
                if let warningLine {
                    Label {
                        Text(warningLine).textSelection(.enabled)
                    } icon: {
                        Image(systemName: "bookmark.slash")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            Section {
                Text("Network locations may be slow to scan; updates may not work reliably there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { loadRows() }
    }

    // MARK: Rows

    /// Valid/missing dot (green/gray by resolvedRoots), monospaced path,
    /// short added date, and the owner's Remove button.
    private func rowView(_ row: LocationRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(row.resolved == nil ? Color.gray : Color.green)
                .accessibilityLabel(Text(row.resolved == nil ? "Missing folder" : "Folder exists"))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.location.canonicalPath)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Text(row.location.addedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                remove(row: row)
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this location from the scan roots")
        }
    }

    // MARK: Mutations (@MainActor only — every store verb runs on the main thread)

    /// Reloads the honest view state: rows (with their resolved reality) plus
    /// the verbatim error/warning lines. Store failures render UNCHANGED text.
    @MainActor
    private func loadRows() {
        do {
            rows = try store.resolvedRoots().map { LocationRow(location: $0.location, resolved: $0.url) }
            errorLine = nil   // a successful render clears the previous failure line
        } catch {
            rows = []
            errorLine = error.localizedDescription
        }
        // Instance-local bookmark observation; read after this pane's own main
        // thread mutations (thread judgment documented on the store class).
        warningLine = store.lastBookmarkWarning
    }

    /// Folder picker per the honesty contract: directories only, one at a time,
    /// confirm button "Add Scan Location", panel message carried verbatim from
    /// the reverse-engineered UX copy.
    @MainActor
    private func openAddPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Scan Location"
        panel.message = "Add additional locations to discover apps stored outside /Applications."
        panel.level = .modalPanel
        guard panel.runModal() == .OK, let chosen = panel.url else { return }   // cancel is not an error
        do {
            try store.add(chosen)
            loadRows()
            onChange?()
        } catch {
            errorLine = error.localizedDescription   // verbatim refusal (e.g. /Applications guard)
            loadRows()
        }
    }

    /// Owner-initiated removal. Unknown ids would throw (store contract), but
    /// ids here come straight from the listed rows, so the catch path exists
    /// for the honest store-read/rotation races — shown verbatim either way.
    @MainActor
    private func remove(row: LocationRow) {
        do {
            try store.remove(id: row.location.id)
            loadRows()
            onChange?()
        } catch {
            errorLine = error.localizedDescription
            loadRows()
        }
    }
}
