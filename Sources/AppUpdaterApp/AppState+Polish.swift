// AppState+Polish.swift — GAP #26, the polish behaviors that hang off the
// coordinator. Lane polish · exclusive app-target files of this lane
// (Sources/AppUpdaterApp/**). The stored state for all of this lives in the
// AppState class body (Swift forbids stored properties in extensions); the
// METHODS live here so the coordinator's main body does not grow.
//
// Three responsibilities, all launch-shaped and honest:
//
// 1. DOCK PRESENCE + BADGE (GAP #26 item 1). The persisted "Show in" choice
//    is applied ONCE at launch as an activation policy (the LSUIElement-aware
//    pattern: the Info.plist stays LSUIElement, menu-bar-only pins .accessory,
//    menu-bar+dock pins .regular — reliable because it happens before any
//    window exists). Toggling in settings PERSISTS ONLY and applies on the
//    NEXT launch — the relaunch contract the settings caption states verbatim;
//    nothing pretends to live-switch. The badge tracks the pending count
//    through the @Observable rows (withObservationTracking, re-armed per fire
//    — the Observation API's one-shot contract) so NO row-mutation path can
//    miss it, including ListViewModel.refresh() which replaces rows inside
//    the VM where the coordinator never sees the fresh array. Zero pending =
//    no badge (the MenuData counts contract). Rows only ever mutate on the
//    MainActor (the VM's class contract), so the tracking hop is sound.
//
// 2. WELCOME TOUR (GAP #26 item 2). Shown EXACTLY ONCE: the persisted flag
//    is checked at launch; ANY dismissal — Get Started OR the window's close
//    button — marks it shown. Presented as a real NSWindow hosting the
//    SwiftUI view because `openWindow(id:)` exists only inside live view
//    context and the menu-bar scene's content is not guaranteed alive at
//    launch; the coordinator already owns AppKit presentation surfaces
//    elsewhere (activate, NSWorkspace, NSPasteboard), so this stays in its
//    role. isReleasedWhenClosed = false: the window's lifetime is the
//    coordinator's (it nils the reference itself), never an NSWindow
//    dealloc-during-close crash.
//
// 3. SETTINGS WRITES. The display picker persists through
//    ``setDisplayMode(showInDock:)`` — which lives in the class body
//    (AppState.swift, the setNotificationsEnabled precedent: private(set)
//    writers cannot be reached from another file's extension). A save
//    failure reloads the disk truth (the picker snaps back to what is
//    actually persisted) and surfaces the verbatim error via
//    ``displayError`` — never a silent "saved".

import SwiftUI
import AppKit
import Observation
import AppUpdaterCore

// MARK: - Item 1: dock presence + badge

extension AppState {

    /// Launch-time dock presence. Called from init BEFORE any window exists
    /// (the only reliable moment for an LSUIElement app's policy decision).
    /// Also clears any stale badge — a fresh launch has no rows yet.
    func applyLaunchDisplayState(_ settings: DisplaySettings) {
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
        NSApp.dockTile.badgeLabel = nil
    }

    /// Arms the one-shot rows observer (re-armed inside the handler —
    /// withObservationTracking fires ONCE per registration). The FIRST arm
    /// happens in init; the badge starts at no-badge from
    /// ``applyLaunchDisplayState``.
    func armDockBadgeObserver() {
        withObservationTracking {
            _ = list.rows
        } onChange: { [weak self] in
            // Rows mutate on the MainActor only; hop back before touching
            // anything, so the badge update always reads SETTLED rows.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateDockBadge()
                self.armDockBadgeObserver()
            }
        }
    }

    /// The badge IS the pending count, only with dock presence. Zero pending
    /// = no badge (never a fake "0" — the MenuData counts contract).
    func updateDockBadge() {
        guard launchShowInDock else { return }
        let pending = list.rows.filter { $0.updateAvailable }.count
        NSApp.dockTile.badgeLabel = pending > 0 ? String(pending) : nil
    }
}

// MARK: - Item 2: welcome tour (exactly once)

extension AppState {

    /// Launch check: present the tour only when the flag says it has never
    /// been shown. The presentation defers one runloop turn (a Task) so the
    /// window appears after the app finishes launching — presenting an
    /// NSWindow during App.init is too early.
    func presentWelcomeTourIfNeeded() {
        guard !welcomeTourStore.load().tourShown else { return }
        welcomeTask = Task { @MainActor [weak self] in
            self?.presentWelcomeTourWindow()
        }
    }

    /// Creates the one-page window. Guarded: one tour window per process.
    private func presentWelcomeTourWindow() {
        guard welcomeWindow == nil else { return }
        let hosting = NSHostingController(
            rootView: WelcomeTourView(onGetStarted: { [weak self] in
                self?.welcomeTourGetStarted()
            }))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to AppUpdater"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        let delegate = WelcomeWindowDelegate { [weak self] in
            self?.welcomeTourWindowWillClose()
        }
        window.delegate = delegate
        welcomeWindow = window
        welcomeWindowDelegate = delegate
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Get Started: mark shown, tear the coordinator's references down, then
    /// close. The close fires windowWillClose → the guard below makes the
    /// second pass a no-op (one markShown, not two).
    private func welcomeTourGetStarted() {
        let window = welcomeWindow
        teardownWelcomeTour()
        window?.close()
    }

    /// Close-button path (windowWillClose): mark shown, tear down. Guarded
    /// so it runs exactly once per window (the Get Started path pre-empts it).
    private func welcomeTourWindowWillClose() {
        guard welcomeWindow != nil else { return }
        teardownWelcomeTour()
    }

    /// Persists the exactly-once flag. A save failure is LOGGED and honestly
    /// accepted: the tour will show once more on the next launch — benign,
    /// and never reported as if it could not happen.
    private func teardownWelcomeTour() {
        welcomeWindow = nil
        welcomeWindowDelegate = nil
        do {
            try welcomeTourStore.markShown()
        } catch {
            Self.welcomeTourLog.error(
                "welcome_state.json save failed (\(String(describing: error), privacy: .public)) — the tour will show again on the next launch"
            )
        }
    }
}

/// NSWindowDelegate holder for the tour window's close path. Kept alive by
/// ``AppState.welcomeWindowDelegate`` (NSWindow holds its delegate weakly).
/// Internal (not private): AppState's stored property types it concretely
/// from AppState.swift.
final class WelcomeWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
