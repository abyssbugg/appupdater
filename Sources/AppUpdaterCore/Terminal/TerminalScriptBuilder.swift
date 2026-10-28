// TerminalScriptBuilder.swift — GAP #25, opt-in Terminal typing: PURE string
// builders producing the exact AppleScript that types one staged owner-command
// into the chosen emulator. THE SCRIPT STRING IS THE PRODUCT: nothing here
// executes AppleScript, spawns a process or touches the network — the
// coordinator's app layer is what runs the returned script (NSAppleScript)
// after an explicit click. This module can be exercised fully hermetically.
//
// Evidence frame (docs/reverse/UPDATEST-FINDINGS.md §3.13 "Terminal automation
// (the privileged path)") + dialect provenance, marked honestly per the sprint
// brief:
//
//   Terminal.app — THEIRS (confirmed fragments in Updatest's binary):
//     `tell application id "<bundleid>" … do script "…"` with `activate`,
//     against the confirmed `com.apple.Terminal` literal. `do script` runs the
//     command immediately in a new Terminal window; the sudo password (when
//     the staged command is one of our privileged staged commands) is typed by
//     the user at the resulting prompt — the entire path stays user-attended.
//     OURS: only the line arrangement / indentation (4 spaces) and the absence
//     of a trailing newline (pure string product, pinned by golden tests).
//
//   iTerm2 — THEIRS (confirmed fragments): `create window with default
//     profile`, `input text "…"` (types the text WITHOUT pressing Return —
//     the command sits on the prompt line for the owner to review and run),
//     plus a reuse-branch fragment (`set term to focused terminal of selected
//     tab of front window`) the teardown documents but whose control flow is
//     silent. OURS (standard dialect chosen where the teardown is silent, per
//     the brief): the bundle id literal `com.googlecode.iterm2`; the
//     deterministic NEW-WINDOW flow (a fresh, known session — typing into
//     "whatever tab is focused" risks hitting the wrong pane with a sudo
//     command, so the reuse branch is deliberately NOT modeled); the
//     `set newWindow to (create window with default profile)` binding that
//     makes `tell current session of newWindow` resolve; `activate` before
//     window creation; and the direct-object `input text "…"` form inside the
//     session tell (the teardown's `input text "…" to term` tail needs a
//     `term` variable we choose not to introduce; same verb, standard form).
//
//   DELIBERATE ASYMMETRY (inherent to the two confirmed verbs, documented so
//   nobody "fixes" it by accident): Terminal.app's `do script` executes the
//   staged command immediately; iTerm2's `input text` leaves it typed-but-
//   unrun for the owner to press Return. Both keep the whole privileged path
//   user-attended; iTerm2's is strictly the more conservative confirm step
//   and is kept exactly as the evidence shows it.
//
// Consent gate (LOCKED decision 14 posture — click-driven, typing opt-in):
// the builder refuses to produce ANY typing script without an explicit
// `userApprovedTyping: true`, and the consent check runs FIRST — the refusal
// priority is consent, then command sanity, then build. The staged commands
// this API is fed are the strings our staged-PKG (`sudo installer -pkg "…" -target /`),
// brew-adopt (`brew install --cask --adopt …`) and MAS-replacement
// (`sudo mas uninstall …`) flows already emit as data.
//
// Quoting contract (test-enforced): the command is embedded in the AppleScript
// source as ONE string literal whose VALUE is the command, byte-for-byte —
// `\` → `\\` and `"` → `\"` (backslash first, or the quote-escapes would be
// double-escaped); every other character passes through verbatim. App names /
// paths with spaces, quotes, backslashes, `$`, semicolons, backticks and
// non-ASCII survive unambiguously as inert text: an adversarial command like
// `App; rm -rf /tmp/x.app` cannot escape the literal into AppleScript code —
// at worst it remains the text the shell would have seen if the owner had
// pasted it, and path shell-quoting is ALREADY the staged flows' own contract,
// not this module's (this layer adds no interpretation, ever).
//
// Control-character refusal (OURS — security floor addition beyond the
// teardown): a staged command is one shell line typed for a human, so ANY
// Unicode scalar in C0 (U+0000–U+001F: NUL, tab, newline, CR, ESC…) or C1
// (U+007F–U+009F: DEL, NEL…) is refused up front. This both (a) keeps
// newline/CR from breaking the AppleScript literal or smuggling a second line
// into the typed text, and (b) makes terminal escape-sequence injection
// structurally impossible — an ESC byte can never reach the owner's terminal
// through this module. Control characters are never silently escaped or
// stripped: refusal is the honest behavior.

import Foundation

// MARK: - Error type

