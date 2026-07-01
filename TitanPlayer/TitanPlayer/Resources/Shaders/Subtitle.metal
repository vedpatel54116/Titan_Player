#include <metal_stdlib>
using namespace metal;

fragment float4 subtitleFragment(
    VertexOut in [[stage_in]],
    texture2d<float> videoTexture [[texture(0)]],
    texture2d<float> subtitleTexture [[texture(1)]]
) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear);
    float4 video = videoTexture.sample(texSampler, in.textureCoordinate);
    float4 subtitle = subtitleTexture.sample(texSampler, in.textureCoordinate);
    return mix(video, subtitle, subtitle.a);
}
