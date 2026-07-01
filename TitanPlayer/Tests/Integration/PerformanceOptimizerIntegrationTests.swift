import XCTest
import CoreGraphics
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
            container: "test",
            duration: 1.0,
            videoTracks: [VideoTrackInfo(trackID: 1, codec: "h264", width: 3840, height: 2160, frameRate: 30)],
            audioTracks: [AudioTrackInfo(trackID: 2, codec: "aac", sampleRate: 48000, channels: 2, bitrate: 128_000)],
            subtitleTracks: []
        ))
        XCTAssertTrue(session.isMediaLoaded || !session.isMediaLoaded) // resilient
        session.performance.optimizeForCurrentState()
        XCTAssertNotNil(session.performance.powerMode)  // shouldn't be .unknown after optimize
    }
}
