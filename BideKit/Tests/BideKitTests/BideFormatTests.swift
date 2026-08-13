import XCTest
@testable import BideKit

final class BideFormatTests: XCTestCase {

    private let me = UUID()

    private func participant(_ id: UUID, named name: String?) -> Participant {
        Participant(userID: id, displayName: name, mode: .walking, status: .accepted)
    }

    func testTheLocalUserIsCalledYouEvenWithoutAName() {
        XCTAssertEqual(BideFormat.name(participant(me, named: nil), me: me), "You")
        XCTAssertEqual(BideFormat.initial(participant(me, named: nil), me: me), "Y")
    }

    func testYouWinsOverTheLocalUsersOwnName() {
        XCTAssertEqual(BideFormat.name(participant(me, named: "Danny"), me: me), "You")
    }

    func testOtherPeopleKeepTheirNames() {
        let sarah = participant(UUID(), named: "Sarah")
        XCTAssertEqual(BideFormat.name(sarah, me: me), "Sarah")
        XCTAssertEqual(BideFormat.initial(sarah, me: me), "S")
    }

    func testAnUnnamedStrangerIsStillSomeone() {
        XCTAssertEqual(BideFormat.name(participant(UUID(), named: nil), me: me), "Someone")
    }

    func testNobodyIsYouWhenTheLocalIdIsUnknown() {
        XCTAssertEqual(BideFormat.name(participant(me, named: "Danny")), "Danny")
        XCTAssertEqual(BideFormat.name(participant(me, named: nil)), "Someone")
    }

    func testABlankNameFallsBackRatherThanShowingNothing() {
        XCTAssertEqual(BideFormat.name(participant(UUID(), named: "   ")), "Someone")
    }

    // MARK: - Schedule

    func testAScheduleStillAheadIsNamed() {
        let now = Date(timeIntervalSince1970: 1_786_030_800)
        let later = now.addingTimeInterval(90 * 60)
        XCTAssertEqual(
            BideFormat.schedule(later, now: now),
            "Today · \(BideFormat.time(later))"
        )
    }

    func testNoScheduleIsAsSoonAsEveryoneCan() {
        XCTAssertEqual(BideFormat.schedule(nil), "As soon as everyone can")
    }

    func testAScheduleThatHasGoneByReadsAsAsap() {
        let now = Date(timeIntervalSince1970: 1_786_030_800)
        XCTAssertEqual(
            BideFormat.schedule(now.addingTimeInterval(-60), now: now),
            "As soon as everyone can"
        )
        XCTAssertEqual(BideFormat.schedule(now, now: now), "As soon as everyone can")
    }

    // MARK: - Participant status

    func testTheArrivalLineDropsItsLabelWithNothingToCompareTo() {
        let arrival = Date(timeIntervalSince1970: 1_786_030_800)
        XCTAssertEqual(
            BideFormat.arrivalLine(arrival, comparedTo: arrival.addingTimeInterval(-15 * 60)),
            BideFormat.actualLine(arrival)
        )
        XCTAssertEqual(
            BideFormat.arrivalLine(arrival, comparedTo: nil),
            BideFormat.time(arrival)
        )
    }
}
