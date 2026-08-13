import XCTest
@testable import BideKit

final class DepartureDetectionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    func testAsapTripArmsDepartureDetectionImmediately() {
        XCTAssertTrue(
            MapKitETAEngine.departureDetectionIsArmed(
                at: now,
                scheduledArrival: nil,
                travelTime: 20 * 60
            )
        )
    }

    func testScheduledTripDoesNotArmDuringAnEarlierErrand() {
        let arrival = now.addingTimeInterval(4 * 60 * 60)

        XCTAssertFalse(
            MapKitETAEngine.departureDetectionIsArmed(
                at: now,
                scheduledArrival: arrival,
                travelTime: 30 * 60
            )
        )
    }

    func testScheduledTripArmsNearCalculatedDeparture() {
        let travelTime: TimeInterval = 30 * 60
        let departure = now.addingTimeInterval(3 * 60 * 60)
        let arrival = departure.addingTimeInterval(travelTime)
        let lead = MapKitETAEngine.departureDetectionLeadTime

        XCTAssertFalse(
            MapKitETAEngine.departureDetectionIsArmed(
                at: departure.addingTimeInterval(-lead - 1),
                scheduledArrival: arrival,
                travelTime: travelTime
            )
        )
        XCTAssertTrue(
            MapKitETAEngine.departureDetectionIsArmed(
                at: departure.addingTimeInterval(-lead),
                scheduledArrival: arrival,
                travelTime: travelTime
            )
        )
    }

    func testScheduledTripWaitsForAFirstRouteEstimate() {
        XCTAssertFalse(
            MapKitETAEngine.departureDetectionIsArmed(
                at: now,
                scheduledArrival: now.addingTimeInterval(60 * 60),
                travelTime: nil
            )
        )
    }
}
