import XCTest
import AVFoundation
@testable import TitanPlayer

final class SubsystemSeamTests: XCTestCase {

    func test_streaming_set_preferred_peak_bitrate_compiles() {
        let manager = StreamingManager.makeDefault()
        // No AVPlayer attached → method should be a no-op, not a crash.
        manager.setPreferredPeakBitrate(2_500_000)
        manager.setPreferredPeakBitrate(8_000_000)
        XCTAssert(true)
    }

    @MainActor
    func test_audio_engine_set_complexity_mode_round_trips() throws {
        let engine = try AudioEngine()
        XCTAssertEqual(engine.currentComplexityMode, .full)
        engine.setComplexityMode(.simplified)
        XCTAssertEqual(engine.currentComplexityMode, .simplified)
        engine.setComplexityMode(.full)
        XCTAssertEqual(engine.currentComplexityMode, .full)
    }

    func test_metal_renderer_resolution_cap_default_is_original() {
        guard let renderer = try? MetalRenderer.make() else {
            // Metal may not be available in some CI environments (e.g., headless).
            throw XCTSkip("Metal not available in this environment")
        }
        XCTAssertEqual(renderer.currentResolutionCap, .original)
        renderer.setResolutionCap(.p1080)
        XCTAssertEqual(renderer.currentResolutionCap, .p1080)
        renderer.setResolutionCap(.original)
        XCTAssertEqual(renderer.currentResolutionCap, .original)
    }
}
