import Foundation

/// A tile as it exists in a Messages thread: the invite, plus whatever the
/// last person to touch it did about it.
///
/// Messages updates a tile by replacing its `MSMessage` inside the same
/// `MSSession`, and the URL is the whole payload — so an answer travels the
/// same way the invitation did. That's what lets the thread show "Sarah can't
/// make it" without a server round trip, and without the extension holding an
/// identity of its own.
public struct BideTileMessage: Equatable, Sendable {

    public let invite: BideInvite
    /// What the sender of *this* message did. Nil on the original invitation.
    public let answer: ParticipantStatus?
    /// When they said they'd set off, if they accepted. Shown as a countdown.
    public let leaveAt: Date?
    /// What the sender calls themselves, so the tile can say "John wants to go
    /// to Nats Park". Messages deliberately doesn't hand out participant
    /// names, so it travels with the tile or not at all.
    public let senderName: String?

    public init(
        invite: BideInvite,
        answer: ParticipantStatus? = nil,
        leaveAt: Date? = nil,
        senderName: String? = nil
    ) {
        self.invite = invite
        self.answer = answer
        self.leaveAt = leaveAt
        self.senderName = senderName
    }

    private enum QueryKey: String {
        case answer
        case leaveAt = "leave"
        case senderName = "from"
    }

    /// The public URL for this tile — the invite's, with the answer appended.
    public func webURL() -> URL { appending(to: invite.webURL()) }

    /// The container app hand-off. Accepting needs location and MKDirections,
    /// which an .appex may not touch, so the answer travels to the app rather
    /// than being acted on in the extension.
    public func appURL() -> URL { appending(to: invite.appURL()) }

    private func appending(to base: URL) -> URL {
        guard
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
            answer != nil || leaveAt != nil || senderName != nil
        else { return base }

        // `queryItems` percent-encodes on assignment, and the invite's own
        // items are already encoded, so this appends to the encoded list and
        // encodes each addition itself.
        var items = components.percentEncodedQueryItems ?? []
        if let answer {
            items.append(URLQueryItem(name: QueryKey.answer.rawValue, value: answer.rawValue))
        }
        if let leaveAt {
            items.append(
                URLQueryItem(
                    name: QueryKey.leaveAt.rawValue,
                    value: String(Int(leaveAt.timeIntervalSince1970))
                )
            )
        }
        if let senderName, let encoded = Self.encode(senderName) {
            items.append(URLQueryItem(name: QueryKey.senderName.rawValue, value: encoded))
        }
        components.percentEncodedQueryItems = items
        return components.url ?? base
    }

    /// Names are people's names: apostrophes, accents, emoji. Encoded to the
    /// same conservative set the invite uses, and capped so one long name
    /// can't push the URL over the payload budget.
    private static func encode(_ name: String) -> String? {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return String(name.prefix(40)).addingPercentEncoding(withAllowedCharacters: allowed)
    }

    /// Decodes a tile from either URL form. Nil if it isn't a Bide tile at all.
    public init?(url: URL) {
        guard let invite = BideInvite(url: url) else { return nil }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: QueryKey) -> String? {
            items.first { $0.name == key.rawValue }?.value
        }

        self.init(
            invite: invite,
            answer: value(.answer).flatMap(ParticipantStatus.init(rawValue:)),
            leaveAt: value(.leaveAt).flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:)),
            senderName: value(.senderName)
        )
    }
}
