import CoreLocation
import MapKit

/// The real ETA engine: Apple Maps for the estimate, a local clock for the
/// countdown between estimates.
///
/// Anchor-and-countdown, per CLAUDE.md. MKDirections is asked once, and the
/// resulting ``ETAReading`` is good until one of three things re-anchors it:
///
/// 1. the traveller drifts off the route MapKit gave us,
/// 2. the mode's timer elapses — 5 minutes driving or on transit, 10 walking,
/// 3. we're inside the last five minutes, where it re-anchors every 60s
///    because that's when a minute of error actually matters.
///
/// Asking continuously instead would be both rate-limited by Apple and a
/// battery problem, and would tell us nothing a countdown doesn't.
@MainActor
public final class MapKitETAEngine: ETAEngine {

    /// How far off the planned route counts as "they've gone a different way".
    private static let routeDeviationThreshold: CLLocationDistance = 80

    /// Inside this much of arrival, re-anchor on the fast cadence.
    private static let finalApproach: TimeInterval = 5 * 60
    private static let finalApproachCadence: TimeInterval = 60

    /// Close enough to the destination to call it arrived.
    private static let arrivalRadius: CLLocationDistance = 75

    private let locations: any LocationProviding

    private var destination: Destination?
    private var mode: TravelMode = .walking
    private var onUpdate: ((Result<ETAReading, ETAError>) -> Void)?

    /// The route the current anchor was computed from, kept only to measure
    /// deviation. Nil for transit, which MapKit gives an ETA for but no route.
    private var route: MKRoute?
    private var latest: ETAReading?
    private var anchorTask: Task<Void, Never>?
    private var reanchorTask: Task<Void, Never>?

    public init(locations: any LocationProviding) {
        self.locations = locations
    }

    // MARK: - One-shot

    public func estimate(to destination: Destination, mode: TravelMode) async throws(ETAError) -> ETAReading {
        guard mode.isSelectable else { throw ETAError.unsupportedMode(mode) }
        let origin = try await locations.currentLocation()
        return try await Self.anchor(from: origin, to: destination, mode: mode).reading
    }

    // MARK: - Tracking

    public func startTracking(
        to destination: Destination,
        mode: TravelMode,
        onUpdate: @escaping (Result<ETAReading, ETAError>) -> Void
    ) {
        stopTracking()

        self.destination = destination
        self.mode = mode
        self.onUpdate = onUpdate

        locations.requestAuthorization()
        reanchor()

        // Location updates are only ever read here, to answer two questions:
        // has this person left the route, and are they there yet. Neither the
        // location nor anything derived from it beyond those answers leaves
        // this object.
        locations.startUpdates { [weak self] location in
            self?.handle(location)
        }
    }

    public func stopTracking() {
        anchorTask?.cancel()
        reanchorTask?.cancel()
        anchorTask = nil
        reanchorTask = nil
        locations.stopUpdates()
        destination = nil
        onUpdate = nil
        route = nil
        latest = nil
    }

    // MARK: - Anchoring

