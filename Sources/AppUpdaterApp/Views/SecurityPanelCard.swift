// SecurityPanelCard.swift — glue-wiring lane: the detail inspector's security
// panel card. Surfaces the tested-but-unwired SecurityPanel engines
// (SecInspector / IOSAppOnMac / SetappSupport / Storefront) as READ-ONLY
// display for the selected app, in MainWindowView's shared visual language.
//
// CONSENT BOUNDARY (restated at the wiring site): everything here is a
// read-only probe — codesign/spctl signature display + strict verification,
// spctl Gatekeeper assessment, entitlement reads, bundle-marker reads, one
// pkgutil query, one StoreKit storefront read. Nothing is modified, nothing
// is installed, no MAS lookup is re-routed (lookups stay pinned to `us` —
// the storefront verdict is DISPLAY data only, and it is stated so verbatim
// in the card).
//
// INTERACTION SHAPE: the two process-spawning probes (signature inspection,
// bundle classification) run only on an explicit button press (user-initiated
// consent posture — no per-selection probe fan-out); the pure Setapp path
// classification runs inline (sync, no processes); the storefront verdict is
// loaded once per session.

import SwiftUI
import AppUpdaterCore

/// The detail-inspector card. Bound through GluePanelsModel (the app-scoped
/// glue model — see GluePanels.swift for the consent + lifecycle headers).
struct SecurityPanelSection: View {
    let row: AppRow
    @EnvironmentObject private var glue: GluePanelsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Security", systemImage: "checkmark.shield")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Read-only probes only — nothing on this card modifies the app.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            inspectRow
            if let report = glue.securityReports[row.app.path] {
                SecReportSummary(report: report)
            }
            classificationRow
            candidateRow
            setappRow
            storefrontRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: row.app.path) {
            // Storefront is a once-per-session machine verdict (StoreKit
            // probe, no network). The classifications are user-initiated
            // (buttons above); only the free, pure one runs inline here.
            await glue.loadStorefront()
        }
    }

    // MARK: signature / Gatekeeper inspection (explicit, user-initiated)

    @ViewBuilder
    private var inspectRow: some View {
        HStack(spacing: 8) {
            if glue.securityInFlight.contains(row.app.path) {
                ProgressView().controlSize(.small)
                Text("Running codesign / spctl probes…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    Task { await glue.inspectSecurity(appPath: row.app.path) }
                } label: {
                    Label(
                        glue.securityReports[row.app.path] == nil
                            ? "Inspect Signature & Gatekeeper"
                            : "Re-run Inspection",
                        systemImage: "shield.lefthalf.filled")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: iOS-app-on-Mac + Setapp classification

    @ViewBuilder
    private var classificationRow: some View {
        HStack(spacing: 8) {
            if glue.iosOnMacInFlight.contains(row.app.path) {
                ProgressView().controlSize(.small)
                Text("Reading bundle receipts…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let info = glue.iosOnMacReports[row.app.path] {
                IOSOnMacSummary(info: info)
            } else {
                Button {
                    Task { await glue.classifyIOSOnMac(bundlePath: row.app.path) }
                } label: {
                    Label("Classify Bundle Receipts", systemImage: "shippingbox")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Read-only check for iOS-app-on-Mac wrapper markers (iTunesMetadata / INSTALL_RECEIPT.json)")
            }
        }
    }

    /// The deep artifact-signal filter (glue-wiring, candidates lane): the
    /// three read-only detectors over the SELECTED app's deployed bundle —
    /// user-initiated (button), file reads only. Display data; never a gate.
    @ViewBuilder
    private var candidateRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if glue.candidateInFlight.contains(row.app.path) {
                    ProgressView().controlSize(.small)
                    Text("Reading bundle files…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        Task { await glue.filterCandidate(appPath: row.app.path) }
                    } label: {
                        Label(
                            glue.candidateReports[row.app.path] == nil
                                ? "Check Artifact Signals"
                                : "Re-check Artifact Signals",
                            systemImage: "shippingbox.and.arrow.backward")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Read-only deep signals: installer-bundle name, InstallBuilder markers, Electron wrong-arch binary")
                }
                Spacer(minLength: 0)
            }
            if let report = glue.candidateReports[row.app.path] {
                CandidateFilterSummary(report: report)
            }
        }
    }

    /// SetappSupport is pure + synchronous (documented root path check) —
    /// computed inline, no model state, no processes.
    @ViewBuilder
    private var setappRow: some View {
        let info = SetappSupport.classify(bundlePath: row.app.path)
        switch info.verdict {
        case .member:
            VStack(alignment: .leading, spacing: 2) {
                Label("Setapp member app", systemImage: "app.dashed")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.indigo)
                Text(info.note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .unknown:
            Label(info.note, systemImage: "questionmark.diamond")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .notMember:
            EmptyView()
        }
    }

    /// The machine's storefront verdict — display data only; MAS lookups stay
    /// pinned to `us` (stated verbatim in the caption, never re-routed).
    @ViewBuilder
    private var storefrontRow: some View {
        if let storefront = glue.storefront {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Label("Storefront", systemImage: "globe")
                        .font(.caption.weight(.medium))
                    Text(storefrontLabel(storefront))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(storefrontColor(storefront).opacity(0.14)))
                        .foregroundStyle(storefrontColor(storefront))
                }
                Text(storefront.note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("Display data only: MAS lookups stay pinned to the documented `us` catalog — this verdict never re-routes a lookup.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func storefrontLabel(_ storefront: StorefrontInfo) -> String {
        switch storefront.status {
        case .eligible: return "eligible (\(storefront.countryCode ?? "?"))"
        case .excluded: return "excluded (\(storefront.countryCode ?? "?"))"
        case .unknown: return "unknown"
        }
    }

    private func storefrontColor(_ storefront: StorefrontInfo) -> Color {
        switch storefront.status {
        case .eligible: return .green
        case .excluded: return .orange
        case .unknown: return .gray
        }
    }
}

// MARK: - Report renderers (honest three-way states, verbatim evidence)

/// Compact SecReport summary for the inspector column. Three-way fields are
/// rendered three-way (nil is "unjudged", never a fake false); tool-derived
/// strings stay verbatim (diffable, lies stay visible as lies).
private struct SecReportSummary: View {
    let report: SecReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                threeWay("Signature", report.signaturePresent)
                threeWay("Verification", report.codesignValid)
                threeWay("Hardened runtime", report.hardenedRuntime)
            }
            HStack(spacing: 12) {
                threeWay("Sandboxed", report.sandboxed)
                threeWay("Ad-hoc", report.isAdHoc)
                gatekeeperChip
            }
            if let source = report.gatekeeperSource {
                verbatim("Gatekeeper source", source)
            }
            if let origin = report.gatekeeperOrigin {
                verbatim("Gatekeeper origin", origin)
            }
            if let team = report.teamIdentifier {
                verbatim("Team ID", team)
            }
            if let ticket = report.notarizationTicket {
                verbatim("Notarization ticket", ticket)
            }
            if let cdHash = report.cdHash {
                verbatim("CDHash", cdHash)
            }
            if let timestamp = report.timestamp {
                verbatim("Signed", timestamp)
            }
            if !report.entitlementKeys.isEmpty {
                verbatim("Entitlements", "\(report.entitlementKeys.count) keys")
            }
            if !report.signatureAuthorities.isEmpty {
                verbatim("Signed by", report.signatureAuthorities[0])
            }
            notesDisclosure
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary))
    }

    private var gatekeeperChip: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Self.gatekeeperColor(report.gatekeeperAssessment))
                .frame(width: 7, height: 7)
            Text("Gatekeeper: \(report.gatekeeperAssessment.rawValue)")
                .font(.caption2.weight(.medium))
        }
    }

    private static func gatekeeperColor(_ assessment: SecReport.GatekeeperAssessment) -> Color {
        switch assessment {
        case .accepted: return .green
        case .rejected: return .red
        case .unknown: return .gray
        }
    }

    /// A Bool? rendered as its honest three-way state — nil is "unjudged",
    /// never collapsed into a boolean (SecReport's structural honesty rule).
    private func threeWay(_ label: String, _ value: Bool?) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(value == nil ? .gray : (value == true ? .green : .red))
                .frame(width: 7, height: 7)
            Text("\(label): \(value == nil ? "unjudged" : (value == true ? "yes" : "no"))")
                .font(.caption2.weight(.medium))
        }
    }

    private func verbatim(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    /// The full honesty trail: every probe outcome a consumer must see
    /// (spawn failures, nonzero exits with verbatim diagnostics, …) —
    /// collapsed by default, never omitted.
    @ViewBuilder
    private var notesDisclosure: some View {
        if !report.notes.isEmpty {
            DisclosureGroup("\(report.notes.count) probe note\(report.notes.count == 1 ? "" : "s")") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(report.notes.enumerated()), id: \.offset) { pair in
                        Text(pair.element)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption2.weight(.medium))
        }
    }
}

