import XCTest
@testable import TitanPlayer

final class SoftwareCapabilitiesTests: XCTestCase {
    func test_queryReturnsCoveredCapabilityShape() {
        let caps = SoftwareCapabilities.query()
        XCTAssertFalse(caps.supportedCodecs.isEmpty)
        XCTAssertGreaterThanOrEqual(caps.maxResolution.width, 1920)
        XCTAssertGreaterThanOrEqual(caps.maxResolution.height, 1080)
        XCTAssertTrue(caps.supportsHDR)
        // Software decoders are a fallback; they explicitly do NOT advertise
        // hardware acceleration even when the FFmpeg path can leverage it.
        XCTAssertFalse(caps.supportsHardwareAcceleration)
    }

    func test_queryIncludesEveryVideoCodec() {
        let caps = SoftwareCapabilities.query()
        for codec in VideoCodec.allCases {
            XCTAssertTrue(caps.supportedCodecs.contains(codec),
                          "expected \(codec) in software supportedCodecs")
        }
    }

    func test_isCodecSupportedIsAlwaysTrue() {
        // FFmpeg covers every codec the project enumerates; this contract
        // is part of the public surface and must not regress.
        for codec in VideoCodec.allCases {
            XCTAssertTrue(SoftwareCapabilities.isCodecSupported(codec),
                          "\(codec) should be supported by FFmpeg")
        }
    }
}
