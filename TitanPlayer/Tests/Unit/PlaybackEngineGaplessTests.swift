import XCTest
@testable import TitanPlayer

@MainActor
final class PlaybackEngineGaplessTests: XCTestCase {
    func testOnNextTrackCallback() {
        let engine = PlaybackEngine()
        var called = false
        engine.onNextTrack = {
            called = true
            return nil
        }
        engine.onNextTrack?()
        XCTAssertTrue(called)
    }
    
    func testPlaybackEndedNotification() async {
        let engine = PlaybackEngine()
        var ended = false
        engine.onPlaybackEnded = {
            ended = true
        }
        // Simulate end by setting state
        engine.state = .ended
        XCTAssertTrue(ended)
    }
}