/// The deep candidate-filter receipt (glue-wiring, candidates lane): the
/// three per-detector verdicts + the combined strongest verdict, rendered in
/// the card's honest three-way style. DISPLAY data — the filter never
/// overrides the security floor (its receipt says so itself, verbatim in
/// the overall notes).
private struct CandidateFilterSummary: View {
    let report: CandidateFilterReport

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                detectorChip("Overall", report.overall)
                detectorChip("Installer-bundle", report.installerBundle)
            }
            HStack(spacing: 12) {
                detectorChip("InstallBuilder", report.installBuilder)
                detectorChip("Electron arch", report.electronWrongArch)
            }
            if let reason = report.overall.reason, !reason.isEmpty {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            DisclosureGroup("Detector notes") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(report.overall.notes.enumerated()), id: \.offset) { pair in
                        Text(pair.element)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption2.weight(.medium))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary))
    }

    /// One detector's outcome chip — one outcome, one color, one word
    /// (reject red / unknown orange / accept green / not-applicable gray).
    private func detectorChip(_ label: String, _ verdict: CandidateVerdict) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Self.outcomeColor(verdict.outcome))
                .frame(width: 7, height: 7)
            Text("\(label): \(verdict.outcome.rawValue)")
                .font(.caption2.weight(.medium))
        }
    }

    private static func outcomeColor(_ outcome: CandidateFilterOutcome) -> Color {
        switch outcome {
        case .reject: return .red
        case .unknown: return .orange
        case .accept: return .green
        case .notApplicable: return .gray
        }
    }
}

