import XCTest
@testable import TitanPlayer

@MainActor
final class SynchronizationTests: XCTestCase {
    
    func testShouldDropFrameBehindAudioClock() {
        let pipeline = MediaPipeline(videoRenderer: MockFrameRenderer())
        let mockProvider = MockSynchronizationProvider(audioTime: 1.0)
        pipeline.synchronizationProvider = mockProvider
        
        // Frame PTS behind audio clock beyond tolerance
        let framePTS = 0.9  // 100ms behind
        XCTAssertTrue(pipeline.shouldDropFrameForTest(framePTS))
    }
    
    func testShouldNotDropFrameWithinTolerance() {
        let pipeline = MediaPipeline(videoRenderer: MockFrameRenderer())
        let mockProvider = MockSynchronizationProvider(audioTime: 1.0)
        pipeline.synchronizationProvider = mockProvider
        
        // Frame PTS within 40ms tolerance
        let framePTS = 0.97  // 30ms behind
        XCTAssertFalse(pipeline.shouldDropFrameForTest(framePTS))
    }
    
    func testShouldNotDropFrameAhead() {
        let pipeline = MediaPipeline(videoRenderer: MockFrameRenderer())
        let mockProvider = MockSynchronizationProvider(audioTime: 1.0)
        pipeline.synchronizationProvider = mockProvider
        
        // Frame PTS ahead of audio clock
        let framePTS = 1.1  // 100ms ahead
        XCTAssertFalse(pipeline.shouldDropFrameForTest(framePTS))
    }
    
    func testAudioCurrentTimeReturnsCorrectValue() {
        let engine = PlaybackEngine(videoRenderer: MockFrameRenderer())
        engine.currentTime = 2.5
        XCTAssertEqual(engine.audioCurrentTime, 2.5)
    }
}

class MockSynchronizationProvider: SynchronizationProvider {
    var audioTime: TimeInterval
    init(audioTime: TimeInterval) {
        self.audioTime = audioTime
    }
    var audioCurrentTime: TimeInterval { audioTime }
}