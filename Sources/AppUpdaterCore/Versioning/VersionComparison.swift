// Version comparison mirrors Sparkle's SUStandardVersionComparator in spirit:
// numeric components compare numerically, missing components zero-fill, and
// prerelease suffix keywords rank alpha < beta < rc < release.
//
// Honest deviations from byte-exact Sparkle parity (documented deliberately):
// - We split on "." AND "-" (Sparkle only splits on ".") because cask and
//   vendor strings use hyphens; hyphen-delimited qualifier tails are separate
//   zero-numbered components ("1.2.3-beta1" → [1, 2, 3, 0·beta·1]).
// - Keyword ranks (alpha=1/beta=2/rc=3) are a deliberate MacUpdater-style
//   extension; Sparkle's raw char comparator would order suffixes
//   alphabetically instead ("alpha" < "rc" both ways here, but "z" is ignored).
// - Unrecognized qualifier words without digits (e.g. "plain", "x") collapse
//   into the release rank, semver-build-metadata style: informative, not
//   order-significant ("1.0plain" == "1.0").
// - Strings we cannot honestly map ("v1"-shaped chunks mid-version, symbols,
//   no digits at all) fall back to deterministic lexicographic comparison of
//   the trimmed strings; it orders, it just isn't a version ordering.

/// Ordering of two version strings: `greater` means the FIRST argument is newer
/// (lhs-relative, like `String.compare(_:compareTo:)` returning ascending).
public enum VersionOrder: String, Sendable {
    case greater
    case equal
    case less
}

/// A parsed version string. Numbers are kept as normalized digit strings so
/// arbitrarily long component values compare exactly (no Int overflow).
///
/// Equality (`==`) is parse-adjacent, not semver-semantic: normalized digits
/// count ("007" == "7"), raw whitespace does not ("␣1.2␣" == "1.2"), but
/// component structure does ("1.2" != "1.2.0" even though `compare` says
/// `.equal` by zero-fill). Use `compare(to:)` for ordering semantics.
public struct AppVersion: Sendable, Hashable, CustomStringConvertible {
    /// One dot/hyphen-delimited component. `"228b"` → number `"228"`,
    /// qualifier `.beta` (alias "b"), sequence `"0"`. `"beta7"` → number `"0"`,
    /// `.beta`, sequence `"7"`. Pure `"2"` → number `"2"`, `.plain`, `"0"`.
    public struct Component: Sendable, Hashable {
        public enum Qualifier: Int, Sendable, Hashable {
            case alpha = 1   // accepted spellings: "alpha", "a"
            case beta = 2    // accepted spellings: "beta", "b" (Xcode/cask style)
            case rc = 3      // accepted spellings: "rc"
            case plain = 4   // no qualifier, OR an unrecognized word (ignored)
        }

        /// Normalized numeric part: leading zeros stripped, `"0"` when absent.
        public let number: String
        public let qualifier: Qualifier
        /// Numbered-variant value ("beta7" → `"7"`), normalized like `number`.
        public let sequence: String

        init(number: String, qualifier: Qualifier, sequence: String) {
            self.number = Self.canonicalDigits(number)
            self.qualifier = qualifier
            self.sequence = Self.canonicalDigits(sequence)
        }

        /// Zero component used when one operand has fewer components.
        static let zero = Component(number: "0", qualifier: .plain, sequence: "0")

        func compare(to other: Component) -> VersionOrder {
            let numberOrder = Self.digitOrder(number, other.number)
            if numberOrder != .equal { return numberOrder }
            if qualifier.rawValue != other.qualifier.rawValue {
                return qualifier.rawValue < other.qualifier.rawValue ? .less : .greater
            }
            return Self.digitOrder(sequence, other.sequence)
        }

        /// Numeric compare on digit strings without overflow: normalize, then
        /// longer canonical form wins; equal length compares digit-by-digit.
        static func digitOrder(_ a: String, _ b: String) -> VersionOrder {
            let left = canonicalDigits(a)
            let right = canonicalDigits(b)
            if left == right { return .equal }
            if left.count != right.count { return left.count < right.count ? .less : .greater }
            return left < right ? .less : .greater
        }

        static func canonicalDigits(_ s: some StringProtocol) -> String {
            let stripped = s.drop { $0 == "0" }
            return stripped.isEmpty ? "0" : String(stripped)
        }

        static func isASCIIDigit(_ char: Character) -> Bool {
            char.isASCII && char.isNumber && ("0"..."9").contains(char)
        }
    }

    /// The input with surrounding whitespace/newlines trimmed (Sparkle trims too).
    /// Lexicographic fallback compares THIS string, not the v-stripped body.
    public let raw: String
    /// `nil` means the string is not honest version material (see file header);
    /// only then does comparison fall back to documented lexicographic order.
    public let components: [Component]?
    public var isParseable: Bool { components != nil }

