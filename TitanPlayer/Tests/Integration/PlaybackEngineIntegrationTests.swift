import XCTest
@testable import TitanPlayer

@MainActor
final class PlaybackEngineIntegrationTests: XCTestCase {
    private func makeEngine() -> PlaybackEngine {
        PlaybackEngine(videoRenderer: MockFrameRenderer())
    }

    func testFullPlaybackCycle() async throws {
        let engine = makeEngine()

        // Test initial state
        XCTAssertEqual(engine.state, .idle)

        // Test rate setting
        engine.setPlaybackRate(1.5)
        XCTAssertEqual(engine.playbackRate, 1.5, accuracy: 0.001)

        // Test audio delay
        engine.setAudioDelay(0.05)
        XCTAssertEqual(engine.audioDelay, 0.05, accuracy: 0.001)

        // Test state transitions
        engine.state = .ready
        engine.play()
        XCTAssertEqual(engine.state, .playing)

        engine.pause()
        XCTAssertEqual(engine.state, .paused)

        engine.stop()
        XCTAssertEqual(engine.state, .idle)
    }

    func testGaplessCallback() async {
        let engine = makeEngine()
        var nextURL: URL?

        engine.onNextTrack = {
            return URL(fileURLWithPath: "/tmp/test2.mp4")
        }

        nextURL = await engine.onNextTrack?()
        XCTAssertNotNil(nextURL)
    }
}
