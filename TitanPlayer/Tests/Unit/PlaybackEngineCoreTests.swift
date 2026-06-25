import XCTest
@testable import TitanPlayer

@MainActor
final class PlaybackEngineCoreTests: XCTestCase {
    func testInitialState() {
        let engine = PlaybackEngine()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(engine.currentTime, 0, accuracy: 0.001)
        XCTAssertEqual(engine.duration, 0, accuracy: 0.001)
        XCTAssertEqual(engine.playbackRate, 1.0, accuracy: 0.001)
    }
    
    func testPlayFromInvalidState() {
        let engine = PlaybackEngine()
        engine.play() // Should not crash, should stay idle
        XCTAssertEqual(engine.state, .idle)
    }
    
    func testPauseFromInvalidState() {
        let engine = PlaybackEngine()
        engine.pause() // Should not crash, should stay idle
        XCTAssertEqual(engine.state, .idle)
    }
    
    func testStopResetsState() {
        let engine = PlaybackEngine()
        engine.stop()
        XCTAssertEqual(engine.state, .idle)
    }
}
