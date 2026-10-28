// TerminalScript tests — GAP #25, opt-in Terminal typing (TerminalEmulator +
// TerminalScriptBuilder). Fully hermetic: pure string assertions over the
// builder products (the module NEVER executes AppleScript — the coordinator's
// app layer does, after a click), plus file-IO tests for the default-emulator
// store over per-test UUID subdirectories under a per-PROCESS unique temp root
// (gotcha ledger: shared fixed temp roots collide across concurrent `swift
// test` runners). Swift Testing only (XCTest discovery is broken on this
// toolchain).
//
// Coverage contract from the sprint brief:
//   1. golden-script assertions for BOTH documented dialects (exact bytes),
//   2. adversarial quoting matrix — spaces, quotes, backslashes, `$`,
//      semicolons, backticks, non-ASCII round-trip as INERT text; the brief's
//      `App; rm -rf /tmp/x.app` fixture cannot escape the AppleScript literal,
//   3. refusal-without-consent (and refusal priority: consent gate first),
//   4. default-emulator persistence round-trip (nil = copy/paste fallback),
//   5. control-character refusals (C0/C1 — newline injection AND terminal
//      escape-sequence injection both structurally impossible).

import Foundation
import Testing
@testable import AppUpdaterCore

// MARK: - Round-trip helper (test-local)

/// Reverses TerminalScriptBuilder.appleScriptEscaped for well-formed escape
/// sequences (`\\` → `\`, `\"` → `"`; every other character passes through).
/// Used to prove the quoting contract's round-trip property without executing
/// AppleScript: unescape(escape(command)) == command, byte for byte.
private func unescapeAppleScriptLiteral(_ escaped: String) -> String {
    var output = ""
    var iterator = escaped.makeIterator()
    while let character = iterator.next() {
        if character == "\\" {
            // Well-formed input always pairs the backslash (the escaper never
            // emits a lone one); a malformed tail would surface as a test
            // failure on the comparison below, never as a crash.
            if let next = iterator.next() {
                output.append(next)
            }
        } else {
            output.append(character)
        }
    }
    return output
}

// MARK: - Dialect goldens + quoting

@Suite struct TerminalScriptBuilderTests {

    private static let pkgCommand = "sudo installer -pkg \"/Applications/My App.pkg\" -target /"
    private static let brewCommand = "brew install --cask --adopt ghostty"

    // MARK: Golden scripts (exact bytes)

