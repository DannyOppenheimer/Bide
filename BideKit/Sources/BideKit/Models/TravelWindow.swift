import Foundation

/// The stretch of time a bide takes out of someone's day: from the moment they
/// have to set off to the moment they're due to arrive.
///
/// This is what makes two bides "at the same time" in the sense that matters —
/// not that they start at the same hour, but that one person cannot physically
/// be at both, because the journeys overlap.
public struct TravelWindow: Equatable, Sendable {

    public let leaveAt: Date
    public let arriveAt: Date

    /// `arriveAt` is clamped to be no earlier than `leaveAt`, so a window is
    /// never inverted no matter what the ETA engine hands over.
    public init(leaveAt: Date, arriveAt: Date) {
        self.leaveAt = leaveAt
        self.arriveAt = max(leaveAt, arriveAt)
    }

    /// Built backwards from an arrival time and how long the journey takes,
    /// which is the direction Bide always works in.
    public init(arriveAt: Date, travelTime: TimeInterval) {
        self.init(leaveAt: arriveAt.addingTimeInterval(-max(0, travelTime)), arriveAt: arriveAt)
    }

    public var duration: TimeInterval { arriveAt.timeIntervalSince(leaveAt) }

    /// Breathing room applied on both sides before two windows count as
    /// clashing. Ten minutes: back-to-back journeys with nothing between them
    /// are a conflict in practice even when the clock says they just miss.
    public static let defaultSlack: TimeInterval = 10 * 60

    public func overlaps(_ other: TravelWindow, slack: TimeInterval = TravelWindow.defaultSlack) -> Bool {
        leaveAt.addingTimeInterval(-slack) < other.arriveAt
            && other.leaveAt.addingTimeInterval(-slack) < arriveAt
    }
}

/// Finds the bide a new commitment would collide with.
///
/// The design's rule: accepting or creating a bide that overlaps one you're
/// already in removes you from the older one, and you get asked first. This is
/// the "asked first" half — pure, so the prompt's wording is never guesswork.
public enum ScheduleConflict {

    /// Anything that occupies a window and can be named in the prompt.
    public struct Candidate: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let destinationName: String
        public let window: TravelWindow

        public init(id: UUID, destinationName: String, window: TravelWindow) {
            self.id = id
            self.destinationName = destinationName
            self.window = window
        }
    }

    /// Every existing commitment the proposed window would clash with, soonest
    /// first. `existing` entries sharing the proposed bide's own id are
    /// ignored, so re-accepting a tile never conflicts with itself.
    public static func conflicts(
        with proposed: TravelWindow,
        proposedID: UUID? = nil,
        among existing: [Candidate],
        slack: TimeInterval = TravelWindow.defaultSlack
    ) -> [Candidate] {
        existing
            .filter { $0.id != proposedID && $0.window.overlaps(proposed, slack: slack) }
            .sorted { $0.window.leaveAt < $1.window.leaveAt }
    }

    /// The sentence shown in the confirmation alert. Named separately so the
    /// wording is tested rather than assembled at the call site.
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
