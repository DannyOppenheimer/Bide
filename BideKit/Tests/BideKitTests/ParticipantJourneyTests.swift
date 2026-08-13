import XCTest
@testable import BideKit

final class ParticipantJourneyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_786_000_000)
    private let me = UUID()

    private func participant(
        minutesAway: Int?,
        hasLeft: Bool = false,
        status: ParticipantStatus = .accepted
    ) -> Participant {
        Participant(
            userID: me,
            mode: .walking,
            etaTimestamp: minutesAway.map { now.addingTimeInterval(TimeInterval($0 * 60)) },
            travelTime: minutesAway.map { TimeInterval($0 * 60) },
            leftAt: hasLeft ? now.addingTimeInterval(-120) : nil,
            status: status,
            updatedAt: now
        )
    }

    // MARK: - Before departure

    func testAJourneyDoesNotShrinkWhileYouStandStill() {
        let ada = participant(minutesAway: 20)
        let later = now.addingTimeInterval(30 * 60)

        XCTAssertEqual(ada.remainingTravel(now: now), 20 * 60)
        XCTAssertEqual(ada.remainingTravel(now: later), 20 * 60)
        XCTAssertEqual(ada.arrival(now: now), now.addingTimeInterval(20 * 60))
        XCTAssertEqual(ada.arrival(now: later), later.addingTimeInterval(20 * 60))
    }

    func testHavingAnETAIsNotHavingLeft() {
        XCTAssertFalse(participant(minutesAway: 20).hasLeft)
        XCTAssertTrue(participant(minutesAway: 20, hasLeft: true).hasLeft)
    }

    // MARK: - After departure

    func testAnArrivalHoldsStillOnceTheyAreMoving() {
        let ada = participant(minutesAway: 20, hasLeft: true)
        let later = now.addingTimeInterval(5 * 60)

        XCTAssertEqual(ada.arrival(now: later), now.addingTimeInterval(20 * 60))
        XCTAssertEqual(ada.remainingTravel(now: later), 15 * 60)
    }

    func testAnOverdueArrivalStopsAtZero() {
        let ada = participant(minutesAway: 20, hasLeft: true)
        XCTAssertEqual(ada.remainingTravel(now: now.addingTimeInterval(60 * 60)), 0)
    }

    // MARK: - Unavailable state

    func testSomeoneWhoIsNotTravellingHasNoJourney() {
        for status in [ParticipantStatus.invited, .declined, .arrived] {
            let them = participant(minutesAway: 20, status: status)
            XCTAssertNil(them.arrival(now: now), "\(status)")
            XCTAssertNil(them.remainingTravel(now: now), "\(status)")
        }
    }

    func testAnOlderRowFallsBackToTheGapItWasWrittenWith() {
        let ada = Participant(
            userID: me,
            mode: .walking,
            etaTimestamp: now.addingTimeInterval(20 * 60),
            status: .accepted,
            updatedAt: now
        )

        XCTAssertEqual(ada.journey, 20 * 60)
    }

    // MARK: - Delay grades

    func testStandingStillIsNotBeingLate() {
        let ada = Participant(
            userID: me,
            mode: .walking,
            etaTimestamp: now.addingTimeInterval(50 * 60),
            baselineETA: now.addingTimeInterval(20 * 60),
            travelTime: 20 * 60,
            status: .accepted,
            updatedAt: now
        )

        XCTAssertEqual(ada.delayGrade, .onSchedule)
    }

    func testSlippingOnTheRoadIsColoured() {
        let ada = Participant(
            userID: me,
            mode: .walking,
            etaTimestamp: now.addingTimeInterval(30 * 60),
            baselineETA: now.addingTimeInterval(20 * 60),
            travelTime: 30 * 60,
            leftAt: now.addingTimeInterval(-120),
            status: .accepted,
            updatedAt: now
        )

        XCTAssertEqual(ada.delayGrade, .late)
    }

    // MARK: - Descriptions

    func testTheHeadlineNumberIsShortEnoughToFitUnderAnAvatar() {
        XCTAssertEqual(BideFormat.shortDuration(14 * 60), "14 min")
        XCTAssertEqual(BideFormat.shortDuration(65 * 60), "1 hr 5 min")
        XCTAssertEqual(BideFormat.shortDuration(30), "Under a min")
        XCTAssertEqual(BideFormat.compactDuration(14 * 60), "14m")
        XCTAssertEqual(BideFormat.compactDuration(65 * 60), "1h 5m")
    }

    func testTheClockTimesSayWhichIsWhich() {
        let scheduled = Date(timeIntervalSince1970: 1_786_030_800)
        XCTAssertTrue(BideFormat.scheduledLine(scheduled).hasPrefix("Scheduled ETA: "))
        XCTAssertTrue(BideFormat.actualLine(scheduled).hasPrefix("Actual: "))
        XCTAssertTrue(BideFormat.scheduledLine(scheduled).hasSuffix(BideFormat.time(scheduled)))
    }
}
