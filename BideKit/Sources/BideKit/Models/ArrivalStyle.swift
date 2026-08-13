import Foundation

/// Determines how participant departure times are coordinated.
public enum ArrivalStyle: String, Codable, Sendable, CaseIterable, Identifiable {

    /// Each participant leaves in time to reach the scheduled arrival time.
    case onTime = "on_time"

    /// Participants coordinate departures around the longest journey.
    case together

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .onTime: "Arrive on time"
        case .together: "Arrive at the same time"
        }
    }

    /// A short description for the compose sheet.
    public var explanation: String {
        switch self {
        case .onTime: "Everyone gets their own leave time for the hour you picked."
        case .together: "Nobody leaves until the furthest person does."
        }
    }
}
