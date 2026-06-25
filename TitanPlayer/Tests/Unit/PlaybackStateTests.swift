import XCTest
@testable import TitanPlayer

final class PlaybackStateTests: XCTestCase {
    func testStateEquality() {
        XCTAssertEqual(PlaybackState.idle, PlaybackState.idle)
        XCTAssertEqual(PlaybackState.loading, PlaybackState.loading)
        XCTAssertEqual(PlaybackState.ready, PlaybackState.ready)
        XCTAssertEqual(PlaybackState.playing, PlaybackState.playing)
        XCTAssertEqual(PlaybackState.paused, PlaybackState.paused)
        XCTAssertEqual(PlaybackState.ended, PlaybackState.ended)
        XCTAssertEqual(PlaybackState.seeking, PlaybackState.seeking)
        XCTAssertEqual(PlaybackState.error("x"), PlaybackState.error("x"))
        
        XCTAssertNotEqual(PlaybackState.idle, PlaybackState.loading)
        XCTAssertNotEqual(PlaybackState.playing, PlaybackState.paused)
        XCTAssertNotEqual(PlaybackState.error("a"), PlaybackState.error("b"))
    }
    
    func testTransitionAllowed() {
        XCTAssertTrue(PlaybackState.idle.canTransition(to: .loading))
        XCTAssertTrue(PlaybackState.loading.canTransition(to: .ready))
        XCTAssertTrue(PlaybackState.loading.canTransition(to: .error("fail")))
        XCTAssertTrue(PlaybackState.ready.canTransition(to: .playing))
        XCTAssertTrue(PlaybackState.playing.canTransition(to: .paused))
        XCTAssertTrue(PlaybackState.playing.canTransition(to: .ended))
        XCTAssertTrue(PlaybackState.ended.canTransition(to: .ready))
        XCTAssertTrue(PlaybackState.paused.canTransition(to: .playing))
        
        XCTAssertFalse(PlaybackState.idle.canTransition(to: .playing))
        XCTAssertFalse(PlaybackState.ended.canTransition(to: .playing))
    }
}
