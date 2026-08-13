import CoreLocation

/// Supplies local location data only to the on-device ETA engine.
@MainActor
public protocol LocationProviding: AnyObject {

    var authorizationStatus: CLAuthorizationStatus { get }

    /// Requests authorization if the user has not responded previously.
    func requestAuthorization()

    /// Returns one location, reusing a recent fix when available.
    func currentLocation() async throws(ETAError) -> CLLocation

    /// Starts updates used for departure, deviation, and arrival detection.
    func startUpdates(_ handler: @escaping (CLLocation) -> Void)

    func stopUpdates()
}

/// CoreLocation-backed location provider.
/// Background updates must be enabled only by the entitled container app.
@MainActor
public final class LocationService: NSObject, LocationProviding {

    private let manager = CLLocationManager()
    private let background: Bool

    /// Maximum age of a reusable location fix.
    private static let freshness: TimeInterval = 30

    /// Maximum wait for a location fix.
    private static let fixTimeout: Duration = .seconds(12)

    private var lastFix: CLLocation?
    /// Pending callers keyed so each timeout resumes only its own continuation.
    private var waiters: [UUID: CheckedContinuation<CLLocation, any Error>] = [:]
    private var updateHandler: ((CLLocation) -> Void)?

    public init(background: Bool = false) {
        self.background = background
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        #if os(iOS)
        // Use the navigation motion model when the app tracks in the background.
        manager.activityType = background ? .automotiveNavigation : .other
        #endif
    }

    public var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    public func requestAuthorization() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    public func currentLocation() async throws(ETAError) -> CLLocation {
        // Ask at first use; denied and restricted states fail immediately.
        switch manager.authorizationStatus {
        case .denied, .restricted:
            throw ETAError.locationUnavailable
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }

        if let lastFix, Date().timeIntervalSince(lastFix.timestamp) < Self.freshness {
            return lastFix
        }

        do {
            let ticket = UUID()
            return try await withCheckedThrowingContinuation { continuation in
                waiters[ticket] = continuation
                // The authorization callback requests a fix after permission is granted.
                if isAuthorized { manager.requestLocation() }
                startTimeout(for: ticket)
            }
        } catch let error as ETAError {
            throw error
        } catch {
            throw ETAError.locationTimedOut
        }
    }

    /// Times out one pending location request unless a fix removes it first.
    private func startTimeout(for ticket: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.fixTimeout)
            guard let self, let continuation = waiters.removeValue(forKey: ticket) else { return }
            continuation.resume(throwing: ETAError.locationTimedOut)
        }
    }

    public func startUpdates(_ handler: @escaping (CLLocation) -> Void) {
        updateHandler = handler

        // The authorization callback starts updates after permission is granted.
        guard isAuthorized else {
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            }
            return
        }
        #if os(iOS)
        if background {
            // Only the entitled container app enables background updates.
            manager.allowsBackgroundLocationUpdates = true
            manager.pausesLocationUpdatesAutomatically = false
            manager.showsBackgroundLocationIndicator = true
        }
        #endif
        manager.startUpdatingLocation()
    }

    public func stopUpdates() {
        updateHandler = nil
        manager.stopUpdatingLocation()
        #if os(iOS)
        if background {
            manager.allowsBackgroundLocationUpdates = false
        }
        #endif
    }

    private var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: true
        default: false
        }
    }

    private func deliver(_ location: CLLocation) {
        lastFix = location
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending {
            continuation.resume(returning: location)
        }
        updateHandler?(location)
    }

    private func fail(_ error: ETAError) {
        let pending = waiters.values
        waiters.removeAll()
        for continuation in pending {
            continuation.resume(throwing: error)
        }
    }
}

// MARK: - CLLocationManagerDelegate

// The main-actor initializer creates the manager on the main queue, where its
// delegate callbacks run; this makes `assumeIsolated` valid.
extension LocationService: CLLocationManagerDelegate {

    nonisolated public func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let latest = locations.last else { return }
        MainActor.assumeIsolated { deliver(latest) }
    }

    nonisolated public func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: any Error
    ) {
        MainActor.assumeIsolated {
            // `locationUnknown` is transient, so keep waiting.
            guard (error as? CLError)?.code != .locationUnknown else { return }
            fail((error as? CLError)?.code == .denied ? .locationUnavailable : .locationTimedOut)
        }
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Capture only the sendable status value before entering main-actor isolation.
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            switch status {
            case .denied, .restricted:
                fail(.locationUnavailable)
            case .authorizedWhenInUse, .authorizedAlways:
                // Resume pending one-shot and continuous requests after authorization.
                if !waiters.isEmpty { self.manager.requestLocation() }
                if let updateHandler { startUpdates(updateHandler) }
            default:
                break
            }
        }
    }
}
