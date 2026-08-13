import Foundation

/// Classifies schedule delay for display. Early arrivals remain on schedule.
public enum DelayGrade: String, Codable, Sendable, Hashable, CaseIterable {

    /// No more than two minutes late, or early.
    case onSchedule

    /// More than two and less than eight minutes late.
    case slipping

    /// At least eight minutes late.
    case late

    /// Delay at which the display changes from on-schedule to slipping.
    public static let slippingThreshold: TimeInterval = 2 * 60

    /// Delay at which the display changes from slipping to late.
    public static let lateThreshold: TimeInterval = 8 * 60

    /// - Parameter delay: Seconds later than planned. Negative means early.
    public init(delay: TimeInterval) {
        switch delay {
        case ..<Self.slippingThreshold: self = .onSchedule
        case ..<Self.lateThreshold: self = .slipping
        default: self = .late
        }
    }

    /// Compares a current arrival estimate with its original estimate.
    ///
    /// - Parameters:
    ///   - projected: Current arrival estimate.
    ///   - planned: Original arrival estimate.
    public init(projected: Date, planned: Date) {
        self.init(delay: projected.timeIntervalSince(planned))
    }
}
