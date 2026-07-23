//
//  Subtitle.metal
//  TitanPlayer
//
//  Vertex + Fragment shaders for subtitle bitmap compositing.
//
//  FIX: The vertex shader now uses a dedicated SubtitleVertex
//  struct with proper UV mapping. The fragment shader outputs
//  premultiplied alpha for correct blending with the video.
//

#include <metal_stdlib>
using namespace metal;
#include "ShaderTypes.h"

// -- Vertex Shader ----------------------------------------------------------
vertex VertexOut subtitle_vertex_shader(
    uint vertexID [[vertex_id]],
    constant SubtitleUniforms &uniforms [[buffer(0)]]
) {
    // Full-screen quad with subtitle scale/offset applied
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0, -1.0),
        float2( 1.0,  1.0)
    };

    float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 1.0),
        float2(1.0, 0.0)
    };

    VertexOut out;
    float2 pos = positions[vertexID];

    // Apply scale and offset for subtitle positioning
    pos = pos * uniforms.scale + uniforms.offset;

    out.position = float4(pos, 0.0, 1.0);
    out.textureCoordinate = texCoords[vertexID];
    return out;
}

// -- Fragment Shader --------------------------------------------------------
fragment float4 subtitle_fragment_shader(
    VertexOut in [[stage_in]],
    texture2d<float> subtitleTexture [[texture(0)]],
    constant SubtitleUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler texSampler(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );

    float4 color = subtitleTexture.sample(texSampler, in.textureCoordinate);

    // Apply opacity
    color.a *= uniforms.opacity;

    // Premultiply alpha for correct blending
    color.rgb *= color.a;

    return color;
}
