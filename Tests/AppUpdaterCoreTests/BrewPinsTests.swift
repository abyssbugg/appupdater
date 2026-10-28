// BrewPins tests — the pinned-set parser + the pinned-file watcher.
// Hermetic: the parser is pure text → sets (fixture strings, no fixtures on
// disk); the watcher drives INJECTED file URLs under per-test UUID temp dirs
// and a ScheduleEngine-style fake clock + parked sleeper (ZERO real poll time —
// the loop only moves via explicit harness advances). Swift Testing only
// (XCTest discovery is broken on this toolchain). Never executes brew: the
// parser parses captured output, the watcher only stats two files.

import Foundation
import Testing
@testable import AppUpdaterCore

// MARK: - Fixtures (captured `brew list --pinned` output shapes)

/// The sectioned shape (Workbrew/Updatest layout — `==> Formulae` / `==> Casks`
/// headers route the lines, like `brew list`'s two-section output).
private let sectionedPinsOutput = """
==> Formulae
wget
node@20

==> Casks
google-chrome
firefox
"""

/// The bare OSS shape: `brew list --pinned` prints pinned formulae only, one
/// per line, with NO section headers.
private let barePinsOutput = "wget\nopenssl@3\n"

/// Binary junk + prose + a column-ish line — nothing parseable as a pin name.
/// The junk is written with unicode escapes (unprintable bytes cannot appear
/// in Swift source) but reaches the parser as exactly the garbage a corrupted
/// capture would carry.
private let malformedPinsOutput = "\u{FFFD}\u{0000} junk\u{FFFD}\nWarning: something went wrong\nnot a name with spaces\n"

/// Mixed: two real pins plus junk lines — the junk is skipped with notes, the
/// real pins still land (never a total failure over one bad line).
private let mixedPinsOutput = """
wget
Warning: something went wrong
node@20
"""

/// An unrecognized section header must not misroute its lines.
private let unknownHeaderPinsOutput = """
==> Formulae
wget

==> Kegs
openssl@3
"""

// MARK: - Parser tests

@Suite(.serialized)
struct BrewPinsParserTests {

    private func parse(_ output: String) -> BrewPinsParseResult {
        BrewPinsParser.parse(output)
    }

    // (1) Sectioned output: headers route lines to the right set.
    @Test func sectionedOutputRoutesFormulaeAndCasks() {
        let result = parse(sectionedPinsOutput)
        #expect(result.pins.formulae == ["wget", "node@20"])
        #expect(result.pins.casks == ["google-chrome", "firefox"])
        #expect(result.notes.isEmpty)
        #expect(result.pins.isEmpty == false)
    }

    // (2) Bare OSS output: headerless lines are pinned formulae; casks empty.
    @Test func bareOutputLandsInFormulae() {
        let result = parse(barePinsOutput)
        #expect(result.pins.formulae == ["wget", "openssl@3"])
        #expect(result.pins.casks.isEmpty)
        #expect(result.notes.isEmpty)
    }

    // (3) Empty output → empty sets, NO notes (nothing pinned is an honest
    // verdict, not a failure).
    @Test func emptyOutputIsEmptyWithNoNotes() {
        let result = parse("")
        #expect(result.pins.isEmpty)
        #expect(result.notes.isEmpty)
    }

    // (4) Whitespace-only output → same as empty (honest, silent).
    @Test func whitespaceOnlyOutputIsEmptyWithNoNotes() {
        let result = parse("\n  \n\t\n")
        #expect(result.pins.isEmpty)
        #expect(result.notes.isEmpty)
    }

    // (5) Malformed input → honest EMPTY sets + notes that say why (never a
    // guessed partial, never a silent swallow).
    @Test func malformedInputHonestEmptyWithNotes() {
        let result = parse(malformedPinsOutput)
        #expect(result.pins.isEmpty)
        #expect(result.notes.contains("no pinned names found in the captured output"))
        #expect(result.notes.count >= 3) // one per skipped line
        #expect(result.notes.contains { $0.contains("skipped non-pin line") })
    }

    // (6) Mixed input: real pins parsed, junk lines noted, no "nothing found"
    // note (names WERE found).
    @Test func mixedInputParsesValidSkipsJunk() {
        let result = parse(mixedPinsOutput)
        #expect(result.pins.formulae == ["wget", "node@20"])
        #expect(result.pins.casks.isEmpty)
        #expect(result.notes.count == 1)
        #expect(result.notes.first?.contains("Warning: something went wrong") == true)
    }

