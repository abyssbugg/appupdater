import SwiftUI
import AppKit
import AppUpdaterCore

/// Right pane. Empty state mirrors Updatest's "No Selection".
struct AppDetailPane: View {
    let row: AppRow?

    var body: some View {
        if let row {
            AppDetailContent(row: row)
                .id(row.id)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "app.dashed")
                    .font(.system(size: 44))
                    .foregroundStyle(.tertiary)
                Text("No Selection")
                    .font(.title2.weight(.semibold))
                Text("Select an app to view more details.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct AppDetailContent: View {
    let row: AppRow
    @EnvironmentObject private var appState: AppState

    var body: some View {
        // Two bands like Updatest: a lighter "act" band (header → note) over a
        // darker "read" band (What's New, Information, Security).
        ScrollView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    actionButtons
                    DetailUpdateStatus(row: row)
                    if let url = row.check?.resolved?.downloadURL, row.check?.verdict == "update" {
                        downloadBox(url)
                    }
                    if let source = row.check?.resolved?.source {
                        discoveredCard(source)
                    }
                    if row.app.isMacAppStore {
                        storeNotice
                    }
                    noteField
                }
                .padding(.horizontal, 44)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.045))
                VStack(alignment: .leading, spacing: 22) {
                    whatsNew
                    informationSection
                    SecurityPanelSection(row: row)
                }
                .padding(.horizontal, 44)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AppIconView(path: row.app.path, size: 96)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.app.name)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(2)
                versionHeadline
                if let sources = row.answeringSourcesText {
                    Text(sources)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let checked = row.app.checkedAt {
                Label(RelativeText.string(for: checked), systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Last checked \(checked.formatted(date: .abbreviated, time: .shortened))")
                    .padding(.top, 6)
            }
        }
    }

    @ViewBuilder
    private var versionHeadline: some View {
        if row.check?.verdict == "update", let info = row.check?.resolved {
            (Text("\(VersionText.installed(row.app)) → ").foregroundStyle(.secondary)
                + Text(VersionText.newest(info)).fontWeight(.semibold)
                    .foregroundStyle(row.updateAvailable ? Color.accentColor : .secondary))
                .font(.title3.monospacedDigit())
                .textSelection(.enabled)
            if row.isMutedUpdate {
                Text("Muted by one of your rules — shown for the record, not offered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(VersionText.installed(row.app))
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(verdictSentence)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var verdictSentence: String {
        switch row.check?.verdict {
        case "current":
            // A verified-install suppression is never silent (VerifiedInstallLedger).
            if let note = row.check?.verifiedInstallNote { return "Up to date — \(note)." }
            return "Up to date."
        case "failed": return "The sources could not answer — nothing is guessed. Check again later."
        case "unknown": return "No source could verify a newer version for this app."
        case nil: return "Not checked yet."
        default: return ""
        }
    }

    // MARK: buttons

    private var actionButtons: some View {
        HStack(alignment: .top, spacing: 10) {
            if row.canUpdateInApp {
                VStack(spacing: 4) {
                    Button {
                        Task { await appState.requestInstall(bundleID: row.app.bundleIdentifier) }
                    } label: {
                        Text(appState.installInFlightBundleID == row.app.bundleIdentifier
                             ? "Updating…" : "Update…")
                    }
                    .buttonStyle(CapsuleButtonStyle(large: true))
                    .disabled(appState.installInFlightBundleID != nil)
                    .help("Download → verify (HTTPS + SHA-256) → back up → replace")
                    openAppCaption
                }
            } else {
                VStack(spacing: 4) {
                    Button("Open App") { openApp() }
                        .buttonStyle(CapsuleButtonStyle(large: true))
                    Text(row.isRunning ? "Running" : " ").font(.caption2).foregroundStyle(.secondary)
                }
            }
            optionsMenu
        }
    }

    private var openAppCaption: some View {
        Button("Open App") { openApp() }
            .buttonStyle(.plain)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private func openApp() {
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: row.app.path),
            configuration: NSWorkspace.OpenConfiguration())
    }

    private var optionsMenu: some View {
        CapsuleMenu(title: "Options", large: true) {
            Toggle("Include in Automatic Checks", isOn: Binding(
                get: { row.decision.autoCheck },
                set: { enabled in
                    Task { await appState.setAutoCheck(row.app.bundleIdentifier, enabled) }
                }))
            Divider()
            if let claim = row.check?.resolved?.newestShortVersion {
                Button("Skip This Version (\(claim))") {
                    Task { await appState.list.ignoreVersion(row.app.bundleIdentifier, claim) }
                }
            }
            Button("Ignore All Updates") {
                Task { await appState.list.ignoreBundle(row.app.bundleIdentifier) }
            }
            if row.decision.ignoredBundle || row.decision.ignoredVersion || !row.decision.autoCheck {
                Button("Clear Rules") {
                    Task { await appState.removeRules(for: row.app.bundleIdentifier) }
                }
            }
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.app.path)])
            }
            Button("Copy Bundle Identifier") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.app.bundleIdentifier, forType: .string)
            }
        }
    }

    // MARK: cards

    private func downloadBox(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Link(destination: url) {
                Text(url.absoluteString)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .underline()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy download URL")
            .accessibilityLabel("Copy download URL")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.55)))
    }

    private func discoveredCard(_ source: SourceKind) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Discovered via \(SourceStyle.label(for: source))")
                    .font(.callout.weight(.semibold))
                Text(SourceStyle.discoverySentence(for: source))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = nextStepHint {
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
            }
            Spacer(minLength: 8)
            CapsuleMenu(title: "Actions") {
                if let url = row.check?.resolved?.downloadURL {
                    Button("Open Download Link") { NSWorkspace.shared.open(url) }
                    Button("Copy Download Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    Divider()
                }
                Button("Open App") { openApp() }
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.app.path)])
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    /// The second paragraph of the card: what the user can do next, true to
    /// what THIS app can do for THIS row.
    private var nextStepHint: String? {
        guard row.check?.verdict == "update" else { return nil }
        if row.canUpdateInApp {
            return "Use Update… to download, verify and replace it, or use the download link above."
        }
        if row.app.isMacAppStore { return "Open the App Store to update it." }
        return "Open the app to check for an update, or use the download link above."
    }

    /// Per-app private note (license key, reminder) — stored locally in the
    /// app's own defaults; never sent anywhere.
    private var noteField: some View {
        TextField("Add a note (license key, reminder, etc.)", text: Binding(
            get: { UserDefaults.standard.string(forKey: noteKey) ?? "" },
            set: { UserDefaults.standard.set($0.isEmpty ? nil : $0, forKey: noteKey) }),
            axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(2...5)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15)))
    }

    private var noteKey: String { "appNote." + row.app.bundleIdentifier }

    private var storeNotice: some View {
        Label("Mac App Store app — updates happen in the App Store; AppUpdater never replaces it here.",
              systemImage: "app.badge.fill")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var whatsNew: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What's New").font(.title3.weight(.semibold))
            if let notes = row.check?.resolved?.releaseNotes.map(Self.plainText), !notes.isEmpty {
                Text(notes)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No Release Notes Available").font(.callout.weight(.medium))
                Text("The developer did not provide release notes for this update source.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Release notes arrive as HTML from many feeds; show readable text only.
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(
            of: "<(br|/p|/li|/h[1-6])\\s*/?>", with: "\n",
            options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<li[^>]*>", with: "• ",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, char) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var informationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Information").font(.title3.weight(.semibold))
            infoRow("Version", VersionText.installed(row.app))
            infoRow("Bundle ID", row.app.bundleIdentifier)
            if let sources = row.answeringSourcesText {
                infoRow("Sources", sources)
            }
            if let failure = row.check?.failures.first {
                infoRow("Last Error", failure.message)
            }
            if let minimum = row.app.minimumSystemVersion {
                infoRow("Requires", "macOS \(minimum)")
            }
            if let team = row.app.signatureTeamID {
                infoRow("Team ID", team)
            }
            infoRow("Location", row.app.path)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}
