import XCTest
@testable import BideKit

final class PendingInviteStoreTests: XCTestCase {

    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        suiteName = "bide.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeInvite(scheduledFor: Date?) -> BideInvite {
        BideInvite(
            destinationName: "Nats Park",
            lat: 38.873,
            lng: -77.007,
            scheduledFor: scheduledFor
        )
    }

    // MARK: Round trip

    func testAnInviteSurvivesBeingWrittenAndReadBack() {
        let store = PendingInviteStore(defaults: defaults)
        let invite = makeInvite(scheduledFor: Date().addingTimeInterval(3600))

        store.add(PendingInvite(invite: invite, mode: .driving))

        let stored = store.all()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.invite, invite)
        // The mode matters: it's the answer the sender already gave, and their
        // session should start with it rather than asking again.
        XCTAssertEqual(stored.first?.mode, .driving)
    }

    /// Sending the same bide twice — a tile re-staged after a false start —
    /// must not leave two copies to claim.
    func testReStagingTheSameBideReplacesIt() {
        let store = PendingInviteStore(defaults: defaults)
        let invite = makeInvite(scheduledFor: Date().addingTimeInterval(3600))

        store.add(PendingInvite(invite: invite, mode: .walking))
        store.add(PendingInvite(invite: invite, mode: .transit))

        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.all().first?.mode, .transit)
    }

    func testRemovingLeavesTheRestAlone() {
        let store = PendingInviteStore(defaults: defaults)
        let kept = makeInvite(scheduledFor: Date().addingTimeInterval(3600))
        let dropped = makeInvite(scheduledFor: Date().addingTimeInterval(7200))

        store.add(PendingInvite(invite: kept, mode: .walking))
        store.add(PendingInvite(invite: dropped, mode: .walking))
        store.remove(dropped.bideID)

        XCTAssertEqual(store.all().map(\.id), [kept.bideID])
        XCTAssertFalse(store.isEmpty)
    }

    // MARK: Expiry

    /// Somebody answering ten minutes late should still get everyone there.
    func testAnInviteSurvivesShortlyPastItsOwnTime() {
        let store = PendingInviteStore(defaults: defaults)
        let start = Date()
        store.add(PendingInvite(invite: makeInvite(scheduledFor: start), mode: .walking, stagedAt: start))

        XCTAssertEqual(store.all(now: start.addingTimeInterval(10 * 60)).count, 1)
    }

    /// Somebody answering the next morning should not resurrect it.
    func testAnInviteIsDroppedWellAfterItsOwnTime() {
        let store = PendingInviteStore(defaults: defaults)
        let start = Date()
        store.add(PendingInvite(invite: makeInvite(scheduledFor: start), mode: .walking, stagedAt: start))

        XCTAssertTrue(store.all(now: start.addingTimeInterval(3 * 60 * 60)).isEmpty)
        // Reading is what prunes, so the expired invite is gone for good
        // rather than being re-judged on every later read.
        XCTAssertTrue(store.isEmpty)
    }

    /// An asap bide has no time of its own to expire against, so it gets a day.
    func testAnAsapInviteExpiresADayAfterItWasSent() {
        let store = PendingInviteStore(defaults: defaults)
        let start = Date()
        store.add(PendingInvite(invite: makeInvite(scheduledFor: nil), mode: .walking, stagedAt: start))

        XCTAssertEqual(store.all(now: start.addingTimeInterval(23 * 60 * 60)).count, 1)
        XCTAssertTrue(store.all(now: start.addingTimeInterval(25 * 60 * 60)).isEmpty)
    }
}
