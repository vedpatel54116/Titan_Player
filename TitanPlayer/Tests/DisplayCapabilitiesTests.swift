import XCTest
import AppKit
import simd
@testable import TitanPlayer

final class DisplayCapabilitiesTests: XCTestCase {

    func testDetectorInitialization() {
        let detector = DisplayCapabilityDetector()
        XCTAssertNotNil(detector)
    }

    func testDetectCapabilitiesOnMainScreen() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("No screen available in this environment")
        }

        let detector = DisplayCapabilityDetector()
        let capabilities = detector.detectCapabilities(for: screen)

        XCTAssertGreaterThanOrEqual(capabilities.maxEDRLuminance, 0)
        XCTAssertTrue(ColorGamut.allCases.contains(capabilities.colorGamut))
    }

    func testDetectICCProfileOnMainScreen() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("No screen available in this environment")
        }

        let detector = DisplayCapabilityDetector()
        let profile = detector.detectICCProfile(for: screen)

        XCTAssertTrue(ColorGamut.allCases.contains(profile.gamut))
    }

    func testSRGBFallbackConstant() {
        let profile = ICCProfile.sRGB
        XCTAssertEqual(profile.gamut, .srgb)
        let identity = simd_float3x3(
            SIMD3<Float>(1.0, 0.0, 0.0),
            SIMD3<Float>(0.0, 1.0, 0.0),
            SIMD3<Float>(0.0, 0.0, 1.0)
        )
        XCTAssertEqual(profile.matrix, identity)
    }

    func testCapabilitiesStructRoundTrip() {
        let caps = DisplayCapabilities(
            supportsHDR: true,
            supportsEDR: true,
            maxEDRLuminance: 1600.0,
            colorGamut: .bt2020
        )
        XCTAssertTrue(caps.supportsHDR)
        XCTAssertTrue(caps.supportsEDR)
        XCTAssertEqual(caps.maxEDRLuminance, 1600.0)
        XCTAssertEqual(caps.colorGamut, .bt2020)
    }

    func testColorGamutAllCases() {
        XCTAssertEqual(Set(ColorGamut.allCases), [.srgb, .displayP3, .bt2020])
    }
}
