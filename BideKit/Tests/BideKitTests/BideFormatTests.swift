import XCTest
@testable import BideKit

final class BideFormatTests: XCTestCase {

    private let me = UUID()

    private func participant(_ id: UUID, named name: String?) -> Participant {
        Participant(userID: id, displayName: name, mode: .walking, status: .accepted)
    }

    /// The reported bug: a solo bide made without signing in listed its own
    /// creator as "Someone", because an anonymous identity has no display name
    /// and the roster had no way to know it was looking at the reader.
    func testTheLocalUserIsCalledYouEvenWithoutAName() {
        XCTAssertEqual(BideFormat.name(participant(me, named: nil), me: me), "You")
        XCTAssertEqual(BideFormat.initial(participant(me, named: nil), me: me), "Y")
    }

    /// And even with one. A roster is read to find out where everyone *else*
    /// has got to, so your own row is the one that should need no reading.
    func testYouWinsOverTheLocalUsersOwnName() {
        XCTAssertEqual(BideFormat.name(participant(me, named: "Danny"), me: me), "You")
    }

    func testOtherPeopleKeepTheirNames() {
        let sarah = participant(UUID(), named: "Sarah")
        XCTAssertEqual(BideFormat.name(sarah, me: me), "Sarah")
        XCTAssertEqual(BideFormat.initial(sarah, me: me), "S")
    }

    /// Somebody else who never set a name is still "Someone" — inventing one
    /// would be worse, and showing a raw identifier worse still.
    func testAnUnnamedStrangerIsStillSomeone() {
        XCTAssertEqual(BideFormat.name(participant(UUID(), named: nil), me: me), "Someone")
    }

    /// Without a local id there is nobody to recognise, which is the case in
    /// the Messages transcript — it has no session to ask.
    func testNobodyIsYouWhenTheLocalIdIsUnknown() {
        XCTAssertEqual(BideFormat.name(participant(me, named: "Danny")), "Danny")
        XCTAssertEqual(BideFormat.name(participant(me, named: nil)), "Someone")
    }

    /// A name that is only whitespace is not a name.
    func testABlankNameFallsBackRatherThanShowingNothing() {
        XCTAssertEqual(BideFormat.name(participant(UUID(), named: "   ")), "Someone")
    }
}
