import SwiftUI
import AppUpdaterCore

/// The schedule pane (window sheet): the SchedulePolicy editor + honest
/// current-state lines. Apply clamps → persists → restarts the engine
/// stream (policy is fixed per stream — the engine's own contract).
struct ScheduleSettingsView: View {
    let onClose: () -> Void
    @EnvironmentObject private var appState: AppState

    @State private var draftMinutes = 240
    @State private var draftSkipOnBattery = true
    @State private var draftCatchUp = true

    /// Picker choices keep the interval floor (15 min) and the explicit
    /// off state (0) honest — no value the engine would silently rewrite.
    static let minuteChoices: [(minutes: Int, label: String)] = [
        (0, "Off"),
        (15, "Every 15 minutes"),
        (30, "Every 30 minutes"),
        (60, "Hourly"),
        (120, "Every 2 hours"),
        (240, "Every 4 hours"),
        (480, "Every 8 hours"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section("Automatic Checking") {
                    Picker("Interval", selection: $draftMinutes) {
                        ForEach(Self.minuteChoices, id: \.minutes) { choice in
                            Text(choice.label).tag(choice.minutes)
                        }
                    }
                    Toggle("Skip while on battery power", isOn: $draftSkipOnBattery)
                    Toggle("Catch up a missed check on wake", isOn: $draftCatchUp)
                }

                Section("Notifications") {
                    Toggle("Notify about newly discovered updates", isOn: Binding(
                        get: { appState.notificationsEnabled },
                        set: { appState.setNotificationsEnabled($0) }))
                    if let state = appState.notificationsState {
                        Label(state, systemImage: "bell.slash")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                    Text("When exactly one app newly pends, its notification carries actions: "
                        + "Open AppUpdater and Stage Install Command (copies the CLI command to "
                        + "the clipboard — nothing runs). Other fires stay quiet summaries.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("Current state") {
                    ForEach(appState.menuData.scheduleSection, id: \.self) { line in
                        Label {
                            Text(line).font(.callout)
                        } icon: {
                            Image(systemName: "clock").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let failure = appState.scheduleError {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                Section {
                    Text("Automatic checks surface updates only — nothing is ever applied by itself (the owner-run CLI boundary). Scheduled checks notify only about newly pending apps; the first check after launch sets a quiet baseline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                Button("Apply") {
                    Task {
                        await appState.applyPolicy(
                            SchedulePolicy(
                                intervalMinutes: draftMinutes,
                                skipOnBattery: draftSkipOnBattery,
                                onWakeCatchUp: draftCatchUp))
                    }
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 440)
        .onAppear(perform: loadDraft)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.checkmark")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Schedule & Notifications").font(.headline)
                Text("How often AppUpdater looks for updates on its own")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
    }

    /// Snaps the loaded interval onto the picker honestly: an off-policy
    /// value maps to Off (≤ 0); an arbitrary ≥ 15 value snaps to the
    /// nearest choice (the APPLY path clamps again, so no silent rewrite).
    private func loadDraft() {
        let policy = appState.schedule.policy
        let loaded = policy.intervalMinutes
        if loaded <= 0 {
            draftMinutes = 0
        } else if let exact = Self.minuteChoices.first(where: { $0.minutes == loaded }) {
            draftMinutes = exact.minutes
        } else {
            draftMinutes = Self.minuteChoices
                .dropFirst()   // exclude the "Off" row from nearest-matching
                .min(by: { abs($0.minutes - loaded) < abs($1.minutes - loaded) })?
                .minutes ?? 240
        }
        draftSkipOnBattery = policy.skipOnBattery
        draftCatchUp = policy.onWakeCatchUp
    }
}