    private func reanchor() {
        guard let destination, let onUpdate else { return }
        let mode = mode

        anchorTask?.cancel()
        anchorTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard mode.isSelectable else { throw ETAError.unsupportedMode(mode) }
                let origin = try await locations.currentLocation()
                let anchored = try await Self.anchor(from: origin, to: destination, mode: mode)
                guard !Task.isCancelled else { return }
                route = anchored.route
                latest = anchored.reading
                onUpdate(.success(anchored.reading))
                scheduleNextAnchor(after: cadence(for: anchored.reading))
            } catch let error as ETAError {
                guard !Task.isCancelled else { return }
                onUpdate(.failure(error))
                // Keep trying on the slow cadence rather than going silent: a
                // tunnel or a flaky network shouldn't end the countdown.
                scheduleNextAnchor(after: mode.reanchorInterval)
            } catch {
                guard !Task.isCancelled else { return }
                onUpdate(.failure(.directionsFailed(String(describing: error))))
                scheduleNextAnchor(after: mode.reanchorInterval)
            }
        }
    }

    /// How long to wait before the next anchor — the mode's normal cadence,
    /// or every minute once arrival is close.
    private func cadence(for reading: ETAReading) -> TimeInterval {
        reading.remaining() <= Self.finalApproach ? Self.finalApproachCadence : mode.reanchorInterval
    }

    private func scheduleNextAnchor(after interval: TimeInterval) {
        reanchorTask?.cancel()
        reanchorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            self?.reanchor()
        }
    }

    /// Called on every location update. Cheap by design — it re-anchors only
    /// when the route says the old answer is stale.
    private func handle(_ location: CLLocation) {
        guard let destination, let latest else { return }

        if location.distance(from: destination.location) <= Self.arrivalRadius {
            guard !latest.hasArrived else { return }
            let arrived = ETAReading(
                arrival: Date(),
                travelTime: 0,
                mode: mode,
                hasArrived: true
            )
            self.latest = arrived
            onUpdate?(.success(arrived))
            return
        }

        guard mode.tracksRouteDeviation, let route else { return }
        if Self.distance(from: location, to: route.polyline) > Self.routeDeviationThreshold {
            reanchor()
        }
    }

    // MARK: - MapKit

    private struct Anchored {
        let reading: ETAReading
        let route: MKRoute?
    }

    private static func anchor(
        from origin: CLLocation,
        to destination: Destination,
        mode: TravelMode
    ) async throws(ETAError) -> Anchored {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
        request.transportType = try transportType(for: mode)
        request.departureDate = Date()

        // Transit has no followable route — MapKit will answer "how long" but
        // not "which way" — so it takes the ETA-only path.
        if mode == .transit {
            let response = try await calculateETA(MKDirections(request: request))
            return Anchored(
                reading: ETAReading(
                    arrival: response.expectedArrivalDate,
                    travelTime: response.expectedTravelTime,
                    mode: mode
                ),
                route: nil
            )
        }

        let response = try await calculateRoute(MKDirections(request: request))
        guard let route = response.routes.min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) else {
            throw ETAError.noRoute
        }
        return Anchored(
            reading: ETAReading(
                arrival: Date().addingTimeInterval(route.expectedTravelTime),
                travelTime: route.expectedTravelTime,
                mode: mode
            ),
            route: route
        )
    }

    private static func transportType(for mode: TravelMode) throws(ETAError) -> MKDirectionsTransportType {
        switch mode {
        case .walking: .walking
        case .driving: .automobile
        case .transit: .transit
        case .cycling, .flying, .train: throw ETAError.unsupportedMode(mode)
        }
    }

    private static func calculateRoute(_ directions: MKDirections) async throws(ETAError) -> MKDirections.Response {
        do {
            return try await directions.calculate()
        } catch {
            throw mapError(error)
        }
    }

    private static func calculateETA(_ directions: MKDirections) async throws(ETAError) -> MKDirections.ETAResponse {
        do {
            return try await directions.calculateETA()
        } catch {
            throw mapError(error)
        }
    }

    private static func mapError(_ error: any Error) -> ETAError {
        guard let mapError = error as? MKError else {
            return .directionsFailed(error.localizedDescription)
        }
        switch mapError.code {
        case .directionsNotFound, .placemarkNotFound:
            // No transit in this city, or nowhere to walk to — a real answer,
            // not a failure to get one.
            return .noRoute
        default:
            return .directionsFailed(mapError.localizedDescription)
        }
    }

    // MARK: - Geometry

    /// Shortest distance from a point to a polyline, in metres.
    ///
    /// Measured against the line's *segments* rather than its vertices.
    /// Vertices alone would report a driver as wildly off-route in the middle
    /// of a long motorway stretch, where MapKit emits points kilometres apart.
    static func distance(from location: CLLocation, to polyline: MKPolyline) -> CLLocationDistance {
        let point = MKMapPoint(location.coordinate)
        let points = polyline.points()
        guard polyline.pointCount > 1 else {
            return polyline.pointCount == 1 ? point.distance(to: points[0]) : .greatestFiniteMagnitude
        }

        var shortest = CLLocationDistance.greatestFiniteMagnitude
        for index in 0..<(polyline.pointCount - 1) {
            let distance = point.distance(to: projection(of: point, onto: points[index], points[index + 1]))
            shortest = min(shortest, distance)
        }
        return shortest
    }

    /// Closest point on the segment `a`–`b` to `point`, in map-point space.
    private static func projection(of point: MKMapPoint, onto a: MKMapPoint, _ b: MKMapPoint) -> MKMapPoint {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return a }

        let t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
        let clamped = min(max(t, 0), 1)
        return MKMapPoint(x: a.x + clamped * dx, y: a.y + clamped * dy)
    }
}
