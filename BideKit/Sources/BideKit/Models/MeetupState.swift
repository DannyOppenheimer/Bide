import Foundation

/// The state of a meetup tile, shared between the container app and the
/// Messages extension via `MSMessage.url` query parameters. The extension
/// can't hold shared memory with the app, so this is the wire format.
public struct MeetupState: Codable, Equatable, Sendable {

    public enum Status: String, Codable, Sendable {
        case proposed
        case accepted
    }

    public let id: UUID
    public let placeName: String
    public let placeAddress: String
    public let latitude: Double
    public let longitude: Double
    /// The proposer's ETA at the moment they sent the tile. Recomputed
    /// on-device by BideKit's ETA engine in the container app — never
    /// derived from a location on the wire.
    public let proposerETAMinutes: Int
    public let accepterETAMinutes: Int?
    public let status: Status

    public init(
        id: UUID = UUID(),
        placeName: String,
        placeAddress: String,
        latitude: Double,
        longitude: Double,
        proposerETAMinutes: Int,
        accepterETAMinutes: Int? = nil,
        status: Status = .proposed
    ) {
        self.id = id
        self.placeName = placeName
        self.placeAddress = placeAddress
        self.latitude = latitude
        self.longitude = longitude
        self.proposerETAMinutes = proposerETAMinutes
        self.accepterETAMinutes = accepterETAMinutes
        self.status = status
    }
}

// MARK: - URL encoding

extension MeetupState {

    private enum QueryKey: String {
        case id, placeName, placeAddress, latitude, longitude
        case proposerETAMinutes, accepterETAMinutes, status
    }

    /// Encodes state as query parameters on a URL so it round-trips through
    /// `MSMessage.url`.
    public func encodedURL(scheme: String = "bide") -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "tile"
        components.queryItems = [
            URLQueryItem(name: QueryKey.id.rawValue, value: id.uuidString),
            URLQueryItem(name: QueryKey.placeName.rawValue, value: placeName),
            URLQueryItem(name: QueryKey.placeAddress.rawValue, value: placeAddress),
            URLQueryItem(name: QueryKey.latitude.rawValue, value: String(latitude)),
            URLQueryItem(name: QueryKey.longitude.rawValue, value: String(longitude)),
            URLQueryItem(name: QueryKey.proposerETAMinutes.rawValue, value: String(proposerETAMinutes)),
            URLQueryItem(name: QueryKey.accepterETAMinutes.rawValue, value: accepterETAMinutes.map(String.init)),
            URLQueryItem(name: QueryKey.status.rawValue, value: status.rawValue),
        ]
        guard let url = components.url else {
            preconditionFailure("MeetupState query items always produce a valid URL")
        }
        return url
    }

    /// Decodes state from the query parameters of an `MSMessage`'s URL.
    /// Returns `nil` if the URL is missing required fields, e.g. a message
    /// sent by a future app version this build doesn't understand.
    public init?(url: URL) {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let items = components.queryItems
        else { return nil }

        func value(_ key: QueryKey) -> String? {
            items.first { $0.name == key.rawValue }?.value
        }

        guard
            let idString = value(.id), let id = UUID(uuidString: idString),
            let placeName = value(.placeName),
            let placeAddress = value(.placeAddress),
            let latitudeString = value(.latitude), let latitude = Double(latitudeString),
            let longitudeString = value(.longitude), let longitude = Double(longitudeString),
            let etaString = value(.proposerETAMinutes), let proposerETAMinutes = Int(etaString),
            let statusString = value(.status), let status = Status(rawValue: statusString)
        else { return nil }

        self.init(
            id: id,
            placeName: placeName,
            placeAddress: placeAddress,
            latitude: latitude,
            longitude: longitude,
            proposerETAMinutes: proposerETAMinutes,
            accepterETAMinutes: value(.accepterETAMinutes).flatMap(Int.init),
            status: status
        )
    }
}

// MARK: - Placeholder data

extension MeetupState {
    /// Hardcoded placeholder used until place search and the on-device ETA
    /// engine are wired up.
    public static let placeholder = MeetupState(
        placeName: "Blue Bottle Coffee",
        placeAddress: "300 Webster St, Oakland, CA",
        latitude: 37.7952,
        longitude: -122.2718,
        proposerETAMinutes: 12,
        status: .proposed
    )
}
