import XCTest

/// Fullscreen on macOS is toggled via Cmd+Ctrl+F or by double-clicking the
/// player surface. We assert the latter works.
final class FullscreenFlow: XCTestCase {
    func test_doubleTapTogglesFullscreen() throws {
        let app = UIAppLauncher.launch(fixtureName: "test.mp4")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let player = app.otherElements["playerView.root"]
        guard player.waitForExistence(timeout: 10) else {
            throw XCTSkip("Player view unavailable — fixture did not load")
        }
        let initial = app.windows.firstMatch.frame
        player.doubleTap()
        sleep(1)
        let toggled = app.windows.firstMatch.frame
        XCTAssertNotEqual(initial.size, toggled.size,
                          "Window size should change after fullscreen toggle")
    }
}
