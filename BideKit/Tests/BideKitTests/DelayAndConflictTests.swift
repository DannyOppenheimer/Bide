import XCTest
@testable import BideKit

/// The green / yellow / red thresholds from the design: yellow past two
/// minutes late, red past eight.
final class DelayGradeTests: XCTestCase {

    func testThresholdsMatchTheDesign() {
        XCTAssertEqual(DelayGrade(delay: 0), .onSchedule)
        XCTAssertEqual(DelayGrade(delay: 119), .onSchedule)
        XCTAssertEqual(DelayGrade(delay: 120), .slipping, "two minutes late is the boundary")
        XCTAssertEqual(DelayGrade(delay: 7 * 60), .slipping)
        XCTAssertEqual(DelayGrade(delay: 8 * 60), .late, "eight minutes late is the boundary")
        XCTAssertEqual(DelayGrade(delay: 60 * 60), .late)
    }

    /// Running early is never a fault. It's the thing Bide exists to stop
    /// people needing to do.
    func testBeingEarlyIsNeverColoured() {
        XCTAssertEqual(DelayGrade(delay: -30 * 60), .onSchedule)
    }

    func testGradesAgainstTheOriginalEstimate() {
        let planned = Date(timeIntervalSince1970: 1_786_000_000)
        XCTAssertEqual(DelayGrade(projected: planned.addingTimeInterval(5 * 60), planned: planned), .slipping)
        XCTAssertEqual(DelayGrade(projected: planned.addingTimeInterval(20 * 60), planned: planned), .late)
    }

    /// A participant with no baseline has nothing to be graded against, which
    /// must read as "no colour" rather than "on schedule".
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

/// Two bides clash when one person can't physically make both — which is
/// about overlapping journeys, not overlapping start times.
final class ScheduleConflictTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    private func window(fromMinute start: Int, toMinute end: Int) -> TravelWindow {
        TravelWindow(
            leaveAt: now.addingTimeInterval(TimeInterval(start * 60)),
            arriveAt: now.addingTimeInterval(TimeInterval(end * 60))
        )
    }

    private func candidate(_ name: String, fromMinute start: Int, toMinute end: Int) -> ScheduleConflict.Candidate {
        ScheduleConflict.Candidate(
            id: UUID(),
            destinationName: name,
            window: window(fromMinute: start, toMinute: end)
        )
    }

    func testOverlappingJourneysConflict() {
        XCTAssertTrue(window(fromMinute: 0, toMinute: 60).overlaps(window(fromMinute: 30, toMinute: 90)))
    }

    /// Far apart in the day, no clash — even with the slack applied.
    func testWellSeparatedJourneysDoNotConflict() {
        XCTAssertFalse(window(fromMinute: 0, toMinute: 30).overlaps(window(fromMinute: 180, toMinute: 210)))
    }

    /// Back-to-back with nothing between them is a clash in practice: you
    /// cannot arrive at one place and be leaving for another in the same
    /// instant.
    func testBackToBackJourneysConflictBecauseOfSlack() {
        XCTAssertTrue(window(fromMinute: 0, toMinute: 30).overlaps(window(fromMinute: 35, toMinute: 60)))
        XCTAssertFalse(
            window(fromMinute: 0, toMinute: 30).overlaps(window(fromMinute: 35, toMinute: 60), slack: 0),
            "with no slack these merely touch"
        )
    }

    /// Re-accepting a tile you're already in must not conflict with itself.
    func testABideDoesNotConflictWithItself() {
        let existing = candidate("Nats Park", fromMinute: 0, toMinute: 60)
        let conflicts = ScheduleConflict.conflicts(
            with: existing.window,
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
            among: [later, sooner]
        )
        XCTAssertEqual(conflicts.map(\.destinationName), ["Sooner", "Later"])
    }

    /// The exact sentence in the confirmation alert, so the wording is tested
    /// rather than assembled at the call site.
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

    /// A window can never be inverted, whatever the ETA engine hands over.
    func testWindowIsNeverInverted() {
        let inverted = TravelWindow(leaveAt: now, arriveAt: now.addingTimeInterval(-600))
        XCTAssertEqual(inverted.duration, 0)
        XCTAssertEqual(TravelWindow(arriveAt: now, travelTime: -60).leaveAt, now)
    }
}
