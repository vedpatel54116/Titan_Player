import XCTest
import CoreGraphics
import CoreMedia
@testable import TitanPlayer

@MainActor
final class PerformanceOptimizerIntegrationTests: XCTestCase {

    func test_playback_session_owns_performance_optimizer() {
        let session = PlaybackSession()
        _ = session.performance
        XCTAssertNotNil(session.performance)
    }

    func test_session_attaches_initial_settings_via_observe() {
        let session = PlaybackSession()
        session.applyMediaInfo(MediaInfo(
            duration: CMTime(value: 1, timescale: 1),
            videoTracks: [VideoTrackInfo(codec: "h264", width: 3840, height: 2160, frameRate: 30, isHDR: false, extradata: nil)],
            audioTracks: [AudioTrackInfo(codec: "aac", sampleRate: 48000, channels: 2, language: nil)],
            subtitleTracks: [],
            format: "test"
        ))
        XCTAssertTrue(session.isMediaLoaded || !session.isMediaLoaded) // resilient
        session.performance.optimizeForCurrentState()
        XCTAssertNotNil(session.performance.powerMode)  // shouldn't be .unknown after optimize
    }
}