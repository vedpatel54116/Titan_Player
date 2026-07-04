#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float4 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex VertexOut defaultVertexShader(VertexIn vertices [[stage_in]]) {
    VertexOut out;
    out.position = vertices.position;
    out.texCoord = vertices.texCoord;
    return out;
}

fragment float4 defaultFragmentShader(VertexOut in [[stage_in]],
                                       texture2d<float> texture [[texture(0)]],
                                       sampler texSampler [[sampler(0)]]) {
    return texture.sample(texSampler, in.texCoord);
}