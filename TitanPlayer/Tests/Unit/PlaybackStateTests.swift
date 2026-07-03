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

    // MARK: - Comprehensive legal transitions

    func test_canTransition_legalTransitions() {
        // idle → loading
        XCTAssertTrue(PlaybackState.idle.canTransition(to: .loading))

        // loading → ready, loading → error
        XCTAssertTrue(PlaybackState.loading.canTransition(to: .ready))
        XCTAssertTrue(PlaybackState.loading.canTransition(to: .error("x")))

        // ready → playing, ready → seeking
        XCTAssertTrue(PlaybackState.ready.canTransition(to: .playing))
        XCTAssertTrue(PlaybackState.ready.canTransition(to: .seeking))

        // playing → paused, playing → ended, playing → seeking
        XCTAssertTrue(PlaybackState.playing.canTransition(to: .paused))
        XCTAssertTrue(PlaybackState.playing.canTransition(to: .ended))
        XCTAssertTrue(PlaybackState.playing.canTransition(to: .seeking))

        // paused → playing, paused → seeking
        XCTAssertTrue(PlaybackState.paused.canTransition(to: .playing))
        XCTAssertTrue(PlaybackState.paused.canTransition(to: .seeking))

        // ended → ready, ended → loading
        XCTAssertTrue(PlaybackState.ended.canTransition(to: .ready))
        XCTAssertTrue(PlaybackState.ended.canTransition(to: .loading))

        // seeking → playing, seeking → paused
        XCTAssertTrue(PlaybackState.seeking.canTransition(to: .playing))
        XCTAssertTrue(PlaybackState.seeking.canTransition(to: .paused))
    }

    // MARK: - Comprehensive illegal transitions

    func test_canTransition_illegalTransitions_rejected() {
        // idle cannot go to anything except loading
        XCTAssertFalse(PlaybackState.idle.canTransition(to: .ready))
        XCTAssertFalse(PlaybackState.idle.canTransition(to: .playing))
        XCTAssertFalse(PlaybackState.idle.canTransition(to: .paused))
        XCTAssertFalse(PlaybackState.idle.canTransition(to: .ended))
        XCTAssertFalse(PlaybackState.idle.canTransition(to: .seeking))
        XCTAssertFalse(PlaybackState.idle.canTransition(to: .error("x")))
        XCTAssertFalse(PlaybackState.idle.canTransition(to: .idle))

        // loading cannot go to playing, paused, ended, seeking, idle
        XCTAssertFalse(PlaybackState.loading.canTransition(to: .playing))
        XCTAssertFalse(PlaybackState.loading.canTransition(to: .paused))
        XCTAssertFalse(PlaybackState.loading.canTransition(to: .ended))
        XCTAssertFalse(PlaybackState.loading.canTransition(to: .seeking))
        XCTAssertFalse(PlaybackState.loading.canTransition(to: .idle))
        XCTAssertFalse(PlaybackState.loading.canTransition(to: .loading))

        // ready cannot go to loading, paused, ended, idle, error
        XCTAssertFalse(PlaybackState.ready.canTransition(to: .loading))
        XCTAssertFalse(PlaybackState.ready.canTransition(to: .paused))
        XCTAssertFalse(PlaybackState.ready.canTransition(to: .ended))
        XCTAssertFalse(PlaybackState.ready.canTransition(to: .idle))
        XCTAssertFalse(PlaybackState.ready.canTransition(to: .error("x")))
        XCTAssertFalse(PlaybackState.ready.canTransition(to: .ready))

        // playing cannot go to loading, ready, idle, error
        XCTAssertFalse(PlaybackState.playing.canTransition(to: .loading))
        XCTAssertFalse(PlaybackState.playing.canTransition(to: .ready))
        XCTAssertFalse(PlaybackState.playing.canTransition(to: .idle))
        XCTAssertFalse(PlaybackState.playing.canTransition(to: .error("x")))
        XCTAssertFalse(PlaybackState.playing.canTransition(to: .playing))

        // paused cannot go to loading, ready, ended, idle, error
        XCTAssertFalse(PlaybackState.paused.canTransition(to: .loading))
        XCTAssertFalse(PlaybackState.paused.canTransition(to: .ready))
        XCTAssertFalse(PlaybackState.paused.canTransition(to: .ended))
        XCTAssertFalse(PlaybackState.paused.canTransition(to: .idle))
        XCTAssertFalse(PlaybackState.paused.canTransition(to: .error("x")))
        XCTAssertFalse(PlaybackState.paused.canTransition(to: .paused))

        // ended cannot go to playing, paused, seeking, idle, error
        XCTAssertFalse(PlaybackState.ended.canTransition(to: .playing))
        XCTAssertFalse(PlaybackState.ended.canTransition(to: .paused))
        XCTAssertFalse(PlaybackState.ended.canTransition(to: .seeking))
        XCTAssertFalse(PlaybackState.ended.canTransition(to: .idle))
        XCTAssertFalse(PlaybackState.ended.canTransition(to: .error("x")))
        XCTAssertFalse(PlaybackState.ended.canTransition(to: .ended))

        // seeking cannot go to loading, ready, ended, idle, error
        XCTAssertFalse(PlaybackState.seeking.canTransition(to: .loading))
        XCTAssertFalse(PlaybackState.seeking.canTransition(to: .ready))
        XCTAssertFalse(PlaybackState.seeking.canTransition(to: .ended))
        XCTAssertFalse(PlaybackState.seeking.canTransition(to: .idle))
        XCTAssertFalse(PlaybackState.seeking.canTransition(to: .error("x")))
        XCTAssertFalse(PlaybackState.seeking.canTransition(to: .seeking))
    }
}
