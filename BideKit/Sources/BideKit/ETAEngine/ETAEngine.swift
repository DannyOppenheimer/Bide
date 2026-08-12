import Foundation

/// A single anchored estimate: when you'll get there, and what it was based on.
///
/// The only thing that ever leaves the device is ``arrival`` — an arrival
/// TIMESTAMP. Everything else here stays local.
public struct ETAReading: Equatable, Sendable {

    /// When the traveller is expected to arrive.
    public let arrival: Date
    /// How long the journey takes from where they were when this was anchored.
    public let travelTime: TimeInterval
    /// When this reading was taken, i.e. the last time MKDirections was asked.
    public let anchoredAt: Date
    public let mode: TravelMode
    /// Whether the traveller is already standing at the destination. Decided
    /// inside the engine, where the location is, so that "they're here" can be
    /// reported without the location leaving.
    public let hasArrived: Bool

    public init(
        arrival: Date,
        travelTime: TimeInterval,
        anchoredAt: Date = Date(),
        mode: TravelMode,
        hasArrived: Bool = false
    ) {
        self.arrival = arrival
        self.travelTime = travelTime
        self.anchoredAt = anchoredAt
        self.mode = mode
        self.hasArrived = hasArrived
    }

    /// The countdown between anchors: how long is left as of `now`, without
    /// asking MapKit again.
    public func remaining(at now: Date = Date()) -> TimeInterval {
        max(0, arrival.timeIntervalSince(now))
    }

    /// When someone has to set off to make `arrival` — the "leave at" the
    /// whole product is built around.
    public func departure(toArriveBy deadline: Date) -> Date {
        deadline.addingTimeInterval(-travelTime)
    }
}

/// Why an ETA couldn't be produced. Distinguished so the UI can say something
/// true: a transit route that doesn't exist reads differently from location
/// being switched off.
public enum ETAError: Error, Equatable, Sendable {

    /// The user hasn't granted location access, or has denied it.
    case locationUnavailable

    /// Location is authorised but no fix arrived in time.
    case locationTimedOut

    /// MapKit has no route for this mode between these two points — common for
    /// transit outside covered cities, and for anything across an ocean.
    case noRoute

    /// MapKit refused the request: rate limited, offline, or a server fault.
    case directionsFailed(String)

    /// The mode can't be routed at all. Cycling, flights and trains land here
    /// until they're built.
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

/// Computes and tracks ETAs on-device. Only ever surfaces an arrival
/// TIMESTAMP to callers — never a raw location — per Bide's privacy
/// commitment.
///
/// Anchor-and-countdown policy: call MKDirections once, count down locally,
/// and re-anchor on route deviation, on a timer (5 min driving / 10 min
/// walking), or every 60s inside the final 5 minutes.
///
/// Main-actor bound because it drives UI and owns a `CLLocationManager`. The
/// Messages extension may call ``estimate(to:mode:)`` for the one-shot preview
/// on the tile, but never ``startTracking(to:mode:onUpdate:)`` — continuous
/// tracking is the container app's job.
@MainActor
public protocol ETAEngine: AnyObject {

    /// One reading, right now. Nothing is kept running afterwards.
    func estimate(to destination: Destination, mode: TravelMode) async throws(ETAError) -> ETAReading

    /// Starts anchoring and re-anchoring, calling back on every new reading
    /// and on every failure after the first.
    func startTracking(
        to destination: Destination,
        mode: TravelMode,
        onUpdate: @escaping (Result<ETAReading, ETAError>) -> Void
    )

    func stopTracking()
}

/// Fixed-answer engine for previews and tests. Never touches location or
/// MapKit, so it runs anywhere.
@MainActor
public final class StubETAEngine: ETAEngine {

    private let result: Result<ETAReading, ETAError>

    public init(minutes: Int = 12, mode: TravelMode = .walking) {
        let travelTime = TimeInterval(minutes * 60)
        result = .success(
            ETAReading(arrival: Date().addingTimeInterval(travelTime), travelTime: travelTime, mode: mode)
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
        onUpdate: @escaping (Result<ETAReading, ETAError>) -> Void
    ) {
        onUpdate(result)
    }

    public func stopTracking() {}
}
