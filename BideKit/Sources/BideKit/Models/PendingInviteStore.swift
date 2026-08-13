import Foundation

/// A tile that has been sent to other people, and that nobody has answered yet.
///
/// Sending a tile is a question, not a commitment. Until someone says yes there
/// is no meetup — so the sender gets no session, no countdown, and nothing
/// holding a slot in their day. The invite waits here instead, and becomes a
/// real session the moment the first person accepts.
public struct PendingInvite: Codable, Equatable, Sendable, Identifiable {

    public let invite: BideInvite
    /// How the sender said *they* would travel. Kept so their session starts
    /// with the answer they already gave, rather than asking again.
    public let mode: TravelMode
    public let stagedAt: Date

    public var id: UUID { invite.bideID }

    public init(invite: BideInvite, mode: TravelMode, stagedAt: Date = Date()) {
        self.invite = invite
        self.mode = mode
        self.stagedAt = stagedAt
    }

    /// How long an unanswered invite is still worth waiting on past the time it
    /// was for. Someone answering ten minutes late should still get everyone
    /// there; someone answering the next morning should not resurrect it.
    public static let grace: TimeInterval = 60 * 60

    /// An asap bide has no time of its own to expire against, so it gets a day.
    public static let asapLifetime: TimeInterval = 24 * 60 * 60

    /// When this stops being worth asking the server about.
    public var expiresAt: Date {
        invite.scheduledFor.map { $0.addingTimeInterval(Self.grace) }
            ?? stagedAt.addingTimeInterval(Self.asapLifetime)
    }

    public func hasExpired(now: Date = Date()) -> Bool { now >= expiresAt }
}

/// The invites this device has sent and is still waiting on.
///
/// In the App Group so the record survives the app being killed between sending
/// a tile and the reply arriving — which is the normal case, not the edge one.
public struct PendingInviteStore: @unchecked Sendable {

    /// `UserDefaults` is thread-safe, which is what the unchecked conformance
    /// stands on.
    private let defaults: UserDefaults
    private static let key = "bide.pendingInvites"

    public init(defaults: UserDefaults = .bideShared) {
        self.defaults = defaults
    }

    /// Everything still outstanding, oldest first, with anything past its time
    /// dropped on the way out — reading is the only moment expiry has to hold.
    public func all(now: Date = Date()) -> [PendingInvite] {
        let stored = decode()
        let live = stored.filter { !$0.hasExpired(now: now) }
        if live.count != stored.count { encode(live) }
        return live.sorted { $0.stagedAt < $1.stagedAt }
    }

    public var isEmpty: Bool { decode().isEmpty }

    /// Re-staging the same bide replaces it rather than queueing a second copy.
    public func add(_ pending: PendingInvite) {
        encode(decode().filter { $0.id != pending.id } + [pending])
    }

    public func remove(_ bideID: UUID) {
        encode(decode().filter { $0.id != bideID })
    }

    public func removeAll() {
        defaults.removeObject(forKey: Self.key)
    }

    // MARK: - Storage

    private func decode() -> [PendingInvite] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([PendingInvite].self, from: data)) ?? []
    }

    private func encode(_ invites: [PendingInvite]) {
        guard !invites.isEmpty else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        guard let data = try? JSONEncoder().encode(invites) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
