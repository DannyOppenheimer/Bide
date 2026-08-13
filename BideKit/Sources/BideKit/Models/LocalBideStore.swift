import Foundation

/// What this device decided about a bide.
public struct LocalAnswer: Codable, Equatable, Sendable {

    public let status: ParticipantStatus
    public let mode: TravelMode
    /// Departure time calculated when the participant accepted.
    public let leaveAt: Date?
    public let answeredAt: Date

    public init(status: ParticipantStatus, mode: TravelMode, leaveAt: Date? = nil, answeredAt: Date = Date()) {
        self.status = status
        self.mode = mode
        self.leaveAt = leaveAt
        self.answeredAt = answeredAt
    }
}

/// Caches this process's answers for immediate tile rendering.
/// The server remains the authoritative source for participant state.
public struct LocalBideStore: @unchecked Sendable {

    /// `UserDefaults` is thread-safe, which supports the unchecked conformance.
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
