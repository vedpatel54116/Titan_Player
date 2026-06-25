#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position;
    float2 textureCoordinate;
};

struct VertexOut {
    float4 position [[position]];
    float2 textureCoordinate;
};

vertex VertexOut vertexShader(constant VertexIn &vertices [[buffer(0)]]) {
    VertexOut output;
    output.position = float4(vertices.position, 0.0, 1.0);
    output.textureCoordinate = vertices.textureCoordinate;
    return output;
}

fragment float4 fragmentShader(VertexOut input [[stage_in]],
                               texture2d<float> texture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    return texture.sample(textureSampler, input.textureCoordinate);
}
