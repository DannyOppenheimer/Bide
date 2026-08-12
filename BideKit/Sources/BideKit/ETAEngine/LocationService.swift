import CoreLocation

/// Supplies the device's own location to the ETA engine, and nothing else.
///
/// Deliberately narrow: a location that comes out of here is used to compute a
/// travel time and is then discarded. It is never stored, never put in a
/// model, and never sent anywhere — the server has nowhere to put one.
@MainActor
public protocol LocationProviding: AnyObject {

    var authorizationStatus: CLAuthorizationStatus { get }

    /// Prompts, if the user hasn't been asked yet. Safe to call repeatedly.
    func requestAuthorization()

    /// A single fix, reusing a recent one if there is one.
    func currentLocation() async throws(ETAError) -> CLLocation

    /// Continuous updates, for spotting that someone has left the route or
    /// reached the destination.
    func startUpdates(_ handler: @escaping (CLLocation) -> Void)

    func stopUpdates()
}

/// CoreLocation-backed implementation.
///
/// `background` is off by default because the Messages extension may create
/// one of these for the tile's one-shot preview, and an extension must never
/// ask for background location. Only the container app passes `true`, and only
/// because it declares the matching background mode — setting the flag without
/// it traps at runtime.
@MainActor
public final class LocationService: NSObject, LocationProviding {

    private let manager = CLLocationManager()
    private let background: Bool

    /// A fix younger than this is good enough to reuse rather than waking the
    /// radios again.
    private static let freshness: TimeInterval = 30

    /// How long to wait for a fix before giving up on it.
    private static let fixTimeout: Duration = .seconds(12)

    private var lastFix: CLLocation?
    /// Everyone currently awaiting a fix, keyed so a timeout can drop exactly
    /// its own caller and leave the rest waiting.
    private var waiters: [UUID: CheckedContinuation<CLLocation, any Error>] = [:]
    private var updateHandler: ((CLLocation) -> Void)?

    public init(background: Bool = false) {
        self.background = background
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        #if os(iOS)
        // Lets CoreLocation apply the right motion model, and — with
        // `automotiveNavigation` — keeps updates flowing while the screen is
        // off, which is exactly when someone is driving to the meetup.
        manager.activityType = background ? .automotiveNavigation : .other
        #endif
    }

    public var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    public func requestAuthorization() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    public func currentLocation() async throws(ETAError) -> CLLocation {
        // Denied is final; not-yet-asked is not. Asking here is what makes the
        // prompt appear at the moment it's needed — when someone accepts a
        // tile — rather than on a cold launch with no explanation.
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
                // Only ask now if we may. If the prompt is still up, the
                // authorisation callback re-requests for anyone waiting.
                if isAuthorized { manager.requestLocation() }
                startTimeout(for: ticket)
            }
        } catch let error as ETAError {
            throw error
        } catch {
            throw ETAError.locationTimedOut
        }
    }

    /// Gives up on one waiter after ``fixTimeout``. A fix that lands first
    /// removes the ticket, so this becomes a no-op.
    private func startTimeout(for ticket: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: Self.fixTimeout)
            guard let self, let continuation = waiters.removeValue(forKey: ticket) else { return }
            continuation.resume(throwing: ETAError.locationTimedOut)
        }
    }

    public func startUpdates(_ handler: @escaping (CLLocation) -> Void) {
        updateHandler = handler

        // Asked but not yet answered: the authorisation callback starts the
        // stream. Without this, granting permission would leave tracking dead
        // until the next launch.
        guard isAuthorized else {
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            }
            return
        }
        #if os(iOS)
        if background {
            // Only ever true in the container app. Live ETAs are worthless if
            // they freeze the moment the phone goes in a pocket.
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

// CoreLocation calls back on the queue the manager was created on, which is
// the main queue here — the initialiser is main-actor bound. That is what
// makes `assumeIsolated` sound rather than a wish.
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
            // `locationUnknown` means "still trying", not "gave up".
            guard (error as? CLError)?.code != .locationUnknown else { return }
            fail((error as? CLError)?.code == .denied ? .locationUnavailable : .locationTimedOut)
        }
    }

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // Read the status out here — the manager itself is not `Sendable`, so
        // only the value crosses into the isolated closure. `self.manager` is
        // the same object anyway.
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            switch status {
            case .denied, .restricted:
                fail(.locationUnavailable)
            case .authorizedWhenInUse, .authorizedAlways:
                // A prompt answered while something was waiting on it: pick up
                // where each caller left off, now that it can succeed.
                if !waiters.isEmpty { self.manager.requestLocation() }
                if let updateHandler { startUpdates(updateHandler) }
            default:
                break
            }
        }
    }
}
