// ProxySettingsSheet.swift — glue-wiring lane: the proxy settings sheet.
// Read-only DISPLAY of the live system proxy picture + CONFIGURATION of the
// app's own proxy settings (the two things the proxy lane's posture allows:
// "read-only display + configuration").
//
// CONSENT BOUNDARY (restated at the wiring site): this sheet edits only
// AppUpdater's own proxy_settings.json (via ProxySettingsStore's atomic
// write) and AppUpdater's own keychain items (via the engine's ProxyKeychain
// seam — passwords NEVER land in the settings JSON). The SYSTEM side is
// strictly read-only: the monitor only reads SCDynamicStore state, and this
// sheet never writes system proxy configuration, never spawns a probe
// connection, and never mutates anything outside the app's own stores.
//
// LIFECYCLE (GluePanels.swift header contract): the system-proxy monitor is
// started and stopped BY THIS SHEET (on appear / on disappear) — no
// launch-time SC store, nothing outlives the sheet. On a store-creation
// failure the sheet shows the honest note instead of a fake empty snapshot.

import SwiftUI
import AppUpdaterCore

struct ProxySettingsSheet: View {
    let onClose: () -> Void
    @EnvironmentObject private var glue: GluePanelsModel

    /// The sheet's working draft (loaded from the store on appear; saved via
    /// the glue model, which adopts it into the engines' session).
    @State private var draft = ProxySettings()
    @State private var httpPassword = ""
    @State private var httpsPassword = ""
    @State private var socks5Password = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    adoptionCard
                    draftEditor
                    credentialsCard
                    monitorCard
                    envCard
                }
                .padding(14)
            }
            Divider()
            HStack {
                if let error = glue.proxyError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Close") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 500, minHeight: 460)
        .task {
            await glue.loadProxySettings()
            if !loaded {
                draft = glue.proxySession.settings
                loaded = true
            }
        }
        .onAppear {
            glue.startProxyMonitor()
        }
        .onDisappear {
            glue.stopProxyMonitor()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Proxy", systemImage: "network.badge.shield.half.filled")
                .font(.title3.weight(.bold))
            Text("Configure how AppUpdater's own update checks reach their sources. Your system settings are only ever READ.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    // MARK: adoption state (the engines' real session)

    @ViewBuilder
    private var adoptionCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Session in force", systemImage: "arrow.triangle.swap")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let note = glue.proxySession.adoptionNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            } else {
                Text("Adopting the persisted settings…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let pac = glue.proxySession.pacNote {
                Text(pac)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let note = glue.proxySaveNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary))
    }

    // MARK: draft editor

    @ViewBuilder
    private var draftEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("AppUpdater proxy settings", systemImage: "slider.horizontal.3")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Mode", selection: Binding(
                get: { draft.mode },
                set: { draft.mode = $0 }
            )) {
                Text("Follow the system configuration").tag(ProxyMode.system)
                Text("No proxy (explicit)").tag(ProxyMode.none)
                Text("Manual override").tag(ProxyMode.manual)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            modeCaption

            if draft.mode == .manual {
                entryEditor("HTTP", entry: Binding(
                    get: { draft.http }, set: { draft.http = $0 }))
                entryEditor("HTTPS", entry: Binding(
                    get: { draft.https }, set: { draft.https = $0 }))
                entryEditor("SOCKS5", entry: Binding(
                    get: { draft.socks5 }, set: { draft.socks5 = $0 }))
            }

            HStack {
                Button {
                    Task {
                        // A successful save is adopted by the glue model
                        // itself (one adoption path — see GluePanelsModel).
                        _ = await glue.saveProxySettings(draft)
                    }
                } label: {
                    Label("Save & Apply", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Reload from disk") {
                    Task {
                        await glue.loadProxySettings()
                        draft = glue.proxySession.settings
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary))
    }

    private var modeCaption: some View {
        Text(modeExplanation)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    private var modeExplanation: String {
        switch draft.mode {
        case .system:
            return "No override dictionary is applied — URLSession follows the system configuration, including system PAC handling natively. \(ProxyConfiguration.pacLimitationNote)."
        case .none:
            return "An explicit empty override: AppUpdater's checks use no proxy at all."
        case .manual:
            return "Per-protocol overrides become the nine documented connection-proxy dictionary keys. A protocol is proxied only when you configure it here. Passwords live in the Keychain — never in proxy_settings.json."
        }
    }

    /// An always-present binding over the optional entry (used only while the
    /// entry is non-nil on screen; the get-fallback is unreachable UI state).
    private static func entryValue(
        _ entry: Binding<ProxyProtocolEntry?>
    ) -> Binding<ProxyProtocolEntry> {
        Binding(
            get: { entry.wrappedValue ?? ProxyProtocolEntry(host: "", port: 8080) },
            set: { entry.wrappedValue = $0 })
    }

    /// One protocol's manual entry editor. Enabling authRequired declares the
    /// credential must exist in the Keychain (entered below) — the flag never
    /// carries the password itself.
    @ViewBuilder
    private func entryEditor(_ title: String, entry: Binding<ProxyProtocolEntry?>) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(title, isOn: Binding(
                get: { entry.wrappedValue != nil },
                set: { enabled in
                    entry.wrappedValue = enabled
                        ? (entry.wrappedValue ?? ProxyProtocolEntry(host: "", port: 8080))
                        : nil
                }))
                .font(.caption.weight(.medium))
                .fixedSize()
            if entry.wrappedValue != nil {
                let value = Self.entryValue(entry)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField("host", text: Binding(
                            get: { value.wrappedValue.host },
                            set: { value.wrappedValue.host = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 170)
                        TextField("port", text: Binding(
                            get: { String(value.wrappedValue.port) },
                            set: { text in
                                if let port = Int(text.trimmingCharacters(in: .whitespaces)),
                                   (1...65_535).contains(port) {
                                    value.wrappedValue.port = port
                                }
                            }))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 64)
                    }
                    Toggle("Authentication required (password stored in the Keychain)", isOn: Binding(
                        get: { value.wrappedValue.authRequired },
                        set: { value.wrappedValue.authRequired = $0 }))
                        .font(.caption2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: keychain credentials

    @ViewBuilder
    private var credentialsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Keychain credentials", systemImage: "key.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Passwords are stored per protocol under the documented service \(ProxyKeychain.service). They never appear in proxy_settings.json. Clearing a field's password deletes the item.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            credentialRow("HTTP", .http, $httpPassword)
            credentialRow("HTTPS", .https, $httpsPassword)
            credentialRow("SOCKS5", .socks5, $socks5Password)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary))
    }

    @ViewBuilder
    private func credentialRow(
        _ title: String, _ protocolName: ProxyProtocolName, _ password: Binding<String>
    ) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).frame(width: 52, alignment: .leading)
            SecureField("password", text: password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
            Button("Store") {
                glue.saveProxyPassword(password.wrappedValue, for: protocolName)
                password.wrappedValue = ""
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(password.wrappedValue.isEmpty)
            credentialChip(glue.proxyCredentials[protocolName])
            Spacer(minLength: 0)
        }
    }

    /// The honest "auth configured" probe (never a claim the password is
    /// VALID — ProxyKeychain's own contract, surfaced verbatim).
    private func credentialChip(_ configured: Bool?) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(configured == true ? .green : .gray)
                .frame(width: 7, height: 7)
            Text(configured == true ? "stored" : "none")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: live system picture (read-only)

    @ViewBuilder
    private var monitorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("System proxy picture (read-only)", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if glue.proxyMonitorRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Monitoring system proxy keys while this sheet is open…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let note = glue.proxyMonitorNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let snapshot = glue.proxyMonitorSnapshot {
                Text(snapshot.detectedDescription)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                if !snapshot.exclusions.isEmpty {
                    Text("Bypass list: \(snapshot.exclusions.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !snapshot.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(snapshot.notes, id: \.self) { note in
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary))
    }

    // MARK: proxy environment variables (read-only, report-only)

    /// The documented proxy environment variables as the process sees them —
    /// a pure env read (ProxyEnvironment's own posture: "reading env is
    /// introspection, not traffic"). REPORT-ONLY: nothing here acts on the
    /// variables or decides precedence between env, system, and manual
    /// settings — the engine's header reserves that decision for the
    /// coordinator, and this sheet has no such authority.
    @ViewBuilder
    private var envCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Proxy environment variables (read-only)", systemImage: "terminal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let passthrough = glue.proxyEnvPassthrough {
                if passthrough.http == nil && passthrough.https == nil && passthrough.socks5 == nil {
                    Text("None of the documented proxy variables are set in this process's environment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    envLine("HTTP", passthrough.http)
                    envLine("HTTPS", passthrough.https)
                    envLine("SOCKS5 (ALL_PROXY)", passthrough.socks5)
                }
                if !passthrough.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(passthrough.notes, id: \.self) { note in
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            } else {
                Text("Reading the environment…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text("Report-only: no precedence decision between these variables, the system configuration, and your settings above is acted on anywhere in the app.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary))
    }

    @ViewBuilder
    private func envLine(_ label: String, _ entry: ProxyProtocolEntry?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            if let entry {
                Text("\(entry.host):\(entry.port)\(entry.authRequired ? " (auth required)" : "")")
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            } else {
                Text("not set").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }
}
