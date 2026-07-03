#include <metal_stdlib>
using namespace metal;
#include "ShaderTypes.h"

fragment float4 video_fragment_shader(
    VertexOut in [[stage_in]],
    texture2d<float> toneMappedTexture [[texture(0)]],
    constant Uniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear);
    float4 color = toneMappedTexture.sample(texSampler, in.textureCoordinate);
    
    color.rgb = uniforms.iccMatrix * color.rgb;
    
    color.rgb += uniforms.brightness;
    
    color.rgb = (color.rgb - 0.5) * uniforms.contrast + 0.5;
    
    float luma = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    color.rgb = mix(float3(luma), color.rgb, uniforms.saturation);
    
    return color;
}
