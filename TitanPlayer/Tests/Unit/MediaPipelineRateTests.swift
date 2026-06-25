import XCTest
@testable import TitanPlayer

final class MediaPipelineRateTests: XCTestCase {
    func testSetPlaybackRate() async {
        let pipeline = MediaPipeline()
        pipeline.setPlaybackRate(2.0)
        XCTAssertEqual(pipeline.playbackRate, 2.0, accuracy: 0.001)
    }
    
    func testRateClamping() async {
        let pipeline = MediaPipeline()
        pipeline.setPlaybackRate(0.1) // Below minimum
        XCTAssertEqual(pipeline.playbackRate, 0.25, accuracy: 0.001)
        pipeline.setPlaybackRate(5.0) // Above maximum
        XCTAssertEqual(pipeline.playbackRate, 4.0, accuracy: 0.001)
    }
}
