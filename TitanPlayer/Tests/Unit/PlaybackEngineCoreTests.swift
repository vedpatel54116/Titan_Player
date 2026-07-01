import XCTest
@testable import TitanPlayer

@MainActor
final class PlaybackEngineCoreTests: XCTestCase {
    private func makeEngine() -> PlaybackEngine {
        PlaybackEngine(videoRenderer: MockFrameRenderer(), audioRenderer: MockAudioRenderer())
    }

    func testInitialState() {
        let engine = makeEngine()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(engine.currentTime, 0, accuracy: 0.001)
        XCTAssertEqual(engine.duration, 0, accuracy: 0.001)
        XCTAssertEqual(engine.playbackRate, 1.0, accuracy: 0.001)
    }

    func testPlayFromInvalidState() {
        let engine = makeEngine()
        engine.play() // Should not crash, should stay idle
        XCTAssertEqual(engine.state, .idle)
    }

    func testPauseFromInvalidState() {
        let engine = makeEngine()
        engine.pause() // Should not crash, should stay idle
        XCTAssertEqual(engine.state, .idle)
    }

    func testStopResetsState() {
        let engine = makeEngine()
        engine.stop()
        XCTAssertEqual(engine.state, .idle)
    }
}
