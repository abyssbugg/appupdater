// WelcomeTourView.swift — GAP #26, first-launch onboarding. Lane polish ·
// exclusive app-target files of this lane (Sources/AppUpdaterApp/**).
//
// ONE page, shown EXACTLY ONCE (the exactly-once flag lives in
// welcome_state.json; the presentation lives in the AppState polish
// extension). HONEST COPY ONLY — what the app does, the consent boundary,
// and the Gatekeeper/ad-hoc-signing reality. No marketing claims, no
// promises the engine does not keep: "installs are click-driven; auto-apply
// is opt-in per app" is the LOCKED decision 14 boundary restated for the
// user, and the Gatekeeper note states the ad-hoc signing caveat the
// release notes document (v0.1.0).

import SwiftUI

/// The single-page onboarding window content. Self-contained: one closure,
/// no environment dependencies — the coordinator presents it in a real
/// NSWindow at first launch (see AppState+Polish.swift for why).
struct WelcomeTourView: View {
    let onGetStarted: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            section(
                icon: "arrow.triangle.2.circlepath", tint: .accentColor,
                title: "What AppUpdater does",
                body: "It scans your installed apps and checks public sources — Homebrew casks, each app's "
                    + "own Sparkle feed, the Mac App Store and GitHub releases — then reports, honestly, "
                    + "which apps have a newer version. Apps it cannot verify are labeled unknown, never guessed.")
            section(
                icon: "hand.tap", tint: .orange,
                title: "Nothing installs by itself",
                body: "Installs are click-driven: a button stages the exact update command, and you run it "
                    + "yourself in your terminal. Automatic applying exists but is strictly opt-in per app, "
                    + "and off by default.")
            section(
                icon: "checkmark.shield", tint: .green,
                title: "First launch on macOS",
                body: "This build is ad-hoc signed and not notarized, so Gatekeeper may ask you to confirm "
                    + "opening it once (right-click → Open, or System Settings → Privacy & Security).")

            Spacer(minLength: 8)

            Button {
                onGetStarted()
            } label: {
                Text("Get Started")
                    .frame(minWidth: 140)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(26)
        .frame(width: 470)
    }

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.orange, .pink],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: 46, height: 46)
                .overlay {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to AppUpdater")
                    .font(.title2.weight(.bold))
                Text("Update checks you can trust — installs you control.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func section(icon: String, tint: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
