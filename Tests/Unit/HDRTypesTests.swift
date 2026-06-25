import XCTest
@testable import TitanPlayer

final class HDRTypesTests: XCTestCase {
    func testHDRModeEquality() {
        let sdr1 = HDRMode.sdr
        let sdr2 = HDRMode.sdr
        XCTAssertEqual(sdr1, sdr2)
        
        let hlg1 = HDRMode.hlg
        let hlg2 = HDRMode.hlg
        XCTAssertEqual(hlg1, hlg2)
    }
    
    func testHDR10MetadataCreation() {
        let metadata = HDR10Metadata(
            displayPrimaries: (
                red: SIMD2<Float>(0.708, 0.292),
                green: SIMD2<Float>(0.170, 0.797),
                blue: SIMD2<Float>(0.131, 0.046)
            ),
            whitePoint: SIMD2<Float>(0.3127, 0.3290),
            maxDisplayLuminance: 1000.0,
            minDisplayLuminance: 0.001,
            maxContentLightLevel: 1000.0,
            maxFrameAverageLightLevel: 400.0
        )
        
        XCTAssertEqual(metadata.maxDisplayLuminance, 1000.0)
        XCTAssertEqual(metadata.minDisplayLuminance, 0.001)
    }
    
    func testColorGamutRawValues() {
        XCTAssertEqual(ColorGamut.srgb.rawValue, "srgb")
        XCTAssertEqual(ColorGamut.displayP3.rawValue, "displayP3")
        XCTAssertEqual(ColorGamut.bt2020.rawValue, "bt2020")
    }
    
    func testDisplayCapabilitiesEquality() {
        let caps1 = DisplayCapabilities(
            supportsHDR: true,
            supportsEDR: true,
            maxEDRLuminance: 1600.0,
            colorGamut: .bt2020
        )
        let caps2 = DisplayCapabilities(
            supportsHDR: true,
            supportsEDR: true,
            maxEDRLuminance: 1600.0,
            colorGamut: .bt2020
        )
        XCTAssertEqual(caps1, caps2)
    }
    
    func testICCProfileSRGB() {
        let srgb = ICCProfile.sRGB
        XCTAssertEqual(srgb.gamut, .srgb)
        XCTAssertEqual(srgb.matrix, simd_float3x3(
            SIMD3<Float>(1.0, 0.0, 0.0),
            SIMD3<Float>(0.0, 1.0, 0.0),
            SIMD3<Float>(0.0, 0.0, 1.0)
        ))
    }
    
    func testHDRModeRawValues() {
        XCTAssertEqual(HDRModeRaw.sdr.rawValue, 0)
        XCTAssertEqual(HDRModeRaw.hdr10.rawValue, 1)
        XCTAssertEqual(HDRModeRaw.hlg.rawValue, 2)
    }
}