    /// Terminal.app golden — THEIRS (confirmed fragments): `tell application
    /// id "com.apple.Terminal"` + `activate` + `do script "…"`; the staged-PKG
    /// path with a SPACE survives the AppleScript literal unambiguously.
    @Test func goldenTerminalScriptStagedPKGExactBytes() {
        let script = try? TerminalScriptBuilder.typingScript(
            command: Self.pkgCommand, emulator: .terminal, userApprovedTyping: true)
        let expected = #"""
        tell application id "com.apple.Terminal"
            activate
            do script "sudo installer -pkg \"/Applications/My App.pkg\" -target /"
        end tell
        """#
        #expect(script == expected)
    }

    /// Terminal.app golden — plain brew-adopt staged command, no escaping
    /// needed, embedded verbatim.
    @Test func goldenTerminalScriptBrewAdoptExactBytes() {
        let script = try? TerminalScriptBuilder.typingScript(
            command: Self.brewCommand, emulator: .terminal, userApprovedTyping: true)
        let expected = #"""
        tell application id "com.apple.Terminal"
            activate
            do script "brew install --cask --adopt ghostty"
        end tell
        """#
        #expect(script == expected)
    }

    /// iTerm2 golden — verbs THEIRS (confirmed): `create window with default
    /// profile` + `input text "…"` (no Return — owner reviews and presses
    /// Return). Flow OURS: bundle id `com.googlecode.iterm2`, deterministic
    /// new window via the `set newWindow to (…)` binding, `activate`, direct
    /// `input text` inside the session tell (marked in the source header).
    @Test func goldenIterm2ScriptStagedPKGExactBytes() {
        let script = try? TerminalScriptBuilder.typingScript(
            command: Self.pkgCommand, emulator: .iterm2, userApprovedTyping: true)
        let expected = #"""
        tell application id "com.googlecode.iterm2"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                input text "sudo installer -pkg \"/Applications/My App.pkg\" -target /"
            end tell
        end tell
        """#
        #expect(script == expected)
    }

    /// iTerm2 golden — plain brew-adopt staged command, embedded verbatim.
    @Test func goldenIterm2ScriptBrewAdoptExactBytes() {
        let script = try? TerminalScriptBuilder.typingScript(
            command: Self.brewCommand, emulator: .iterm2, userApprovedTyping: true)
        let expected = #"""
        tell application id "com.googlecode.iterm2"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                input text "brew install --cask --adopt ghostty"
            end tell
        end tell
        """#
        #expect(script == expected)
    }

    // MARK: Escaping contract (direct values)

    @Test func escapeBackslashFirstThenQuote() {
        #expect(TerminalScriptBuilder.appleScriptEscaped("he said \"hi\"") == "he said \\\"hi\\\"")
        #expect(TerminalScriptBuilder.appleScriptEscaped("a\\b") == "a\\\\b")
        // The killer pair — backslash immediately followed by a quote — must
        // become THREE characters (escaped backslash, escaped quote), proving
        // the backslash-first order cannot double-escape the quote escape.
        #expect(TerminalScriptBuilder.appleScriptEscaped("seq \\\"") == "seq \\\\\\\"")
    }

    // MARK: Adversarial quoting matrix (round-trip as inert text)

    /// Every fixture survives `escape` → `unescape` byte-for-byte: the
    /// AppleScript literal's VALUE is the command, unambiguously. Semicolons,
    /// `$`, command substitution and backticks pass through VERBATIM — inert
    /// at this layer (the shell sees what a pasted command would have shown;
    /// path shell-quoting is the staged flows' own contract, never re-derived
    /// here).
    @Test func adversarialQuotingMatrixRoundTrips() {
        let fixtures: [String] = [
            "App; rm -rf /tmp/x.app",
            "sudo installer -pkg \"/Applications/App; rm -rf /tmp/x.app\" -target /",
            "echo \"he said \\\"hi\\\" there\"",
            "tr '\\\\' '/'",
            "foo \\",
            "seq \\\"",
            "echo $HOME; rm -rf $HOME/x '$VAR'",
            "brew install --cask --adopt \"my-$(rm -rf /)-cask\"",
            "echo 'backtick` ls'",
            "sudo installer -pkg \"/Applications/日本語 App — émoji 🎉.pkg\" -target /",
            "sudo mas uninstall 1234567",
            "brew upgrade --force --cask --appdir=\"/opt/homebrew\""
        ]
        for fixture in fixtures {
            #expect(
                unescapeAppleScriptLiteral(TerminalScriptBuilder.appleScriptEscaped(fixture)) == fixture,
                "quoting round-trip failed for fixture: \(fixture)")
        }
    }

    /// The brief's injection fixture, embedded in BOTH dialects: the whole
    /// script is exactly wrapperPrefix + escape(command) + wrapperSuffix —
    /// the command cannot leak out of the string literal into AppleScript
    /// code, and nothing else in the script varies.
    @Test func adversarialCommandEmbedsInertlyInBothDialects() {
        let hostile = "sudo installer -pkg \"/Applications/App; rm -rf /tmp/x.app\" -target /"
        let escaped = TerminalScriptBuilder.appleScriptEscaped(hostile)

        let terminal = try? TerminalScriptBuilder.typingScript(
            command: hostile, emulator: .terminal, userApprovedTyping: true)
        let terminalExpected = #"""
        tell application id "com.apple.Terminal"
            activate
            do script "
        """# + escaped + #"""
        "
        end tell
        """#
        #expect(terminal == terminalExpected)

        let iterm2 = try? TerminalScriptBuilder.typingScript(
            command: hostile, emulator: .iterm2, userApprovedTyping: true)
        let iterm2Expected = #"""
        tell application id "com.googlecode.iterm2"
            activate
            set newWindow to (create window with default profile)
            tell current session of newWindow
                input text "
        """# + escaped + #"""
        "
            end tell
        end tell
        """#
        #expect(iterm2 == iterm2Expected)
    }

    // MARK: Consent gate (LOCKED decision 14 posture — typing is opt-in)

    /// Without `userApprovedTyping` the builder refuses for BOTH emulators,
    /// even for a perfectly valid staged command.
    @Test func refusesWithoutConsentBothEmulators() {
        for emulator in [TerminalEmulator.terminal, .iterm2] {
            #expect(throws: TerminalScriptError.missingTypingConsent) {
                try TerminalScriptBuilder.typingScript(
                    command: Self.brewCommand, emulator: emulator, userApprovedTyping: false)
            }
        }
    }

    /// Refusal priority: the consent gate fires FIRST — an unapproved build
    /// refuses with .missingTypingConsent even when the command would also
    /// fail the empty or control-character gates.
    @Test func consentGateRunsBeforeCommandValidation() {
        #expect(throws: TerminalScriptError.missingTypingConsent) {
            try TerminalScriptBuilder.typingScript(
                command: "", emulator: .terminal, userApprovedTyping: false)
        }
        #expect(throws: TerminalScriptError.missingTypingConsent) {
            try TerminalScriptBuilder.typingScript(
                command: "echo a\u{001B}[31mb", emulator: .iterm2, userApprovedTyping: false)
        }
    }

    // MARK: Command sanity gates

    @Test func refusesEmptyAndWhitespaceOnlyCommands() {
        #expect(throws: TerminalScriptError.emptyCommand) {
            try TerminalScriptBuilder.typingScript(
                command: "", emulator: .terminal, userApprovedTyping: true)
        }
        #expect(throws: TerminalScriptError.emptyCommand) {
            try TerminalScriptBuilder.typingScript(
                command: "   ", emulator: .iterm2, userApprovedTyping: true)
        }
        // A tab-ONLY command is whitespace-only — nothing meaningful to type —
        // so the empty gate honestly fires first (gate order: empty → control;
        // .whitespaces includes tab). A tab INSIDE a real command is still a
        // control character — see refusesControlCharacters.
        #expect(throws: TerminalScriptError.emptyCommand) {
            try TerminalScriptBuilder.typingScript(
                command: "\t", emulator: .terminal, userApprovedTyping: true)
        }
    }

    /// C0/C1 control scalars are REFUSED, never escaped or stripped: newline
    /// and CR (literal smuggling / AppleScript breakage), tab INSIDE a command,
    /// NUL, and the terminal-injection set (ESC, DEL, NEL, C1-CSI). Each case
    /// also proves no script is produced (the throw carries the whole outcome).
    @Test func refusesControlCharacters() {
        let controls: [String] = [
            "\n", "\r", "\r\n", "\u{0000}",
            "\u{001B}", "\u{007F}", "\u{0085}", "\u{009B}",
            "echo a\u{001B}[31mred\u{001B}[0m",
            "echo a\u{0009}b",
            "sudo installer -pkg \"/tmp/a\u{000A}b.pkg\" -target /"
        ]
        for control in controls {
            #expect(throws: TerminalScriptError.commandContainsControlCharacters) {
                try TerminalScriptBuilder.typingScript(
                    command: control, emulator: .terminal, userApprovedTyping: true)
            }
            #expect(throws: TerminalScriptError.commandContainsControlCharacters) {
                try TerminalScriptBuilder.typingScript(
                    command: control, emulator: .iterm2, userApprovedTyping: true)
            }
        }
    }

    // MARK: Emulator model

    /// Bundle-id provenance: Terminal.app's `com.apple.Terminal` is a CONFIRMED
    /// literal in Updatest's binary; `com.googlecode.iterm2` is OUR standard
    /// choice (teardown silent on the literal). CopyPaste is deliberately NOT
    /// a case — it is the built-in fallback this store models the ABSENCE of.
    @Test func emulatorBundleIDsAndModelShape() {
        #expect(TerminalEmulator.terminal.bundleID == "com.apple.Terminal")
        #expect(TerminalEmulator.iterm2.bundleID == "com.googlecode.iterm2")
        #expect(TerminalEmulator.terminal.displayName == "Terminal")
        #expect(TerminalEmulator.iterm2.displayName == "iTerm2")
        #expect(TerminalEmulator.allCases == [.terminal, .iterm2])
    }
}

// MARK: - Default-emulator persistence

@Suite struct TerminalEmulatorStoreTests {

    /// Per-PROCESS unique root (gotcha ledger: a constant wiped temp root
    /// collides with concurrent `swift test` runners). Each test gets its own
    /// UUID subdirectory beneath it — no wipe needed, no cross-test or
    /// cross-process collision.
    private static let processRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("appupdater-terminal-\(UUID().uuidString)")

    private func makeStore() -> (store: TerminalEmulatorStore, directory: URL) {
        let directory = Self.processRoot.appendingPathComponent(UUID().uuidString)
        return (TerminalEmulatorStore(directory: directory), directory)
    }

    @Test func missingFileLoadsNilAndCreatesNothing() throws {
        let (store, directory) = makeStore()
        #expect(try store.loadDefault() == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
    }

    /// The round-trip the brief demands: save → load → same emulator, for
    /// both cases, over ONE store instance (save-through persistence).
    @Test func saveLoadRoundTripBothEmulators() throws {
        let (store, _) = makeStore()
        try store.saveDefault(.terminal)
        #expect(try store.loadDefault() == .terminal)
        try store.saveDefault(.iterm2)
        #expect(try store.loadDefault() == .iterm2)
    }

    /// Clearing returns to the copy/paste fallback (nil); clearing an already
    /// absent choice is an honest no-op.
    @Test func clearDefaultReturnsToFallbackDefault() throws {
        let (store, _) = makeStore()
        try store.saveDefault(.iterm2)
        try store.clearDefault()
        #expect(try store.loadDefault() == nil)
        try store.clearDefault()
        #expect(try store.loadDefault() == nil)
    }

    /// A corrupt store file throws clean and is NEVER auto-deleted, never
    /// fake-emptied — bytes stay untouched (tested byte-for-byte).
    @Test func corruptFileThrowsAndBytesAreNeverTouched() throws {
        let (store, directory) = makeStore()
        let fileURL = directory.appendingPathComponent("terminal_emulator.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrupt = Data("not json at all".utf8)
        try corrupt.write(to: fileURL)

        #expect(throws: TerminalEmulatorStoreError.self) { try store.loadDefault() }
        #expect((try? Data(contentsOf: fileURL)) == corrupt)
    }

    @Test func unsupportedSchemaVersionThrows() throws {
        let (store, directory) = makeStore()
        let fileURL = directory.appendingPathComponent("terminal_emulator.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let future = Data("{\"schemaVersion\": 99, \"defaultEmulator\": \"terminal\"}".utf8)
        try future.write(to: fileURL)

        #expect(throws: TerminalEmulatorStoreError.self) { try store.loadDefault() }
        #expect((try? Data(contentsOf: fileURL)) == future)
    }

    /// An unknown emulator tag is an unreadable file, not a guess — throw
    /// clean (unknown raw values must never decode into an invented case).
    @Test func unknownEmulatorTagThrows() throws {
        let (store, directory) = makeStore()
        let fileURL = directory.appendingPathComponent("terminal_emulator.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unknown = Data("{\"schemaVersion\": 1, \"defaultEmulator\": \"warp\"}".utf8)
        try unknown.write(to: fileURL)

        #expect(throws: TerminalEmulatorStoreError.self) { try store.loadDefault() }
        #expect((try? Data(contentsOf: fileURL)) == unknown)
    }

    /// Save-through overwrite: the second save wins atomically, and no
    /// staging temp file survives (the directory holds exactly the store file).
    @Test func overwriteLeavesOnlyTheStoreFile() throws {
        let (store, directory) = makeStore()
        try store.saveDefault(.terminal)
        try store.saveDefault(.iterm2)
        #expect(try store.loadDefault() == .iterm2)

        let entries = try FileManager.default.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false))
        #expect(entries == ["terminal_emulator.json"])
    }
}
