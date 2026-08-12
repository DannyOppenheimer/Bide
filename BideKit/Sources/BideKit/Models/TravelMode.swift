import Foundation

/// How someone is travelling to the destination.
///
/// The picker shows all six in ``displayOrder`` because the design's mode row
/// is part of the brand, but only ``selectable`` modes can be chosen or
/// persisted — `participants.mode` is constrained to exactly those. The rest
/// are shown dimmed:
///
/// - `cycling` has no MapKit directions API, so an honest ETA isn't available.
/// - `flying` and `train` need live carrier tracking, which is deliberately
///   out of scope for this pass.
public enum TravelMode: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case walking
    case driving
    case cycling
    case flying
    case transit
    case train

    public var id: String { rawValue }

    /// The modes Bide can compute a real ETA for today.
    public static let selectable: [TravelMode] = [.walking, .driving, .transit]

    /// Left to right, as the design lays the row out.
    public static let displayOrder: [TravelMode] = [.walking, .driving, .cycling, .flying, .transit]

    /// Whether this mode can be picked. Everything else in ``displayOrder`` is
    /// rendered, but disabled.
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

    /// How often the ETA engine re-anchors on a timer, per the
    /// anchor-and-countdown policy: 5 minutes for modes exposed to traffic and
    /// timetables, 10 minutes for modes that move at a steady human pace.
    public var reanchorInterval: TimeInterval {
        switch self {
        case .driving, .transit, .train, .flying: 5 * 60
        case .walking, .cycling: 10 * 60
        }
    }

    /// Whether a re-anchor should be triggered by drifting off the planned
    /// route. Only modes MapKit returns a polyline for can answer that;
    /// transit has an ETA but no followable route, so it re-anchors on the
    /// timer alone.
    public var tracksRouteDeviation: Bool {
        switch self {
        case .walking, .driving: true
        case .transit, .cycling, .flying, .train: false
        }
    }
}
