//
//  Video.metal
//  TitanPlayer
//
//  Vertex + Fragment shaders for final video compositing.
//
//  FIX: The ICC color matrix is now applied in the compute pass
//  (ycbcr_to_rgb or hdr_tone_mapping), so the fragment shader
//  only applies brightness/contrast/saturation adjustments.
//  This eliminates the double color transform bug.
//

#include <metal_stdlib>
using namespace metal;
#include "ShaderTypes.h"

// -- Vertex Shader ----------------------------------------------------------
vertex VertexOut video_vertex_shader(
    uint vertexID [[vertex_id]],
    constant VideoVertex *vertices [[buffer(0)]]
) {
    VertexOut out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.textureCoordinate = vertices[vertexID].textureCoordinate;
    return out;
}

// -- Fragment Shader ---------------------------------------------------------
// Input: tone-mapped (or SDR) RGB texture from compute pass.
// The ICC matrix has ALREADY been applied in the compute pass,
// so we only do brightness / contrast / saturation here.
fragment float4 video_fragment_shader(
    VertexOut in [[stage_in]],
    texture2d<float> videoTexture [[texture(0)]],
    constant Uniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler texSampler(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );

    float4 color = videoTexture.sample(texSampler, in.textureCoordinate);

    // Brightness adjustment
    color.rgb += uniforms.brightness;

    // Contrast adjustment (pivot around 0.5)
    color.rgb = (color.rgb - 0.5) * uniforms.contrast + 0.5;

    // Saturation adjustment
    float luma = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    color.rgb = mix(float3(luma), color.rgb, uniforms.saturation);

    // Clamp to valid range
    color.rgb = saturate(color.rgb);

    return color;
}
