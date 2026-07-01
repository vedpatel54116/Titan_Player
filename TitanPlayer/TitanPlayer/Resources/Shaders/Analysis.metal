#include <metal_stdlib>
using namespace metal;

constant uint kHistogramBins   = 256u;
constant uint kVectorscopeGrid = 256u;
constant uint kWaveformColumns = 1024u;
constant uint kWaveformBuckets = 8u;

struct ColorPickerArgs {
    uint2 coord;
};

static inline float2 rgbToYCbCr(float3 rgb) {
    float cb = -0.168736 * rgb.r - 0.331264 * rgb.g + 0.5 * rgb.b;
    float cr =  0.5      * rgb.r - 0.418688 * rgb.g - 0.081312 * rgb.b;
    return float2(cb, cr);
}

static inline float rgbMaxMinRange(float3 rgb) {
    float mx = max(rgb.r, max(rgb.g, rgb.b));
    float mn = min(rgb.r, min(rgb.g, rgb.b));
    return mx > 0.0 ? (mx - mn) / mx : 0.0;
}

// MARK: - Histogram

kernel void kernelHistogram(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    device atomic_uint *outR [[buffer(0)]],
    device atomic_uint *outG [[buffer(1)]],
    device atomic_uint *outB [[buffer(2)]],
    device atomic_uint *outY [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;

    float4 px = inputTexture.read(gid);
    float r = clamp(px.r, 0.0, 1.0);
    float g = clamp(px.g, 0.0, 1.0);
    float b = clamp(px.b, 0.0, 1.0);
    float y = clamp(dot(px.rgb, float3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);

    uint binR = (uint)floor(r * 255.0);
    uint binG = (uint)floor(g * 255.0);
    uint binB = (uint)floor(b * 255.0);
    uint binY = (uint)floor(y * 255.0);

    atomic_fetch_add_explicit(outR + binR, 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(outG + binG, 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(outB + binB, 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(outY + binY, 1u, memory_order_relaxed);
}

// MARK: - Vectorscope

kernel void kernelVectorscope(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    device atomic_uint *grid [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
    float4 px = inputTexture.read(gid);
    if (max(px.r, max(px.g, px.b)) <= 0.0) return;

    float2 cc = rgbToYCbCr(px.rgb);
    float sat = rgbMaxMinRange(px.rgb);
    if (sat < 0.05) return;

    int gx = int(clamp((cc.x + 0.5) * 127.5, 0.0, 255.0));
    int gy = int(clamp((cc.y + 0.5) * 127.5, 0.0, 255.0));
    uint weight = max(1u, (uint)floor(sat * 255.0 + 0.5));
    atomic_fetch_add_explicit(grid + (gy * (int)kVectorscopeGrid + gx), weight, memory_order_relaxed);
}

// MARK: - Waveform

kernel void kernelWaveform(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    device atomic_uint *outRY [[buffer(0)]],   // R/Y channel: stride = kWaveformColumns * kWaveformBuckets
    device atomic_uint *outGY [[buffer(1)]],   // G
    device atomic_uint *outBY [[buffer(2)]],   // B
    device atomic_uint *outYY [[buffer(3)]],   // Y
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;

    uint outCol = (gid.x * kWaveformColumns) / max(1u, inputTexture.get_width());
    outCol = min(outCol, kWaveformColumns - 1u);

    float4 px = inputTexture.read(gid);
    float r = clamp(px.r, 0.0, 1.0);
    float g = clamp(px.g, 0.0, 1.0);
    float b = clamp(px.b, 0.0, 1.0);
    float y = clamp(dot(px.rgb, float3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);

    uint bucketR = min((uint)floor(r * (float)kWaveformBuckets), kWaveformBuckets - 1u);
    uint bucketG = min((uint)floor(g * (float)kWaveformBuckets), kWaveformBuckets - 1u);
    uint bucketB = min((uint)floor(b * (float)kWaveformBuckets), kWaveformBuckets - 1u);
    uint bucketY = min((uint)floor(y * (float)kWaveformBuckets), kWaveformBuckets - 1u);

    atomic_fetch_add_explicit(outRY + outCol * kWaveformBuckets + bucketR, 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(outGY + outCol * kWaveformBuckets + bucketG, 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(outBY + outCol * kWaveformBuckets + bucketB, 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(outYY + outCol * kWaveformBuckets + bucketY, 1u, memory_order_relaxed);
}

// MARK: - Color picker

kernel void kernelColorPicker(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    device float4 *outSample [[buffer(0)]],
    constant ColorPickerArgs &args [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x != 0 || gid.y != 0) return;
    uint w = inputTexture.get_width();
    uint h = inputTexture.get_height();
    if (args.coord.x >= w || args.coord.y >= h) {
        outSample[0] = float4(0.0, 0.0, 0.0, 0.0);
        return;
    }
    float4 px = inputTexture.read(args.coord);
    outSample[0] = float4(px.r, px.g, px.b, px.a);
}
