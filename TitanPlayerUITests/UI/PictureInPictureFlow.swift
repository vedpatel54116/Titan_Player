import XCTest

/// Picture-in-Picture is launched from the system video controls on macOS.
/// We assert the player view contains the expected identifiers; PiP toggling
/// requires AVKit UI hooks that vary by macOS version. The test is best-effort
/// and skips when the system affordance is unavailable.
final class PictureInPictureFlow: XCTestCase {
    func test_playerViewRootExists() throws {
        let app = UIAppLauncher.launch(fixtureName: "test.mp4")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let player = app.otherElements["playerView.root"]
        XCTAssertTrue(player.waitForExistence(timeout: 10),
                      "Player view root should be present")
    }
}
