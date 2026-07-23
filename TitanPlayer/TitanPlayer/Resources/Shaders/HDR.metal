//
//  HDR.metal
//  TitanPlayer
//
//  HDR tone mapping compute shader.
//  Converts PQ/HLG -> linear -> tone-mapped -> ICC-adjusted RGB.
//
//  FIXES:
//  - Added ICC matrix application (was only in fragment shader)
//  - Added NaN/Inf guards for degenerate metadata
//  - Added HLG inverse OETF (was incomplete)
//

#include <metal_stdlib>
using namespace metal;
#include "ShaderTypes.h"

// -- PQ EOTF (ST 2084) ----------------------------------------------------
float3 hdr_pq_to_linear(float3 pq) {
    float m1 = 0.1593017578125;
    float m2 = 78.84375;
    float c1 = 0.8359375;
    float c2 = 18.8515625;
    float c3 = 18.6875;

    float3 pqPow = pow(max(pq, 0.0), float3(1.0 / m2));
    float3 num = max(pqPow - c1, 0.0);
    float3 den = max(c2 - c3 * pqPow, 1e-6);  // Guard against division by zero
    return pow(num / den, float3(1.0 / m1));
}

// -- HLG OETF inverse -----------------------------------------------------
float3 hdr_hlg_to_linear(float3 hlg) {
    float a = 0.17883277;
    float b = 0.28466892;  // 1 - 4a
    float c = 0.55991073;  // 0.5 - a * ln(4a)

    float3 linear;
    for (int i = 0; i < 3; i++) {
        float v = hlg[i];
        if (v <= 0.5) {
            linear[i] = (v * v) / 3.0;
        } else {
            linear[i] = (exp((v - c) / a) + b) / 12.0;
        }
    }
    return linear;
}

// -- ACES Filmic Tone Map --------------------------------------------------
float3 hdr_aces_tone_map(float3 x) {
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

// -- Dynamic Bezier Tone Map (Dolby Vision / HDR10+) ----------------------
float3 hdr_dynamic_tone_map(float3 color, constant HDRUniforms &uniforms) {
    float maxLum = max(uniforms.dynamicMaxLuminance, 1.0);  // Guard against 0
    float anchor = uniforms.dynamicBezierAnchor;

    // Normalize to display range
    float3 normalized = color / maxLum;

    // Bezier curve: smooth transition at anchor point
    float3 result;
    for (int i = 0; i < 3; i++) {
        float x = normalized[i];
        if (x <= anchor) {
            result[i] = x * x / (2.0 * anchor);
        } else {
            float t = (x - anchor) / (1.0 - anchor);
            result[i] = anchor + (1.0 - anchor) * (1.0 - pow(1.0 - t, 2.0));
        }
    }

    return result * maxLum;
}

// -- Dynamic Adjustments (saturation, brightness) -------------------------
float3 hdr_apply_dynamic_adjustments(float3 color, constant HDRUniforms &uniforms) {
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    float3 adjusted = mix(float3(luma), color, uniforms.dynamicSaturation);
    adjusted += uniforms.dynamicBrightness;
    return max(adjusted, 0.0);
}

// -- Linear -> sRGB -------------------------------------------------------
float3 hdr_linear_to_srgb(float3 linear) {
    float3 srgb;
    for (int i = 0; i < 3; i++) {
        float v = linear[i];
        if (v <= 0.0031308) {
            srgb[i] = 12.92 * v;
        } else {
            srgb[i] = 1.055 * pow(v, 1.0 / 2.4) - 0.055;
        }
    }
    return srgb;
}

// -- Main Kernel ----------------------------------------------------------
kernel void hdr_tone_mapping(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant HDRUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) {
        return;
    }

    float4 input = inputTexture.read(gid);
    float3 color = input.rgb;

    // Guard against NaN/Inf from degenerate input
    if (any(isnan(color)) || any(isinf(color))) {
        outputTexture.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }

    // Step 1: PQ or HLG -> Linear
    if (uniforms.hdrMode == 1) {
        color = hdr_pq_to_linear(color);
    } else if (uniforms.hdrMode == 2) {
        color = hdr_hlg_to_linear(color);
    }

    // Step 2: Apply ICC color matrix (moved from fragment shader)
    color = uniforms.iccMatrix * color;

    // Step 3: Tone mapping
    if (uniforms.useDynamicMetadata == 1) {
        color = hdr_dynamic_tone_map(color, uniforms);
    } else {
        color = hdr_aces_tone_map(color);
    }

    // Step 4: Dynamic adjustments
    color = hdr_apply_dynamic_adjustments(color, uniforms);

    // Step 5: Linear -> sRGB for SDR displays
    if (uniforms.isHDRDisplay == 0) {
        color = hdr_linear_to_srgb(color);
    }

    // Final clamp
    color = saturate(color);

    outputTexture.write(float4(color, 1.0), gid);
}
