import XCTest
@testable import TitanPlayer

final class HardwareCapabilitiesTests: XCTestCase {
    func test_queryAdvertisesHWH264HEVC() {
        let caps = HardwareCapabilities.query()
        XCTAssertTrue(caps.supportedCodecs.contains(.h264))
        XCTAssertTrue(caps.supportedCodecs.contains(.hevc))
        XCTAssertTrue(caps.supportsHDR)
        XCTAssertTrue(caps.supportsHardwareAcceleration)
    }

    func test_isCodecSupported_isH264AlwaysTrue() {
        XCTAssertTrue(HardwareCapabilities.isCodecSupported(.h264))
    }

    func test_isCodecSupported_isHEVCAlwaysTrue() {
        XCTAssertTrue(HardwareCapabilities.isCodecSupported(.hevc))
    }

    func test_isCodecSupported_legacyCodecsAlwaysFalse() {
        XCTAssertFalse(HardwareCapabilities.isCodecSupported(.mpeg2))
        XCTAssertFalse(HardwareCapabilities.isCodecSupported(.vc1))
    }

    func test_isCodecSupported_vp9RequiresAppleSilicon() {
        let expected = HardwareCapabilities.isAppleSilicon()
        XCTAssertEqual(
            HardwareCapabilities.isCodecSupported(.vp9),
            expected,
            "VP9 hardware decode should follow the Apple Silicon flag"
        )
    }

    func test_isCodecSupported_av1RequiresM3OrLater() {
        let expected = HardwareCapabilities.isM3OrLater()
        XCTAssertEqual(
            HardwareCapabilities.isCodecSupported(.av1),
            expected,
            "AV1 hardware decode should track M3+"
        )
    }

    func test_maxResolutionPerCodecMatchesProfile() {
        // HEVC / VP9 / AV1 all advertise 8K on hardware; legacy codecs cap at HD.
        XCTAssertEqual(HardwareCapabilities.maxResolution(for: .hevc),
                       CGSize(width: 8192, height: 4320))
        XCTAssertEqual(HardwareCapabilities.maxResolution(for: .av1),
                       CGSize(width: 8192, height: 4320))
        XCTAssertEqual(HardwareCapabilities.maxResolution(for: .mpeg2),
                       CGSize(width: 1920, height: 1080))
    }

    func test_isAppleSiliconIsArchStable() {
        // Compile-time arch(arm64) gate; this test pins the contract on
        // whatever architecture we run on.
        let isArm: Bool
        #if arch(arm64)
        isArm = true
        #else
        isArm = false
        #endif
        XCTAssertEqual(HardwareCapabilities.isAppleSilicon(), isArm)
    }
}
