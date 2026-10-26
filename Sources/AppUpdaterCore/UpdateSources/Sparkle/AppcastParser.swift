import Foundation

// MARK: - Parsed item model

/// One parsed `<channel><item>` from a Sparkle appcast (RSS 2.0 + the `sparkle:` namespace).
/// Field-preserving: nothing is embellished here; `SparkleSource` decides honesty/policy.
struct SparkleAppcastItem: Sendable, Hashable {
    /// `sparkle:version` on the enclosure (CFBundleVersion-style). Nil ⇒ item is untrusted (see parser docs).
    var sparkleVersion: String?
    /// `sparkle:shortVersionString` on the enclosure (CFBundleShortVersionString-style).
    var shortVersionString: String?
    /// Enclosure `url` attribute, resolved as a URL when absolute.
    var enclosureURL: URL?
    /// `sparkle:edSignature` attribute on the enclosure (Ed25519 signature over the artifact).
    var edSignature: String?
    /// `sparkle:criticalUpdate` element present on the item.
    var criticalUpdate: Bool
    /// Item-level `sparkle:minimumSystemVersion`, else the channel-level fallback (nil if neither).
    var minimumSystemVersion: String?
    /// `sparkle:channel` attribute (e.g. "beta"); nil means the default channel.
    var channel: String?
    /// Parsed `pubDate`, or nil when absent/unparseable (kept honest — no fake date invented).
    var pubDate: Date?
    /// `sparkle:releaseNotesLink` text, else the item `<description>` HTML, stored as-given.
    var releaseNotes: String?
}

// MARK: - Parser

/// Foundation `XMLParser` (SAX) parser for Sparkle appcasts.
///
/// Sparkle namespace URIs accepted (Sparkle 2 current + Sparkle 1.x legacy + very old legacy):
/// `http://www.sparkle-project.org/xml/sparkle/2008`, `http://www.andymatuschak.org/xml/sparkle/2008`,
/// `http://www.andymatuschak.org/xml/sparkle/2006`, or any URI prefixed with either
/// `http://www.sparkle-project.org/xml/sparkle` / `http://www.andymatuschak.org/xml/sparkle`.
/// Strictly unnamespaced sparkle fields are out of spec and ignored; the RSS-native
/// `channel`/`item`/`pubDate`/`description`/`enclosure` elements are read regardless of namespace.
///
/// Documented rules of the whole sparkle source stack:
/// - **Untrusted items are skipped**: a feed item carrying no `sparkle:version` cannot be ordered
///   against the installed version, so it is untrusted and never selected (Sparkle 2 requires the field).
/// - **Channel policy (v1)**: the enclosure's `sparkle:channel` attribute must be absent (⇒ default)
///   or exactly "default". Beta/opt-in channel support is deliberately deferred.
/// - `minimumSystemVersion`: item-level wins, channel-level `sparkle:minimumSystemVersion` is the fallback.
/// - `criticalUpdate` may appear as the `sparkle:criticalUpdate` element or as the same-named
///   namespaced attribute on the enclosure (older feeds).
/// - Malformed XML: items already closed before the error are kept; `parseError` carries the
///   remaining truth for callers that want to react to a partially-broken feed.
enum AppcastParser {
    /// Parse an appcast body into channel items, in feed order, plus the XML parsing error if any.
    /// The SAX collector is created, driven, and consumed wholly inside this synchronous call —
    /// its mutable state never escapes, so no actor-isolation machinery is required.
    static func parse(data: Data) -> (items: [SparkleAppcastItem], parseError: Error?) {
        let collector = Collector()
        let parser = XMLParser(data: data)
        // Namespace processing: makes element callbacks carry namespaceURI and fires the
        // prefix->URI mapping callbacks. (Toolchain note: this Foundation port has no
        // `shouldReportNamespaces` API; `shouldProcessNamespaces` is the supported knob.)
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        let ok = parser.parse()
        let items = collector.finish()
        return (items, ok ? nil : parser.parserError)
    }

