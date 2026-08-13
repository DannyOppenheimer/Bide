import XCTest
@testable import BideKit

final class CyclingEstimateTests: XCTestCase {

    private func walkingTime(for distance: Double) -> TimeInterval { distance / 1.4 }

    // MARK: - Estimate behavior

    func testARealRideIsFasterThanTheWalk() {
        let distance = 5_000.0
        let cycling = CyclingEstimate.travelTime(
            distance: distance,
            walkingTime: walkingTime(for: distance)
        )

        XCTAssertEqual(cycling, 90 + 5_000 / 4.2, accuracy: 1)
        XCTAssertLessThan(cycling, walkingTime(for: distance))
    }

    func testCyclingIsNeverSlowerThanWalking() {
        for distance in stride(from: 0.0, through: 4_000, by: 25) {
            let walk = walkingTime(for: distance)
            XCTAssertLessThanOrEqual(
                CyclingEstimate.travelTime(distance: distance, walkingTime: walk),
                walk,
                "cycling came out slower than walking at \(Int(distance))m"
            )
        }
    }

    func testATripAcrossTheRoadIsJustTheWalk() {
        let distance = 120.0
        let walk = walkingTime(for: distance)
        XCTAssertEqual(
            CyclingEstimate.travelTime(distance: distance, walkingTime: walk),
            walk,
            accuracy: 0.001
        )
    }

    func testTheModelIsContinuousAcrossTheCrossover() {
        let below = CyclingEstimate.travelTime(distance: 185, walkingTime: walkingTime(for: 185))
        let above = CyclingEstimate.travelTime(distance: 195, walkingTime: walkingTime(for: 195))
        XCTAssertEqual(below, above, accuracy: 5)
    }

    // MARK: - Confidence limits

    func testTheEstimateIncludesGettingTheBikeOut() {
        let riding = 1_000 / 4.2
        let estimate = CyclingEstimate.travelTime(
            distance: 1_000,
            walkingTime: walkingTime(for: 1_000)
        )
        XCTAssertEqual(estimate - riding, 90, accuracy: 0.001)
    }

    func testTheSpeedIsADoorToDoorFigureNotACruisingOne() {
        let kmPerHour = CyclingEstimate.cruisingSpeed * 3.6
        XCTAssertGreaterThan(kmPerHour, 12)
        XCTAssertLessThan(kmPerHour, 18)
    }

    // MARK: - Edge cases

    func testNoDistanceIsNoJourney() {
        XCTAssertEqual(CyclingEstimate.travelTime(distance: 0, walkingTime: 0), 0)
    }

    func testNonsenseInputCannotProduceANegativeETA() {
        XCTAssertGreaterThanOrEqual(
            CyclingEstimate.travelTime(distance: -500, walkingTime: -60),
            0
        )
    }
}
