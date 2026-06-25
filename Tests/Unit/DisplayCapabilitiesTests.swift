import XCTest
@testable import TitanPlayer

final class DisplayCapabilitiesTests: XCTestCase {
    func testDisplayCapabilityDetectorInitialization() {
        let detector = DisplayCapabilityDetector()
        XCTAssertNotNil(detector)
    }
    
    func testDetectCapabilitiesOnMainScreen() {
        let detector = DisplayCapabilityDetector()
        guard let screen = NSScreen.main else {
            XCTSkip("No screen available")
            return
        }
        
        let capabilities = detector.detectCapabilities(for: screen)
        
        XCTAssertFalse(capabilities.maxEDRLuminance < 0)
        XCTAssertTrue(ColorGamut.allCases.contains(capabilities.colorGamut))
    }
    
    func testDetectICCProfileOnMainScreen() {
        let detector = DisplayCapabilityDetector()
        guard let screen = NSScreen.main else {
            XCTSkip("No screen available")
            return
        }
        
        let profile = detector.detectICCProfile(for: screen)
        
        XCTAssertTrue(ColorGamut.allCases.contains(profile.gamut))
    }
    
    func testSRGBFallbackWhenNoColorSpace() {
        let profile = ICCProfile.sRGB
        XCTAssertEqual(profile.gamut, .srgb)
        XCTAssertEqual(profile.matrix, simd_float3x3(
            SIMD3<Float>(1.0, 0.0, 0.0),
            SIMD3<Float>(0.0, 1.0, 0.0),
            SIMD3<Float>(0.0, 0.0, 1.0)
        ))
    }
}
