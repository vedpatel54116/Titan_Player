#include <metal_stdlib>
using namespace metal;

#include "ShaderTypes.h"

kernel void ycbcr_to_rgb(
    texture2d<float, access::read> yTexture [[texture(0)]],
    texture2d<float, access::read> cbcrTexture [[texture(1)]],
    texture2d<float, access::write> outputTexture [[texture(2)]],
    constant YCbCrUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    float y = yTexture.read(gid).r;
    float2 cbcr = cbcrTexture.read(uint2(gid.x / 2, gid.y / 2)).rg;

    y = y * uniforms.yScale + uniforms.yOffset;
    cbcr = cbcr * uniforms.cbcrScale + uniforms.cbcrOffset;

    float3 ycbcr = float3(y, cbcr.x - 0.5, cbcr.y - 0.5);

    float3x3 ycbcrToRGB;

    if (uniforms.isHDR == 1) {
        // BT.2020 YCbCr -> RGB matrix
        ycbcrToRGB = float3x3(
            float3(1.164383,  1.164383, 1.164383),
            float3(0.000000, -0.187326, 2.141772),
            float3(1.678674, -0.650428, 0.000000)
        );
    } else {
        // BT.601 YCbCr -> RGB matrix (SDR)
        ycbcrToRGB = float3x3(
            float3(1.0,     1.0,     1.0),
            float3(0.0,    -0.344,  1.772),
            float3(1.402,  -0.714,  0.0)
        );
    }

    float3 rgb = ycbcrToRGB * ycbcr;
    rgb = clamp(rgb, 0.0, 1.0);

    outputTexture.write(float4(rgb, 1.0), gid);
}

vertex VertexOut vertexShader(constant VertexIn *vertices [[buffer(0)]],
                              uint vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.textureCoordinate = vertices[vid].textureCoordinate;
    return out;
}
