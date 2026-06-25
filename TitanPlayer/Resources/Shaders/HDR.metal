#include <metal_stdlib>
using namespace metal;

constant float PQ_MAX_LUMINANCE = 1000.0;
constant float SDR_MAX_LUMINANCE = 100.0;

float pqToLinear(float pq) {
    float pqPow = pow(pq, 1.0 / 78.8438);
    return pow(max(pqPow - 0.8359, 0.0) / (18.8515 - 18.6875 * pqPow), 1.0 / 0.1593);
}

float hlgToLinear(float hlg) {
    float a = 0.17883277;
    float b = 0.28466892;
    float c = 0.55991073;
    
    if (hlg <= 0.5) {
        return (hlg * hlg) / 3.0;
    }
    return (exp((hlg - c) / a) + b) / 12.0;
}

fragment float4 hdrFragmentShader(VertexOut input [[stage_in]],
                                   texture2d<float> texture [[texture(0)]],
                                   constant bool &hdrEnabled [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float4 color = texture.sample(textureSampler, input.textureCoordinate);
    
    if (hdrEnabled) {
        float linear = pqToLinear(color.r);
        float sdr = linear * (SDR_MAX_LUMINANCE / PQ_MAX_LUMINANCE);
        color = float4(sdr, sdr, sdr, color.a);
    }
    
    return color;
}
