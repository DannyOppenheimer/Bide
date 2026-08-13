import Foundation

/// Compact, display-ready participant data for a Live Activity payload.
public struct ActivityParticipant: Codable, Hashable, Identifiable, Sendable {

    public let id: UUID
    public let name: String
    public let initial: String
    public let mode: TravelMode
    /// Preformatted fallback status text.
    public let line: String
    /// Current journey duration, if applicable.
    public let travelTime: TimeInterval?
    /// Arrival date used by the Live Activity to render an updating countdown.
    public let eta: Date?
    /// Whether the arrival date should count down as a fixed estimate.
    public let hasDeparted: Bool
    public let grade: DelayGrade?

    public init(
        id: UUID,
        name: String,
        initial: String,
        mode: TravelMode,
        line: String,
        travelTime: TimeInterval? = nil,
        eta: Date? = nil,
        hasDeparted: Bool = false,
        grade: DelayGrade?
    ) {
        self.id = id
        self.name = name
        self.initial = initial
        self.mode = mode
        self.line = line
        self.travelTime = travelTime
        self.eta = eta
        self.hasDeparted = hasDeparted
        self.grade = grade
    }

    /// - Parameter me: Local user identifier used to label their row as "You".
    public init(participant: Participant, me: UUID? = nil, now: Date = Date()) {
        self.init(
            id: participant.userID,
            name: BideFormat.name(participant, me: me),
            initial: BideFormat.initial(participant, me: me),
            mode: participant.mode,
            line: BideFormat.participantStatus(participant, now: now),
            // Completed and declined participants use their static status line.
            travelTime: participant.remainingTravel(now: now),
            eta: participant.status == .accepted ? participant.arrival(now: now) : nil,
            hasDeparted: participant.hasLeft,
            grade: participant.delayGrade
        )
    }
}

// ActivityKit symbols are unavailable on macOS even when the module can be imported.
#if os(iOS)
import ActivityKit

/// Static attributes and dynamic content for Bide's Live Activity.
/// Only the container app starts and updates activities.
public struct BideActivityAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable, Sendable {
        /// Primary status text shown by the activity.
        public var headline: String
        public var participants: [ActivityParticipant]
        /// Local departure time used for the lock-screen countdown; `nil` after departure.
        public var leaveAt: Date?
        /// Local journey duration shown in the compact Dynamic Island slot.
        public var myTravelTime: TimeInterval?
        public var myArrival: Date?
        /// Whether the local user has departed.
        public var hasDeparted: Bool
        public var isComplete: Bool

        public init(
            headline: String,
            participants: [ActivityParticipant],
            leaveAt: Date? = nil,
            myTravelTime: TimeInterval? = nil,
            myArrival: Date? = nil,
            hasDeparted: Bool = false,
            isComplete: Bool = false
        ) {
            self.headline = headline
            self.participants = participants
            self.leaveAt = leaveAt
            self.myTravelTime = myTravelTime
            self.myArrival = myArrival
            self.hasDeparted = hasDeparted
            self.isComplete = isComplete
        }
    }

    public let bideID: UUID
    public let destinationName: String
    /// Scheduled arrival. Changing it requires replacing the immutable activity.
    public let scheduledFor: Date?

    public init(bideID: UUID, destinationName: String, scheduledFor: Date? = nil) {
        self.bideID = bideID
        self.destinationName = destinationName
        self.scheduledFor = scheduledFor
    }
}
#endif
