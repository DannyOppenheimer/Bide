import Foundation

/// The current timing instructions for one participant.
public struct BidePlan: Equatable, Sendable {

    /// Shared target arrival time.
    public let targetArrival: Date?
    /// Local departure time, or `nil` while unavailable or held back.
    public let departure: Date?
    /// Whether this participant must wait for the longest traveller to leave.
    public let isHeldBack: Bool
    /// The participant whose departure currently gates this plan.
    public let waitingOn: Participant?
    /// Most recent travel-time estimate for this participant.
    public let travelTime: TimeInterval?
    /// Expected arrival. Before departure, this remains relative to the current time.
    public let arrival: Date?
    /// Whether the participant has left the departure area.
    public let hasDeparted: Bool
    /// Whether the participant has arrived.
    public let hasArrived: Bool

    public init(
        targetArrival: Date?,
        departure: Date?,
        isHeldBack: Bool = false,
        waitingOn: Participant? = nil,
        travelTime: TimeInterval? = nil,
        arrival: Date? = nil,
        hasDeparted: Bool = false,
        hasArrived: Bool = false
    ) {
        self.targetArrival = targetArrival
        self.departure = departure
        self.isHeldBack = isHeldBack
        self.waitingOn = waitingOn
        self.travelTime = travelTime
        self.arrival = arrival
        self.hasDeparted = hasDeparted
        self.hasArrived = hasArrived
    }
}

/// Calculates one participant's departure and arrival plan from shared state.
/// An available ETA does not imply departure; movement is tracked separately.
public enum BidePlanner {

    /// - Parameters:
    ///   - myTravelTime: Current on-device travel estimate, if available.
    ///   - hasDeparted: Local departure state, which may be newer than the server value.
    public static func plan(
        for state: BideState,
        me: UUID,
        myTravelTime: TimeInterval?,
        hasDeparted: Bool = false,
        now: Date = Date()
    ) -> BidePlan {
        let mine = state.participant(me)
        let departed = hasDeparted || mine?.hasLeft == true
        let hasArrived = mine?.status == .arrived

        // After departure the server ETA is fixed; before departure it moves with `now`.
        let myArrival: Date?
        if departed, let eta = mine?.etaTimestamp {
            myArrival = eta
        } else {
            myArrival = myTravelTime.map { now.addingTimeInterval($0) }
        }

        let others = state.participants(besides: me).filter { $0.status.isTravelling }

        // Use the scheduled time, or derive an ASAP target from the longest journey.
        let longestOtherJourney = others
            .compactMap { $0.arrival(now: now)?.timeIntervalSince(now) }
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

        func plan(
            targetArrival: Date?,
            departure: Date?,
            isHeldBack: Bool = false,
            waitingOn: Participant? = nil
        ) -> BidePlan {
            BidePlan(
                targetArrival: targetArrival,
                departure: departure,
                isHeldBack: isHeldBack,
                waitingOn: waitingOn,
                travelTime: myTravelTime,
                arrival: myArrival,
                hasDeparted: departed,
                hasArrived: hasArrived
            )
        }

        guard state.arrivalStyle == .together else {
            return plan(targetArrival: target, departure: departure)
        }

        // MARK: Arrive together
        // Hold departures until every traveller has an estimate and the longest
        // traveller leaves. Their projected arrival then becomes the shared target.
        if let unestimated = others.first(where: { $0.arrival(now: now) == nil }) {
            return plan(
                targetArrival: target,
                departure: nil,
                isHeldBack: !departed,
                waitingOn: unestimated
            )
        }

        guard
            let furthest = others.max(by: { lhs, rhs in
                (lhs.arrival(now: now) ?? .distantPast) < (rhs.arrival(now: now) ?? .distantPast)
            }),
            let furthestArrival = furthest.arrival(now: now)
        else {
            // With no other traveller, use the ordinary departure plan.
            return plan(targetArrival: target, departure: departure)
        }

        guard furthest.hasLeft else {
            // The local participant may leave first if their journey is at least as long.
            if let myArrival, myArrival >= furthestArrival {
                return plan(targetArrival: target, departure: departure)
            }
            return plan(
                targetArrival: target,
                departure: nil,
                isHeldBack: !departed,
                waitingOn: furthest
            )
        }

        // Work each departure backward from the longest traveller's projected arrival.
        return plan(
            targetArrival: furthestArrival,
            departure: myTravelTime.map { furthestArrival.addingTimeInterval(-$0) }
        )
    }

    /// Builds a watcher headline about the traveller instead of the local user.
    public static func watcherHeadline(for state: BideState, now: Date = Date()) -> String {
        guard let traveller = state.travellers.first ?? state.roster.first else {
            // The card remains visible until the next refresh removes it.
            return "Nobody is going any more"
        }

        let who = BideFormat.name(traveller)
        switch traveller.status {
        case .arrived: return "\(who) is there"
        case .declined, .watching, .invited: return "\(who) hasn't set off"
        case .accepted:
            guard traveller.hasLeft else { return "\(who) hasn't left yet" }
            guard let arrival = traveller.arrival(now: now) else { return "\(who) is on the way" }
            return "\(who) arrives at \(BideFormat.time(arrival))"
        }
    }

    /// Builds the primary status line shared by cards, tiles, and Live Activities.
    public static func headline(for plan: BidePlan, state: BideState, now: Date = Date()) -> String {
        if state.isComplete { return "Everyone's here" }
        if plan.hasArrived { return "You're here" }
        // Departure instructions are no longer relevant once travel begins.
        if plan.hasDeparted { return "On the way" }

        if plan.isHeldBack, let waitingOn = plan.waitingOn {
            return "Waiting for \(BideFormat.name(waitingOn)) to leave"
        }
        if let departure = plan.departure {
            return BideFormat.leavePhrase(at: departure, now: now)
        }
        if state.isAwaitingAnswers {
            return "Waiting for everyone to answer"
        }
        // No estimate is available yet.
        if state.isSolo { return "Working out when to leave" }
        // The destination is already displayed beside this status.
        return "Nobody has set off yet"
    }

    /// Returns the greater available value without treating `nil` as zero.
    private static func max(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> TimeInterval? {
        switch (lhs, rhs) {
        case (let lhs?, let rhs?): Swift.max(lhs, rhs)
        case (let lhs?, nil): lhs
        case (nil, let rhs?): rhs
        case (nil, nil): nil
        }
    }
}

/// Combines two optional values only when both are present.
private func zip<A, B>(_ lhs: A?, _ rhs: B?) -> (A, B)? {
    guard let lhs, let rhs else { return nil }
    return (lhs, rhs)
}
