import XCTest
@testable import TitanPlayer

@MainActor
final class AirPlayControllerTests: XCTestCase {
    func testApplyExternalActiveAddsDelay() {
        let monitor = MockExternalPlaybackMonitor(initial: false)
        let controller = AirPlayController(monitor: monitor, defaultDelay: 0.08)
        XCTAssertEqual(controller.currentAudioDelayOffset, 0)

        monitor.setActive(true)
        controller.refresh()
        XCTAssertEqual(controller.currentAudioDelayOffset, 0.08)
        XCTAssertTrue(controller.isExternalPlaybackActive)
    }

    func testStoppingExternalPlaybackRestoresZeroDelay() {
        let monitor = MockExternalPlaybackMonitor(initial: true)
        let controller = AirPlayController(monitor: monitor, defaultDelay: 0.08)
        controller.refresh()
        monitor.setActive(false)
        controller.refresh()
        XCTAssertEqual(controller.currentAudioDelayOffset, 0)
    }

    func testUserOverrideIsSticky() {
        let monitor = MockExternalPlaybackMonitor(initial: true)
        let controller = AirPlayController(monitor: monitor, defaultDelay: 0.08)
        controller.refresh()
        controller.setAudioDelayOffset(0.2)
        monitor.setActive(false)
        controller.refresh()
        XCTAssertEqual(controller.currentAudioDelayOffset, 0.2)
    }
}
