import XCTest
@testable import BideKit

/// The bridge between a roster row and the lock screen.
///
/// The Live Activity is redrawn only when the app pushes it something, while
/// the app's own roster redraws every second off a ticking clock. That is why
/// the arrival time crosses as a *date* and not only as the string the app
/// rendered from it: a string is right for one instant, and the lock screen is
/// looked at at all the others. With the date carried across, both surfaces
/// render it live and cannot drift apart — which they did, by a minute, on the
/// same person at the same moment.
final class ActivityParticipantTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_786_000_000)
    private let me = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private func participant(
        status: ParticipantStatus,
        minutesAway: Int?
    ) -> Participant {
        Participant(
            userID: me,
            displayName: "Sarah",
            mode: .driving,
            etaTimestamp: minutesAway.map { now.addingTimeInterval(TimeInterval($0 * 60)) },
            status: status,
            updatedAt: now
        )
    }

    func testATravellerCarriesTheirArrivalTimeAcross() {
        let flattened = ActivityParticipant(
            participant: participant(status: .accepted, minutesAway: 9),
            now: now
        )

        XCTAssertEqual(flattened.eta, now.addingTimeInterval(9 * 60))
        // The rendered line still crosses, as the fallback for anywhere the
        // date can't be counted down — and for accessibility.
        XCTAssertEqual(flattened.line, "9 minutes")
    }

    /// "Arrived" and "Not coming" are statements, not countdowns. Handing them
    /// a date would start a clock against something that has already happened.
    func testAnEndedJourneyCarriesNoDate() {
        for status in [ParticipantStatus.arrived, .declined] {
            let flattened = ActivityParticipant(
                participant: participant(status: status, minutesAway: 3),
                now: now
            )
            XCTAssertNil(flattened.eta, "\(status) should not count down")
        }
    }

    /// Somebody who has said yes but hasn't set off has nothing to count down
    /// to yet, and the line says so.
    func testAcceptedButNotMovingHasNothingToCountDown() {
        let flattened = ActivityParticipant(
            participant: participant(status: .accepted, minutesAway: nil),
            now: now
        )

        XCTAssertNil(flattened.eta)
        XCTAssertEqual(flattened.line, "Waiting...")
    }

    func testTheReaderSeesThemselfAsYou() {
        let flattened = ActivityParticipant(
            participant: participant(status: .accepted, minutesAway: 9),
            me: me,
            now: now
        )

        XCTAssertEqual(flattened.name, "You")
        XCTAssertEqual(flattened.initial, "Y")
    }
}
