import XCTest
@testable import TitanPlayer

@MainActor
final class PlaybackEngineRateTests: XCTestCase {
    func testSetPlaybackRate() {
        let engine = PlaybackEngine()
        engine.setPlaybackRate(2.0)
        XCTAssertEqual(engine.playbackRate, 2.0, accuracy: 0.001)
    }
    
    func testRateClamping() {
        let engine = PlaybackEngine()
        engine.setPlaybackRate(0.1)
        XCTAssertEqual(engine.playbackRate, 0.25, accuracy: 0.001)
        engine.setPlaybackRate(5.0)
        XCTAssertEqual(engine.playbackRate, 4.0, accuracy: 0.001)
    }
    
    func testRateIncrements() {
        let engine = PlaybackEngine()
        engine.setPlaybackRate(1.05)
        XCTAssertEqual(engine.playbackRate, 1.05, accuracy: 0.001)
    }
}
