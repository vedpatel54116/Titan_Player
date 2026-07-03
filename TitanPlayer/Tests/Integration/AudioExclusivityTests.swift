import XCTest
@testable import TitanPlayer

@MainActor
final class AudioExclusivityTests: XCTestCase {

    private func makeEngine() -> PlaybackEngine {
        PlaybackEngine(videoRenderer: MockFrameRenderer())
    }

    private func testFileURL() throws -> URL {
        guard let url = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4") else {
            throw XCTSkip("Fixtures/test.mp4 missing from test bundle")
        }
        return url
    }

    // MARK: - Default state: AVPlayer is the audio owner

    func testDefaultAudioOwnerIsAVPlayer() {
        let engine = makeEngine()
        // By default MediaPipeline audio rendering is disabled.
        XCTAssertFalse(engine.mediaPipelineAudioRenderingEnabled,
                       "MediaPipeline audio rendering should be off when AVPlayer owns audio")
    }

    // MARK: - After load, still AVPlayer-owned

    func testAudioOwnerRemainsAVPlayerAfterLoad() async throws {
        let engine = makeEngine()
        let url = try testFileURL()
        try await engine.load(url: url)

        XCTAssertFalse(engine.mediaPipelineAudioRenderingEnabled,
                       "MediaPipeline audio rendering should remain off after load")
    }

    // MARK: - Spatial audio transfer

    func testSpatialAudioTransfersOwnershipToMediaPipeline() async throws {
        let engine = makeEngine()
        let url = try testFileURL()
        try await engine.load(url: url)

        // Simulate spatial audio being enabled (mutes AVPlayer).
        engine.setSpatialAudioEnabled(true)

        XCTAssertTrue(engine.mediaPipelineAudioRenderingEnabled,
                       "MediaPipeline should own audio when spatial audio is active")
    }

    func testDisablingSpatialAudioReturnsOwnershipToAVPlayer() async throws {
        let engine = makeEngine()
        let url = try testFileURL()
        try await engine.load(url: url)

        engine.setSpatialAudioEnabled(true)
        XCTAssertTrue(engine.mediaPipelineAudioRenderingEnabled)

        engine.setSpatialAudioEnabled(false)
        XCTAssertFalse(engine.mediaPipelineAudioRenderingEnabled,
                       "AVPlayer should resume as audio owner when spatial audio is disabled")
    }

    // MARK: - Only one owner active at a time

    func testExactlyOneAudioOwnerActiveDuringPlayback() async throws {
        let engine = makeEngine()
        let url = try testFileURL()
        try await engine.load(url: url)

        // Without spatial audio — AVPlayer owns audio.
        engine.play()
        XCTAssertTrue(engine.mediaPipelineAudioRenderingEnabled == false,
                       "AVPlayer should be the sole audio owner during normal playback")
        engine.stop()

        // With spatial audio — MediaPipeline owns audio.
        engine.setSpatialAudioEnabled(true)
        engine.play()
        XCTAssertTrue(engine.mediaPipelineAudioRenderingEnabled,
                       "MediaPipeline should be the sole audio owner during spatial playback")
        engine.stop()
    }

    // MARK: - Audio tap gating via MediaPipeline

    func testAudioTapIsNilWhenAudioRenderingDisabled() async throws {
        let pipeline = MediaPipeline(videoRenderer: MockFrameRenderer())
        let url = try testFileURL()
        try await pipeline.openFile(url: url)

        // Audio rendering is off by default.
        XCTAssertNil(pipeline.audioTap, "audioTap should be nil when audio rendering is disabled")
    }

    func testAudioTapPassthroughWhenAudioRenderingEnabled() async throws {
        let pipeline = MediaPipeline(videoRenderer: MockFrameRenderer())
        let url = try testFileURL()
        try await pipeline.openFile(url: url)

        let expectation = XCTestExpectation(description: "audioTap called")
        var received = false

        pipeline.setAudioRenderingEnabled(true)
        pipeline.audioTap = { _ in
            received = true
            expectation.fulfill()
        }

        // The tap should be stored.
        XCTAssertNotNil(pipeline.audioTap, "audioTap should be non-nil when audio rendering is enabled")

        // Simulate a frame delivery (decoder must be active).
        // Note: current decoders only produce video frames, so the tap
        // may never fire — we verify storage, not invocation.
        XCTAssertTrue(received == false, "Tap should not have fired yet (video-only decoder)")
    }

    func testAudioTapIgnoredWhenReEnabledAfterDisable() async throws {
        let pipeline = MediaPipeline(videoRenderer: MockFrameRenderer())
        let url = try testFileURL()
        try await pipeline.openFile(url: url)

        pipeline.setAudioRenderingEnabled(true)
        pipeline.audioTap = { _ in }
        XCTAssertNotNil(pipeline.audioTap)

        pipeline.setAudioRenderingEnabled(false)
        // After disabling, the getter should return nil.
        XCTAssertNil(pipeline.audioTap, "audioTap should be nil after audio rendering is disabled")
    }

    // MARK: - Stop resets ownership

    func testStopResetsAudioOwnership() async throws {
        let engine = makeEngine()
        let url = try testFileURL()
        try await engine.load(url: url)

        engine.setSpatialAudioEnabled(true)
        XCTAssertTrue(engine.mediaPipelineAudioRenderingEnabled)

        engine.stop()
        XCTAssertFalse(engine.mediaPipelineAudioRenderingEnabled,
                       "Stop should reset audio ownership back to AVPlayer")
    }
}
