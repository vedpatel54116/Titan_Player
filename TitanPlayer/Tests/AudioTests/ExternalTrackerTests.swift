import XCTest
@testable import TitanPlayer

final class ExternalTrackerTests: XCTestCase {
    func testExternalTrackerInitialization() {
        let tracker = ExternalTracker()

        XCTAssertNotNil(tracker)
        XCTAssertFalse(tracker.isTracking)
    }

    func testExternalTrackerDetectsDevices() {
        let tracker = ExternalTracker()

        let devices = tracker.availableDevices

        XCTAssertNotNil(devices)
    }
}
