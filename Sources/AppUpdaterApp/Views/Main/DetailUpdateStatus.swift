import SwiftUI
import AppUpdaterCore

/// The live/last-outcome block for the clicked update: progress, abort,
/// success receipt, staged pkg command, or refusal. Same state machine the
/// old inspector's install card rendered — only the wording and placement
/// changed (Updatest parity: "Update", never "Install").
struct DetailUpdateStatus: View {
    let row: AppRow
    @EnvironmentObject private var appState: AppState

    private var bundleID: String { row.app.bundleIdentifier }

    var body: some View {
        if appState.installInFlightBundleID == bundleID {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Updating — download → verify (HTTPS + SHA-256 + artifact check) → back up → quit → replace…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let outcome = appState.lastInstallOutcome,
                  appState.lastInstallOutcomeBundleID == bundleID,
                  let aborted = outcome.abortedStep {
            Label("Update stopped at \(aborted.rawValue) — nothing was left half-done; the receipt shows how far it got.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if let outcome = appState.lastInstallOutcome,
                  appState.lastInstallOutcomeBundleID == bundleID,
                  outcome.stagedCommand == nil {
            VStack(alignment: .leading, spacing: 3) {
                Label("Updated", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
                Text(outcome.finalInstalledShortVersion.map {
                    "\(row.app.name) is now at version \($0)."
                } ?? "Replacement complete — reopening \(row.app.name) runs the new version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if outcome.backup != nil {
                    Text("A backup of the previous version was kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if let command = appState.lastInstallCommand, appState.lastInstallBundleID == bundleID {
            VStack(alignment: .leading, spacing: 6) {
                Text("This update is a .pkg installer — run this command yourself:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        appState.typeStagedCommandInTerminal(command)
                    }
                    .font(.caption)
                    .help("Opt-in: types the same command into your terminal (you attend any password prompt)")
                }
            }
        } else if appState.lastInstallErrorBundleID == bundleID, let refusal = appState.lastInstallError {
            Label(refusal, systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
