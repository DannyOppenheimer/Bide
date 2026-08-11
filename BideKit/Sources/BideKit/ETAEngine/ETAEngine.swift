import Foundation

/// Computes and tracks ETAs on-device. Only ever surfaces an arrival
/// TIMESTAMP to callers — never a raw location — per Bide's privacy
/// commitment.
///
/// Anchor-and-countdown policy: call MKDirections once, count down locally,
/// and re-anchor on route deviation, on a timer (5 min driving / 10 min
/// walking), or every 60s inside the final 5 minutes. The Messages extension
/// never runs this itself — it can't do background work — so this only ever
/// runs inside the container app.
public protocol ETAEngine {
    /// Starts counting down to `destination`, invoking `onUpdate` with the
    /// current estimated arrival date whenever the engine (re-)anchors.
    func startTracking(to destination: MeetupState, onUpdate: @escaping (Date) -> Void)
    func stopTracking()
}

/// Placeholder implementation with a fixed ETA. The container app will
/// replace this with an MKDirections-backed engine that follows the
/// anchor-and-countdown policy above.
public final class PlaceholderETAEngine: ETAEngine {
    public init() {}

    public func startTracking(to destination: MeetupState, onUpdate: @escaping (Date) -> Void) {
        onUpdate(Date().addingTimeInterval(TimeInterval(destination.proposerETAMinutes * 60)))
    }

    public func stopTracking() {}
}
