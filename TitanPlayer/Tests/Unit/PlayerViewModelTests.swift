import XCTest
@testable import TitanPlayer

@MainActor
final class PlayerViewModelTests: XCTestCase {
    func testInitialState() {
        let vm = PlayerViewModel()
        XCTAssertEqual(vm.playState, .idle)
        XCTAssertEqual(vm.currentTime, 0, accuracy: 0.001)
        XCTAssertEqual(vm.volume, 1.0, accuracy: 0.001)
    }
    
    func testTogglePlayPause() {
        let vm = PlayerViewModel()
        vm.togglePlayPause() // Should not crash when idle
        XCTAssertEqual(vm.playState, .idle)
    }
}
