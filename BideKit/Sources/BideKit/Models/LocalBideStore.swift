import Foundation

/// What this device decided about a bide.
public struct LocalAnswer: Codable, Equatable, Sendable {

    public let status: ParticipantStatus
    public let mode: TravelMode
    /// When this person has to set off, as computed at the moment they
    /// accepted. Lets the tile in the transcript count down without asking
    /// anything — a transcript view has no business making network calls.
    public let leaveAt: Date?
    public let answeredAt: Date

    public init(status: ParticipantStatus, mode: TravelMode, leaveAt: Date? = nil, answeredAt: Date = Date()) {
        self.status = status
        self.mode = mode
        self.leaveAt = leaveAt
        self.answeredAt = answeredAt
    }
}

/// Remembers this device's own answers, so a tile can be drawn correctly the
/// instant it appears.
///
/// Deliberately local and deliberately small. The Messages extension and the
/// container app do *not* share this — they can't, without an App Group, and
/// the project doesn't provision one — so each keeps the answers it made
/// itself. The server remains the source of truth for everyone's state; this
/// only exists so the transcript has something to draw before anyone asks.
public struct LocalBideStore: @unchecked Sendable {

    /// `UserDefaults` is thread-safe, which is what the unchecked conformance
    /// stands on.
    private let defaults: UserDefaults
    private let keyPrefix = "bide.answer."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func answer(for bideID: UUID) -> LocalAnswer? {
        guard let data = defaults.data(forKey: key(bideID)) else { return nil }
        return try? JSONDecoder().decode(LocalAnswer.self, from: data)
    }

    public func record(_ answer: LocalAnswer, for bideID: UUID) {
        guard let data = try? JSONEncoder().encode(answer) else { return }
        defaults.set(data, forKey: key(bideID))
    }

    public func clear(_ bideID: UUID) {
        defaults.removeObject(forKey: key(bideID))
    }

    private func key(_ bideID: UUID) -> String { keyPrefix + bideID.uuidString }
}