    // (7) An unrecognized section header is noted and does NOT switch the
    // current section (openssl@3 stays a formulae line, never misrouted).
    @Test func unknownHeaderIsNotedDoesNotSwitchSection() {
        let result = parse(unknownHeaderPinsOutput)
        #expect(result.pins.formulae == ["wget", "openssl@3"])
        #expect(result.pins.casks.isEmpty)
        #expect(result.notes == ["ignored unrecognized section header 'Kegs'"])
    }

    // (8) Duplicates collapse (pinned sets, not lists).
    @Test func duplicateLinesDedupe() {
        let result = parse("wget\nwget\nwget\n")
        #expect(result.pins.formulae == ["wget"])
        #expect(result.notes.isEmpty)
    }

    // (9) Brew token charset: @versions, plus, dots, underscores and
    // tap-qualified slashes are names; anything with whitespace is not.
    @Test func pinNameCharset() {
        let result = parse("node@20\nlibgit2@1.8\nuser/repo/formula\nsome+thing.app_name\n")
        #expect(result.pins.formulae == ["node@20", "libgit2@1.8", "user/repo/formula", "some+thing.app_name"])
        #expect(BrewPinsParser.isValidPinName("openssl@3") == true)
        #expect(BrewPinsParser.isValidPinName("two words") == false)
        #expect(BrewPinsParser.isValidPinName("") == false)
        #expect(BrewPinsParser.isValidPinName("junk\u{FFFD}\u{0000}") == false)
        #expect(BrewPinsParser.isValidPinName("trailing space ") == false) // caller trims first; raw space fails charset
    }

    // (10) Prose-only output ("Nothing is pinned."-style lines) → honest empty
    // + notes (a prose line is not a pin and not a silence).
    @Test func proseOnlyOutputHonestEmptyWithNotes() {
        let result = parse("Nothing is pinned.\n")
        #expect(result.pins.isEmpty)
        #expect(result.notes.contains("no pinned names found in the captured output"))
    }
}

// MARK: - Prefix resolution tests (the injected `brew --prefix` seam)

@Suite(.serialized)
struct BrewPrefixResolverTests {

    private func resolver(
        exitStatus: Int32 = 0, stdout: String, stderr: String = ""
    ) -> BrewPrefixResolver {
        BrewPrefixResolver(runner: BrewProcessRunner { _, arguments, _ in
            // The seam pin: the probe is exactly `brew --prefix` through env.
            #expect(arguments == ["brew", "--prefix"])
            return BrewProcessRun(stdout: stdout, stderr: stderr, exitStatus: exitStatus)
        })
    }

    // (11) Exit 0 + a POSIX path on stdout → the prefix URL (trimmed).
    @Test func exitZeroWithPathResolves() async {
        let url = await resolver(stdout: "/opt/homebrew\n").resolve()
        #expect(url?.path == "/opt/homebrew")
    }

    // (12) A non-zero exit (brew broken/unhappy) → nil, never a guessed prefix.
    @Test func nonZeroExitResolvesNil() async {
        let url = await resolver(exitStatus: 1, stdout: "/opt/homebrew\n").resolve()
        #expect(url == nil)
    }

    // (13) Empty or non-path stdout → nil (never a fabricated location).
    @Test func emptyOrNonPathOutputResolvesNil() async {
        #expect(await resolver(stdout: "").resolve() == nil)
        #expect(await resolver(stdout: "   \n").resolve() == nil)
        #expect(await resolver(stdout: "not a path").resolve() == nil)
    }

    // (14) The spawn itself failing (brew absent from PATH) → nil.
    @Test func spawnThrowResolvesNil() async {
        let failing = BrewPrefixResolver(runner: BrewProcessRunner { _, _, _ in
            throw URLError(.cannotFindHost)
        })
        #expect(await failing.resolve() == nil)
    }

    // (15) The pinned locations are PREFIX-RELATIVE (`<prefix>/pinned` +
    // `<prefix>/pinned_casks` — the Updatest layout with the runtime prefix
    // substituted; /var/homebrew is never hardcoded anywhere).
    @Test func pinnedFileURLsArePrefixRelative() {
        let prefix = URL(fileURLWithPath: "/opt/homebrew", isDirectory: true)
        let urls = BrewPrefixResolver.pinnedFileURLs(prefix: prefix)
        #expect(urls.formulae.path == "/opt/homebrew/pinned")
        #expect(urls.casks.path == "/opt/homebrew/pinned_casks")
    }
}
