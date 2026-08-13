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
        XCTAssertEqual(stored.first?.mode, .driving)
    }

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

    func testAnInviteSurvivesShortlyPastItsOwnTime() {
        let store = PendingInviteStore(defaults: defaults)
        let start = Date()
        store.add(PendingInvite(invite: makeInvite(scheduledFor: start), mode: .walking, stagedAt: start))

        XCTAssertEqual(store.all(now: start.addingTimeInterval(10 * 60)).count, 1)
    }

    func testAnInviteIsDroppedWellAfterItsOwnTime() {
        let store = PendingInviteStore(defaults: defaults)
        let start = Date()
        store.add(PendingInvite(invite: makeInvite(scheduledFor: start), mode: .walking, stagedAt: start))

        XCTAssertTrue(store.all(now: start.addingTimeInterval(3 * 60 * 60)).isEmpty)
        XCTAssertTrue(store.isEmpty)
    }

    func testAnAsapInviteExpiresADayAfterItWasSent() {
        let store = PendingInviteStore(defaults: defaults)
        let start = Date()
        store.add(PendingInvite(invite: makeInvite(scheduledFor: nil), mode: .walking, stagedAt: start))

        XCTAssertEqual(store.all(now: start.addingTimeInterval(23 * 60 * 60)).count, 1)
        XCTAssertTrue(store.all(now: start.addingTimeInterval(25 * 60 * 60)).isEmpty)
    }
}
