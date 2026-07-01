#include <metal_stdlib>
using namespace metal;

kernel void hdrToneMapping(
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
    
    if (uniforms.hdrMode == 1) {
        color = pqToLinear(color);
    } else if (uniforms.hdrMode == 2) {
        color = hlgToLinear(color);
    }
    
    color = uniforms.colorMatrix * color;
    
    if (uniforms.useDynamicMetadata == 1) {
        color = dynamicToneMap(color, uniforms);
    } else {
        color = acesToneMap(color);
    }
    
    color = applyDynamicAdjustments(color, uniforms);
    
    if (uniforms.isHDRDisplay == 0) {
        color = linearToSRGB(color);
    }
    
    outputTexture.write(float4(color, 1.0), gid);
}

float3 dynamicToneMap(float3 color, constant HDRUniforms &uniforms) {
    float3 compressed = color;
    float maxComponent = max(compressed.r, max(compressed.g, compressed.b));
    
    if (maxComponent > uniforms.kneePoint) {
        float3 excess = compressed - uniforms.kneePoint;
        float3 compressedExcess = excess * uniforms.compressionRatio;
        compressed = uniforms.kneePoint + compressedExcess;
    }
    
    return acesToneMap(compressed);
}

float3 applyDynamicAdjustments(float3 color, constant HDRUniforms &uniforms) {
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = mix(float3(luma), color, uniforms.saturationScale);
    color += uniforms.brightnessAdjustment;
    return color;
}

float3 pqToLinear(float3 pq) {
    float m1 = 0.1593017578125;
    float m2 = 78.84375;
    float c1 = 0.8359375;
    float c2 = 18.8515625;
    float c3 = 18.6875;
    
    float3 pqPow = pow(pq, float3(1.0 / m2));
    float3 num = max(pqPow - c1, 0.0);
    float3 den = c2 - c3 * pqPow;
    return pow(num / den, float3(1.0 / m1));
}

float3 hlgToLinear(float3 hlg) {
    float a = 0.17883277;
    float b = 0.28466892;
    float c = 0.55991073;
    
    float3 linear;
    linear.r = (hlg.r <= 0.5) ? 
        (hlg.r * hlg.r) / 3.0 : 
        (exp((hlg.r - c) / a) + b) / 12.0;
    linear.g = (hlg.g <= 0.5) ? 
        (hlg.g * hlg.g) / 3.0 : 
        (exp((hlg.g - c) / a) + b) / 12.0;
    linear.b = (hlg.b <= 0.5) ? 
        (hlg.b * hlg.b) / 3.0 : 
        (exp((hlg.b - c) / a) + b) / 12.0;
    return linear;
}

float3 acesToneMap(float3 x) {
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

float3 linearToSRGB(float3 linear) {
    return select(
        1.055 * pow(linear, float3(1.0 / 2.4)) - 0.055,
        12.92 * linear,
        linear <= 0.0031308
    );
}
