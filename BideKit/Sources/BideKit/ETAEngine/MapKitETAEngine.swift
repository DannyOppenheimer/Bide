import CoreLocation
import MapKit

/// MapKit-backed ETA engine using local countdowns between route calculations.
/// It recalculates on route deviation, a mode-specific cadence, and every minute
/// during final approach. Departure and arrival are detected entirely on-device.
@MainActor
public final class MapKitETAEngine: ETAEngine {

    /// Default route-deviation threshold.
    private static let routeDeviationThreshold: CLLocationDistance = 80

    /// Wider threshold for cycling because it uses a proxy walking route.
    private static let cyclingDeviationThreshold: CLLocationDistance = 200

    /// Remaining duration at which the one-minute cadence begins.
    private static let finalApproach: TimeInterval = 5 * 60
    private static let finalApproachCadence: TimeInterval = 60

    /// Radius used to detect arrival.
    private static let arrivalRadius: CLLocationDistance = 75

    /// Departure radius chosen to exceed typical indoor GPS drift and site size.
    private static let departureRadius: CLLocationDistance = 150

    /// Lead time before the expected departure when movement detection becomes active.
    nonisolated static let departureDetectionLeadTime: TimeInterval = 15 * 60

    private let locations: any LocationProviding

    private var destination: Destination?
    private var mode: TravelMode = .walking
    private var scheduledArrival: Date?
    private var onUpdate: ((Result<ETAReading, ETAError>) -> Void)?

    /// Private, in-memory origin used only for departure detection.
    private var origin: CLLocation?
    /// One-way departure state; later fixes cannot reverse it.
    private var hasDeparted = false

