import XCTest
@testable import BideKit

final class DelayGradeTests: XCTestCase {

    func testThresholdsMatchTheDesign() {
        XCTAssertEqual(DelayGrade(delay: 0), .onSchedule)
        XCTAssertEqual(DelayGrade(delay: 119), .onSchedule)
        XCTAssertEqual(DelayGrade(delay: 120), .slipping, "two minutes late is the boundary")
        XCTAssertEqual(DelayGrade(delay: 7 * 60), .slipping)
        XCTAssertEqual(DelayGrade(delay: 8 * 60), .late, "eight minutes late is the boundary")
        XCTAssertEqual(DelayGrade(delay: 60 * 60), .late)
    }

    func testBeingEarlyIsNeverColoured() {
        XCTAssertEqual(DelayGrade(delay: -30 * 60), .onSchedule)
    }

    func testGradesAgainstTheOriginalEstimate() {
        let planned = Date(timeIntervalSince1970: 1_786_000_000)
        XCTAssertEqual(DelayGrade(projected: planned.addingTimeInterval(5 * 60), planned: planned), .slipping)
        XCTAssertEqual(DelayGrade(projected: planned.addingTimeInterval(20 * 60), planned: planned), .late)
    }

    func testParticipantWithoutABaselineHasNoGrade() {
        let eta = Date()
        XCTAssertNil(
            Participant(userID: UUID(), mode: .walking, etaTimestamp: eta, status: .accepted).delayGrade
        )
        XCTAssertNotNil(
            Participant(
                userID: UUID(),
                mode: .walking,
                etaTimestamp: eta,
                baselineETA: eta,
                status: .accepted
            ).delayGrade
        )
    }
}

final class ScheduleConflictTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    private func window(fromMinute start: Int, toMinute end: Int) -> TravelWindow {
        TravelWindow(
            leaveAt: now.addingTimeInterval(TimeInterval(start * 60)),
            arriveAt: now.addingTimeInterval(TimeInterval(end * 60))
        )
    }

    private func place(_ name: String) -> Destination {
        let offset = Double(name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) })
        return Destination(name: name, latitude: 38 + offset / 100, longitude: -77)
    }

    private func candidate(
        _ name: String,
        fromMinute start: Int,
        toMinute end: Int,
        at destination: Destination? = nil
    ) -> ScheduleConflict.Candidate {
        ScheduleConflict.Candidate(
            id: UUID(),
            destination: destination ?? place(name),
            window: window(fromMinute: start, toMinute: end)
        )
    }

    func testOverlappingJourneysConflict() {
        XCTAssertTrue(window(fromMinute: 0, toMinute: 60).overlaps(window(fromMinute: 30, toMinute: 90)))
    }

    func testWellSeparatedJourneysDoNotConflict() {
        XCTAssertFalse(window(fromMinute: 0, toMinute: 30).overlaps(window(fromMinute: 180, toMinute: 210)))
    }

    func testBackToBackJourneysConflictBecauseOfSlack() {
        XCTAssertTrue(window(fromMinute: 0, toMinute: 30).overlaps(window(fromMinute: 35, toMinute: 60)))
        XCTAssertFalse(
            window(fromMinute: 0, toMinute: 30).overlaps(window(fromMinute: 35, toMinute: 60), slack: 0),
            "with no slack these merely touch"
        )
    }

    func testABideDoesNotConflictWithItself() {
        let existing = candidate("Nats Park", fromMinute: 0, toMinute: 60)
        let conflicts = ScheduleConflict.conflicts(
            with: existing.window,
            goingTo: existing.destination,
            proposedID: existing.id,
            among: [existing]
        )
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testConflictsComeBackSoonestFirst() {
        let later = candidate("Later", fromMinute: 40, toMinute: 70)
        let sooner = candidate("Sooner", fromMinute: 10, toMinute: 50)

        let conflicts = ScheduleConflict.conflicts(
            with: window(fromMinute: 20, toMinute: 60),
            goingTo: place("Elsewhere"),
            among: [later, sooner]
        )
        XCTAssertEqual(conflicts.map(\.destinationName), ["Sooner", "Later"])
    }

    func testOverlappingBidesToTheSamePlaceDoNotConflict() {
        let ballpark = place("Nationals Park")
        let group = candidate("Nationals Park", fromMinute: 0, toMinute: 45, at: ballpark)

        let conflicts = ScheduleConflict.conflicts(
            with: window(fromMinute: 5, toMinute: 50),
            goingTo: ballpark,
            among: [group]
        )
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testNearbyRecordsOfOnePlaceCountAsTheSamePlace() {
        let gateA = Destination(name: "Nationals Park", latitude: 38.8730, longitude: -77.0074)
        let gateC = Destination(name: "Nationals Park Gate C", latitude: 38.8735, longitude: -77.0074)
        XCTAssertTrue(gateA.isSamePlace(as: gateC))

        let conflicts = ScheduleConflict.conflicts(
            with: window(fromMinute: 0, toMinute: 45),
            goingTo: gateA,
            among: [
                ScheduleConflict.Candidate(
                    id: UUID(),
                    destination: gateC,
                    window: window(fromMinute: 10, toMinute: 40)
                )
            ]
        )
        XCTAssertTrue(conflicts.isEmpty)
    }

    func testAnotherPlaceInTheSameWindowStillConflicts() {
        let ballpark = Destination(name: "Nationals Park", latitude: 38.8730, longitude: -77.0074)
        let bar = Destination(name: "Bluejacket", latitude: 38.8779, longitude: -77.0074)
        XCTAssertFalse(ballpark.isSamePlace(as: bar))

        let conflicts = ScheduleConflict.conflicts(
            with: window(fromMinute: 0, toMinute: 45),
            goingTo: ballpark,
            among: [
                ScheduleConflict.Candidate(
                    id: UUID(),
                    destination: bar,
                    window: window(fromMinute: 10, toMinute: 40)
                )
            ]
        )
        XCTAssertEqual(conflicts.map(\.destinationName), ["Bluejacket"])
    }

    func testWarningWording() {
        XCTAssertNil(ScheduleConflict.warning(for: []))
        XCTAssertEqual(
            ScheduleConflict.warning(for: [candidate("Nats Park", fromMinute: 0, toMinute: 30)]),
            "This overlaps Nats Park. You'll be removed from it."
        )
        XCTAssertEqual(
            ScheduleConflict.warning(for: [
                candidate("Nats Park", fromMinute: 0, toMinute: 30),
                candidate("Blue Bottle", fromMinute: 0, toMinute: 30),
            ]),
            "This overlaps Nats Park and Blue Bottle. You'll be removed from them."
        )
        XCTAssertEqual(
            ScheduleConflict.warning(for: [
                candidate("A", fromMinute: 0, toMinute: 30),
                candidate("B", fromMinute: 0, toMinute: 30),
                candidate("C", fromMinute: 0, toMinute: 30),
            ]),
            "This overlaps A, B, and C. You'll be removed from them."
        )
    }

    func testWindowIsNeverInverted() {
        let inverted = TravelWindow(leaveAt: now, arriveAt: now.addingTimeInterval(-600))
        XCTAssertEqual(inverted.duration, 0)
        XCTAssertEqual(TravelWindow(arriveAt: now, travelTime: -60).leaveAt, now)
    }
}
