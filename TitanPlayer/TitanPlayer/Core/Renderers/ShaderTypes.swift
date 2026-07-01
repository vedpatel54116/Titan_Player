import Foundation
import simd

struct VertexIn {
    var position: simd_float2
    var textureCoordinate: simd_float2
}

struct VertexOut {
    var position: SIMD4<Float>
    var textureCoordinate: simd_float2
}

struct Uniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var hue: Float
    var iccMatrix: simd_float3x3
}

struct HDRUniforms {
    var hdrMode: UInt32
    var isHDRDisplay: UInt32
    var colorMatrix: simd_float3x3
    var maxLuminance: Float
    var minLuminance: Float
    var maxContentLightLevel: Float
    var maxFrameAverageLightLevel: Float
    var kneePoint: Float
    var compressionRatio: Float
    var saturationScale: Float
    var brightnessAdjustment: Float
    var useDynamicMetadata: UInt32
}

struct YCbCrUniforms {
    var yScale: Float
    var yOffset: Float
    var cbcrScale: Float
    var cbcrOffset: Float
    var isHDR: UInt32
}

enum HDRModeRaw: UInt32 {
    case sdr = 0
    case hdr10 = 1
    case hlg = 2
}
