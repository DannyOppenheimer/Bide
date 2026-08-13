import XCTest
@testable import BideKit

final class BideStateLifetimeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_786_000_000)
    private let me = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private func bide(scheduledFor: Date?, createdAt: Date) -> BideState {
        BideState(
            bideID: UUID(),
            destinationName: "Nats Park",
            lat: 38.873,
            lng: -77.007,
            scheduledFor: scheduledFor,
            createdAt: createdAt,
            createdBy: me,
            participants: [Participant(userID: me, mode: .driving, status: .accepted, updatedAt: createdAt)]
        )
    }

    // MARK: - Scheduled bides

    func testABideIsLiveRightUpToItsScheduledTime() {
        let state = bide(scheduledFor: now.addingTimeInterval(60), createdAt: now)
        XCTAssertFalse(state.isExpired(now: now))
    }

    func testABideOutlivesItsScheduledTime() {
        let state = bide(scheduledFor: now, createdAt: now)
        XCTAssertFalse(state.isExpired(now: now.addingTimeInterval(5 * 3600)))
    }

    func testABideExpiresOnceItsLifetimeHasRunOut() {
        let state = bide(scheduledFor: now, createdAt: now)
        XCTAssertTrue(state.isExpired(now: now.addingTimeInterval(BideState.lifetime + 1)))
    }

    func testYesterdaysBideIsGone() {
        let state = bide(scheduledFor: now.addingTimeInterval(-24 * 3600), createdAt: now.addingTimeInterval(-25 * 3600))
        XCTAssertTrue(state.isExpired(now: now))
    }

    func testAFutureBideIsNeverExpired() {
        let state = bide(scheduledFor: now.addingTimeInterval(7 * 24 * 3600), createdAt: now)
        XCTAssertFalse(state.isExpired(now: now))
    }

    // MARK: - ASAP bides

    func testAnAsapBideIsMeasuredFromWhenItWasCreated() {
        let state = bide(scheduledFor: nil, createdAt: now)

        XCTAssertFalse(state.isExpired(now: now.addingTimeInterval(BideState.lifetime - 60)))
        XCTAssertTrue(state.isExpired(now: now.addingTimeInterval(BideState.lifetime + 60)))
    }
}

final class InviteLifetimeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    private func invite(scheduledFor: Date?, createdAt: Date) -> BideInvite {
        BideInvite(
            destinationName: "Nats Park",
            lat: 38.873,
            lng: -77.007,
            scheduledFor: scheduledFor,
            createdAt: createdAt
        )
    }

    func testAnInviteEndsWithTheBideItDescribes() {
        let scheduled = invite(scheduledFor: now, createdAt: now.addingTimeInterval(-3600))
        XCTAssertFalse(scheduled.hasEnded(now: now))
        XCTAssertFalse(scheduled.hasEnded(now: now.addingTimeInterval(BideState.lifetime - 1)))
        XCTAssertTrue(scheduled.hasEnded(now: now.addingTimeInterval(BideState.lifetime)))
    }

    func testAnASAPInviteEndsFromWhenItWasMade() {
        let asap = invite(scheduledFor: nil, createdAt: now)
        XCTAssertFalse(asap.hasEnded(now: now.addingTimeInterval(BideState.lifetime - 1)))
        XCTAssertTrue(asap.hasEnded(now: now.addingTimeInterval(BideState.lifetime)))
    }

    func testAnInviteAndItsSessionEndTogether() {
        let scheduled = invite(scheduledFor: now, createdAt: now)
        let state = bide(scheduledFor: now, createdAt: now)
        let after = now.addingTimeInterval(BideState.lifetime + 1)
        XCTAssertEqual(scheduled.hasEnded(now: after), state.isExpired(now: after))
    }

    private func bide(scheduledFor: Date?, createdAt: Date) -> BideState {
        BideState(
            bideID: UUID(),
            destinationName: "Nats Park",
            lat: 38.873,
            lng: -77.007,
            scheduledFor: scheduledFor,
            createdAt: createdAt,
            createdBy: UUID(),
            participants: []
        )
    }
}
