#ifndef ShaderTypes_h
#define ShaderTypes_h

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

struct YCbCrUniforms {
    float yScale;
    float yOffset;
    float cbcrScale;
    float cbcrOffset;
    uint isHDR;
};

#endif /* ShaderTypes_h */
