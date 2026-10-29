// ProxySession.swift — glue-wiring lane: THE URLSession adoption point the
// proxy lane's read-only posture anticipated ("the coordinator later applies
// this configuration to the app's URLSession(s)" — ProxyConfiguration.swift
// header). The persisted ProxySettings are loaded and turned into a real
// URLSession through the engine's documented dictionary bridge
// (`ProxyConfiguration.connectionProxyDictionary(for:)`); the engines' network
// sources are then constructed with ``ProxySessionController/session`` at
// their construction sites (AppState + the CLI).
//
// CONSENT BOUNDARY (restated at the wiring site): nothing here opens a
// connection, probes a proxy, or touches SYSTEM proxy state. It builds an
// app-local URLSessionConfiguration — that is all "adopting" means. Settings
// persistence stays with ProxySettingsStore (via GluePanelsModel's proxy
// sheet); keychain credentials stay with ProxyKeychain; the system side stays
// read-only in SystemProxyMonitor. No new network path is introduced here —
// the session it builds is the same session the sources already used,
// configured instead of default.
//
// MODE SEMANTICS (ProxyConfiguration's documented contract, surfaced 1:1):
//   .system → nil dictionary → URLSession default system behavior (which
//             includes system PAC handling natively). The session object is
//             still a dedicated configuration so the later swap is uniform;
//             semantically identical to .shared for this mode.
//   .none   → empty dictionary → explicit no-proxy session.
//   .manual → the nine documented keys; invalid settings THROW with the
//             documented "Invalid proxy configuration" reason — which is
//             surfaced verbatim and NOT applied (the previous session stays;
//             never a half-configured session, never a swallowed failure).
//
// PAC: in .system mode the engine's verbatim limitation note
// (`ProxyConfiguration.pacLimitationNote`) is surfaced on
// ``adoptionNote``'s companion field so no surface claims PAC evaluation.
//
// SWAP DISCIPLINE: sessions are replaced, not mutated. A replaced session's
// outstanding work is finished gracefully (`finishTasksAndInvalidate`);
// `URLSession.shared` itself is NEVER invalidated (process-wide object).
// Sources read ``session`` at CONSTRUCTION time — the next check pass picks
// up the newly adopted session; a pass already in flight keeps the session
// it was constructed with (honest, documented race semantics).

import Foundation
import SwiftUI
import AppUpdaterCore

@MainActor
final class ProxySessionController: ObservableObject {

    /// The settings currently in force (loaded from proxy_settings.json at
    /// construction; replaced by adoption). Published so the proxy sheet can
    /// mirror the session's truth, not just its own draft.
    @Published private(set) var settings: ProxySettings = ProxySettings()

    /// The honest adoption outcome (nil = nothing to report yet). Either the
    /// applied-mode description, or the verbatim failure reason with the
    /// explicit statement that the previous session stayed in force.
    @Published private(set) var adoptionNote: String?

    /// The engine's verbatim PAC limitation, surfaced when the applied
    /// configuration is the .system path (where system PAC handling applies
    /// natively). nil otherwise.
    @Published private(set) var pacNote: String?

    /// The session the engines' sources are constructed with. Starts as
    /// `.shared` — for the default `.system` settings that is byte-for-byte
    /// the same behavior (no override dictionary) — until the persisted
    /// settings load and are adopted below.
    private(set) var session: URLSession = .shared

    /// The previous non-shared session (invalidated after a swap; nil while
    /// the controller still runs on `.shared` itself).
    private var previousSession: URLSession?

    init() {
        // The controller owns its own kick-off so the AppState wiring site
        // stays a single line. Until the async load completes, `.shared`
        // (system behavior) is in force — the honest default.
        Task { await self.reloadFromStore() }
    }

    /// Loads the persisted settings and adopts them. A load failure surfaces
    /// verbatim and keeps the current session (never a fake success).
    func reloadFromStore() async {
        do {
            let loaded = try await ProxySettingsStore().load()
            adopt(loaded)
        } catch {
            adoptionNote =
                "proxy settings load failed — \(error); the session keeps its previous configuration"
        }
    }

    /// Adopts `newSettings` into ``session`` via the engine's dictionary
    /// bridge. Invalid settings are NOT applied: the documented
    /// "Invalid proxy configuration" reason is surfaced verbatim and the
    /// previous session stays in force.
    func adopt(_ newSettings: ProxySettings) {
        settings = newSettings
        do {
            let dictionary = try ProxyConfiguration.connectionProxyDictionary(for: newSettings)
            let configuration = URLSessionConfiguration.default
            configuration.connectionProxyDictionary = dictionary
            let adopted = URLSession(configuration: configuration)
            swapIn(adopted)
            pacNote = newSettings.mode == .system ? ProxyConfiguration.pacLimitationNote : nil
            adoptionNote = Self.description(for: newSettings)
        } catch {
            pacNote = nil
            adoptionNote = "\(error) — not applied; the session keeps its previous configuration"
        }
    }

    /// Swaps the live session in and finishes the replaced one gracefully.
    /// `URLSession.shared` is never invalidated (it is process-wide).
    private func swapIn(_ adopted: URLSession) {
        if let previous = previousSession {
            previous.finishTasksAndInvalidate()
        }
        if session !== URLSession.shared {
            previousSession = session
        }
        session = adopted
    }

    /// The honest one-line description of what a mode's adoption means
    /// (mirrors ProxyConfiguration's documented semantics; used verbatim in
    /// ``adoptionNote``).
    private static func description(for settings: ProxySettings) -> String {
        switch settings.mode {
        case .system:
            return "session follows the system proxy configuration (no override dictionary)"
        case .none:
            return "session configured with an explicit empty override — no proxy"
        case .manual:
            var parts: [String] = []
            if let http = settings.http { parts.append("http \(http.host):\(http.port)") }
            if let https = settings.https { parts.append("https \(https.host):\(https.port)") }
            if let socks5 = settings.socks5 {
                parts.append("socks5 \(socks5.host):\(socks5.port)")
            }
            return "session overrides applied: " + parts.joined(separator: ", ")
        }
    }
}
