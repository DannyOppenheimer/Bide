import XCTest
@testable import BideKit

final class BidePlannerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_786_000_000)
    private let me = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let them = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func participant(
        _ id: UUID,
        name: String,
        minutesAway: Int?,
        hasLeft: Bool = false,
        status: ParticipantStatus = .accepted,
        mode: TravelMode = .driving
    ) -> Participant {
        Participant(
            userID: id,
            displayName: name,
            mode: mode,
            etaTimestamp: minutesAway.map { now.addingTimeInterval(TimeInterval($0 * 60)) },
            travelTime: minutesAway.map { TimeInterval($0 * 60) },
            leftAt: hasLeft ? now.addingTimeInterval(-60) : nil,
            status: status,
            updatedAt: now
        )
    }

    private func bide(
        scheduledFor: Date?,
        style: ArrivalStyle = .onTime,
        participants: [Participant]
    ) -> BideState {
        BideState(
            bideID: UUID(),
            destinationName: "Nats Park",
            lat: 38.873,
            lng: -77.007,
            scheduledFor: scheduledFor,
            arrivalStyle: style,
            createdAt: now,
            createdBy: me,
            participants: participants
        )
    }

    // MARK: - Arrive on time

    func testOnTimeLeavesYourOwnJourneyBeforeTheAgreedTime() {
        let state = bide(
            scheduledFor: now.addingTimeInterval(60 * 60),
            participants: [
                participant(me, name: "Ada", minutesAway: 15),
                participant(them, name: "Sarah", minutesAway: 45),
            ]
        )

        let plan = BidePlanner.plan(for: state, me: me, myTravelTime: 15 * 60, now: now)

        XCTAssertEqual(plan.targetArrival, now.addingTimeInterval(60 * 60))
        XCTAssertEqual(plan.departure, now.addingTimeInterval(45 * 60))
        XCTAssertFalse(plan.isHeldBack, "an on-time bide never holds anyone back")
    }

    func testNoTravelTimeMeansNoDeparture() {
        let state = bide(
            scheduledFor: now.addingTimeInterval(3600),
            participants: [participant(me, name: "Ada", minutesAway: nil)]
        )

        XCTAssertNil(BidePlanner.plan(for: state, me: me, myTravelTime: nil, now: now).departure)
    }

    // MARK: - As soon as everyone can

    func testAsapTargetsTheLongestJourney() {
        let state = bide(
            scheduledFor: nil,
            participants: [
                participant(me, name: "Ada", minutesAway: 10),
                participant(them, name: "Sarah", minutesAway: 40),
            ]
        )

        let plan = BidePlanner.plan(for: state, me: me, myTravelTime: 10 * 60, now: now)

        XCTAssertEqual(plan.targetArrival, now.addingTimeInterval(40 * 60))
        XCTAssertEqual(plan.departure, now.addingTimeInterval(30 * 60), "30 minutes on the couch")
    }

    func testDeclinedParticipantsDoNotSetTheTarget() {
        let state = bide(
            scheduledFor: nil,
            participants: [
                participant(me, name: "Ada", minutesAway: 10),
                participant(them, name: "Sarah", minutesAway: 90, status: .declined),
            ]
        )

        let plan = BidePlanner.plan(for: state, me: me, myTravelTime: 10 * 60, now: now)
        XCTAssertEqual(plan.targetArrival, now.addingTimeInterval(10 * 60))
    }

    // MARK: - Departure

    func testAnAnchoredETAIsNotDeparture() {
        let state = bide(
            scheduledFor: now.addingTimeInterval(60 * 60),
            participants: [participant(me, name: "Ada", minutesAway: 15)]
        )

        let plan = BidePlanner.plan(for: state, me: me, myTravelTime: 15 * 60, now: now)

        XCTAssertFalse(plan.hasDeparted)
        XCTAssertEqual(BidePlanner.headline(for: plan, state: state, now: now), "Leave in 45 minutes")
    }

    func testAnAsapBideSaysLeaveNowUntilTheyActuallyGo() {
        let state = bide(
            scheduledFor: nil,
            participants: [participant(me, name: "Ada", minutesAway: 20)]
        )

        let waiting = BidePlanner.plan(for: state, me: me, myTravelTime: 20 * 60, now: now)
        XCTAssertEqual(waiting.departure, now)
        XCTAssertEqual(BidePlanner.headline(for: waiting, state: state, now: now), "Leave now")

        let gone = BidePlanner.plan(for: state, me: me, myTravelTime: 20 * 60, hasDeparted: true, now: now)
        XCTAssertEqual(BidePlanner.headline(for: gone, state: state, now: now), "On the way")
    }

    func testDepartureIsTakenFromTheRowWhenTheCallerDoesNotKnow() {
        let state = bide(
            scheduledFor: now.addingTimeInterval(3600),
            participants: [participant(me, name: "Ada", minutesAway: 15, hasLeft: true)]
        )

        let plan = BidePlanner.plan(for: state, me: me, myTravelTime: 15 * 60, now: now)
        XCTAssertTrue(plan.hasDeparted)
    }

    func testArrivalMovesWithTheClockUntilTheyLeave() {
        let state = bide(
            scheduledFor: now.addingTimeInterval(3600),
            participants: [participant(me, name: "Ada", minutesAway: 15)]
        )

        let plan = BidePlanner.plan(for: state, me: me, myTravelTime: 15 * 60, now: now)
        XCTAssertEqual(plan.arrival, now.addingTimeInterval(15 * 60))

        let later = now.addingTimeInterval(30 * 60)
        let stillAtHome = BidePlanner.plan(for: state, me: me, myTravelTime: 15 * 60, now: later)
        XCTAssertEqual(
            stillAtHome.arrival,
            later.addingTimeInterval(15 * 60),
            "standing still doesn't get you any closer"
        )
    }

    // MARK: - Arrive at the same time

    func testTogetherHoldsEveryoneUntilTheFurthestActuallyLeaves() {
        let state = bide(
            scheduledFor: now.addingTimeInterval(3600),
            style: .together,
            participants: [
                participant(me, name: "Ada", minutesAway: 10),
                participant(them, name: "Sarah", minutesAway: 50),
            ]
        )

        let plan = BidePlanner.plan(for: state, me: me, myTravelTime: 10 * 60, now: now)

        XCTAssertTrue(plan.isHeldBack)
        XCTAssertNil(plan.departure)
        XCTAssertEqual(plan.waitingOn?.userID, them)
        XCTAssertEqual(
            BidePlanner.headline(for: plan, state: state, now: now),
            "Waiting for Sarah to leave"
        )
    }

    func testTogetherWaitsOnAnyoneWithoutAnEstimate() {
        let state = bide(
            scheduledFor: now.addingTimeInterval(3600),
            style: .together,
            participants: [
                participant(me, name: "Ada", minutesAway: 10),
                participant(them, name: "Sarah", minutesAway: nil),
            ]
        )

        let plan = BidePlanner.plan(for: state, me: me, myTravelTime: 10 * 60, now: now)

        XCTAssertTrue(plan.isHeldBack)
        XCTAssertEqual(plan.waitingOn?.userID, them)
    }

    func testTogetherReleasesOnceTheFurthestHasLeft() {
        let state = bide(
            scheduledFor: now.addingTimeInterval(3600),
            style: .together,
            participants: [
                participant(me, name: "Ada", minutesAway: 10),
                participant(them, name: "Sarah", minutesAway: 50, hasLeft: true),
            ]
        )

        let plan = BidePlanner.plan(for: state, me: me, myTravelTime: 10 * 60, now: now)

        XCTAssertFalse(plan.isHeldBack)
        XCTAssertEqual(plan.targetArrival, now.addingTimeInterval(50 * 60))
        XCTAssertEqual(plan.departure, now.addingTimeInterval(40 * 60), "10 minutes behind Sarah")
        XCTAssertEqual(BidePlanner.headline(for: plan, state: state, now: now), "Leave in 40 minutes")
    }

    func testTogetherSaysLeaveNowWhenTheFurthestIsAsCloseAsYouAre() {
        let state = bide(
            scheduledFor: now.addingTimeInterval(3600),
            style: .together,
            participants: [
                participant(me, name: "Ada", minutesAway: 10),
                participant(them, name: "Sarah", minutesAway: 10, hasLeft: true),
            ]
        )

        let plan = BidePlanner.plan(for: state, me: me, myTravelTime: 10 * 60, now: now)
        XCTAssertEqual(BidePlanner.headline(for: plan, state: state, now: now), "Leave now")
    }

    func testTheFurthestPersonIsNotHeldBackByThemselves() {
        let state = bide(
            scheduledFor: now.addingTimeInterval(3600),
            style: .together,
            participants: [
                participant(me, name: "Ada", minutesAway: 50),
                participant(them, name: "Sarah", minutesAway: 10),
            ]
        )

        let plan = BidePlanner.plan(for: state, me: me, myTravelTime: 50 * 60, now: now)

        XCTAssertFalse(plan.isHeldBack)
        XCTAssertEqual(plan.departure, now.addingTimeInterval(10 * 60))
    }

    // MARK: - Headlines

    func testHeadlineCountsDownToDeparture() {
        let state = bide(
            scheduledFor: now.addingTimeInterval(3600),
            participants: [participant(me, name: "Ada", minutesAway: 50)]
        )
        let plan = BidePlanner.plan(for: state, me: me, myTravelTime: 50 * 60, now: now)

        XCTAssertEqual(BidePlanner.headline(for: plan, state: state, now: now), "Leave in 10 minutes")
    }

    func testHeadlineWhenEveryoneHasArrived() {
        let state = bide(
            scheduledFor: nil,
            participants: [participant(me, name: "Ada", minutesAway: 0, status: .arrived)]
        )
        let plan = BidePlanner.plan(for: state, me: me, myTravelTime: 0, now: now)

        XCTAssertTrue(state.isComplete)
        XCTAssertEqual(BidePlanner.headline(for: plan, state: state, now: now), "Everyone's here")
    }

    func testHeadlineWhileWaitingOnAnswers() {
        let state = bide(
            scheduledFor: nil,
            participants: [
                participant(me, name: "Ada", minutesAway: nil),
                participant(them, name: "Sarah", minutesAway: nil, status: .invited),
            ]
        )
        let plan = BidePlanner.plan(for: state, me: me, myTravelTime: nil, now: now)

        XCTAssertEqual(
            BidePlanner.headline(for: plan, state: state, now: now),
            "Waiting for everyone to answer"
        )
    }
}
