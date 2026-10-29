// BrewPinsSheet.swift — glue-wiring lane: the brew pins + doctor sheet.
// Surfaces BrewPrefixResolver / BrewPinsParser / BrewPinWatcher /
// BrewDoctorCheck / BrewFormulaIndexStore as read-only display.
//
// CONSENT BOUNDARY (restated at the wiring site): pins are READ and WATCHED.
// The watcher stats two files' mtimes and re-reads + re-parses them on change
// — it never runs brew, mas, or any install/update. `brew doctor` is the
// engine-sanctioned read-only probe (no sudo; the engine applies its own
// hardening environment). Command execution stays with the owner, always.
//
// LIFECYCLE (GluePanels.swift header contract): the mtime watcher is started
// and stopped BY THIS SHEET (on appear / on disappear) — no launch-time
// watcher, nothing outlives the sheet. The formula whole-index load is
// BUTTON-INITIATED (one ETag-cached GET of the public formulae.brew.sh
// catalog) — no launch-time or sheet-open network.

import SwiftUI
import AppUpdaterCore

struct BrewPinsSheet: View {
    let onClose: () -> Void
    @EnvironmentObject private var glue: GluePanelsModel

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    consentCaption
                    prefixCard
                    pinsCard
                    watcherCard
                    doctorCard
                    formulaIndexCard
                }
                .padding(14)
            }
            Divider()
            HStack {
                Spacer()
                Button("Close") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 470, minHeight: 420)
        .task {
            await glue.refreshBrewPins()
        }
        .onDisappear {
            Task { await glue.setBrewWatcherRunning(false) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Homebrew Pins", systemImage: "pin.square")
                .font(.title3.weight(.bold))
            Text("What the owner pinned with `brew pin` / `brew unpin` — read-only display.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var consentCaption: some View {
        Label("Read-only: pins are read and watched. AppUpdater never runs brew, mas, or any installer — commands stay yours.",
              systemImage: "lock.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.08)))
    }

    // MARK: prefix

    @ViewBuilder
    private var prefixCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Prefix", systemImage: "folder")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let prefix = glue.brewPrefixURL {
                Text(prefix.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } else if let note = glue.brewPrefixNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Not resolved yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary))
    }

    // MARK: pins

    @ViewBuilder
    private var pinsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Pinned formulae & casks", systemImage: "pin")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await glue.refreshBrewPins() }
                } label: {
                    Label("Re-read", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if let pins = glue.brewPins {
                if pins.isEmpty {
                    Text("No pins recorded — every install is free to move.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    pinList("Formulae", sorted(pins.formulae))
                    pinList("Casks", sorted(pins.casks))
                }
            } else if glue.brewPrefixURL == nil {
                Text("Pins unknown — the prefix could not be resolved (never guessed).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Reading pinned files…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if !glue.brewNotes.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(glue.brewNotes, id: \.self) { note in
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary))
    }

    private func pinList(_ title: String, _ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(title) (\(names.count))")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            FlowOrList(names: names)
        }
    }

    /// A wrapped capsule row of pinned names (or the honest empty line).
    private struct FlowOrList: View {
        let names: [String]

        var body: some View {
            if names.isEmpty {
                Text("none").font(.caption2).foregroundStyle(.tertiary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)],
                    alignment: .leading, spacing: 4) {
                    ForEach(names, id: \.self) { name in
                        Text(name)
                            .font(.caption.monospaced())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.blue.opacity(0.10)))
                            .lineLimit(1)
                            .help(name)
                    }
                }
            }
        }
    }

    private func sorted(_ set: Set<String>) -> [String] {
        set.sorted()
    }

    // MARK: watcher

    @ViewBuilder
    private var watcherCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Pins watcher", systemImage: "eye")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Toggle("Watch the pinned files while this sheet is open", isOn: Binding(
                get: { glue.brewWatcherRunning },
                set: { running in Task { await glue.setBrewWatcherRunning(running) } }))
            Text("Stats the two pinned files' modification times every 2s and re-reads them on change. Read-only — the watcher never runs brew. It lives only while this sheet is open.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let observation = glue.brewLastObservation {
                Text("Last observation \(observation.observedAt.formatted(date: .omitted, time: .standard))"
                    + " — formulae file \(observation.formulaeMtime.map { $0.formatted(date: .omitted, time: .standard) } ?? "absent")"
                    + ", casks file \(observation.casksMtime.map { $0.formatted(date: .omitted, time: .standard) } ?? "absent")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary))
    }

    // MARK: doctor

    @ViewBuilder
    private var doctorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("`brew doctor`", systemImage: "stethoscope")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await glue.runBrewDoctor() }
                } label: {
                    Label(glue.brewDoctor == nil ? "Run brew doctor" : "Re-run brew doctor",
                          systemImage: "play")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(glue.brewDoctorInFlight)
            }
            if glue.brewDoctorInFlight {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Running the read-only doctor probe…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let result = glue.brewDoctor {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Self.doctorColor(result.verdict))
                        .frame(width: 8, height: 8)
                    Text(Self.doctorLabel(result.verdict))
                        .font(.caption.weight(.semibold))
                    if let exit = result.exitStatus {
                        Text("exit \(exit)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                if let note = result.note {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
                if !result.stdout.isEmpty || !result.stderr.isEmpty {
                    DisclosureGroup("Verbatim output") {
                        VStack(alignment: .leading, spacing: 4) {
                            if !result.stdout.isEmpty {
                                Text(result.stdout)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if !result.stderr.isEmpty {
                                Text(result.stderr)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.orange)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption2.weight(.medium))
                }
            }
            Text("The probe runs `brew doctor` with the engine's hardening environment and no sudo. Nothing is fixed automatically — the output is yours to act on.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary))
    }

    private static func doctorColor(_ verdict: BrewDoctorResult.Verdict) -> Color {
        switch verdict {
        case .clean: return .green
        case .issues: return .orange
        case .brewMissing: return .red
        }
    }

    private static func doctorLabel(_ verdict: BrewDoctorResult.Verdict) -> String {
        switch verdict {
        case .clean: return "clean — ready to brew"
        case .issues: return "issues reported (verbatim output below)"
        case .brewMissing: return "brew could not be run (missing or not spawnable)"
        }
    }

    // MARK: formula whole-index (BrewFormulaIndexStore)

    /// The brew FORMULA whole-index card (glue-wiring): the engine's own
    /// ETag-cached GET of the public formulae.brew.sh catalog. BUTTON-ONLY —
    /// no load happens on sheet open or anywhere at launch (no surprise
    /// network; the cache lives in the shared Application Support home). Read
    /// -only data plane: brew is never executed, nothing is installed.
    @ViewBuilder
    private var formulaIndexCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Formula index", systemImage: "books.vertical")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await glue.loadBrewFormulaIndex() }
                } label: {
                    Label(
                        glue.brewIndexLoaded == nil
                            ? "Load formula index"
                            : "Re-validate formula index",
                        systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(glue.brewIndexInFlight)
            }
            if glue.brewIndexInFlight {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Fetching / revalidating the public formula catalog (ETag-cached)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let loaded = glue.brewIndexLoaded {
                HStack(spacing: 6) {
                    Circle()
                        .fill(loaded ? .green : .orange)
                        .frame(width: 8, height: 8)
                    Text(loaded ? "loaded" : "load failed (honest data below)")
                        .font(.caption.weight(.semibold))
                    if let count = glue.brewIndexRecordCount {
                        Text("\(count) formulae")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                if let lastError = glue.brewIndexLastError {
                    Text(lastError)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            } else if !glue.brewIndexInFlight {
                Text("Not loaded yet — the load is button-initiated (one cached GET of formulae.brew.sh/api/formula.json; nothing runs at launch or on sheet open).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text("The engine's own read-only data plane: it only ever GETs the public JSON catalog and caches it in Application Support. It never runs brew and never installs anything.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary))
    }
}
