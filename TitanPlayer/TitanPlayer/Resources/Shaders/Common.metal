#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position;
    float2 textureCoordinate;
};

struct VertexOut {
    float4 position [[position]];
    float2 textureCoordinate;
};

struct Uniforms {
    float brightness;
    float contrast;
    float saturation;
    float hue;
    float3x3 iccMatrix;
};

struct HDRUniforms {
    uint hdrMode;
    uint isHDRDisplay;
    float3x3 colorMatrix;
    float maxLuminance;
    float minLuminance;
    float maxContentLightLevel;
    float maxFrameAverageLightLevel;
    float kneePoint;
    float compressionRatio;
    float saturationScale;
    float brightnessAdjustment;
    uint useDynamicMetadata;
};

vertex VertexOut vertexShader(constant VertexIn *vertices [[buffer(0)]],
                              uint vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.textureCoordinate = vertices[vid].textureCoordinate;
    return out;
}
