import XCTest
@testable import TitanPlayer

final class HeadTrackingManagerTests: XCTestCase {
    func testHeadTrackingManagerInitialization() {
        let manager = HeadTrackingManager()

        XCTAssertNotNil(manager)
        XCTAssertEqual(manager.trackingSource, .software)
    }

    func testHeadTrackingManagerUpdatesPosition() {
        let manager = HeadTrackingManager()
        let newPosition = SIMD3<Float>(1.0, 0.0, 0.0)

        manager.updatePosition(newPosition)

        XCTAssertEqual(manager.position.x, 1.0)
    }
}
