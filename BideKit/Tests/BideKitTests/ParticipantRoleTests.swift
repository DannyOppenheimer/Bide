import XCTest
@testable import BideKit

final class ParticipantRoleTests: XCTestCase {

    private let alice = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let bob = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let unassigned = ParticipantRole.unassignedIdentifier

    func testTileSentByLocalUserIsSender() {
        let role = ParticipantRole(senderIdentifier: alice, localIdentifier: alice)
        XCTAssertEqual(role, .sender)
        XCTAssertFalse(role.showsAcceptButton)
        XCTAssertTrue(role.isWaitingOnOtherParticipant)
    }

    func testTileSentByOtherParticipantIsRecipient() {
        let role = ParticipantRole(senderIdentifier: bob, localIdentifier: alice)
        XCTAssertEqual(role, .recipient)
        XCTAssertTrue(role.showsAcceptButton)
        XCTAssertFalse(role.isWaitingOnOtherParticipant)
    }

    func testUnsentMessageIsIndeterminate() {
        // Messages reports an all-zero sender until the message is actually sent.
        let role = ParticipantRole(senderIdentifier: unassigned, localIdentifier: alice)
        XCTAssertEqual(role, .indeterminate)
        XCTAssertFalse(role.showsAcceptButton)
        XCTAssertFalse(role.isWaitingOnOtherParticipant)
    }

    func testMissingLocalParticipantIsIndeterminate() {
        XCTAssertEqual(ParticipantRole(senderIdentifier: bob, localIdentifier: unassigned), .indeterminate)
    }

    func testBothIdentifiersMissingIsIndeterminate() {
        XCTAssertEqual(
            ParticipantRole(senderIdentifier: unassigned, localIdentifier: unassigned),
            .indeterminate
        )
    }

    /// An unassigned sender must never be read as "someone else sent it" just
    /// because it differs from the local identifier — that would put an Accept
    /// button on the local user's own unsent draft.
    func testUnassignedSenderIsNotTreatedAsAnotherParticipant() {
        XCTAssertNotEqual(ParticipantRole(senderIdentifier: unassigned, localIdentifier: alice), .recipient)
    }

    /// Documents the platform limitation this function exists to work around:
    /// in a conversation with yourself both identifiers are the same, so the
    /// Accept path is unreachable by self-texting. It is not a bug in the
    /// comparison — it is why the recipient path is covered here instead.
    func testSelfTextingCannotProduceAnAcceptButton() {
        XCTAssertEqual(ParticipantRole(senderIdentifier: alice, localIdentifier: alice), .sender)
        XCTAssertFalse(ParticipantRole(senderIdentifier: alice, localIdentifier: alice).showsAcceptButton)
    }

    func testRoleIsSymmetricAcrossTheTwoParticipants() {
        // The same message, viewed from each device.
        XCTAssertEqual(ParticipantRole(senderIdentifier: alice, localIdentifier: alice), .sender)
        XCTAssertEqual(ParticipantRole(senderIdentifier: alice, localIdentifier: bob), .recipient)
    }

    /// Group threads: anyone who isn't the local user is "them".
    func testThirdParticipantIsRecipient() {
        let carol = UUID()
        XCTAssertEqual(ParticipantRole(senderIdentifier: carol, localIdentifier: alice), .recipient)
        XCTAssertEqual(ParticipantRole(senderIdentifier: bob, localIdentifier: carol), .recipient)
    }
}