    /// Select the newest eligible item.
    ///
    /// - Eligible = non-empty `sparkle:version` AND default channel (absent or "default").
    /// - With an installed `bundleVersion`: the newest eligible item STRICTLY newer wins.
    ///   Nothing newer ⇒ nil (no inflated "update available" claim).
    /// - Without installed version info (documented compromise): the single newest-looking
    ///   eligible item is returned, letting the engine show a candidate for an unknown install.
    /// - Ties (equal version): newer pubDate wins; equal/unknown dates ⇒ first item in feed order.
    static func selectNewest(
        from items: [SparkleAppcastItem],
        installedBundleVersion: String?
    ) -> SparkleAppcastItem? {
        let eligible = items.filter { item in
            guard let version = item.sparkleVersion, !version.isEmpty else { return false }  // untrusted
            return isDefaultChannel(item.channel)
        }
        guard !eligible.isEmpty else { return nil }

        let installed = installedBundleVersion?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidates = installed.isEmpty
            ? eligible
            : eligible.filter { SparkleVersionComparator.isNewerVersion($0.sparkleVersion!, than: installed) }
        guard let first = candidates.first else { return nil }

        var winner = first
        for candidate in candidates.dropFirst() {
            let comparison = SparkleVersionComparator.compare(candidate.sparkleVersion!, winner.sparkleVersion!)
            if comparison > 0 {
                winner = candidate
            } else if comparison == 0,
                      (candidate.pubDate ?? .distantPast) > (winner.pubDate ?? .distantPast) {
                winner = candidate
            }
        }
        return winner
    }

    static func isDefaultChannel(_ channel: String?) -> Bool {
        guard let channel, !channel.isEmpty else { return true }
        return channel.lowercased() == "default"
    }

    // MARK: sparkle namespace resolution

    static let sparkleNamespaceURIs: Set<String> = [
        "http://www.sparkle-project.org/xml/sparkle/2008",  // Sparkle 2
        "http://www.andymatuschak.org/xml/sparkle/2008",    // Sparkle 1.x
        "http://www.andymatuschak.org/xml/sparkle/2006",    // very old legacy feeds
    ]

    static func isSparkleNamespace(_ uri: String?) -> Bool {
        guard let uri, !uri.isEmpty else { return false }
        if sparkleNamespaceURIs.contains(uri) { return true }
        return uri.hasPrefix("http://www.sparkle-project.org/xml/sparkle")
            || uri.hasPrefix("http://www.andymatuschak.org/xml/sparkle")
    }

    // MARK: pubDate parsing (tolerant; unparseable ⇒ nil, honestly)

