import Foundation

/// A participant's current state, persisted as `participants.status`.
public enum ParticipantStatus: String, Codable, Sendable, CaseIterable {

    /// Has not responded to the invitation.
    case invited

    /// Is attending and has an active journey.
    case accepted

    /// Declined the invitation. The record remains so the response is visible.
    case declined

    /// Reached the destination.
    case arrived

    /// Follows another participant's journey without attending.
    case watching

    /// Whether the participant is currently travelling to the destination.
    public var isTravelling: Bool {
        switch self {
        case .accepted: true
        case .invited, .declined, .arrived, .watching: false
        }
    }

    /// Whether a response is still pending.
    public var isAwaitingAnswer: Bool { self == .invited }

    /// Whether the participant is following rather than attending.
    public var isWatching: Bool { self == .watching }
}
