import Foundation

/// The interval from a participant's departure through expected arrival.
public struct TravelWindow: Equatable, Sendable {

    public let leaveAt: Date
    public let arriveAt: Date

    /// Creates a window, clamping arrival so the interval cannot be inverted.
    public init(leaveAt: Date, arriveAt: Date) {
        self.leaveAt = leaveAt
        self.arriveAt = max(leaveAt, arriveAt)
    }

    /// Creates a window by subtracting travel time from the arrival time.
    public init(arriveAt: Date, travelTime: TimeInterval) {
        self.init(leaveAt: arriveAt.addingTimeInterval(-max(0, travelTime)), arriveAt: arriveAt)
    }

    public var duration: TimeInterval { arriveAt.timeIntervalSince(leaveAt) }

    /// Buffer applied when checking whether two travel windows conflict.
    public static let defaultSlack: TimeInterval = 10 * 60

    public func overlaps(_ other: TravelWindow, slack: TimeInterval = TravelWindow.defaultSlack) -> Bool {
        leaveAt.addingTimeInterval(-slack) < other.arriveAt
            && other.leaveAt.addingTimeInterval(-slack) < arriveAt
    }
}

/// Finds existing commitments that overlap a proposed travel window.
public enum ScheduleConflict {

    /// A scheduled commitment that can appear in a conflict warning.
    public struct Candidate: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let destination: Destination
        public let window: TravelWindow

        public var destinationName: String { destination.name }

        public init(id: UUID, destination: Destination, window: TravelWindow) {
            self.id = id
            self.destination = destination
            self.window = window
        }
    }

    /// Returns conflicts ordered by departure time, excluding the proposed bide
    /// and same-destination commitments that can share one journey.
    public static func conflicts(
        with proposed: TravelWindow,
        goingTo destination: Destination,
        proposedID: UUID? = nil,
        among existing: [Candidate],
        slack: TimeInterval = TravelWindow.defaultSlack
    ) -> [Candidate] {
        existing
            .filter { $0.id != proposedID }
            .filter { !$0.destination.isSamePlace(as: destination) }
            .filter { $0.window.overlaps(proposed, slack: slack) }
            .sorted { $0.window.leaveAt < $1.window.leaveAt }
    }

    /// Builds the confirmation message shown before replacing conflicting commitments.
    public static func warning(for conflicts: [Candidate]) -> String? {
        let names = conflicts.map(\.destinationName)
        switch names.count {
        case 0: return nil
        case 1: return "This overlaps \(names[0]). You'll be removed from it."
        case 2: return "This overlaps \(names[0]) and \(names[1]). You'll be removed from them."
        default:
            let leading = names.dropLast().joined(separator: ", ")
            return "This overlaps \(leading), and \(names[names.count - 1]). You'll be removed from them."
        }
    }
}
