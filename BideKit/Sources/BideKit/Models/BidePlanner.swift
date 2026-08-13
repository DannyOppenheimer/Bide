import Foundation

/// What a bide is asking of one person right now.
public struct BidePlan: Equatable, Sendable {

    /// When everyone is aiming to be there.
    public let targetArrival: Date?
    /// When *this* person should set off. Nil until there's an ETA to work
    /// back from.
    public let departure: Date?
    /// True when the answer is "not yet": an arrive-together bide where the
    /// person with the longest journey hasn't set off, so telling anyone else
    /// to leave would only make them wait at the other end.
    public let isHeldBack: Bool
    /// Who everyone is waiting on, when they're being held back.
    public let waitingOn: Participant?

    public init(
        targetArrival: Date?,
        departure: Date?,
        isHeldBack: Bool = false,
        waitingOn: Participant? = nil
    ) {
        self.targetArrival = targetArrival
        self.departure = departure
        self.isHeldBack = isHeldBack
        self.waitingOn = waitingOn
    }
}

/// Turns a bide plus one person's travel time into "leave at".
///
/// Pure and separate from the engine, because this is the product's central
/// claim — that Bide knows when *you* should leave — and it should be provable
/// without a device, a network, or a clock that moves.
public enum BidePlanner {

    /// - Parameters:
    ///   - myTravelTime: How long this person's journey takes right now, from
    ///     the on-device ETA engine. Nil if it hasn't been anchored yet.
    public static func plan(
        for state: BideState,
        me: UUID,
        myTravelTime: TimeInterval?,
        now: Date = Date()
    ) -> BidePlan {
        let others = state.participants(besides: me).filter { $0.status.isTravelling }

        // What everyone is aiming for. An agreed time wins; otherwise it's the
        // longest journey among the people going, which is the only arrival
        // time everyone can actually make.
        let longestOtherJourney = others
            .compactMap { $0.etaTimestamp?.timeIntervalSince(now) }
            .max()
        let target: Date?
        if let scheduled = state.scheduledFor {
            target = scheduled
        } else if let longest = max(longestOtherJourney, myTravelTime) {
            target = now.addingTimeInterval(longest)
        } else {
            target = nil
        }

        let departure = zip(target, myTravelTime).map { $0.addingTimeInterval(-$1) }

        // Arrive-together: nobody moves until the furthest person does. "Has
        // left" is the presence of an ETA — the engine only produces one once
        // it's tracking someone in motion.
        guard state.arrivalStyle == .together else {
            return BidePlan(targetArrival: target, departure: departure)
        }

        let furthest = others.max { lhs, rhs in
            (lhs.etaTimestamp ?? .distantPast) < (rhs.etaTimestamp ?? .distantPast)
        }
        let waitingOn = others.first { !$0.hasLeft }

        return BidePlan(
            targetArrival: target,
            departure: departure,
            isHeldBack: waitingOn != nil,
            waitingOn: waitingOn ?? furthest
        )
    }

    /// The one line the card, the tile, and the Live Activity all lead with.
    public static func headline(for plan: BidePlan, state: BideState, now: Date = Date()) -> String {
        if state.isComplete { return "Everyone's here" }

        if plan.isHeldBack, let waitingOn = plan.waitingOn {
            return "Waiting for \(BideFormat.name(waitingOn)) to leave"
        }
        if let departure = plan.departure {
            return BideFormat.leavePhrase(at: departure, now: now)
        }
        if state.isAwaitingAnswers {
            return "Waiting for everyone to answer"
        }
        // Deliberately not "Heading to <place>". Every surface that shows this
        // line now shows the destination beside it, so naming it here printed
        // it twice; this says the thing the destination can't, which is that
        // everybody has said yes and nobody has moved.
        return "Nobody has set off yet"
    }

    /// `max` over two optionals, where nil means "no opinion" rather than
    /// "zero" — a participant without an ETA must not drag the target down.
    private static func max(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> TimeInterval? {
        switch (lhs, rhs) {
        case (let lhs?, let rhs?): Swift.max(lhs, rhs)
        case (let lhs?, nil): lhs
        case (nil, let rhs?): rhs
        case (nil, nil): nil
        }
    }
}

/// `zip` for optionals — both present, or nothing.
private func zip<A, B>(_ lhs: A?, _ rhs: B?) -> (A, B)? {
    guard let lhs, let rhs else { return nil }
    return (lhs, rhs)
}