    /// Tolerant formats seen in real appcasts: RFC 822 with/without weekday, 1- or 2-digit day,
    /// two-digit-year variant, and an ISO-8601 fallback. Formatters are created per call
    /// (no shared mutable formatter state) — deliberately safe under Swift 6 concurrency.
    static func parseAppcastDate(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEEE, dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yy HH:mm:ss Z",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

// MARK: - SAX collector (state confined to one synchronous parse call)

/// Collector state. Constructed and used synchronously inside `AppcastParser.parse(data:)`; the
/// instance never escapes that call. Mutable state here is the documented pattern for XMLParser
/// delegate work under Swift 6 strict concurrency (delegate APIs are nonisolated).
private final class Collector: NSObject, XMLParserDelegate {
    struct RawItem {
        var sparkleVersion: String?
        var shortVersionString: String?
        var enclosureURL: URL?
        var edSignature: String?
        var criticalUpdate = false
        var itemMinimumSystem: String?
        var channel: String?
        var pubDateRaw: String?
        var releaseNotesLink: String?
        var descriptionHTML: String?
    }

    private(set) var rawItems: [RawItem] = []
    private(set) var channelMinimumSystem: String?

    private var prefixURIs: [String: String] = [:]
    private var current: RawItem?
    private var channelDepth = 0
    private var insideItem = false
    private var capture: CaptureKind?
    private var buffer = ""

    private enum CaptureKind {
        case itemMinimumSystem
        case channelMinimumSystem
        case itemPubDate
        case itemReleaseNotesLink
        case itemDescriptionHTML
    }

    func finish() -> [SparkleAppcastItem] {
        rawItems.map { raw in
            SparkleAppcastItem(
                sparkleVersion: trimmed(raw.sparkleVersion),
                shortVersionString: trimmed(raw.shortVersionString),
                enclosureURL: raw.enclosureURL,
                edSignature: trimmed(raw.edSignature),
                criticalUpdate: raw.criticalUpdate,
                minimumSystemVersion: trimmed(raw.itemMinimumSystem) ?? trimmed(channelMinimumSystem),
                channel: trimmed(raw.channel),
                pubDate: raw.pubDateRaw.flatMap(AppcastParser.parseAppcastDate),
                releaseNotes: trimmed(raw.releaseNotesLink)
                    ?? (raw.descriptionHTML?.isEmpty == false ? raw.descriptionHTML : nil)
            )
        }
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        prefixURIs[prefix] = namespaceURI
    }

    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
        prefixURIs.removeValue(forKey: prefix)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let isRSSPlain = namespaceURI == nil || namespaceURI?.isEmpty == true

        // Track channel scope (RSS `channel`/`item` are namespace-free in well-formed feeds).
        if isRSSPlain, elementName == "channel" {
            channelDepth += 1
        }

        if isRSSPlain, elementName == "item", channelDepth > 0, !insideItem {
            current = RawItem()
            insideItem = true
            return
        }

        // Channel-level sparkle:minimumSystemVersion fallback (outside any item).
        if !insideItem, channelDepth > 0,
           AppcastParser.isSparkleNamespace(namespaceURI), elementName == "minimumSystemVersion" {
            capture = .channelMinimumSystem
            buffer = ""
            return
        }

        guard insideItem, var item = current else { return }

        if elementName == "enclosure" {
            if let url = attributeDict["url"], !url.isEmpty {
                item.enclosureURL = URL(string: url)
            }
            applySparkleAttributes(attributeDict, into: &item)
            current = item
            return
        }

        switch (AppcastParser.isSparkleNamespace(namespaceURI), elementName, isRSSPlain) {
        case (true, "criticalUpdate", _):
            item.criticalUpdate = true
            current = item
        case (true, "minimumSystemVersion", _):
            if item.itemMinimumSystem == nil {
                capture = .itemMinimumSystem
                buffer = ""
            }
            current = item
        case (true, "releaseNotesLink", _):
            if item.releaseNotesLink == nil {
                capture = .itemReleaseNotesLink
                buffer = ""
            }
            current = item
        case (_, "pubDate", true):
            if item.pubDateRaw == nil {
                capture = .itemPubDate
                buffer = ""
            }
            current = item
        case (_, "description", true):
            // RSS-native `<description>` inside the item: capture the HTML as-given.
            // Nested sub-elements keep the capture open so their text accumulates too.
            if item.descriptionHTML == nil {
                capture = .itemDescriptionHTML
                buffer = ""
            }
            current = item
        default:
            current = item
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capture != nil { buffer += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard capture != nil, let text = String(data: CDATABlock, encoding: .utf8) else { return }
        buffer += text
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let isRSSPlain = namespaceURI == nil || namespaceURI?.isEmpty == true

        // Flush a capture only when its OWN element closes; nested sub-elements (e.g. a rich
        // <description> with inline tags) pass through so their text keeps accumulating.
        if let kind = capture, captureMatches(kind, elementName, isRSSPlain: isRSSPlain) {
            let text = buffer
            buffer = ""
            capture = nil
            switch kind {
            case .channelMinimumSystem:
                if channelMinimumSystem == nil {
                    channelMinimumSystem = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case .itemMinimumSystem:
                if var item = current, item.itemMinimumSystem == nil {
                    item.itemMinimumSystem = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    current = item
                }
            case .itemPubDate:
                if var item = current, item.pubDateRaw == nil {
                    item.pubDateRaw = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    current = item
                }
            case .itemReleaseNotesLink:
                if var item = current, item.releaseNotesLink == nil {
                    item.releaseNotesLink = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    current = item
                }
            case .itemDescriptionHTML:
                if var item = current, item.descriptionHTML == nil {
                    item.descriptionHTML = text  // as-given, deliberately untrimmed
                    current = item
                }
            }
        }

        if isRSSPlain, elementName == "item", insideItem {
            insideItem = false
            capture = nil
            if let finished = current {
                rawItems.append(finished)
            }
            current = nil
        }
        if isRSSPlain, elementName == "channel" {
            channelDepth = max(0, channelDepth - 1)
        }
    }

    private func captureMatches(_ kind: CaptureKind, _ elementName: String, isRSSPlain: Bool) -> Bool {
        switch kind {
        case .itemMinimumSystem, .channelMinimumSystem:
            // Both flavours close on the same local name; scope was fixed at capture start.
            return elementName == "minimumSystemVersion"
        case .itemPubDate:
            return elementName == "pubDate" && isRSSPlain
        case .itemReleaseNotesLink:
            return elementName == "releaseNotesLink"
        case .itemDescriptionHTML:
            return elementName == "description" && isRSSPlain
        }
    }

    // MARK: sparkle attribute resolution

    /// Attribute keys arrive prefixed ("sparkle:version") with no URI parameter, so the prefix is
    /// resolved through the mapping callbacks. Tolerances (both documented, deliberately narrow):
    /// - If the document never mapped the used prefix to a URI (out-of-spec feed) but the prefix is
    ///   exactly "sparkle", treat it as sparkle anyway — the conventional de-facto prefix.
    /// - Unprefixed attribute keys whose name exactly matches a sparkle field on the enclosure are
    ///   accepted; on this one element the names are unambiguous (url/length/type are the only
    ///   RSS-native enclosure attributes and never collide).
    private func applySparkleAttributes(_ attributes: [String: String], into item: inout RawItem) {
        let sparkleFieldNames: Set<String> = [
            "version", "shortVersionString", "edSignature", "channel", "criticalUpdate",
        ]
        for (key, value) in attributes {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            let localName: String
            let resolvedIsSparkle: Bool
            if parts.count == 2 {
                let prefix = parts[0]
                localName = parts[1]
                let uri = prefixURIs[prefix]
                resolvedIsSparkle = AppcastParser.isSparkleNamespace(uri) || (uri == nil && prefix == "sparkle")
            } else {
                localName = key
                resolvedIsSparkle = sparkleFieldNames.contains(key)
            }
            guard resolvedIsSparkle, !value.isEmpty else { continue }

            switch localName {
            case "version":
                if item.sparkleVersion == nil { item.sparkleVersion = value }
            case "shortVersionString":
                if item.shortVersionString == nil { item.shortVersionString = value }
            case "edSignature":
                if item.edSignature == nil { item.edSignature = value }
            case "channel":
                if item.channel == nil { item.channel = value }
            case "criticalUpdate":
                item.criticalUpdate = true  // legacy attribute form alongside the element form
            default:
                break
            }
        }
    }
}

// MARK: - Temporary version comparator

// TODO(merge): replace with VersionOracle after lanes merge.
//
/// Minimal numeric-aware dot comparator — this lane's MUST-level minimum (e.g. "1.10" > "1.2").
/// Known limitations (documented, intentionally not fixed here):
/// - Dot segments that parse fully-numeric compare numerically; others compare lexically
///   (case-insensitive).
/// - A numeric segment beats a non-numeric one at the same position, Sparkle-style
///   release-beats-prerelease ("1.2" > "1.2a4"); no deeper prerelease alphabet ordering.
/// - Missing trailing segments pad as numeric 0, so "1.2" == "1.2.0".
/// Mixed-format comparisons ("2200" vs "2.2.0") degrade gracefully but are NOT phase-accurate —
/// that nuance is exactly what VersionOracle must own.
enum SparkleVersionComparator {
    static func isNewerVersion(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) > 0
    }

    /// -1, 0, or +1 comparison of two version strings.
    static func compare(_ lhs: String, _ rhs: String) -> Int {
        let left = segments(lhs), right = segments(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : Segment.numeric(0)
            let r = index < right.count ? right[index] : Segment.numeric(0)
            switch (l, r) {
            case let (.numeric(a), .numeric(b)):
                if a < b { return -1 }
                if a > b { return 1 }
            case let (.text(a), .text(b)):
                let ordering = a.compare(b, options: .caseInsensitive)
                if ordering == .orderedAscending { return -1 }
                if ordering == .orderedDescending { return 1 }
            case (.numeric, .text):
                return 1   // numeric position beats prerelease-style text
            case (.text, .numeric):
                return -1
            }
        }
        return 0
    }

    private enum Segment: Equatable {
        case numeric(Int)
        case text(String)
    }

    private static func segments(_ version: String) -> [Segment] {
        version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".").map { piece -> Segment in
                let plain = String(piece)
                return Int(plain).map(Segment.numeric) ?? .text(plain)
            }
    }
}
