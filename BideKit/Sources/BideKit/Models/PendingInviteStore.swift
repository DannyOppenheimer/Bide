import Foundation

/// An invitation awaiting its first response.
public struct PendingInvite: Codable, Equatable, Sendable, Identifiable {

    public let invite: BideInvite
    /// The sender's selected travel mode.
    public let mode: TravelMode
    public let stagedAt: Date

    public var id: UUID { invite.bideID }

    public init(invite: BideInvite, mode: TravelMode, stagedAt: Date = Date()) {
        self.invite = invite
        self.mode = mode
        self.stagedAt = stagedAt
    }

    /// Time after a scheduled arrival during which the invite remains valid.
    public static let grace: TimeInterval = 60 * 60

    /// Lifetime of an unscheduled invitation.
    public static let asapLifetime: TimeInterval = 24 * 60 * 60

    /// Time after which the invitation should no longer be reconciled.
    public var expiresAt: Date {
        invite.scheduledFor.map { $0.addingTimeInterval(Self.grace) }
            ?? stagedAt.addingTimeInterval(Self.asapLifetime)
    }

    public func hasExpired(now: Date = Date()) -> Bool { now >= expiresAt }
}

/// Stores pending invitations in the shared App Group.
public struct PendingInviteStore: @unchecked Sendable {

    /// `UserDefaults` provides the thread safety required by this unchecked conformance.
    private let defaults: UserDefaults
    private static let key = "bide.pendingInvites"

    public init(defaults: UserDefaults = .bideShared) {
        self.defaults = defaults
    }

    /// Returns unexpired invitations oldest first and removes expired entries.
    public func all(now: Date = Date()) -> [PendingInvite] {
        let stored = decode()
        let live = stored.filter { !$0.hasExpired(now: now) }
        if live.count != stored.count { encode(live) }
        return live.sorted { $0.stagedAt < $1.stagedAt }
    }

    public var isEmpty: Bool { decode().isEmpty }

    /// Adds or replaces an invitation with the same bide identifier.
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
