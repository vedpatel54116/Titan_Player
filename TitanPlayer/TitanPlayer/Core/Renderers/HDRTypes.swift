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

enum ColorGamut: String, CaseIterable, Codable {
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

// MARK: - HDR10+ Dynamic Metadata

struct HDR10PlusMetadata: Equatable {
    let curveExponent: UInt8
    let kneePointX: UInt16
    let kneePointY: UInt16
    let numBezierCurveAnchors: UInt8
    let bezierCurveAnchors: [UInt16]
    let colorSaturationMap: [UInt8]
    
    static func == (lhs: HDR10PlusMetadata, rhs: HDR10PlusMetadata) -> Bool {
        lhs.curveExponent == rhs.curveExponent &&
        lhs.kneePointX == rhs.kneePointX &&
        lhs.kneePointY == rhs.kneePointY &&
        lhs.numBezierCurveAnchors == rhs.numBezierCurveAnchors &&
        lhs.bezierCurveAnchors == rhs.bezierCurveAnchors
    }
}

// MARK: - Dolby Vision Metadata

enum DolbyVisionProfile: UInt8, Equatable {
    case profile4 = 4
    case profile5 = 5
    case profile7 = 7
    case profile8 = 8
    
    var supportsDualLayer: Bool {
        switch self {
        case .profile4, .profile7:
            return true
        case .profile5, .profile8:
            return false
        }
    }
    
    var colorSpace: String {
        switch self {
        case .profile4, .profile7:
            return "BT.2020"
        case .profile5:
            return "BT.2020"
        case .profile8:
            return "IPT-PQ"
        }
    }
}

struct DolbyVisionMetadata: Equatable {
    let profile: DolbyVisionProfile
    let blVideoSignalInfo: DolbyVisionVideoSignalInfo
    let elVideoSignalInfo: DolbyVisionVideoSignalInfo?
    let rpuMetadata: DolbyVisionRPUMetadata
    
    static func == (lhs: DolbyVisionMetadata, rhs: DolbyVisionMetadata) -> Bool {
        lhs.profile == rhs.profile &&
        lhs.blVideoSignalInfo == rhs.blVideoSignalInfo &&
        lhs.rpuMetadata == rhs.rpuMetadata
    }
}

struct DolbyVisionVideoSignalInfo: Equatable {
    let colorSpace: DolbyVisionColorSpace
    let transferCharacteristic: DolbyVisionTransferCharacteristic
    let colorPrimaries: DolbyVisionColorPrimaries
    
    static func == (lhs: DolbyVisionVideoSignalInfo, rhs: DolbyVisionVideoSignalInfo) -> Bool {
        lhs.colorSpace == rhs.colorSpace &&
        lhs.transferCharacteristic == rhs.transferCharacteristic &&
        lhs.colorPrimaries == rhs.colorPrimaries
    }
}

enum DolbyVisionColorSpace: UInt8, Equatable {
    case bt709 = 1
    case bt2020 = 2
}

enum DolbyVisionTransferCharacteristic: UInt8, Equatable {
    case sdr = 1
    case pq = 2
    case hlg = 3
}

enum DolbyVisionColorPrimaries: UInt8, Equatable {
    case bt709 = 1
    case bt2020 = 2
}

struct DolbyVisionRPUMetadata: Equatable {
    let sceneRefreshFlag: Bool
    let targetDisplayMaxLuminance: UInt16
    let targetDisplayMinLuminance: UInt16
    let trimPasses: [DolbyVisionTrimPass]
    let activeAreaOffsets: DolbyVisionActiveAreaOffsets?
    
    static func == (lhs: DolbyVisionRPUMetadata, rhs: DolbyVisionRPUMetadata) -> Bool {
        lhs.sceneRefreshFlag == rhs.sceneRefreshFlag &&
        lhs.targetDisplayMaxLuminance == rhs.targetDisplayMaxLuminance &&
        lhs.trimPasses == rhs.trimPasses
    }
}

struct DolbyVisionTrimPass: Equatable {
    let trimInfo: DolbyVisionTrimInfo
    let targetDisplayIndex: UInt8
    
    static func == (lhs: DolbyVisionTrimPass, rhs: DolbyVisionTrimPass) -> Bool {
        lhs.trimInfo == rhs.trimInfo &&
        lhs.targetDisplayIndex == rhs.targetDisplayIndex
    }
}

struct DolbyVisionTrimInfo: Equatable {
    let percentile: UInt8
    let targetMaxLuminance: UInt16
    let targetMinLuminance: UInt16
    
    static func == (lhs: DolbyVisionTrimInfo, rhs: DolbyVisionTrimInfo) -> Bool {
        lhs.percentile == rhs.percentile &&
        lhs.targetMaxLuminance == rhs.targetMaxLuminance &&
        lhs.targetMinLuminance == rhs.targetMinLuminance
    }
}

struct DolbyVisionActiveAreaOffsets: Equatable {
    let top: UInt16
    let bottom: UInt16
    let left: UInt16
    let right: UInt16
    
    static func == (lhs: DolbyVisionActiveAreaOffsets, rhs: DolbyVisionActiveAreaOffsets) -> Bool {
        lhs.top == rhs.top &&
        lhs.bottom == rhs.bottom &&
        lhs.left == rhs.left &&
        lhs.right == rhs.right
    }
}

// MARK: - Extended HDR Mode

enum ExtendedHDRMode: Equatable {
    case sdr
    case hdr10(HDR10Metadata)
    case hdr10Plus(HDR10PlusMetadata)
    case dolbyVision(DolbyVisionMetadata)
    case hlg
    
    var isDynamic: Bool {
        switch self {
        case .hdr10Plus, .dolbyVision:
            return true
        case .sdr, .hdr10, .hlg:
            return false
        }
    }
}

// MARK: - Metadata Processing Configuration

struct HDRProcessingConfig: Equatable {
    let enableDynamicToneMapping: Bool
    let enableMetadataPassthrough: Bool
    let fallbackToStaticHDR: Bool
    let targetLuminance: Float
    
    static let `default` = HDRProcessingConfig(
        enableDynamicToneMapping: true,
        enableMetadataPassthrough: true,
        fallbackToStaticHDR: true,
        targetLuminance: 1000.0
    )
}
