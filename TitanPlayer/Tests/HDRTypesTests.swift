import XCTest
import simd
@testable import TitanPlayer

final class HDRTypesTests: XCTestCase {

    func testHDRModeSDREquality() {
        XCTAssertEqual(HDRMode.sdr, HDRMode.sdr)
    }

    func testHDRModeHLGEquality() {
        XCTAssertEqual(HDRMode.hlg, HDRMode.hlg)
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
        XCTAssertEqual(metadata.maxContentLightLevel, 1000.0)
        XCTAssertEqual(metadata.maxFrameAverageLightLevel, 400.0)
    }

    func testHDR10MetadataEquality() {
        let m1 = HDR10Metadata(
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
        let m2 = HDR10Metadata(
            displayPrimaries: (
                red: SIMD2<Float>(0.0, 0.0),
                green: SIMD2<Float>(0.0, 0.0),
                blue: SIMD2<Float>(0.0, 0.0)
            ),
            whitePoint: SIMD2<Float>(0.0, 0.0),
            maxDisplayLuminance: 1000.0,
            minDisplayLuminance: 0.001,
            maxContentLightLevel: 1000.0,
            maxFrameAverageLightLevel: 400.0
        )

        XCTAssertEqual(m1, m2, "Equality should ignore primaries/whitePoint per custom ==")
    }

    func testHDR10MetadataInequality() {
        let m1 = HDR10Metadata(
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
        let m2 = HDR10Metadata(
            displayPrimaries: (
                red: SIMD2<Float>(0.708, 0.292),
                green: SIMD2<Float>(0.170, 0.797),
                blue: SIMD2<Float>(0.131, 0.046)
            ),
            whitePoint: SIMD2<Float>(0.3127, 0.3290),
            maxDisplayLuminance: 2000.0,
            minDisplayLuminance: 0.001,
            maxContentLightLevel: 1000.0,
            maxFrameAverageLightLevel: 400.0
        )

        XCTAssertNotEqual(m1, m2)
    }

    func testColorGamutRawValues() {
        XCTAssertEqual(ColorGamut.srgb.rawValue, "srgb")
        XCTAssertEqual(ColorGamut.displayP3.rawValue, "displayP3")
        XCTAssertEqual(ColorGamut.bt2020.rawValue, "bt2020")
        XCTAssertEqual(ColorGamut.allCases.count, 3)
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

        let caps3 = DisplayCapabilities(
            supportsHDR: false,
            supportsEDR: false,
            maxEDRLuminance: 80.0,
            colorGamut: .srgb
        )
        XCTAssertNotEqual(caps1, caps3)
    }

    func testICCProfileSRGB() {
        let srgb = ICCProfile.sRGB
        XCTAssertEqual(srgb.gamut, .srgb)
        let identity = simd_float3x3(
            SIMD3<Float>(1.0, 0.0, 0.0),
            SIMD3<Float>(0.0, 1.0, 0.0),
            SIMD3<Float>(0.0, 0.0, 1.0)
        )
        XCTAssertEqual(srgb.matrix, identity)
    }

    func testICCProfileEquality() {
        let p1 = ICCProfile(gamut: .displayP3, matrix: ICCProfile.sRGB.matrix)
        let p2 = ICCProfile(gamut: .displayP3, matrix: ICCProfile.sRGB.matrix)
        XCTAssertEqual(p1, p2)

        let p3 = ICCProfile(gamut: .srgb, matrix: ICCProfile.sRGB.matrix)
        XCTAssertNotEqual(p1, p3)
    }

    func testHDRModeRawValues() {
        XCTAssertEqual(HDRModeRaw.sdr.rawValue, 0)
        XCTAssertEqual(HDRModeRaw.hdr10.rawValue, 1)
        XCTAssertEqual(HDRModeRaw.hlg.rawValue, 2)
    }

    // MARK: - HDR10+ / Dolby Vision types

    func testHDR10PlusMetadataEquality() {
        let m1 = HDR10PlusMetadata(
            curveExponent: 20,
            kneePointX: 2048,
            kneePointY: 1024,
            numBezierCurveAnchors: 2,
            bezierCurveAnchors: [32, 64],
            colorSaturationMap: [128]
        )
        let m2 = HDR10PlusMetadata(
            curveExponent: 20,
            kneePointX: 2048,
            kneePointY: 1024,
            numBezierCurveAnchors: 2,
            bezierCurveAnchors: [32, 64],
            colorSaturationMap: [255]
        )

        XCTAssertEqual(m1, m2, "Equality should ignore colorSaturationMap per custom ==")

        var m3 = m2
        m3 = HDR10PlusMetadata(
            curveExponent: 20,
            kneePointX: 2048,
            kneePointY: 1024,
            numBezierCurveAnchors: 2,
            bezierCurveAnchors: [32, 96],
            colorSaturationMap: [128]
        )
        XCTAssertNotEqual(m1, m3)
    }

    func testDolbyVisionProfileDualLayer() {
        XCTAssertTrue(DolbyVisionProfile.profile4.supportsDualLayer)
        XCTAssertTrue(DolbyVisionProfile.profile7.supportsDualLayer)
        XCTAssertFalse(DolbyVisionProfile.profile5.supportsDualLayer)
        XCTAssertFalse(DolbyVisionProfile.profile8.supportsDualLayer)
    }

    func testExtendedHDRModeIsDynamic() {
        XCTAssertFalse(ExtendedHDRMode.sdr.isDynamic)
        XCTAssertFalse(ExtendedHDRMode.hlg.isDynamic)

        let hdr10 = HDR10Metadata(
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
        XCTAssertFalse(ExtendedHDRMode.hdr10(hdr10).isDynamic)
    }

    func testHDRProcessingConfigDefault() {
        let config = HDRProcessingConfig.default
        XCTAssertTrue(config.enableDynamicToneMapping)
        XCTAssertTrue(config.enableMetadataPassthrough)
        XCTAssertTrue(config.fallbackToStaticHDR)
        XCTAssertEqual(config.targetLuminance, 1000.0)
    }
}
