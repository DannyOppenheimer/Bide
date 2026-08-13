import Foundation

/// One on-device travel estimate anchored at a specific time.
public struct ETAReading: Equatable, Sendable {

    /// When the traveller is expected to arrive.
    public let arrival: Date
    /// Travel duration from the location used for this estimate.
    public let travelTime: TimeInterval
    /// Time at which directions were last calculated.
    public let anchoredAt: Date
    public let mode: TravelMode
    /// Whether on-device movement indicates that the traveller has departed.
    public let hasDeparted: Bool
    /// Whether the traveller is within the destination arrival radius.
    public let hasArrived: Bool

    public init(
        arrival: Date,
        travelTime: TimeInterval,
        anchoredAt: Date = Date(),
        mode: TravelMode,
        hasDeparted: Bool = false,
        hasArrived: Bool = false
    ) {
        self.arrival = arrival
        self.travelTime = travelTime
        self.anchoredAt = anchoredAt
        self.mode = mode
        self.hasDeparted = hasDeparted
        self.hasArrived = hasArrived
    }

    /// Returns the locally counted-down duration remaining until arrival.
    public func remaining(at now: Date = Date()) -> TimeInterval {
        max(0, arrival.timeIntervalSince(now))
    }

    /// Calculates the departure time needed to reach a deadline.
    public func departure(toArriveBy deadline: Date) -> Date {
        deadline.addingTimeInterval(-travelTime)
    }
}

/// Specific reasons an ETA could not be calculated.
public enum ETAError: Error, Equatable, Sendable {

    /// Location permission is unavailable or denied.
    case locationUnavailable

    /// No location fix arrived before the timeout.
    case locationTimedOut

    /// MapKit found no route for the requested mode and endpoints.
    case noRoute

    /// MapKit could not complete the directions request.
    case directionsFailed(String)

    /// The travel mode has no available ETA implementation.
    case unsupportedMode(TravelMode)
}

extension ETAError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .locationUnavailable: "Bide needs your location to work out when to leave."
        case .locationTimedOut: "Couldn't get a location fix. Try again in a moment."
        case .noRoute: "No route for that way of travelling."
        case .directionsFailed: "Couldn't reach Apple Maps for directions."
        case .unsupportedMode(let mode): "\(mode.title) isn't supported yet."
        }
    }
}

/// Computes and tracks ETAs on-device without exposing raw locations.
///
/// It recalculates after route deviation, at each mode's interval, and every
/// minute during the final five minutes.
///
/// Main-actor isolation supports UI callbacks and `CLLocationManager` ownership.
/// The Messages extension uses only one-shot estimates; continuous tracking is app-only.
@MainActor
public protocol ETAEngine: AnyObject {

    /// Produces one estimate without starting continuous tracking.
    func estimate(to destination: Destination, mode: TravelMode) async throws(ETAError) -> ETAReading

    /// Starts continuous tracking and reports each estimate or failure.
    ///
    /// - Parameter scheduledArrival: Used to delay departure detection until the trip is near.
    func startTracking(
        to destination: Destination,
        mode: TravelMode,
        scheduledArrival: Date?,
        onUpdate: @escaping (Result<ETAReading, ETAError>) -> Void
    )

    func stopTracking()
}

/// Fixed-result engine for previews and tests.
@MainActor
public final class StubETAEngine: ETAEngine {

    private let result: Result<ETAReading, ETAError>

    public init(minutes: Int = 12, mode: TravelMode = .walking, hasDeparted: Bool = false) {
        let travelTime = TimeInterval(minutes * 60)
        result = .success(
            ETAReading(
                arrival: Date().addingTimeInterval(travelTime),
                travelTime: travelTime,
                mode: mode,
                hasDeparted: hasDeparted
            )
        )
    }

    public init(failing error: ETAError) {
        result = .failure(error)
    }

    public func estimate(to destination: Destination, mode: TravelMode) async throws(ETAError) -> ETAReading {
        switch result {
        case .success(let reading): return reading
        case .failure(let error): throw error
        }
    }

    public func startTracking(
        to destination: Destination,
        mode: TravelMode,
        scheduledArrival: Date? = nil,
        onUpdate: @escaping (Result<ETAReading, ETAError>) -> Void
    ) {
        onUpdate(result)
    }

    public func stopTracking() {}
}
