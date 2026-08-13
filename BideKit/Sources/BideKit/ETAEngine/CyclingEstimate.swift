import CoreLocation
import Foundation

/// Estimates cycling time from walking-route distance because MapKit has no
/// cycling transport type. The conservative speed includes typical stops but
/// cannot account for hills, wind, bike lanes, or unridable shortcuts.
enum CyclingEstimate {

    /// Door-to-door average speed: 4.2 m/s (15.1 km/h).
    static let cruisingSpeed: CLLocationDistance = 4.2

    /// Fixed time for retrieving, unlocking, parking, and locking the bike.
    static let handlingOverhead: TimeInterval = 90

    /// - Parameters:
    ///   - distance: Walking-route length in metres.
    ///   - walkingTime: MapKit's duration for that route on foot.
    static func travelTime(distance: CLLocationDistance, walkingTime: TimeInterval) -> TimeInterval {
        let riding = handlingOverhead + max(0, distance) / cruisingSpeed

        // For very short trips, report the faster walking estimate.
        return min(max(0, walkingTime), riding)
    }
}
