import XCTest
@testable import BideKit

final class SentInviteStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var store: SentInviteStore!
    private let group = "conversation-a"
    private let otherGroup = "conversation-b"

    override func setUp() {
        super.setUp()
        let suite = "bide.tests.sent.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        store = SentInviteStore(defaults: defaults)
    }

    override func tearDown() {
        store.removeAll()
        defaults = nil
        store = nil
        super.tearDown()
    }

    private func invite(
        _ bideID: UUID = UUID(),
        conversation: String,
        destination: String = "Nats Park",
        scheduledFor: Date? = nil,
        sentAt: Date = Date()
    ) -> SentInvite {
        SentInvite(
            bideID: bideID,
            conversationKey: conversation,
            destinationName: destination,
            scheduledFor: scheduledFor,
            sentAt: sentAt
        )
    }

    func testAConversationHoldsTheBideSentToIt() {
        store.record(invite(conversation: group))
        XCTAssertEqual(store.live(inConversation: group)?.destinationName, "Nats Park")
        XCTAssertNil(store.live(inConversation: otherGroup), "another thread is unaffected")
    }

    func testAnUnidentifiedConversationIsNeverOccupied() {
        store.record(invite(conversation: ""))
        XCTAssertNil(store.live(inConversation: nil))
        XCTAssertNil(store.live(inConversation: ""))
    }

    func testRecordsExpireWithTheBide() {
        let sentAt = Date(timeIntervalSince1970: 1_786_000_000)
        store.record(invite(conversation: group, sentAt: sentAt))

        let stillLive = sentAt.addingTimeInterval(BideState.lifetime - 60)
        XCTAssertNotNil(store.live(inConversation: group, now: stillLive))

        let expired = sentAt.addingTimeInterval(BideState.lifetime + 60)
        XCTAssertNil(store.live(inConversation: group, now: expired))
        XCTAssertTrue(store.all(now: expired).isEmpty, "expired records are swept")
    }

    func testAScheduledBideOccupiesItsThreadFromItsMeetingTime() {
        let sentAt = Date(timeIntervalSince1970: 1_786_000_000)
        let meetingTime = sentAt.addingTimeInterval(24 * 60 * 60)
        store.record(invite(conversation: group, scheduledFor: meetingTime, sentAt: sentAt))

        let dayLater = sentAt.addingTimeInterval(12 * 60 * 60)
        XCTAssertNotNil(
            store.live(inConversation: group, now: dayLater),
            "a Bide for tomorrow still holds the thread today"
        )
    }

    func testRevokingFreesTheConversationAndQueuesTheDeletion() {
        let bideID = UUID()
        store.record(invite(bideID, conversation: group))

        store.revoke(bideID)

        XCTAssertNil(store.live(inConversation: group))
        XCTAssertEqual(store.revoked(), [bideID])

        store.clearRevocation(bideID)
        XCTAssertTrue(store.revoked().isEmpty)
    }

    func testRevokingTwiceQueuesOneDeletion() {
        let bideID = UUID()
        store.record(invite(bideID, conversation: group))
        store.revoke(bideID)
        store.revoke(bideID)
        XCTAssertEqual(store.revoked(), [bideID])
    }

    func testForgettingAlsoDropsAPendingDeletion() {
        let bideID = UUID()
        store.record(invite(bideID, conversation: group))
        store.revoke(bideID)

        store.forget(bideID)

        XCTAssertTrue(store.revoked().isEmpty)
        XCTAssertNil(store.live(inConversation: group))
    }

    func testRecordingAgainReplacesTheEntryForABide() {
        let bideID = UUID()
        store.record(invite(bideID, conversation: group, destination: "Nats Park"))
        store.record(invite(bideID, conversation: group, destination: "Union Market"))

        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.live(inConversation: group)?.destinationName, "Union Market")
    }

    func testTheNewestRecordHoldsAConversation() {
        let older = Date(timeIntervalSince1970: 1_786_000_000)
        store.record(invite(conversation: group, destination: "Nats Park", sentAt: older))
        store.record(
            invite(
                conversation: group,
                destination: "Union Market",
                sentAt: older.addingTimeInterval(60)
            )
        )

        XCTAssertEqual(
            store.live(inConversation: group, now: older.addingTimeInterval(120))?.destinationName,
            "Union Market"
        )
    }
}
