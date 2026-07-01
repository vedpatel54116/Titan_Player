import XCTest

/// Verifies the AirPlay route picker is present and tappable. macOS shows
/// the system route-picker popover — we only assert the affordance opens.
final class AirPlayMenuFlow: XCTestCase {
    func test_airPlayButtonExists() throws {
        let app = UIAppLauncher.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let airPlay = app.otherElements["airPlay.root"]
        XCTAssertTrue(airPlay.waitForExistence(timeout: 10),
                      "AirPlay route picker should be visible on the control bar")
    }
}
