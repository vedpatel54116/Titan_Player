import XCTest
@testable import TitanPlayer
import AppKit

final class DisplayProviderTests: XCTestCase {
    func testSystemProviderReturnsAtLeastMain() {
        let provider = SystemDisplayProvider()
        let screens = provider.currentScreens()
        XCTAssertFalse(screens.isEmpty)
        XCTAssertNotNil(screens.first(where: { $0 == NSScreen.main }))
    }
}
