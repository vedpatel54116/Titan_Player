//
//  Common.metal
//  TitanPlayer
//
//  YCbCr (NV12) → Linear RGB compute shader.
//
//  FIX: The ICC color matrix is now applied HERE in the compute
//  pass, so the fragment shader doesn't need to re-apply it.
//  This eliminates the double color transform.
//

#include <metal_stdlib>
using namespace metal;
#include "ShaderTypes.h"

// BT.709 YCbCr → RGB matrix (full range)
constant float3x3 bt709_matrix = float3x3(
    float3(1.0,  0.0,       1.5748),
    float3(1.0, -0.1873,   -0.4681),
    float3(1.0,  1.8556,    0.0)
);

// BT.2020 YCbCr → RGB matrix (for HDR/UHD content)
constant float3x3 bt2020_matrix = float3x3(
    float3(1.0,  0.0,       1.4746),
    float3(1.0, -0.1646,   -0.5714),
    float3(1.0,  1.8814,    0.0)
);

kernel void ycbcr_to_rgb(
    texture2d<float, access::read> yTexture [[texture(0)]],
    texture2d<float, access::read> cbCrTexture [[texture(1)]],
    texture2d<float, access::write> rgbTexture [[texture(2)]],
    constant Uniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= rgbTexture.get_width() || gid.y >= rgbTexture.get_height()) {
        return;
    }

    // Read Y and CbCr samples
    float y = yTexture.read(gid).r;
    uint2 cbCrCoord = uint2(gid.x / 2, gid.y / 2);
    float2 cbCr = cbCrTexture.read(cbCrCoord).rg;

    // Offset to [-0.5, 0.5] range
    float3 ycbcr = float3(y, cbCr.x - 0.5, cbCr.y - 0.5);

    // Select color matrix based on content
    // (In production, pass a flag via uniforms to select BT.709 vs BT.2020)
    float3x3 colorMatrix = bt709_matrix;
    float3 rgb = colorMatrix * ycbcr;

    // Apply ICC color matrix HERE (not in fragment shader)
    rgb = uniforms.iccMatrix * rgb;

    // Clamp to valid range
    rgb = saturate(rgb);

    rgbTexture.write(float4(rgb, 1.0), gid);
}
