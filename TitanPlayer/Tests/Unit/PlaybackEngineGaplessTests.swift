import XCTest
@testable import TitanPlayer

@MainActor
final class PlaybackEngineGaplessTests: XCTestCase {
    private func makeEngine() -> PlaybackEngine {
        PlaybackEngine(videoRenderer: MockFrameRenderer())
    }

    func testOnNextTrackCallback() async {
        let engine = makeEngine()
        var called = false
        engine.onNextTrack = {
            called = true
            return nil
        }
        _ = await engine.onNextTrack?()
        XCTAssertTrue(called)
    }

    func testPlaybackEndedNotification() async {
        let engine = makeEngine()
        var ended = false
        engine.onPlaybackEnded = {
            ended = true
        }
        // Simulate end by setting state
        engine.state = .ended
        XCTAssertTrue(ended)
    }
}