/// Honest refusal with a distinct case per gate (Equatable for tests) and
/// verbatim human `reason` text the app layer surfaces unchanged. Every case
/// is thrown BEFORE anything is built — a refusal produces no script.
public enum TerminalScriptError: Error, Equatable, Sendable {
    /// `userApprovedTyping` was not `true`. Typing is strictly opt-in; this
    /// gate fires FIRST, even before command validation.
    case missingTypingConsent
    /// The staged command is empty or whitespace-only — nothing to type.
    case emptyCommand
    /// The staged command contains a control character (C0/C1) — refused,
    /// never escaped or stripped (see the file header for the rationale).
    case commandContainsControlCharacters

    /// Human-readable, user-surfaceable refusal text.
    public var reason: String {
        switch self {
        case .missingTypingConsent:
            return "Terminal typing was not approved — a command is only typed into the "
                + "user's Terminal after the owner explicitly approves typing (copy/paste "
                + "remains the default and always-available path)"
        case .emptyCommand:
            return "the staged command is empty — there is nothing to type into the Terminal"
        case .commandContainsControlCharacters:
            return "the staged command contains control characters (tab/newline/escape…), "
                + "which are refused — a staged command is one shell line, and control bytes "
                + "could smuggle input into the user's Terminal session"
        }
    }
}

// MARK: - Builder

/// Pure AppleScript builders for the two documented emulator dialects.
public enum TerminalScriptBuilder {

    /// Builds the AppleScript that types one staged owner-command in
    /// `emulator`. THE SCRIPT STRING IS THE PRODUCT — the caller (coordinator's
    /// app layer) runs it via NSAppleScript after an explicit click; this
    /// module never executes anything.
    ///
    /// Gate order (test-pinned): `userApprovedTyping` FIRST (typing is opt-in —
    /// an unapproved build refuses even for an invalid command), then the
    /// command must be non-empty (whitespace-only counts as empty), then it
    /// must contain no C0/C1 control scalars (refused, never escaped).
    /// Command embedding: exactly one AppleScript string literal whose value
    /// round-trips the command byte-for-byte (`\` → `\\`, `"` → `\"`).
    public static func typingScript(
        command: String,
        emulator: TerminalEmulator,
        userApprovedTyping: Bool
    ) throws -> String {
        guard userApprovedTyping else { throw TerminalScriptError.missingTypingConsent }

        guard !command.isEmpty,
              !command.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw TerminalScriptError.emptyCommand
        }
        guard !containsControlCharacter(command) else {
            throw TerminalScriptError.commandContainsControlCharacters
        }

        switch emulator {
        case .terminal: return terminalScript(escapedCommand: appleScriptEscaped(command))
        case .iterm2: return iterm2Script(escapedCommand: appleScriptEscaped(command))
        }
    }

    /// AppleScript string-literal escaping for one command: `\` → `\\` then
    /// `"` → `\"`; every other scalar passes through verbatim. Public because
    /// the quoting contract is part of this module's product surface (the
    /// round-trip property is test-enforced against adversarial fixtures).
    /// Callers must NOT feed commands containing control characters — the
    /// builder refuses those before reaching this function, and this function
    /// alone gives them no safe treatment.
    public static func appleScriptEscaped(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Dialects

    /// Terminal.app — THEIRS (confirmed fragments): `tell application id
    /// "com.apple.Terminal"` + `activate` + `do script "…"`. OURS: the exact
    /// line arrangement, 4-space indentation, no trailing newline.
    /// `do script` (no `in window` parameter) opens a new window and executes
    /// the command; the user attends the sudo prompt it may raise.
    private static func terminalScript(escapedCommand: String) -> String {
        """
        tell application id "com.apple.Terminal"
            activate
            do script "\(escapedCommand)"
        end tell
        """
    }

    /// iTerm2 — verbs THEIRS (confirmed): `create window with default profile`
    /// + `input text "…"` (types WITHOUT Return — the owner reviews and presses
    /// Return, then answers the sudo prompt). Flow OURS (teardown silent on
    /// control flow; standard dialect chosen): bundle id
    /// `com.googlecode.iterm2`, deterministic new window via the
    /// `set newWindow to (…)` binding so `tell current session of newWindow`
    /// resolves, `activate` first, direct-object `input text` inside the
    /// session tell, 4-space indentation, no trailing newline. The teardown's
    /// reuse branch (`set term to focused terminal of selected tab of front
    /// window`) is deliberately NOT modeled — typing into whatever session
    /// happens to be focused is the wrong-pane risk a sudo path must not take.
    private static func iterm2Script(escapedCommand: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                input text "\(escapedCommand)"
            end tell
        end tell
        """
    }

    // MARK: Control-character gate

    /// True when ANY Unicode scalar of `command` falls in C0 (U+0000–U+001F)
    /// or C1 (U+007F–U+009F). Scalars are scanned directly (not Characters) so
    /// a control byte hiding inside a composed grapheme is still caught.
    private static func containsControlCharacter(_ command: String) -> Bool {
        command.unicodeScalars.contains { scalar in
            let value = scalar.value
            return value <= 0x1F || (0x7F...0x9F).contains(value)
        }
    }
}
