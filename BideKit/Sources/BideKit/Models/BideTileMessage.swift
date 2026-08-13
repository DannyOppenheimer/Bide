import Foundation

/// The invitation and response state encoded in a Messages tile URL.
public struct BideTileMessage: Equatable, Sendable {

    public let invite: BideInvite
    /// The current message sender's response, or `nil` for the original invitation.
    public let answer: ParticipantStatus?
    /// The sender's departure time, used to display a countdown after acceptance.
    public let leaveAt: Date?
    /// The sender name carried in the URL because Messages does not expose it.
    public let senderName: String?
    /// Whether the recipient is invited to follow the journey rather than attend.
    public let isTrackingInvite: Bool

    public init(
        invite: BideInvite,
        answer: ParticipantStatus? = nil,
        leaveAt: Date? = nil,
        senderName: String? = nil,
        isTrackingInvite: Bool = false
    ) {
        self.invite = invite
        self.answer = answer
        self.leaveAt = leaveAt
        self.senderName = senderName
        self.isTrackingInvite = isTrackingInvite
    }

    private enum QueryKey: String {
        case answer
        case leaveAt = "leave"
        case senderName = "from"
        case tracking = "watch"
    }

    /// Returns the public invite URL with tile state appended.
    public func webURL() -> URL { appending(to: invite.webURL()) }

    /// Returns the container-app handoff URL with tile state appended.
    public func appURL() -> URL { appending(to: invite.appURL()) }

    private func appending(to base: URL) -> URL {
        guard
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
            answer != nil || leaveAt != nil || senderName != nil || isTrackingInvite
        else { return base }

        // Preserve the invite's existing encoding and let each new item encode itself.
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
        if isTrackingInvite {
            items.append(URLQueryItem(name: QueryKey.tracking.rawValue, value: "1"))
        }
        components.percentEncodedQueryItems = items
        return components.url ?? base
    }

    /// Encodes at most 40 characters to keep names within the URL payload budget.
    private static func encode(_ name: String) -> String? {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return String(name.prefix(40)).addingPercentEncoding(withAllowedCharacters: allowed)
    }

    /// Decodes a tile from a public or app URL.
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
            senderName: value(.senderName),
            isTrackingInvite: value(.tracking) == "1"
        )
    }
}
