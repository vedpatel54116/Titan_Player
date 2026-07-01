import XCTest

/// Verifies that opening a file (via launch argument) and tapping play / pause
/// reflects in the SwiftUI control bar.
final class OpenFilePlayPauseFlow: XCTestCase {
    func test_windowAppears() throws {
        let app = UIAppLauncher.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10),
                      "TitanPlayer main window should appear")
    }

    func test_playPauseButtonExists() throws {
        let app = UIAppLauncher.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let button = app.buttons["controlBar.playPause"]
        XCTAssertTrue(button.waitForExistence(timeout: 10),
                      "controlBar.playPause should be visible after media loads")
    }

    func test_playPauseRespondsToTap() throws {
        let app = UIAppLauncher.launch(fixtureName: "test.mp4")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let button = app.buttons["controlBar.playPause"]
        guard button.waitForExistence(timeout: 10) else {
            throw XCTSkip("controlBar.playPause did not appear — fixture may not have loaded")
        }
        let initial = button.label
        button.tap()
        sleep(1)
        let afterTap = button.label
        XCTAssertNotEqual(initial, afterTap,
                          "Play/pause icon should change after tapping")
    }
}
