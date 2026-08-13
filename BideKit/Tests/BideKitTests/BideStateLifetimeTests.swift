import XCTest
@testable import BideKit

/// When a bide stops being one.
///
/// `isComplete` is the ending the model was built around and the one that
/// almost never happens — it needs every participant marked `arrived`, which
/// takes their app being open and tracking at the far end. `isExpired` is the
/// ending that actually fires: the clock runs out. Without it a bide is
/// forever, and a forever-bide is not just clutter on the home screen — it
/// stays the candidate the app picks to track, so it holds a location
/// subscription open for a meetup nobody is going to.
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

    /// A table booked for 7pm is still worth showing at midnight — people run
    /// late, and dinner runs long.
    func testABideOutlivesItsScheduledTime() {
        let state = bide(scheduledFor: now, createdAt: now)
        XCTAssertFalse(state.isExpired(now: now.addingTimeInterval(5 * 3600)))
    }

    func testABideExpiresOnceItsLifetimeHasRunOut() {
        let state = bide(scheduledFor: now, createdAt: now)
        XCTAssertTrue(state.isExpired(now: now.addingTimeInterval(BideState.lifetime + 1)))
    }

    /// Nothing survives the night, which is what "old sessions are still here
    /// after a relaunch" was.
    func testYesterdaysBideIsGone() {
        let state = bide(scheduledFor: now.addingTimeInterval(-24 * 3600), createdAt: now.addingTimeInterval(-25 * 3600))
        XCTAssertTrue(state.isExpired(now: now))
    }

    /// Next week's dinner is not expired — the interval is negative, and this
    /// must only ever retire the past.
    func testAFutureBideIsNeverExpired() {
        let state = bide(scheduledFor: now.addingTimeInterval(7 * 24 * 3600), createdAt: now)
        XCTAssertFalse(state.isExpired(now: now))
    }

    // MARK: - Asap bides

    /// An asap bide has no agreed time, so creation is the only clock it has.
    func testAnAsapBideIsMeasuredFromWhenItWasCreated() {
        let state = bide(scheduledFor: nil, createdAt: now)

        XCTAssertFalse(state.isExpired(now: now.addingTimeInterval(BideState.lifetime - 60)))
        XCTAssertTrue(state.isExpired(now: now.addingTimeInterval(BideState.lifetime + 60)))
    }
}
