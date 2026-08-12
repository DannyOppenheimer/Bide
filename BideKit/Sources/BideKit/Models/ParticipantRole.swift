import Foundation

/// Who the local user is, relative to a tile in the conversation.
///
/// This is what decides whether the extension shows "Waiting for them" or an
/// Accept button. The decision is pure — it takes the two identifiers as
/// parameters rather than reaching for `MSMessage` / `MSConversation` — so it
/// can be tested without a device and without a second iCloud account.
///
/// It matters that this is testable off-device: a message you send to
/// *yourself* reports the same identifier for sender and local participant, so
/// self-texting always looks like ``sender`` and can never produce an Accept
/// button. Verifying the recipient path by texting yourself gives a false
/// result; the unit tests are the real check.
public enum ParticipantRole: String, Codable, Equatable, Sendable {

    /// The local user sent this tile. They're waiting on the other person.
    case sender

    /// Someone else sent this tile. The local user can accept it.
    case recipient

    /// Neither — an identifier was missing. Messages reports an all-zero
    /// identifier for a message that has been composed but not yet sent, so
    /// this is the state of a tile staged in the input field.
    case indeterminate
}

extension ParticipantRole {

    /// The identifier Messages reports when a participant isn't assigned yet,
    /// e.g. a message the local user has composed but not sent. Public because
    /// the extension needs it as the stand-in when there is no selected
    /// message at all.
    public static let unassignedIdentifier = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Decides the local user's role by comparing a message's sender against
    /// the conversation's local participant.
    ///
    /// - Parameters:
    ///   - senderIdentifier: `MSMessage.senderParticipantIdentifier`.
    ///   - localIdentifier: `MSConversation.localParticipantIdentifier`.
    ///
    /// Pass the raw identifiers straight through — do not pre-filter them.
    /// Handling the unassigned case is this function's job.
    public init(senderIdentifier: UUID, localIdentifier: UUID) {
        guard
            senderIdentifier != Self.unassignedIdentifier,
            localIdentifier != Self.unassignedIdentifier
        else {
            self = .indeterminate
            return
        }
        self = senderIdentifier == localIdentifier ? .sender : .recipient
    }

    /// Whether the extension should offer an Accept button for this tile.
    public var showsAcceptButton: Bool { self == .recipient }

    /// Whether the extension should tell the local user it's on the other
    /// person now.
    public var isWaitingOnOtherParticipant: Bool { self == .sender }
}