    /// Parse-adjacent equality (see type docs): parsed-vs-parsed compares
    /// normalized component arrays; unparseable-vs-unparseable compares the
    /// trimmed raw strings; mixed states are never equal.
    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        switch (lhs.components, rhs.components) {
        case (.some(let left), .some(let right)): return left == right
        case (nil, nil): return lhs.raw == rhs.raw
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        // Mirrors `==` exactly so equal values hash equally.
        if let components {
            hasher.combine(0)
            hasher.combine(components)
        } else {
            hasher.combine(1)
            hasher.combine(raw)
        }
    }

    public init(_ string: String) {
        let trimmed = Self.trimWhitespace(string)
        self.raw = trimmed

        var body = trimmed
        if let first = body.first, first == "v" || first == "V",
           let second = body.dropFirst().first, Component.isASCIIDigit(second) {
            body.removeFirst()
        }

        guard body.contains(where: Component.isASCIIDigit) else {
            components = nil // no digits at all: never invent version semantics
            return
        }

        let chunks = body.split(omittingEmptySubsequences: false) { $0 == "." || $0 == "-" }
        var parsed: [Component] = []
        parsed.reserveCapacity(chunks.count)
        for chunk in chunks {
            guard let component = Self.component(from: chunk) else {
                components = nil // e.g. unknown-word-with-digits ("v1", "1x5")
                return
            }
            parsed.append(component)
        }
        components = parsed
    }

    public static func parse(_ string: String) -> AppVersion { AppVersion(string) }

    public func compare(to other: AppVersion) -> VersionOrder {
        switch (components, other.components) {
        case (.some(let mine), .some(let theirs)):
            let count = max(mine.count, theirs.count)
            for index in 0..<count {
                let left = index < mine.count ? mine[index] : Component.zero
                let right = index < theirs.count ? theirs[index] : Component.zero
                let order = left.compare(to: right)
                if order != .equal { return order }
            }
            return .equal
        default:
            // At least one side is unparseable (garbage, empty, or unknown-word
            // chunks): deterministic lexicographic fallback, as documented.
            return Self.lexicographic(raw, other.raw)
        }
    }

    static func lexicographic(_ a: String, _ b: String) -> VersionOrder {
        if a == b { return .equal }
        return a < b ? .less : .greater
    }

    public var description: String {
        // Echo the (trimmed) input. Components are the described form; we do
        // not pretend to re-serialize exactly, since unknown qualifier words
        // collapse into `.plain` and would not round-trip honestly.
        raw
    }

    private static func trimWhitespace(_ s: String) -> String {
        var result = s
        while let first = result.first, first.isWhitespace || first.isNewline { result.removeFirst() }
        while let last = result.last, last.isWhitespace || last.isNewline { result.removeLast() }
        return result
    }

    /// Component grammar: `digits? ( qualifierWord digits? | wordOnly )`.
    /// `digits 228` + `b` → beta alias; `beta7` → beta, seq 7; word-only
    /// unknowns ("plain", "x") → plain rank, ignored. Unknown word WITH digits
    /// ("v1", "1x5"), non-letter bytes ("+", "~"), or compound tails ("b1a")
    /// return nil → the WHOLE string falls back to lexicographic comparison.
    static func component(from chunk: some StringProtocol) -> Component? {
        let characters = Array(chunk)
        var index = 0
        while index < characters.count, Component.isASCIIDigit(characters[index]) {
            index += 1
        }
        let rest = Array(characters[index...]) // fresh array: slices keep absolute indices
        guard !rest.isEmpty else {
            return Component(number: String(characters[..<index]), qualifier: .plain, sequence: "")
        }
        var lettersEnd = 0
        while lettersEnd < rest.count, rest[lettersEnd].isASCII, rest[lettersEnd].isLetter {
            lettersEnd += 1
        }
        guard lettersEnd > 0 else { return nil } // rest starts with a non-letter byte
        let word = String(rest[..<lettersEnd]).lowercased()
        let tailDigits = String(rest[lettersEnd...])
        guard tailDigits.allSatisfy(Component.isASCIIDigit) else { return nil } // compound/compound-tail
        if tailDigits.isEmpty {
            return Component(number: String(characters[..<index]), qualifier: Self.qualifier(for: word), sequence: "")
        }
        guard let known = Self.knownQualifier(for: word) else { return nil } // unknown word WITH digits
        return Component(number: String(characters[..<index]), qualifier: known, sequence: tailDigits)
    }

    static func knownQualifier(for word: String) -> Component.Qualifier? {
        switch word {
        case "alpha", "a": return .alpha
        case "beta", "b": return .beta
        case "rc": return .rc
        default: return nil
        }
    }

    static func qualifier(for word: String) -> Component.Qualifier {
        knownQualifier(for: word) ?? .plain
    }
}
