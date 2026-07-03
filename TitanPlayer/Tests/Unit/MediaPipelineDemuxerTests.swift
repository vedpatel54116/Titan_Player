import XCTest
@testable import TitanPlayer

@MainActor
final class MediaPipelineDemuxerTests: XCTestCase {

    private func makePipeline() -> MediaPipeline {
        MediaPipeline(videoRenderer: MockFrameRenderer())
    }

    // MARK: - AVFoundation direct path

    func testAVFoundationDirectPathUsesAVFoundationDemuxer() async throws {
        let pipeline = makePipeline()
        let testURL = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4")!

        try await pipeline.openFile(url: testURL)

        XCTAssertEqual(pipeline.demuxerBackendKind, "AVFoundation")
        XCTAssertEqual(pipeline.playState, .paused)
    }

    // MARK: - FFmpeg path (MKV routes through shouldTryFFmpegFirst)

    func testFFmpegPathUsesFFmpegDemuxer() async throws {
        let pipeline = makePipeline()
        let testURL = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mkv")!

        try await pipeline.openFile(url: testURL)

        XCTAssertEqual(pipeline.demuxerBackendKind, "FFmpeg")
        XCTAssertEqual(pipeline.playState, .paused)
    }

    func testFFmpegPathReusesProbedDemuxerInstance() async throws {
        let pipeline = makePipeline()
        let testURL = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mkv")!

        try await pipeline.openFile(url: testURL)

        // The demuxer assigned to the pipeline should be an FFmpegDemuxer
        // (the same instance created for probing, not a second one).
        XCTAssertTrue(pipeline.demuxerForTest is FFmpegDemuxer)
    }

    // MARK: - FFmpeg fallback to AVFoundation

    func testFFmpegFailureFallsBackToAVFoundation() async {
        let pipeline = makePipeline()
        let nonexistentURL = URL(fileURLWithPath: "/tmp/nonexistent_file.mkv")

        do {
            try await pipeline.openFile(url: nonexistentURL)
            XCTFail("Should throw for nonexistent file")
        } catch {
            // FFmpeg fails → AVFoundation fallback also fails (file missing).
            XCTAssertEqual(pipeline.demuxerBackendKind, "none")
        }
    }
}
