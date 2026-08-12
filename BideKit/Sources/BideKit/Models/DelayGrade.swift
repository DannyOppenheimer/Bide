import Foundation

/// How far off plan someone has drifted, as the three colours the design uses
/// for a time.
///
/// Graded on *lateness* only. Running early is never coloured as a problem —
/// arriving before you said you would is the outcome the whole app is trying
/// to avoid needing, not a fault.
public enum DelayGrade: String, Codable, Sendable, Hashable, CaseIterable {

    /// Within a couple of minutes of the original estimate, or early.
    case onSchedule

    /// Slipping: more than 2 minutes late, up to 8.
    case slipping

    /// More than 8 minutes late.
    case late

    /// Past this much lateness a time stops being green.
    public static let slippingThreshold: TimeInterval = 2 * 60

    /// Past this much lateness a time turns red.
    public static let lateThreshold: TimeInterval = 8 * 60

    /// - Parameter delay: Seconds later than planned. Negative means early.
    public init(delay: TimeInterval) {
        switch delay {
        case ..<Self.slippingThreshold: self = .onSchedule
        case ..<Self.lateThreshold: self = .slipping
        default: self = .late
        }
    }

    /// Grades a live estimate against the estimate it started from.
    ///
    /// - Parameters:
    ///   - projected: What we now think will happen.
    ///   - planned: What we thought when the bide was anchored.
    public init(projected: Date, planned: Date) {
        self.init(delay: projected.timeIntervalSince(planned))
    }
}
