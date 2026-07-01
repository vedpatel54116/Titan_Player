import XCTest
@testable import TitanPlayer

@MainActor
final class PlaybackEngineSyncTests: XCTestCase {
    private func makeEngine() -> PlaybackEngine {
        PlaybackEngine(videoRenderer: MockFrameRenderer(), audioRenderer: MockAudioRenderer())
    }

    func testAudioDelayProperty() {
        let engine = makeEngine()
        XCTAssertEqual(engine.audioDelay, 0, accuracy: 0.001)
    }

    func testSetAudioDelay() {
        let engine = makeEngine()
        engine.setAudioDelay(0.05)
        XCTAssertEqual(engine.audioDelay, 0.05, accuracy: 0.001)
    }

    func testAudioDelayClamping() {
        let engine = makeEngine()
        engine.setAudioDelay(0.2) // Above max
        XCTAssertEqual(engine.audioDelay, 0.1, accuracy: 0.001)
        engine.setAudioDelay(-0.2) // Below min
        XCTAssertEqual(engine.audioDelay, -0.1, accuracy: 0.001)
    }
}
