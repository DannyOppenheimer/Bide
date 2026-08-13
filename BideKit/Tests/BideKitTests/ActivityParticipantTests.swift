import XCTest
@testable import BideKit

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
        XCTAssertEqual(flattened.line, "9 minutes")
    }

    func testAnEndedJourneyCarriesNoDate() {
        for status in [ParticipantStatus.arrived, .declined] {
            let flattened = ActivityParticipant(
                participant: participant(status: status, minutesAway: 3),
                now: now
            )
            XCTAssertNil(flattened.eta, "\(status) should not count down")
        }
    }

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
