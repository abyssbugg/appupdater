import SwiftUI
import AppKit
import AppUpdaterCore

// MARK: - Shared visual language (Updatest-parity main window)

/// Real app icon from disk (also used by the menu-bar rows).
struct AppIconView: View {
    let path: String
    var size: CGFloat = 36

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
    }
}

/// One source kind → one user-facing name, everywhere (Updatest captions:
/// "Homebrew Catalog", "Sparkle", "App Store", "GitHub"). `.unknown` carries the
/// least-trusted claims (Electron / derived feeds — LOCKED decision 12).
enum SourceStyle {
    static func label(for kind: SourceKind) -> String {
        switch kind {
        case .cask: return "Homebrew Catalog"
        case .sparkle: return "Sparkle"
        case .mas: return "App Store"
        case .github: return "GitHub"
        case .unknown: return "Other"
        }
    }

    /// Plain sentence for the "Discovered via …" card. User sentences only —
    /// engine provenance notes never render (UI parity sprint rule).
    static func discoverySentence(for kind: SourceKind) -> String {
        switch kind {
        case .cask:
            return "The newest version was found in the public Homebrew cask index."
        case .sparkle:
            return "The newest version was found in the app's own Sparkle update feed."
        case .mas:
            return "The newest version was found through the Mac App Store lookup."
        case .github:
            return "The newest version was found in the project's GitHub Releases."
        case .unknown:
            return "The newest version came from a least-trusted source; it is shown for information only."
        }
    }

    /// Order used by the Source filter menu.
    static let menuOrder: [SourceKind] = [.mas, .cask, .sparkle, .github, .unknown]
}

/// Version strings the Updatest way: "short (build)" when a distinct build exists.
enum VersionText {
    static func installed(_ app: InstalledApp) -> String {
        let short = app.shortVersion ?? "?"
        if let build = app.bundleVersion, !build.isEmpty, build != short {
            return "\(short) (\(build))"
        }
        return short
    }

    static func newest(_ info: UpdateInfo) -> String {
        if let build = info.newestBuild, !build.isEmpty, build != info.newestShortVersion {
            return "\(info.newestShortVersion) (\(build))"
        }
        return info.newestShortVersion
    }
}

/// "9 mins ago" / "in 7 hours" — the Updatest footer phrasing.
enum RelativeText {
    static func string(for date: Date, relativeTo now: Date = Date()) -> String {
        if abs(date.timeIntervalSince(now)) < 60 {
            return date <= now ? "just now" : "in under a minute"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

extension AppRow {
    /// True when the app is running right now (Updatest's dot under the icon).
    @MainActor var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == app.bundleIdentifier
        }
    }

    /// Sources that ANSWERED for this app: the resolved claim's source, else
    /// every distinct candidate source (a "current" verdict has candidates but
    /// no resolved claim — showing it as "No Source" was a live honesty bug).
    var answeringSources: [SourceKind] {
        if let source = check?.resolved?.source { return [source] }
        var seen: [SourceKind] = []
        for candidate in check?.candidates ?? [] where !seen.contains(candidate.source) {
            seen.append(candidate.source)
        }
        return seen
    }

    /// "Homebrew, Sparkle" — Updatest's sources caption.
    var answeringSourcesText: String? {
        let sources = answeringSources
        return sources.isEmpty ? nil : sources.map(SourceStyle.label(for:)).joined(separator: ", ")
    }

    /// A rules-muted update: the source claims newer, a rule hides it.
    var isMutedUpdate: Bool { check?.verdict == "update" && !updateAvailable }

    /// The row can run the in-app verified update chain.
    var canUpdateInApp: Bool { updateAvailable && !app.isMacAppStore }
}

/// Updatest's soft gray capsule buttons (Update…, Open App, Adopt…).
struct CapsuleButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .body.weight(.semibold) : .callout.weight(.medium))
            .padding(.horizontal, large ? 16 : 13)
            .padding(.vertical, large ? 7 : 5)
            .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.22 : 0.12)))
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// A menu that looks like Updatest's "Options ⌄" / "Actions ⌄" capsules.
struct CapsuleMenu<Content: View>: View {
    let title: String
    var large = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        // macOS draws a Menu label's image BEFORE its text; the chevron is
        // drawn beside the menu instead so it reads "Options ⌄" like Updatest.
        HStack(spacing: 6) {
            Menu(content: content) { Text(title) }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .allowsHitTesting(false)
        }
        .font(large ? .body.weight(.medium) : .callout.weight(.medium))
        .padding(.horizontal, large ? 16 : 13)
        .padding(.vertical, large ? 7 : 5)
        .background(Capsule().fill(Color.primary.opacity(0.12)))
    }
}
