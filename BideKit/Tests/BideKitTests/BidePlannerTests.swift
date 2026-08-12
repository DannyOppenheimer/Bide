import XCTest
@testable import BideKit

/// The claim the whole product rests on: Bide knows when *you* should leave.
/// It is worked out here, so it can be proved without a device, a network, or
/// a clock that moves.
final class BidePlannerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_786_000_000)
    private let me = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let them = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func participant(
        _ id: UUID,
        name: String,
        minutesAway: Int?,
        status: ParticipantStatus = .accepted,
        mode: TravelMode = .driving
    ) -> Participant {
        Participant(
            userID: id,
            displayName: name,
            mode: mode,
            etaTimestamp: minutesAway.map { now.addingTimeInterval(TimeInterval($0 * 60)) },
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

    /// The everyday case: a time was agreed, so each person leaves their own
    /// journey ahead of it. Being closer means leaving later — the point of
    /// the app.
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

    /// Without an ETA of their own there is nothing to subtract, and the plan
    /// says so rather than guessing at zero.
    func testNoTravelTimeMeansNoDeparture() {
        let state = bide(
            scheduledFor: now.addingTimeInterval(3600),
            participants: [participant(me, name: "Ada", minutesAway: nil)]
        )

        XCTAssertNil(BidePlanner.plan(for: state, me: me, myTravelTime: nil, now: now).departure)
    }

    // MARK: - As soon as everyone can

    /// With no agreed time, the target is the longest journey among the people
    /// going — the only arrival everyone can actually make.
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

    /// Someone who declined must not drag the meeting later.
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

    // MARK: - Arrive at the same time

    /// Nobody moves until the furthest person has set off. "Has set off" is
    /// the presence of an ETA — the engine only produces one for someone in
    /// motion.
    func testTogetherHoldsEveryoneUntilTheFurthestLeaves() {
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
        XCTAssertEqual(
            BidePlanner.headline(for: plan, state: state, now: now),
            "Waiting for Sarah to leave"
        )
    }

    /// Once they're moving, everyone else gets a real leave time.
    func testTogetherReleasesOnceTheFurthestHasLeft() {
        let state = bide(
            scheduledFor: now.addingTimeInterval(3600),
            style: .together,
            participants: [
                participant(me, name: "Ada", minutesAway: 10),
                participant(them, name: "Sarah", minutesAway: 50),
            ]
        )

        let plan = BidePlanner.plan(for: state, me: me, myTravelTime: 10 * 60, now: now)

        XCTAssertFalse(plan.isHeldBack)
        XCTAssertEqual(plan.departure, now.addingTimeInterval(50 * 60))
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
