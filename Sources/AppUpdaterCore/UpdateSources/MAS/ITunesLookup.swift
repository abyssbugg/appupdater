import Foundation

/// Codables for the real iTunes lookup endpoint shape —
/// `https://itunes.apple.com/lookup?bundleId=…&country=…`:
/// an envelope of `resultCount` + `results`, each result carrying App Store JSON field
/// names verbatim (`bundleId`, `trackId`, `version`, `minimumOsVersion`, …).
/// Apple omits fields freely and adds extras freely, so every declared field is a
/// tolerant optional and unknown keys are ignored by the compiler-generated decoder.
public struct ITunesLookupResponse: Codable, Hashable, Sendable {
    public var resultCount: Int
    public var results: [ITunesResult]

    public init(resultCount: Int, results: [ITunesResult]) {
        self.resultCount = resultCount
        self.results = results
    }
}

/// One app entry in a lookup response. Only the fields we map are declared.
public struct ITunesResult: Codable, Hashable, Sendable {
    public var bundleId: String?
    public var trackName: String?
    /// The human/short version shown in the App Store (the key the lookup calls `version`).
    public var version: String?
    /// Lookup payloads frequently omit a separate bundle-version key; tolerated as nil and
    /// (per the phase brief) never mapped into `UpdateInfo.newestBundleVersion`.
    public var bundleVersion: String?
    public var minimumOsVersion: String?
    public var trackId: Int64?
    /// Raw release-date string of the current track version — modern payloads are ISO 8601,
    /// legacy/alternate renderings are RFC 822-ish. Use `parsedCurrentVersionReleaseDate`.
    public var currentVersionReleaseDate: String?
    public var releaseNotes: String?
    /// App Store web page of the app — a viewing URL, deliberately NOT treated as a download URL.
    public var trackViewUrl: String?

    public init(
        bundleId: String? = nil,
        trackName: String? = nil,
        version: String? = nil,
        bundleVersion: String? = nil,
        minimumOsVersion: String? = nil,
        trackId: Int64? = nil,
        currentVersionReleaseDate: String? = nil,
        releaseNotes: String? = nil,
        trackViewUrl: String? = nil
    ) {
        self.bundleId = bundleId
        self.trackName = trackName
        self.version = version
        self.bundleVersion = bundleVersion
        self.minimumOsVersion = minimumOsVersion
        self.trackId = trackId
        self.currentVersionReleaseDate = currentVersionReleaseDate
        self.releaseNotes = releaseNotes
        self.trackViewUrl = trackViewUrl
    }
}

public extension ITunesResult {
    /// Tolerant parse of `currentVersionReleaseDate`:
    /// 1. ISO 8601 (`2026-03-14T09:41:33Z`, with or without fractional seconds) — primary form.
    /// 2. RFC-822-ish fallbacks (`Thu, 05 Mar 2026 09:41:33 GMT` / `2026-03-14 09:41:33 +0000`).
    /// nil when the key is absent or unparsable — a release date is an optional claim anyway.
    /// Formatters are built per call: Foundation formatters are not safe as shared static state.
    var parsedCurrentVersionReleaseDate: Date? {
        guard let raw = currentVersionReleaseDate, !raw.isEmpty else { return nil }

        if let iso = parseISO8601(raw) { return iso }

        // Fallbacks for the RFC-822-ish renderings Apple has historically shipped.
        // " GMT" is normalized to a numeric offset so one format string covers both spellings.
        for normalized in [raw, raw.replacingOccurrences(of: " GMT", with: " +0000")] {
            for format in ["EEE, d MMM yyyy HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss Z"] {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(identifier: "UTC")
                formatter.dateFormat = format
                if let date = formatter.date(from: normalized) { return date }
            }
        }
        return nil
    }

    private func parseISO8601(_ raw: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: raw) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw)
    }
}

/// Failure modes of the lookup client itself (decode failures from the current shape of the
/// endpoint surface as `DecodingError`, transport failures as `URLError`).
public enum ITunesLookupError: Error, Sendable {
    case invalidURL(bundleIdentifier: String)
}

/// Lookup client. Trivial by design: one GET + one decode, under the pinned v1 policy —
/// HTTPS only, `country=us`, UA `AppUpdater/0.1 (macOS)`. The URLSession is injectable so
/// tests stay hermetic (custom URLProtocol stub, zero network).
public struct ITunesLookupClient: Sendable {
    public static let userAgent = "AppUpdater/0.1 (macOS)"

    /// v1 lock: pinned to the US storefront so "newest version" always reads from one
    /// consistent catalog (regional lookups can differ). Revisit with the owner before
    /// any localization work.
    public let country: String
    public let session: URLSession

    public init(session: URLSession = .shared, country: String = "us") {
        self.session = session
        self.country = country
    }

    /// Builds the lookup URL; `URLComponents` percent-encodes the bundle id properly.
    public static func lookupURL(bundleIdentifier: String, country: String = "us") -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleIdentifier),
            URLQueryItem(name: "country", value: country),
        ]
        return components?.url
    }

    public func lookup(bundleIdentifier: String) async throws -> ITunesLookupResponse {
        try await lookup(bundleIdentifier: bundleIdentifier, country: self.country)
    }

    public func lookup(bundleIdentifier: String, country: String) async throws -> ITunesLookupResponse {
        guard let url = Self.lookupURL(bundleIdentifier: bundleIdentifier, country: country) else {
            throw ITunesLookupError.invalidURL(bundleIdentifier: bundleIdentifier)
        }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        // Non-2xx statuses are deliberately not translated: a 200-with-HTML error page fails
        // at decode (thrown), keeping "malformed payload" a single documented failure mode.
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(ITunesLookupResponse.self, from: data)
    }
}
