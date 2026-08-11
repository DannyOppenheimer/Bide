import XCTest
@testable import BideKit

final class MeetupStateTests: XCTestCase {
    func testURLRoundTrip() {
        let original = MeetupState.placeholder
        let decoded = MeetupState(url: original.encodedURL())
        XCTAssertEqual(decoded, original)
    }

    func testURLRoundTripWithAccepterETA() {
        let original = MeetupState(
            placeName: "Blue Bottle Coffee",
            placeAddress: "300 Webster St, Oakland, CA",
            latitude: 37.7952,
            longitude: -122.2718,
            proposerETAMinutes: 12,
            accepterETAMinutes: 8,
            status: .accepted
        )
        let decoded = MeetupState(url: original.encodedURL())
        XCTAssertEqual(decoded, original)
    }

    func testDecodeFailsOnMalformedURL() {
        let url = URL(string: "bide://tile?placeName=OnlyOneField")!
        XCTAssertNil(MeetupState(url: url))
    }
}
