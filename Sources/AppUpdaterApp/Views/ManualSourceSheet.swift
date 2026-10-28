// ManualSourceSheet.swift — standalone SwiftUI sheet for editing the
// bookmark-free per-app manual source pins (gap #2, Updatest §3.11
// AddManualSourceView). STANDALONE by design: the coordinator presents it and
// supplies the production store (~/Library/Application Support/AppUpdater)
// plus the scanned app list; this file owns only the pin list + add/remove UX.
//
// Honesty rules:
//   - Every store refusal/failure surfaces VERBATIM via `localizedDescription`
//     (including the duplicate form "… already has a GitHub release pin …" and
//     the invalid-slug texts) — never reworded or summarized.
//   - Empty state: "No manual pins — sources auto-detect updates on their
//     own." (the manual-over-builtin truth: un-pinned apps stay on the auto
//     sinks).
//   - A pinned app whose bundle id is not in the scanned list STILL RENDERS,
//     under its raw bundle identifier — the store is authoritative, the scan
//     set is not (pins may outlive install locations).
//   - Pin identity is the bundle identifier, EXACTLY (matched against
//     `InstalledApp.bundleIdentifier`; one scanned app per bundle id shown in
//     the picker, because one pin serves all duplicate installs of it).
//   - @MainActor-only mutations (all store calls happen on the main thread);
//     no force unwrap anywhere; Swift 6 strict concurrency clean.

import SwiftUI
import AppUpdaterCore

/// One rendered sheet row: the persisted pin plus the display name it should
/// show (matched from the scanned apps by bundleIdentifier, falling back to
/// the raw bundle identifier when that app is currently unknown to the scan).
struct ManualPinRow: Identifiable {
    let pin: ManualSource
    let displayName: String
    var id: String { pin.id }
}

/// One picker option over the scanned apps: deduped by bundleIdentifier
/// (duplicate installs share one pin), labeled "name (bundle id)".
struct ManualAppOption: Identifiable, Hashable {
    let bundleID: String
    let label: String
    var id: String { bundleID }
}

/// Sheet listing manual source pins with Add/Remove and verbatim honest state
/// lines. The sheet is fully functional on its own (it owns its reload
/// cycle); `onChange` is the coordinator seam.
public struct ManualSourceSheet: View {
    /// The manual pin store this sheet edits (explicit at init — the
    /// coordinator supplies the production location; tests use temp dirs).
    private let store: ManualSourceStore

    /// Scanned apps to pick the pin's target from (deduped by bundle id at
    /// load; stale pins not in this list remain listable).
    private let apps: [InstalledApp]

    /// Seam filled by the coordinator: called after every SUCCESSFUL mutation
    /// (add/remove) so the owning app can refresh whatever depends on the
    /// pins (e.g. trigger a re-check). Called on the main thread.
    /// Usage (mirrors LocationSettingsView exactly): `var sheet =
    /// ManualSourceSheet(store:store, apps:apps); sheet.onChange = { … }`.
    public var onChange: (() -> Void)?

    public init(store: ManualSourceStore, apps: [InstalledApp]) {
        self.store = store
        self.apps = apps
    }

    // MARK: State

    @State private var rows: [ManualPinRow] = []
    @State private var appOptions: [ManualAppOption] = []
    @State private var selectedBundleID: String = ""
    @State private var kind: ManualSource.Kind = .github
    @State private var ownerField: String = ""
    @State private var repoField: String = ""
    @State private var tokenField: String = ""
    @State private var errorLine: String?

