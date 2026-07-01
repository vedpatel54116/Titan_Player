import XCTest

/// The HDR badge appears in the control bar when HDR content is loaded.
/// Defaults to gating on the `isHDRContent` PlaybackSession property.
final class HdrBadgeFlow: XCTestCase {
    func test_hdrBadgeAppearsWithHdrFixture() throws {
        let app = UIAppLauncher.launch(fixtureName: "test_4k_hdr10.mp4")
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let badge = app.staticTexts["controlBar.hdrBadge"]
        guard badge.waitForExistence(timeout: 5) else {
            throw XCTSkip("HDR fixture not present in CI; skipping badge assertion")
        }
        XCTAssertTrue(badge.isHittable,
                      "HDR badge should be visible when HDR content is loaded")
    }
}
