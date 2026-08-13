import CoreLocation

/// A named meeting place. These coordinates never represent a participant's location.
public struct Destination: Equatable, Sendable, Hashable {

    public let name: String
    public let latitude: Double
    public let longitude: Double

    public init(name: String, latitude: Double, longitude: Double) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }

    public init(name: String, coordinate: CLLocationCoordinate2D) {
        self.init(name: name, latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    /// Radius within which two records count as the same meeting place.
    /// One venue has several map entries whose coordinates disagree by a block.
    public static let samePlaceRadius: CLLocationDistance = 100

    /// Whether two destinations describe one meeting place.
    /// Compared by distance rather than name, which varies by search result.
    public func isSamePlace(as other: Destination) -> Bool {
        location.distance(from: other.location) <= Self.samePlaceRadius
    }
}

extension BideInvite {
    public var destination: Destination {
        Destination(name: destinationName, latitude: lat, longitude: lng)
    }
}

extension BideState {
    public var destination: Destination {
        Destination(name: destinationName, latitude: lat, longitude: lng)
    }
}
