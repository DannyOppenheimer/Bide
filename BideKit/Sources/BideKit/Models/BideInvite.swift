import Foundation

/// An invitation to meet somewhere: the immutable facts about a bide, shared
/// between the container app and the Messages extension via `MSMessage.url`
/// query parameters. The extension can't hold shared memory with the app, so
/// this is the wire format — the URL is the only thing that travels.
///
/// That URL is public-facing. On macOS, and on any device without the app
/// installed, Messages shows it to the recipient verbatim and tapping it opens
/// the web, so it is built to be read by a person: see ``webURL()``.
///
/// Deliberately carries no ETA and no location for either participant. ETAs
/// are computed on-device by ``ETAEngine`` in the container app, and the
/// server only ever receives an arrival timestamp.
public struct BideInvite: Codable, Equatable, Hashable, Sendable {

    public let bideID: UUID
    public let destinationName: String
    public let lat: Double
    public let lng: Double

    /// When everyone is due at the destination. `nil` means as soon as
    /// everyone can get there — the design's "asap" — in which case the
    /// arrival time is whatever the slowest accepted person's ETA works out to.
    public let scheduledFor: Date?

    /// Whether everyone aims for ``scheduledFor`` or for each other.
    public let arrivalStyle: ArrivalStyle

    /// When the invite was created, truncated to the millisecond.
    ///
    /// The wire format carries an ISO 8601 timestamp, which resolves to
    /// milliseconds, so the initializer snaps this to what the URL can
    /// actually represent. Without that, an invite and its own decoded copy
    /// would compare unequal for any `Date` taken from the system clock, which
    /// carries finer precision than the format does.
    public let createdAt: Date

    public init(
        bideID: UUID = UUID(),
        destinationName: String,
        lat: Double,
        lng: Double,
        scheduledFor: Date? = nil,
        arrivalStyle: ArrivalStyle = .onTime,
        createdAt: Date = Date()
    ) {
        self.bideID = bideID
        self.destinationName = destinationName
        self.lat = lat
        self.lng = lng
        self.scheduledFor = scheduledFor.map(Self.snappedToWirePrecision)
        self.arrivalStyle = arrivalStyle
        self.createdAt = Self.snappedToWirePrecision(createdAt)
    }
}

// MARK: - URL encoding

extension BideInvite {

    /// The public home of an invite. A tile's `MSMessage.url` points here, so
    /// a recipient without the app still lands somewhere that explains what
    /// they were sent.
    public static let webHost = "trybide.app"
    public static let webPath = "/meet"

    /// Custom scheme used only for the extension's hand-off to the container
    /// app — see ``appURL()``. Never sent to another person.
    public static let appScheme = "bide"
    public static let appHost = "invite"

    /// Exclusive ceiling on the encoded URL, in UTF-8 bytes: an encoded invite
    /// is always *strictly* smaller than this, i.e. under 1KB. The URL is the
    /// entire payload, so ``webURL()`` holds the line by shortening
    /// `destinationName` if it has to.
    public static let maxURLByteCount = 1024

    /// Query keys are words, not abbreviations, because the recipient may read
    /// this URL as text. Ordered destination-first in ``webURL()`` for the same
    /// reason — the useful part should be visible before the line wraps.
    private enum QueryKey: String {
        case destinationName = "to"
        case lat
        case lng
        case scheduledFor = "at"
        case arrivalStyle = "style"
        case createdAt = "t"
        case bideID = "id"
    }

