import Foundation

/// What "meeting up" means for a given bide. Chosen once by whoever sends the
/// tile, and it changes what everyone is told to do.
public enum ArrivalStyle: String, Codable, Sendable, CaseIterable, Identifiable {

    /// Everyone should be there by the scheduled time. Each person gets their
    /// own "leave at" derived from their own ETA, so they all land together at
    /// the time that was agreed.
    case onTime = "on_time"

    /// Everyone should arrive at the same moment, whenever that turns out to
    /// be. Nobody is told to leave until the person with the longest journey
    /// sets off; the rest are held back so they aren't left waiting.
    case together

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .onTime: "Arrive on time"
        case .together: "Arrive at the same time"
        }
    }

    /// One line explaining the consequence, for the compose sheet.
    public var explanation: String {
        switch self {
        case .onTime: "Everyone gets their own leave time for the hour you picked."
        case .together: "Nobody leaves until the furthest person does."
        }
    }
}
