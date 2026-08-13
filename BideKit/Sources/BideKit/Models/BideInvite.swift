import Foundation

/// Immutable invitation data encoded in the URL shared by the app and Messages extension.
/// Participant locations and ETAs are intentionally excluded from the payload.
public struct BideInvite: Codable, Equatable, Hashable, Sendable {

    public let bideID: UUID
    public let destinationName: String
    public let lat: Double
    public let lng: Double

    /// Target arrival time. `nil` means as soon as all participants can arrive.
    public let scheduledFor: Date?

    /// Whether departures target the schedule or a shared arrival time.
    public let arrivalStyle: ArrivalStyle

    /// Creation time rounded to the wire format's millisecond precision.
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

extension BideInvite {

    /// When this invitation stops describing anything that can still happen.
    /// Uses ``BideState/lifetime`` so a tile and its session end together.
    public var endsAt: Date {
        (scheduledFor ?? createdAt).addingTimeInterval(BideState.lifetime)
    }

    /// Whether the meetup has ended, derived locally because transcript tiles
    /// cannot fetch server state.
    public func hasEnded(now: Date = Date()) -> Bool { now >= endsAt }
}

// MARK: - URL encoding

extension BideInvite {

    /// Public destination for invitation and tracking links.
    public static let webHost = "trybide.app"
    public static let webPath = "/trip"

    /// Legacy path accepted for previously sent invitations but never emitted.
    static let legacyWebPath = "/meet"

    /// Custom scheme used only to hand an invitation from the extension to the app.
    public static let appScheme = "bide"
    public static let appHost = "invite"

    /// Exclusive UTF-8 byte limit for an encoded invitation URL.
    public static let maxURLByteCount = 1024

    /// Human-readable query keys for the public-facing URL.
    private enum QueryKey: String {
        case destinationName = "to"
        case lat
        case lng
        case scheduledFor = "at"
        case arrivalStyle = "style"
        case createdAt = "t"
        case bideID = "id"
    }

    /// RFC 3986 query-safe characters, plus readable punctuation used in place names.
    /// URL delimiters, `%`, `+`, and `;` remain escaped to avoid ambiguous parsing.
    private static let queryAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~,:'()!@"
    )

    private static func percentEncoded(_ value: String) -> String {
        // Encoding cannot fail for this allowed character set.
        value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? ""
    }

    // MARK: Timestamps

    /// Creates a UTC ISO 8601 formatter with millisecond precision.
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

    /// Rounds a date by encoding and decoding it with the wire formatter.
    private static func snappedToWirePrecision(_ date: Date) -> Date {
        parsed(formatted(date)) ?? date
    }

    // MARK: Encoding

    /// Returns the canonical public URL, truncating the destination on character
    /// boundaries when needed to remain under ``maxURLByteCount``.
    public func webURL() -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.webHost
        components.path = Self.webPath
        return encoded(into: components)
    }

    /// Returns the private URL used to hand the invitation to the container app.
    public func appURL() -> URL {
        var components = URLComponents()
        components.scheme = Self.appScheme
        components.host = Self.appHost
        return encoded(into: components)
    }

    private func encoded(into components: URLComponents) -> URL {
        // Omit `at` for an unscheduled invitation instead of encoding an empty value.
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

        // Reserve the remaining byte budget for the destination name.
        let skeleton = Self.url(components, trailingItems: trailingItems, encodedName: "")
        let budget = Self.maxURLByteCount - skeleton.absoluteString.utf8.count - 1
        return Self.url(
            components,
            trailingItems: trailingItems,
            encodedName: Self.encodedName(destinationName, budget: budget)
        )
    }

    /// Encodes complete characters until the byte budget is exhausted.
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
        // Assign pre-encoded values directly to avoid double-encoding `%`.
        components.percentEncodedQueryItems =
            [URLQueryItem(name: QueryKey.destinationName.rawValue, value: encodedName)] + trailingItems
        guard let url = components.url else {
            preconditionFailure("BideInvite query items always produce a valid URL")
        }
        return url
    }

    // MARK: Decoding

    /// Decodes an invitation from its public or app URL.
    /// Returns `nil` for unrelated URLs or missing required fields.
    public init?(url: URL) {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            Self.isInviteLocation(components),
            let items = components.percentEncodedQueryItems
        else { return nil }

        func value(_ key: QueryKey) -> String? {
            // Invalid UTF-8 escapes fail decoding.
            items.first { $0.name == key.rawValue }?.value?.removingPercentEncoding
        }

        guard
            let idString = value(.bideID), let bideID = UUID(uuidString: idString),
            let destinationName = value(.destinationName),
            let latString = value(.lat), let lat = Double(latString), lat.isFinite,
            let lngString = value(.lng), let lng = Double(lngString), lng.isFinite,
            let createdAtString = value(.createdAt), let createdAt = Self.parsed(createdAtString)
        else { return nil }

        // Time and style are optional for unscheduled and legacy invitations.
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

    /// Validates the public and app URL locations accepted for invitations.
    private static func isInviteLocation(_ components: URLComponents) -> Bool {
        let scheme = components.scheme?.lowercased()
        let host = components.host?.lowercased()

        if scheme == "https", host == webHost,
           components.path == webPath || components.path == legacyWebPath {
            return true
        }
        return scheme == appScheme && host == appHost
    }
}