    /// Characters left unescaped in query values.
    ///
    /// RFC 3986 unreserved, plus the sub-delimiters that are legal in a query
    /// and common in place names — `Rudy's`, `Dean, Sons & Co.`, `Bar (Annex)`.
    /// Leaving those readable is the whole point of a user-visible URL.
    ///
    /// Deliberately *not* included: `&` `=` `#` `?` `/` and space, which would
    /// be read as URL syntax; `%`, which would corrupt neighbouring escapes;
    /// `+`, which form-style decoders silently turn into a space; and `;`,
    /// which some servers still treat as a parameter separator.
    private static let queryAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~,:'()!@"
    )

    private static func percentEncoded(_ value: String) -> String {
        // Never nil: the allowed set contains no unpaired surrogates.
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? ""
    }

    // MARK: Timestamps

    /// ISO 8601 in UTC with milliseconds — `2026-08-11T19:43:25.205Z`.
    ///
    /// Readable in the URL, and unambiguous to anything that might parse it
    /// later. `ISO8601DateFormatter` is a class, so it's built per call rather
    /// than cached in a `static` the compiler would have to prove concurrency-safe;
    /// encoding an invite is not a hot path.
    private static func makeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    private static func formatted(_ date: Date) -> String {
        makeFormatter().string(from: date)
    }

    private static func parsed(_ string: String) -> Date? {
        makeFormatter().date(from: string)
    }

    /// Rounds a date to the precision the wire format can carry, by pushing it
    /// through that format. Doing it this way — rather than arithmetic on
    /// milliseconds — guarantees the result is a value the formatter reproduces
    /// exactly, which is what makes encode/decode lossless.
    private static func snappedToWirePrecision(_ date: Date) -> Date {
        parsed(formatted(date)) ?? date
    }

    // MARK: Encoding

    /// The canonical, shareable URL for this invite, on `trybide.app`.
    ///
    /// This is what a tile's `MSMessage.url` carries. It is human-readable on
    /// purpose: Messages on macOS, and any device without the app, shows the
    /// recipient this URL directly, and tapping it reaches a page that names
    /// the destination and explains what Bide is.
    ///
    /// The result is always under ``maxURLByteCount`` bytes. If the encoded
    /// destination name would overrun that, it is cut to the longest prefix
    /// that fits — on whole `Character` boundaries, so a multi-scalar emoji is
    /// dropped entirely rather than split into mojibake. That is the only case
    /// where a round trip is lossy.
    public func webURL() -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.webHost
        components.path = Self.webPath
        return encoded(into: components)
    }

    /// Private hand-off URL, used only when the Messages extension opens the
    /// container app. Accepting a tile means "start counting down my ETA",
    /// which needs CoreLocation and MKDirections — neither of which an .appex
    /// may touch — and a custom scheme reaches the app directly, where an
    /// `https` URL would open Safari until Universal Links are configured.
    public func appURL() -> URL {
        var components = URLComponents()
        components.scheme = Self.appScheme
        components.host = Self.appHost
        return encoded(into: components)
    }

    private func encoded(into components: URLComponents) -> URL {
        // `at` is omitted entirely for an asap bide rather than sent empty, so
        // the absence of a time is unambiguous in a URL a person may read.
        let scheduledItems: [URLQueryItem] = scheduledFor.map {
            [URLQueryItem(name: QueryKey.scheduledFor.rawValue, value: Self.percentEncoded(Self.formatted($0)))]
        } ?? []

        let trailingItems: [URLQueryItem] = [
            URLQueryItem(name: QueryKey.lat.rawValue, value: Self.percentEncoded(String(lat))),
            URLQueryItem(name: QueryKey.lng.rawValue, value: Self.percentEncoded(String(lng))),
        ] + scheduledItems + [
            URLQueryItem(
                name: QueryKey.arrivalStyle.rawValue,
                value: Self.percentEncoded(arrivalStyle.rawValue)
            ),
            URLQueryItem(
                name: QueryKey.createdAt.rawValue,
                value: Self.percentEncoded(Self.formatted(createdAt))
            ),
            URLQueryItem(name: QueryKey.bideID.rawValue, value: Self.percentEncoded(bideID.uuidString)),
        ]

        // Measure everything except the name, then spend what's left on it.
        // The extra byte keeps the total strictly under `maxURLByteCount`.
        let skeleton = Self.url(components, trailingItems: trailingItems, encodedName: "")
        let budget = Self.maxURLByteCount - skeleton.absoluteString.utf8.count - 1
        return Self.url(
            components,
            trailingItems: trailingItems,
            encodedName: Self.encodedName(destinationName, budget: budget)
        )
    }

    /// Percent-encodes `name` one `Character` at a time, stopping before the
    /// first cluster that would not fit in `budget` bytes.
    private static func encodedName(_ name: String, budget: Int) -> String {
        var encoded = ""
        var used = 0
        for character in name {
            let chunk = percentEncoded(String(character))
            let size = chunk.utf8.count
            guard used + size <= budget else { break }
            encoded += chunk
            used += size
        }
        return encoded
    }

    private static func url(
        _ components: URLComponents,
        trailingItems: [URLQueryItem],
        encodedName: String
    ) -> URL {
        var components = components
        // Values are already percent-encoded above, so they go in verbatim;
        // handing them to `queryItems` would double-encode the `%` signs.
        components.percentEncodedQueryItems =
            [URLQueryItem(name: QueryKey.destinationName.rawValue, value: encodedName)] + trailingItems
        guard let url = components.url else {
            preconditionFailure("BideInvite query items always produce a valid URL")
        }
        return url
    }

    // MARK: Decoding

    /// Decodes an invite from either form: the public ``webURL()`` that arrives
    /// on `MSMessage.url`, or the ``appURL()`` the extension hands to the
    /// container app.
    ///
    /// Returns `nil` if the URL isn't a Bide invite or is missing a required
    /// field — e.g. a message sent by a future app version this build doesn't
    /// understand. Callers should fall back to a neutral state rather than
    /// treating that as an error.
    public init?(url: URL) {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            Self.isInviteLocation(components),
            let items = components.percentEncodedQueryItems
        else { return nil }

        func value(_ key: QueryKey) -> String? {
            // `removingPercentEncoding` returns nil on escapes that decode to
            // invalid UTF-8, which is a decode failure.
            items.first { $0.name == key.rawValue }?.value?.removingPercentEncoding
        }

        guard
            let idString = value(.bideID), let bideID = UUID(uuidString: idString),
            let destinationName = value(.destinationName),
            let latString = value(.lat), let lat = Double(latString), lat.isFinite,
            let lngString = value(.lng), let lng = Double(lngString), lng.isFinite,
            let createdAtString = value(.createdAt), let createdAt = Self.parsed(createdAtString)
        else { return nil }

        // Both of these are absent from an asap invite, and from any tile sent
        // by a build that predates them, so neither is allowed to fail the
        // decode. A missing style means the design's default.
        self.init(
            bideID: bideID,
            destinationName: destinationName,
            lat: lat,
            lng: lng,
            scheduledFor: value(.scheduledFor).flatMap(Self.parsed),
            arrivalStyle: value(.arrivalStyle).flatMap(ArrivalStyle.init(rawValue:)) ?? .onTime,
            createdAt: createdAt
        )
    }

    /// Rejects anything that isn't one of our two invite locations, so a
    /// future message kind — or an unrelated link — can't be mis-read as an
    /// invite. The web host is matched case-insensitively because hostnames
    /// are, and a URL typed by hand may not be lowercase.
    private static func isInviteLocation(_ components: URLComponents) -> Bool {
        let scheme = components.scheme?.lowercased()
        let host = components.host?.lowercased()

        if scheme == "https", host == webHost, components.path == webPath {
            return true
        }
        return scheme == appScheme && host == appHost
    }
}
