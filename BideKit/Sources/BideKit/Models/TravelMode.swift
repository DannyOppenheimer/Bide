import Foundation

/// A participant's mode of travel.
///
/// Only modes in ``selectable`` can be persisted. Cycling estimates use a
/// walking route because MapKit does not provide cycling directions.
public enum TravelMode: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case walking
    case driving
    case cycling
    case flying
    case transit
    case train

    public var id: String { rawValue }

    /// Modes for which Bide can calculate an ETA.
    public static let selectable: [TravelMode] = [.walking, .driving, .cycling, .transit]

    /// Modes in their visual display order.
    public static let displayOrder: [TravelMode] = [.walking, .driving, .cycling, .flying, .transit]

    /// Whether the mode is available for selection.
    public var isSelectable: Bool { Self.selectable.contains(self) }

    /// SF Symbol shown in the mode row.
    public var symbolName: String {
        switch self {
        case .walking: "figure.walk"
        case .driving: "car.fill"
        case .cycling: "bicycle"
        case .flying: "airplane"
        case .transit: "tram.fill"
        case .train: "train.side.front.car"
        }
    }

    public var title: String {
        switch self {
        case .walking: "Walking"
        case .driving: "Driving"
        case .cycling: "Cycling"
        case .flying: "Flying"
        case .transit: "Transit"
        case .train: "Train"
        }
    }

    /// The periodic interval between ETA recalculations.
    public var reanchorInterval: TimeInterval {
        switch self {
        case .driving, .transit, .train, .flying: 5 * 60
        case .walking, .cycling: 10 * 60
        }
    }

    /// Whether route deviation can trigger an ETA recalculation.
    ///
    /// Cycling uses its proxy walking route. Modes without a route polyline
    /// rely on periodic recalculation instead.
    public var tracksRouteDeviation: Bool {
        switch self {
        case .walking, .driving, .cycling: true
        case .transit, .flying, .train: false
        }
    }
}
