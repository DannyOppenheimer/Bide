import XCTest
@testable import BideKit

final class BideTileMessageTests: XCTestCase {

    private func invite(scheduled: Bool = true) -> BideInvite {
        BideInvite(
            bideID: UUID(uuidString: "8B5C1E7A-4D3F-4C21-9E88-0A1B2C3D4E5F")!,
            destinationName: "Nats Park",
            lat: 38.873,
            lng: -77.007,
            scheduledFor: scheduled ? Date(timeIntervalSince1970: 1_786_478_100) : nil,
            arrivalStyle: .together,
            createdAt: Date(timeIntervalSince1970: 1_786_000_000)
        )
    }

    private func assertRoundTrips(_ tile: BideTileMessage, line: UInt = #line) {
        for url in [tile.webURL(), tile.appURL()] {
            guard let decoded = BideTileMessage(url: url) else {
                return XCTFail("failed to decode \(url.absoluteString)", line: line)
            }
            XCTAssertEqual(decoded.invite, tile.invite, line: line)
            XCTAssertEqual(decoded.answer, tile.answer, line: line)
            XCTAssertEqual(decoded.senderName, tile.senderName, line: line)
            XCTAssertEqual(
                decoded.leaveAt?.timeIntervalSince1970,
                tile.leaveAt.map { $0.timeIntervalSince1970.rounded(.down) },
                line: line
            )
        }
    }

    func testInvitationIsJustTheInvite() {
        let tile = BideTileMessage(invite: invite())
        XCTAssertEqual(tile.webURL(), tile.invite.webURL())
        assertRoundTrips(tile)
    }

    func testAcceptedTileCarriesTheDepartureTime() {
        assertRoundTrips(
            BideTileMessage(
                invite: invite(),
                answer: .accepted,
                leaveAt: Date(timeIntervalSince1970: 1_786_476_000),
                senderName: "John"
            )
        )
    }

    func testDeclinedTileRoundTrips() {
        assertRoundTrips(BideTileMessage(invite: invite(), answer: .declined, senderName: "Sarah"))
    }

    func testAsapTileRoundTrips() {
        assertRoundTrips(BideTileMessage(invite: invite(scheduled: false), answer: .accepted))
    }

    func testNamesWithPunctuationSurvive() {
        for name in ["Ana María", "O'Brien", "山田", "Jo 🎈"] {
            assertRoundTrips(BideTileMessage(invite: invite(), answer: .accepted, senderName: name))
        }
    }

    func testNameCannotInjectQueryParameters() {
        let tile = BideTileMessage(
            invite: invite(),
            answer: .accepted,
            senderName: "X&answer=declined&lat=0"
        )
        let decoded = BideTileMessage(url: tile.webURL())
        XCTAssertEqual(decoded?.answer, .accepted, "an injected answer must not win")
        XCTAssertEqual(decoded?.invite.lat, 38.873)
    }

    func testUnrelatedURLsAreRejected() {
        XCTAssertNil(BideTileMessage(url: URL(string: "https://example.com/trip?to=Nowhere")!))
        XCTAssertNil(BideTileMessage(url: URL(string: "bide://something-else")!))
    }
}

final class BidePlanDraftTests: XCTestCase {

    func testADraftWithoutADestinationIsNotComplete() {
        XCTAssertFalse(BidePlanDraft().isComplete)
        XCTAssertNil(BidePlanDraft().invite())

        let draft = BidePlanDraft(destination: Destination(name: "Nats Park", latitude: 38.873, longitude: -77.007))
        XCTAssertTrue(draft.isComplete)
        XCTAssertEqual(draft.invite()?.destinationName, "Nats Park")
    }

    func testDefaultTimeRoundsUpToTheNextQuarterHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        for (minute, expected) in [(0, 15), (7, 15), (15, 30), (44, 45), (46, 0)] {
            let base = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 15, minute: minute))!
            let rounded = BidePlanDraft.defaultTime(after: base, calendar: calendar)
            XCTAssertEqual(calendar.component(.minute, from: rounded), expected, "from :\(minute)")
            XCTAssertEqual(calendar.component(.second, from: rounded), 0)
        }
    }

    func testAsapDraftCarriesNoTime() {
        let draft = BidePlanDraft(
            destination: Destination(name: "Nats Park", latitude: 38.873, longitude: -77.007)
        )
        XCTAssertNil(draft.invite()?.scheduledFor)
        XCTAssertFalse(draft.isInThePast())
    }

    func testATimeAlreadyGoneIsFlagged() {
        let draft = BidePlanDraft(
            destination: Destination(name: "Nats Park", latitude: 38.873, longitude: -77.007),
            scheduledFor: Date(timeIntervalSince1970: 0)
        )
        XCTAssertTrue(draft.isInThePast())
    }
}