/// The iOS-app-on-Mac classification summary (verdict + verbatim evidence).
private struct IOSOnMacSummary: View {
    let info: IOSAppOnMacInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Label(Self.verdictLabel(info.verdict), systemImage: Self.verdictSymbol(info.verdict))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Self.verdictColor(info.verdict))
            }
            Text(info.note)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(info.evidence, id: \.self) { line in
                Text(line)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private static func verdictLabel(_ verdict: IOSAppOnMacInfo.Verdict) -> String {
        switch verdict {
        case .iosAppOnMac: return "iOS app on Mac (wrapper receipts present)"
        case .macAppStoreApp: return "Mac App Store app (macOS receipts only)"
        case .notIOSAppOnMac: return "No iOS-on-Mac markers"
        case .unknown: return "Unreadable bundle — unknown"
        }
    }

    private static func verdictSymbol(_ verdict: IOSAppOnMacInfo.Verdict) -> String {
        switch verdict {
        case .iosAppOnMac: return "iphone"
        case .macAppStoreApp: return "app.badge.fill"
        case .notIOSAppOnMac: return "macwindow"
        case .unknown: return "questionmark.diamond"
        }
    }

    private static func verdictColor(_ verdict: IOSAppOnMacInfo.Verdict) -> Color {
        switch verdict {
        case .iosAppOnMac: return .indigo
        case .macAppStoreApp: return .orange
        case .notIOSAppOnMac: return .secondary
        case .unknown: return .gray
        }
    }
}
