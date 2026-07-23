//
//  ShaderTypes.swift
//  TitanPlayer
//
//  Swift mirrors of the C structs in ShaderTypes.h.
//  Must match the C layout exactly for setBytes/setFragmentBytes.
//

import simd

struct VideoVertex {
    var position: SIMD2<Float>
    var textureCoordinate: SIMD2<Float>
}

struct Uniforms {
    var brightness: Float = 0.0
    var contrast: Float = 1.0
    var saturation: Float = 1.0
    var iccMatrix: matrix_float3x3 = matrix_identity_float3x3
}

struct HDRUniforms {
    var hdrMode: Int32 = 0
    var isHDRDisplay: Int32 = 0
    var displayMaxLuminance: Float = 100.0
    var maxContentLightLevel: Float = 1000.0
    var maxFrameAverageLightLevel: Float = 400.0
    var useDynamicMetadata: Int32 = 0
    var dynamicMaxLuminance: Float = 1000.0
    var dynamicBezierAnchor: Float = 0.5
    var dynamicSaturation: Float = 1.0
    var dynamicBrightness: Float = 0.0
    var iccMatrix: matrix_float3x3 = matrix_identity_float3x3
}

struct SubtitleUniforms {
    var scale: SIMD2<Float> = SIMD2<Float>(1.0, 1.0)
    var offset: SIMD2<Float> = SIMD2<Float>(0.0, 0.0)
    var opacity: Float = 1.0
}

// MARK: - HDR Mode Mapping

enum HDRMode: Int32 {
    case sdr = 0
    case pq = 1
    case hlg = 2
    case dolbyVision = 3
    case hdr10Plus = 4

    var shaderValue: Int32 { rawValue }
}
