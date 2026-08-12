import Foundation

/// One person, flattened for the Live Activity.
///
/// The activity's payload has a hard size limit and is re-encoded on every
/// update, so it carries strings that are ready to draw rather than the model
/// they came from.
public struct ActivityParticipant: Codable, Hashable, Identifiable, Sendable {

    public let id: UUID
    public let name: String
    public let initial: String
    public let mode: TravelMode
    /// "Waiting...", "45 minutes", "Arrived".
    public let line: String
    public let grade: DelayGrade?

    public init(id: UUID, name: String, initial: String, mode: TravelMode, line: String, grade: DelayGrade?) {
        self.id = id
        self.name = name
        self.initial = initial
        self.mode = mode
        self.line = line
        self.grade = grade
    }

    public init(participant: Participant, now: Date = Date()) {
        self.init(
            id: participant.userID,
            name: BideFormat.name(participant),
            initial: BideFormat.initial(participant),
            mode: participant.mode,
            line: BideFormat.participantStatus(participant, now: now),
            grade: participant.delayGrade
        )
    }
}

// ActivityKit is iOS-only: the framework is importable on macOS but every
// symbol in it is unavailable there, so this is gated on the platform rather
// than on the import.
#if os(iOS)
import ActivityKit

/// The Live Activity — the surface the design brief calls the main event.
///
/// Started and updated by the container app only. The Messages extension can't
/// touch ActivityKit, and doesn't need to: by the time an activity exists, the
/// app is the thing tracking the ETA.
public struct BideActivityAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable, Sendable {
        /// "Leave in 10 minutes", "Waiting for everyone to answer".
        public var headline: String
        public var participants: [ActivityParticipant]
        /// When the local user has to set off, if that's known — drives the
        /// self-updating countdown on the lock screen.
        public var leaveAt: Date?
        public var isComplete: Bool

        public init(
            headline: String,
            participants: [ActivityParticipant],
            leaveAt: Date? = nil,
            isComplete: Bool = false
        ) {
            self.headline = headline
            self.participants = participants
            self.leaveAt = leaveAt
            self.isComplete = isComplete
        }
    }

    public let bideID: UUID
    public let destinationName: String

    public init(bideID: UUID, destinationName: String) {
        self.bideID = bideID
        self.destinationName = destinationName
    }
}
#endif
