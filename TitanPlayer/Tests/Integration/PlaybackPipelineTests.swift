import XCTest
@testable import TitanPlayer

@MainActor
final class PlaybackPipelineTests: XCTestCase {
    private func makePipeline() -> MediaPipeline {
        MediaPipeline(videoRenderer: MockFrameRenderer(), audioRenderer: MockAudioRenderer())
    }

    func testPipelineOpensMediaFile() async throws {
        let pipeline = makePipeline()
        let testURL = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4")!

        await pipeline.openFile(url: testURL)

        XCTAssertNotEqual(pipeline.playState, .idle)
        XCTAssertGreaterThan(pipeline.duration, 0)
    }

    func testPipelinePlayPause() async throws {
        let pipeline = makePipeline()
        let testURL = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4")!

        await pipeline.openFile(url: testURL)
        pipeline.play()

        XCTAssertEqual(pipeline.playState, .playing)

        pipeline.pause()

        XCTAssertEqual(pipeline.playState, .paused)
    }

    func testPipelineSeek() async throws {
        let pipeline = makePipeline()
        let testURL = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4")!

        await pipeline.openFile(url: testURL)
        pipeline.play()

        await pipeline.seek(to: 5.0)

        XCTAssertEqual(pipeline.currentTime, 5.0, accuracy: 0.1)
    }

    func testPipelineStop() async throws {
        let pipeline = makePipeline()
        let testURL = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4")!

        await pipeline.openFile(url: testURL)
        pipeline.play()
        pipeline.stop()

        XCTAssertEqual(pipeline.playState, .idle)
    }
}
