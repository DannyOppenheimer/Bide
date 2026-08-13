import Foundation

/// The local user's role relative to a Messages tile.
public enum ParticipantRole: String, Codable, Equatable, Sendable {

    /// The local user sent the tile.
    case sender

    /// Another participant sent the tile.
    case recipient

    /// Messages has not assigned one or both participant identifiers yet.
    case indeterminate
}

extension ParticipantRole {

    /// The all-zero identifier Messages uses before assigning a participant.
    public static let unassignedIdentifier = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// Determines the local user's role from Messages participant identifiers.
    ///
    /// - Parameters:
    ///   - senderIdentifier: `MSMessage.senderParticipantIdentifier`.
    ///   - localIdentifier: `MSConversation.localParticipantIdentifier`.
    ///
    /// Pass raw identifiers so this initializer can handle unassigned values.
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

    /// Whether the extension should show the Accept button.
    public var showsAcceptButton: Bool { self == .recipient }

    /// Whether the extension is waiting for another participant to respond.
    public var isWaitingOnOtherParticipant: Bool { self == .sender }
}
