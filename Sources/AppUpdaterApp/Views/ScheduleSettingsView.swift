import SwiftUI
import AppUpdaterCore

/// The schedule pane (window sheet): the SchedulePolicy editor + the honest
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
        VStack(alignment: .leading, spacing: 12) {
            Text("Automatic Check Schedule").font(.headline)

            Picker("Interval", selection: $draftMinutes) {
                ForEach(Self.minuteChoices, id: \.minutes) { choice in
                    Text(choice.label).tag(choice.minutes)
                }
            }
            Toggle("Skip while on battery power", isOn: $draftSkipOnBattery)
            Toggle("Catch up a missed check on wake", isOn: $draftCatchUp)

            Divider()
            ForEach(appState.menuData.scheduleSection, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let failure = appState.scheduleError {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Text("Automatic checks surface updates only — nothing is ever applied by itself (the owner-run CLI boundary).")
                .font(.caption2)
                .foregroundStyle(.secondary)

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
            }
        }
        .padding(18)
        .frame(width: 400)
        .onAppear(perform: loadDraft)
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
