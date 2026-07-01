import XCTest
import AVFAudio
@testable import TitanPlayer

@MainActor
final class AudioIntegrationTests: XCTestCase {
    func testPlaybackEngineUsesSpatialAudio() throws {
        let audioEngine = try AudioEngine()
        let playbackEngine = PlaybackEngine(
            videoRenderer: MockFrameRenderer()
        )

        playbackEngine.setSpatialAudioEngine(audioEngine)

        XCTAssertTrue(playbackEngine.spatialAudioEnabled)
    }

    func testPlaybackEngineCanToggleSpatialAudio() throws {
        let audioEngine = try AudioEngine()
        let playbackEngine = PlaybackEngine(
            videoRenderer: MockFrameRenderer()
        )
        playbackEngine.setSpatialAudioEngine(audioEngine)

        playbackEngine.setSpatialAudioEnabled(false)

        XCTAssertFalse(playbackEngine.spatialAudioEnabled)
        XCTAssertFalse(audioEngine.spatialAudioEnabled)
    }
}