    /// Current route used for deviation checks; unavailable for transit.
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
        scheduledArrival: Date? = nil,
        onUpdate: @escaping (Result<ETAReading, ETAError>) -> Void
    ) {
        stopTracking()

        self.destination = destination
        self.mode = mode
        self.scheduledArrival = scheduledArrival
        self.onUpdate = onUpdate

        locations.requestAuthorization()
        reanchor()

        // Raw updates remain here and are used only for departure, deviation, and arrival.
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
        scheduledArrival = nil
        onUpdate = nil
        route = nil
        latest = nil
        origin = nil
        hasDeparted = false
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
                let here = try await locations.currentLocation()
                guard !Task.isCancelled else { return }
                note(here)
                let anchored = try await Self.anchor(
                    from: here,
                    to: destination,
                    mode: mode,
                    hasDeparted: hasDeparted
                )
                guard !Task.isCancelled else { return }
                route = anchored.route
                latest = anchored.reading
                onUpdate(.success(anchored.reading))
                scheduleNextAnchor(after: cadence(for: anchored.reading))
            } catch let error as ETAError {
                guard !Task.isCancelled else { return }
                onUpdate(.failure(error))
                // Retry transient failures at the mode's normal cadence.
                scheduleNextAnchor(after: mode.reanchorInterval)
            } catch {
                guard !Task.isCancelled else { return }
                onUpdate(.failure(.directionsFailed(String(describing: error))))
                scheduleNextAnchor(after: mode.reanchorInterval)
            }
        }
    }

    /// Returns the normal or final-approach recalculation interval.
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

    /// Processes a location update and recalculates only when state or route changes.
    private func handle(_ location: CLLocation) {
        guard let destination, let latest else { return }

        if location.distance(from: destination.location) <= Self.arrivalRadius {
            guard !latest.hasArrived else { return }
            let arrived = ETAReading(
                arrival: Date(),
                travelTime: 0,
                mode: mode,
                hasDeparted: true,
                hasArrived: true
            )
            self.latest = arrived
            onUpdate?(.success(arrived))
            return
        }

        // Recalculate immediately when departure changes the plan from leave time to ETA.
        if note(location) {
            reanchor()
            return
        }

        guard mode.tracksRouteDeviation, let route else { return }
        if Self.distance(from: location, to: route.polyline) > Self.deviationThreshold(for: mode) {
            reanchor()
        }
    }

    private static func deviationThreshold(for mode: TravelMode) -> CLLocationDistance {
        mode == .cycling ? cyclingDeviationThreshold : routeDeviationThreshold
    }

    /// Records a fix and returns `true` only when it first detects departure.
    @discardableResult
    private func note(_ location: CLLocation) -> Bool {
        guard let origin else {
            // Store the first fix locally as the departure origin.
            origin = location
            return false
        }
        // Before detection is armed, move the origin so unrelated travel is ignored.
        guard departureDetectionIsArmed(at: Date()) else {
            self.origin = location
            return false
        }
        guard !hasDeparted, location.distance(from: origin) > Self.departureRadius else { return false }
        hasDeparted = true
        return true
    }

    /// ASAP trips arm immediately; scheduled trips arm near their estimated departure.
    private func departureDetectionIsArmed(at now: Date) -> Bool {
        Self.departureDetectionIsArmed(
            at: now,
            scheduledArrival: scheduledArrival,
            travelTime: latest?.travelTime,
            leadTime: Self.departureDetectionLeadTime
        )
    }

    /// Pure departure-arming calculation used by regression tests.
    nonisolated static func departureDetectionIsArmed(
        at now: Date,
        scheduledArrival: Date?,
        travelTime: TimeInterval?,
        leadTime: TimeInterval = departureDetectionLeadTime
    ) -> Bool {
        guard let scheduledArrival else { return true }
        guard let travelTime else { return false }
        let departure = scheduledArrival.addingTimeInterval(-max(0, travelTime))
        return now >= departure.addingTimeInterval(-max(0, leadTime))
    }

    // MARK: - MapKit

    private struct Anchored {
        let reading: ETAReading
        let route: MKRoute?
    }

    private static func anchor(
        from origin: CLLocation,
        to destination: Destination,
        mode: TravelMode,
        hasDeparted: Bool = false
    ) async throws(ETAError) -> Anchored {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.coordinate))
        request.transportType = try transportType(for: mode)
        request.departureDate = Date()

        // Transit supplies an ETA but no route polyline for deviation checks.
        if mode == .transit {
            let response = try await calculateETA(MKDirections(request: request))
            return Anchored(
                reading: ETAReading(
                    arrival: response.expectedArrivalDate,
                    travelTime: response.expectedTravelTime,
                    mode: mode,
                    hasDeparted: hasDeparted
                ),
                route: nil
            )
        }

        let response = try await calculateRoute(MKDirections(request: request))
        // Rank cycling routes with the cycling model instead of walking duration.
        guard let route = response.routes.min(by: {
            Self.travelTime(of: $0, mode: mode) < Self.travelTime(of: $1, mode: mode)
        }) else {
            throw ETAError.noRoute
        }
        let travelTime = Self.travelTime(of: route, mode: mode)
        return Anchored(
            reading: ETAReading(
                arrival: Date().addingTimeInterval(travelTime),
                travelTime: travelTime,
                mode: mode,
                hasDeparted: hasDeparted
            ),
            route: route
        )
    }

    /// Returns MapKit's duration, or a modelled cycling duration.
    private static func travelTime(of route: MKRoute, mode: TravelMode) -> TimeInterval {
        guard mode == .cycling else { return route.expectedTravelTime }
        return CyclingEstimate.travelTime(
            distance: route.distance,
            walkingTime: route.expectedTravelTime
        )
    }

    /// Maps cycling to walking so its distance and polyline can be reinterpreted.
    private static func transportType(for mode: TravelMode) throws(ETAError) -> MKDirectionsTransportType {
        switch mode {
        case .walking, .cycling: .walking
        case .driving: .automobile
        case .transit: .transit
        case .flying, .train: throw ETAError.unsupportedMode(mode)
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
            // The endpoints have no route for the requested mode.
            return .noRoute
        default:
            return .directionsFailed(mapError.localizedDescription)
        }
    }

    // MARK: - Geometry

    /// Returns the shortest distance from a location to any polyline segment.
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

    /// Returns the closest point on segment `a`–`b` in map-point space.
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
