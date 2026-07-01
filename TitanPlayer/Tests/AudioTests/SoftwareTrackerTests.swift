import XCTest
@testable import TitanPlayer

final class SoftwareTrackerTests: XCTestCase {
    func testSoftwareTrackerInitialization() {
        let tracker = SoftwareTracker()

        XCTAssertNotNil(tracker)
        XCTAssertFalse(tracker.isTracking)
    }

    func testSoftwareTrackerHandlesMouseMovement() {
        let tracker = SoftwareTracker()
        let position = SIMD3<Float>(0.5, 0.0, 0.0)

        tracker.handleMouseMovement(to: position)

        XCTAssertEqual(tracker.position.x, 0.5)
    }
}
