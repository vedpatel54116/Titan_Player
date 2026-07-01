import XCTest
@testable import TitanPlayer

final class AirPodsTrackerTests: XCTestCase {
    func testAirPodsTrackerInitialization() {
        let tracker = AirPodsTracker()

        XCTAssertNotNil(tracker)
        XCTAssertFalse(tracker.isTracking)
    }

    func testAirPodsTrackerStopWithoutStartIsSafe() {
        let tracker = AirPodsTracker()

        tracker.stopTracking()

        XCTAssertFalse(tracker.isTracking)
    }
}
