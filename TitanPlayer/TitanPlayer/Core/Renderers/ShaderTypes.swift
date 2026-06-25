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
    var hdrEnabled: Bool
}
