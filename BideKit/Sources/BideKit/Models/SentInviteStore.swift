import Foundation

/// Records a tile sent to one Messages conversation.
/// The extension needs this local record because it cannot read thread history.
public struct SentInvite: Codable, Equatable, Sendable, Identifiable {

    public let bideID: UUID
    /// Per-install conversation key derived without storing handles or phone numbers.
    public let conversationKey: String
    public let destinationName: String
    public let scheduledFor: Date?
    public let sentAt: Date

    public var id: UUID { bideID }

    public init(
        bideID: UUID,
        conversationKey: String,
        destinationName: String,
        scheduledFor: Date? = nil,
        sentAt: Date = Date()
    ) {
        self.bideID = bideID
        self.conversationKey = conversationKey
        self.destinationName = destinationName
        self.scheduledFor = scheduledFor
        self.sentAt = sentAt
    }

    /// Expires with the associated bide so the conversation can accept a new tile.
    public var expiresAt: Date {
        (scheduledFor ?? sentAt).addingTimeInterval(BideState.lifetime)
    }

    public func hasExpired(now: Date = Date()) -> Bool { now >= expiresAt }
}

/// Tracks active sent invites and queues extension-requested deletions for the app.
///
/// The extension cannot write to the server, so it stages deletions in the App
/// Group for the container app to process on its next refresh.
public struct SentInviteStore: @unchecked Sendable {

    /// `UserDefaults` provides the thread safety required by this unchecked conformance.
    private let defaults: UserDefaults
    private static let sentKey = "bide.sentInvites"
    private static let revokedKey = "bide.revokedBides"

    public init(defaults: UserDefaults = .bideShared) {
        self.defaults = defaults
    }

    // MARK: - Conversation occupancy

    /// Returns unexpired records newest first and removes expired entries.
    public func all(now: Date = Date()) -> [SentInvite] {
        let stored = decode()
        let live = stored.filter { !$0.hasExpired(now: now) }
        if live.count != stored.count { encode(live) }
        return live.sorted { $0.sentAt > $1.sentAt }
    }

    /// Returns the active Bide in this conversation, or nil for a missing key.
    public func live(inConversation key: String?, now: Date = Date()) -> SentInvite? {
        guard let key, !key.isEmpty else { return nil }
        return all(now: now).first { $0.conversationKey == key }
    }

    /// Adds or replaces the record for a bide.
    public func record(_ sent: SentInvite) {
        encode(decode().filter { $0.bideID != sent.bideID } + [sent])
    }

    /// Removes local state for a session without requesting server deletion.
    public func forget(_ bideID: UUID) {
        encode(decode().filter { $0.bideID != bideID })
        clearRevocation(bideID)
    }

    // MARK: - Deletion requested from the extension

    /// Queues server deletion and releases the conversation for a replacement tile.
    public func revoke(_ bideID: UUID) {
        var pending = revoked()
        if !pending.contains(bideID) { pending.append(bideID) }
        encode(revoked: pending)
        encode(decode().filter { $0.bideID != bideID })
    }

    /// Bide IDs awaiting deletion by the app.
    public func revoked() -> [UUID] {
        let stored = defaults.array(forKey: Self.revokedKey) as? [String] ?? []
        return stored.compactMap(UUID.init(uuidString:))
    }

    public func clearRevocation(_ bideID: UUID) {
        encode(revoked: revoked().filter { $0 != bideID })
    }

    public func removeAll() {
        defaults.removeObject(forKey: Self.sentKey)
        defaults.removeObject(forKey: Self.revokedKey)
    }

    // MARK: - Storage

    private func decode() -> [SentInvite] {
        guard let data = defaults.data(forKey: Self.sentKey) else { return [] }
        return (try? JSONDecoder().decode([SentInvite].self, from: data)) ?? []
    }

    private func encode(_ sent: [SentInvite]) {
        guard !sent.isEmpty else {
            defaults.removeObject(forKey: Self.sentKey)
            return
        }
        guard let data = try? JSONEncoder().encode(sent) else { return }
        defaults.set(data, forKey: Self.sentKey)
    }

    private func encode(revoked: [UUID]) {
        guard !revoked.isEmpty else {
            defaults.removeObject(forKey: Self.revokedKey)
            return
        }
        defaults.set(revoked.map(\.uuidString), forKey: Self.revokedKey)
    }
}
