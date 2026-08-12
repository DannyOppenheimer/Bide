import Foundation

/// Where one person stands in a bide.
///
/// This replaces the earlier `arrived` boolean: the tile has to distinguish
/// "hasn't answered yet" from "said no", and a bool can't. Persisted as
/// `participants.status`.
public enum ParticipantStatus: String, Codable, Sendable, CaseIterable {

    /// Sent the tile, or was sent it, and hasn't answered.
    case invited

    /// In. Their ETA is being tracked.
    case accepted

    /// Out. Kept rather than deleted so the tile can say so, and so the same
    /// person can change their mind without a second invite.
    case declined

    /// Made it. When everyone reaches this, the bide is finished.
    case arrived

    /// Whether this person is still expected to turn up — the set the
    /// countdown, the Live Activity, and the "is everyone here yet" check all
    /// work from.
    public var isTravelling: Bool {
        switch self {
        case .accepted: true
        case .invited, .declined, .arrived: false
        }
    }

    /// Whether we still need an answer from them before the bide can start.
    public var isAwaitingAnswer: Bool { self == .invited }
}
