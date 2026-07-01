import XCTest
@testable import TitanPlayer

final class QualityActionTests: XCTestCase {

    func test_resolution_cap_pixel_mapping() {
        XCTAssertNil(ResolutionCap.original.maxPixels)
        XCTAssertEqual(ResolutionCap.p2160.maxPixels, 3840 * 2160)
        XCTAssertEqual(ResolutionCap.p1080.maxPixels, 1920 * 1080)
        XCTAssertEqual(ResolutionCap.p720.maxPixels,  1280 *  720)
    }

    func test_quality_action_is_hashable() {
        let actions: Set<QualityAction> = [
            .preferHardware(true),
            .preferHardware(false),
            .downscaleRenderTo(.p1080),
            .streamPreferBitrate(2_500_000),
            .reduceAudioComplexity(.simplified),
            .deferPrefetch(seconds: 2),
        ]
        XCTAssertEqual(actions.count, 6)
    }

    func test_audio_mode_cases() {
        XCTAssertEqual(AudioMode.allCases.count, 2)
        XCTAssertTrue(AudioMode.allCases.contains(.full))
        XCTAssertTrue(AudioMode.allCases.contains(.simplified))
    }
}