    public var body: some View {
        Form {
            Section("Manual Sources") {
                if rows.isEmpty {
                    Text("No manual pins — sources auto-detect updates on their own.")
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    rowView(row)
                }
            }

            Section("Add a Pin") {
                Picker("App", selection: $selectedBundleID) {
                    ForEach(appOptions) { option in
                        Text(option.label).tag(option.bundleID)
                    }
                }
                Picker("Kind", selection: $kind) {
                    Text("GitHub release").tag(ManualSource.Kind.github)
                    Text("Homebrew cask").tag(ManualSource.Kind.cask)
                }
                if kind == .github {
                    TextField("Owner (for example \"microsoft\")", text: $ownerField)
                    TextField("Repository (for example \"vscode\")", text: $repoField)
                } else {
                    TextField("Cask token (for example \"google-chrome\")", text: $tokenField)
                }
                Text(hintText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    add()
                } label: {
                    Label("Add Pin", systemImage: "plus")
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
                } else {
                    Text(honestyFootnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 380)
        .onAppear { loadRows() }
    }

    /// Kind-conditional honest hint (what the pin attests and what happens to
    /// the built-ins for that one app).
    private var hintText: String {
        switch kind {
        case .github:
            return "Pins this app to GitHub releases of an owner/repo you attest."
        case .cask:
            return "Pins this app to a Homebrew cask token you attest."
        }
    }

    /// Status-section footnote when no failure line is showing (line-length
    /// split keeps the lint gate quiet).
    private var honestyFootnote: String {
        "Manual pins replace auto-detected sources for their app; built-in "
            + "sinks stay silent for it. Claims still must beat the installed version."
    }

    // MARK: Rows

    /// Kind label, monospaced target, short added date, and the Remove button.
    private func rowView(_ row: ManualPinRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.pin.kind == .github ? "chevron.up.square" : "shippingbox")
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(row.pin.kind.label))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                    .font(.callout)
                HStack(spacing: 6) {
                    Text(row.pin.kind.label)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    Text(row.pin.targetDescription)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Text(row.pin.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .opacity(row.displayName == row.pin.bundleID ? 0 : 1)
                Text("added \(row.pin.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                removePin(row: row)
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove this manual pin — the app falls back to its auto-detected sources")
        }
    }

    // MARK: State loading

    /// Refreshes the honest view state: pins (with display names), deduped
    /// app picker options, and the verbatim error line. Store failures
    /// render UNCHANGED text; the list renders EMPTY-but-true state.
    @MainActor
    private func loadRows() {
        let known = Dictionary(apps.map { ($0.bundleIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        appOptions = known.values
            .sorted { $0.name.caseInsensitiveCompare($1.name) == .orderedAscending }
            .map { ManualAppOption(bundleID: $0.bundleIdentifier, label: "\($0.name) (\($0.bundleIdentifier))") }
        do {
            rows = try store.pins().map { pin in
                ManualPinRow(
                    pin: pin,
                    displayName: known[pin.bundleID]?.name ?? pin.bundleID
                )
            }
            errorLine = nil // a successful render clears the previous failure line
        } catch {
            rows = []
            errorLine = error.localizedDescription // verbatim corrupt-store text
        }
    }

    // MARK: Mutations (@MainActor only — every store verb runs on the main thread)

    /// Owner-initiated add through the kind-matched store verb. Refusals
    /// (duplicate pin, invalid slug, whitespace token) surface VERBATIM.
    @MainActor
    private func add() {
        do {
            switch kind {
            case .github:
                try store.add(githubPin: ownerField, repo: repoField, bundleID: selectedBundleID)
                ownerField = ""
                repoField = ""
            case .cask:
                try store.add(caskPin: tokenField, bundleID: selectedBundleID)
                tokenField = ""
            }
            loadRows()
            onChange?()
        } catch {
            errorLine = error.localizedDescription
            loadRows()
        }
    }

    /// Owner-initiated removal. Unknown ids would throw (store contract), but
    /// ids here come straight from the listed rows, so the catch path exists
    /// for the honest store-read races — shown verbatim either way.
    @MainActor
    private func removePin(row: ManualPinRow) {
        do {
            try store.remove(id: row.pin.id)
            loadRows()
            onChange?()
        } catch {
            errorLine = error.localizedDescription
            loadRows()
        }
    }
}
