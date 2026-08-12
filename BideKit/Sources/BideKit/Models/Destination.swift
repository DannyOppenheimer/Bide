import CoreLocation

/// Where a bide is headed.
///
/// The one place in Bide where coordinates are a first-class value, and they
/// describe a *place* — somewhere both people agreed on in a text thread —
/// never a person. Nothing in this package models a participant's position.
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
