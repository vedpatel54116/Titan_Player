import XCTest
@testable import TitanPlayer

@MainActor
final class PlaybackPipelineTests: XCTestCase {
    private func makePipeline() -> MediaPipeline {
        MediaPipeline(videoRenderer: MockFrameRenderer())
    }

    func testPipelineOpensMediaFile() async throws {
        let pipeline = makePipeline()
        let testURL = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4")!

        try await pipeline.openFile(url: testURL)

        XCTAssertNotEqual(pipeline.phase, .idle)
        XCTAssertGreaterThan(pipeline.duration, 0)
    }

    func testPipelinePlayPause() async throws {
        let pipeline = makePipeline()
        let testURL = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4")!

        try await pipeline.openFile(url: testURL)
        pipeline.play(currentState: .ready)

        XCTAssertEqual(pipeline.phase, .decoding)

        pipeline.pause(currentState: .playing)

        XCTAssertEqual(pipeline.phase, .paused)
    }

    func testPipelineSeek() async throws {
        let pipeline = makePipeline()
        let testURL = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4")!

        try await pipeline.openFile(url: testURL)
        pipeline.play(currentState: .ready)

        await pipeline.seek(to: 5.0)

        XCTAssertEqual(pipeline.currentTime, 5.0, accuracy: 0.1)
    }

    func testPipelineStop() async throws {
        let pipeline = makePipeline()
        let testURL = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4")!

        try await pipeline.openFile(url: testURL)
        pipeline.play(currentState: .ready)
        pipeline.stop(currentState: .playing)

        XCTAssertEqual(pipeline.phase, .stopped)
    }
}
