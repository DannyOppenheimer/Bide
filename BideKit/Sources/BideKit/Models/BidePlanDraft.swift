import Foundation

/// Editable values used to compose either an invitation or a solo bide.
public struct BidePlanDraft: Equatable, Sendable {

    public var destination: Destination?
    public var mode: TravelMode
    /// Desired arrival time. `nil` means as soon as possible.
    public var scheduledFor: Date?
    public var arrivalStyle: ArrivalStyle

    public init(
        destination: Destination? = nil,
        mode: TravelMode = .walking,
        scheduledFor: Date? = nil,
        arrivalStyle: ArrivalStyle = .onTime
    ) {
        self.destination = destination
        self.mode = mode
        self.scheduledFor = scheduledFor
        self.arrivalStyle = arrivalStyle
    }

    /// Whether all required values have been provided.
    public var isComplete: Bool { destination != nil }

    /// Whether the selected arrival time is in the past.
    public func isInThePast(now: Date = Date()) -> Bool {
        guard let scheduledFor else { return false }
        return scheduledFor < now
    }

    /// Creates an invitation, or returns `nil` if no destination is selected.
    public func invite(id: UUID = UUID(), createdAt: Date = Date()) -> BideInvite? {
        guard let destination else { return nil }
        return BideInvite(
            bideID: id,
            destinationName: destination.name,
            lat: destination.latitude,
            lng: destination.longitude,
            scheduledFor: scheduledFor,
            arrivalStyle: arrivalStyle,
            createdAt: createdAt
        )
    }

    /// Returns the next quarter-hour boundary after `now`.
    public static func defaultTime(after now: Date = Date(), calendar: Calendar = .current) -> Date {
        let minute = calendar.component(.minute, from: now)
        let next = ((minute / 15) + 1) * 15
        let base = calendar.date(bySetting: .second, value: 0, of: now) ?? now
        return calendar.date(byAdding: .minute, value: next - minute, to: base) ?? now
    }
}
