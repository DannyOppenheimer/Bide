import XCTest
@testable import BideKit

final class WatcherTests: XCTestCase {

    private let traveller = UUID()
    private let watcher = UUID()
    private let now = Date(timeIntervalSince1970: 1_786_030_800)

    private func bide(
        travellerStatus: ParticipantStatus = .accepted,
        leftAt: Date? = nil
    ) -> BideState {
        BideState(
            bideID: UUID(),
            destinationName: "Nats Park",
            lat: 38.873,
            lng: -77.007,
            isSolo: true,
            createdAt: now,
            createdBy: traveller,
            participants: [
                Participant(
                    userID: traveller,
                    displayName: "Danny",
                    mode: .driving,
                    etaTimestamp: now.addingTimeInterval(20 * 60),
                    travelTime: 20 * 60,
                    leftAt: leftAt,
                    status: travellerStatus,
                    updatedAt: now
                ),
                Participant(userID: watcher, displayName: "Sarah", mode: .walking, status: .watching),
            ]
        )
    }

    // MARK: - Membership

    func testAWatcherIsNotInTheRoster() {
        let state = bide()
        XCTAssertEqual(state.roster.map(\.userID), [traveller])
        XCTAssertEqual(state.travellers.map(\.userID), [traveller])
        XCTAssertEqual(state.watchers.map(\.userID), [watcher])
    }

    func testAWatcherIsRecognisedAsOne() {
        let state = bide()
        XCTAssertTrue(state.isWatching(watcher))
        XCTAssertFalse(state.isWatching(traveller))
        XCTAssertFalse(state.isWatching(nil))
    }

    func testAWatcherCannotHoldABideOpen() {
        XCTAssertTrue(bide(travellerStatus: .arrived).isComplete)
    }

    func testAWatcherIsNotAnUnansweredInvitation() {
        XCTAssertFalse(bide().isAwaitingAnswers)
    }

    // MARK: - Watcher messaging

    func testAWatchersHeadlineIsAboutTheTraveller() {
        let waiting = BidePlanner.watcherHeadline(for: bide(), now: now)
        XCTAssertEqual(waiting, "Danny hasn't left yet")

        let moving = BidePlanner.watcherHeadline(
            for: bide(leftAt: now.addingTimeInterval(-5 * 60)),
            now: now
        )
        XCTAssertTrue(moving.hasPrefix("Danny arrives at "), moving)

        XCTAssertEqual(
            BidePlanner.watcherHeadline(for: bide(travellerStatus: .arrived), now: now),
            "Danny is there"
        )
    }

    func testAWatchedBideWithNobodyLeftSaysSo() {
        let empty = BideState(
            bideID: UUID(),
            destinationName: "Nats Park",
            lat: 38.873,
            lng: -77.007,
            isSolo: true,
            createdAt: now,
            createdBy: traveller,
            participants: [
                Participant(userID: watcher, displayName: "Sarah", mode: .walking, status: .watching),
            ]
        )
        XCTAssertEqual(BidePlanner.watcherHeadline(for: empty, now: now), "Nobody is going any more")
    }

    // MARK: - Status behavior

    func testWatchingIsNeitherTravellingNorAwaitingAnAnswer() {
        XCTAssertFalse(ParticipantStatus.watching.isTravelling)
        XCTAssertFalse(ParticipantStatus.watching.isAwaitingAnswer)
        XCTAssertTrue(ParticipantStatus.watching.isWatching)
    }

    func testWatchingRoundTripsThroughItsStoredName() {
        XCTAssertEqual(ParticipantStatus.watching.rawValue, "watching")
        XCTAssertEqual(ParticipantStatus(rawValue: "watching"), .watching)
    }

    // MARK: - Tile rendering

    func testATrackingTileStaysOneThroughItsURL() throws {
        let invite = BideInvite(
            destinationName: "Nats Park",
            lat: 38.873,
            lng: -77.007,
            scheduledFor: now.addingTimeInterval(3600)
        )
        let tile = BideTileMessage(invite: invite, senderName: "Danny", isTrackingInvite: true)

        let decoded = try XCTUnwrap(BideTileMessage(url: tile.webURL()))
        XCTAssertTrue(decoded.isTrackingInvite)
        XCTAssertEqual(decoded.senderName, "Danny")

        let viaApp = try XCTUnwrap(BideTileMessage(url: tile.appURL()))
        XCTAssertTrue(viaApp.isTrackingInvite)
    }

    func testAnOrdinaryTileIsNotATrackingInvite() throws {
        let invite = BideInvite(destinationName: "Nats Park", lat: 38.873, lng: -77.007)
        let tile = BideTileMessage(invite: invite, senderName: "Danny")
        XCTAssertFalse(try XCTUnwrap(BideTileMessage(url: tile.webURL())).isTrackingInvite)
    }

    func testATrackingTileTalksAboutThemNotEveryone() {
        XCTAssertEqual(BideFormat.soloSchedule(nil), "As soon as they can")
        XCTAssertEqual(
            BideFormat.soloSchedule(now.addingTimeInterval(-60), now: now),
            "As soon as they can"
        )
        XCTAssertEqual(
            BideFormat.soloSchedule(now.addingTimeInterval(3600), now: now),
            BideFormat.schedule(now.addingTimeInterval(3600), now: now)
        )
    }
}
