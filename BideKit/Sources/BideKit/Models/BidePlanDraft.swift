import Foundation

/// A bide being composed, before it exists anywhere.
///
/// The same draft backs both places a bide can be started — the Messages
/// compose sheet and "Create Solo-Bide" in the app — because they ask for the
/// same four things. Keeping it here rather than in a view means the rules
/// about when a draft is sendable are testable.
public struct BidePlanDraft: Equatable, Sendable {

    public var destination: Destination?
    public var mode: TravelMode
    /// When to be there. Nil means as soon as everyone can make it.
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

    /// A destination is the only thing that can't be defaulted.
    public var isComplete: Bool { destination != nil }

    /// Whether the time asked for has already gone. Worth catching before
    /// anything is sent — a meetup in the past helps nobody.
    public func isInThePast(now: Date = Date()) -> Bool {
        guard let scheduledFor else { return false }
        return scheduledFor < now
    }

    /// The invite this draft becomes. Nil until there's somewhere to go.
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

    /// Rounds "now plus a bit" to the next quarter hour, which is what the
    /// date and time chips open on. People arrange to meet at :00, :15, :30
    /// and :45, not at 3:07.
    public static func defaultTime(after now: Date = Date(), calendar: Calendar = .current) -> Date {
        let minute = calendar.component(.minute, from: now)
        let next = ((minute / 15) + 1) * 15
        let base = calendar.date(bySetting: .second, value: 0, of: now) ?? now
        return calendar.date(byAdding: .minute, value: next - minute, to: base) ?? now
    }
}
