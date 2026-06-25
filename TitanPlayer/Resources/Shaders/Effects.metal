#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float brightness;
    float contrast;
    float saturation;
    float hue;
};

fragment float4 effectsFragmentShader(VertexOut input [[stage_in]],
                                      texture2d<float> texture [[texture(0)]],
                                      constant Uniforms &uniforms [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float4 color = texture.sample(textureSampler, input.textureCoordinate);
    
    // Brightness
    color.rgb += uniforms.brightness;
    
    // Contrast
    color.rgb = (color.rgb - 0.5) * uniforms.contrast + 0.5;
    
    // Saturation
    float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    color.rgb = mix(float3(luminance), color.rgb, uniforms.saturation);
    
    return color;
}
