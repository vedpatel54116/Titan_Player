import Foundation
import simd

enum HDRMode: Equatable {
    case sdr
    case hdr10(HDR10Metadata)
    case hlg
}

struct HDR10Metadata: Equatable {
    let displayPrimaries: (red: SIMD2<Float>, green: SIMD2<Float>, blue: SIMD2<Float>)
    let whitePoint: SIMD2<Float>
    let maxDisplayLuminance: Float
    let minDisplayLuminance: Float
    let maxContentLightLevel: Float
    let maxFrameAverageLightLevel: Float
    
    static func == (lhs: HDR10Metadata, rhs: HDR10Metadata) -> Bool {
        lhs.maxDisplayLuminance == rhs.maxDisplayLuminance &&
        lhs.minDisplayLuminance == rhs.minDisplayLuminance &&
        lhs.maxContentLightLevel == rhs.maxContentLightLevel &&
        lhs.maxFrameAverageLightLevel == rhs.maxFrameAverageLightLevel
    }
}

enum ColorGamut: String, CaseIterable {
    case srgb
    case displayP3
    case bt2020
}

struct DisplayCapabilities: Equatable {
    let supportsHDR: Bool
    let supportsEDR: Bool
    let maxEDRLuminance: Float
    let colorGamut: ColorGamut
}

struct ICCProfile: Equatable {
    let gamut: ColorGamut
    let matrix: simd_float3x3
    
    static func == (lhs: ICCProfile, rhs: ICCProfile) -> Bool {
        lhs.gamut == rhs.gamut &&
        lhs.matrix == rhs.matrix
    }
    
    static let sRGB = ICCProfile(
        gamut: .srgb,
        matrix: simd_float3x3(
            SIMD3<Float>(1.0, 0.0, 0.0),
            SIMD3<Float>(0.0, 1.0, 0.0),
            SIMD3<Float>(0.0, 0.0, 1.0)
        )
    )
}
