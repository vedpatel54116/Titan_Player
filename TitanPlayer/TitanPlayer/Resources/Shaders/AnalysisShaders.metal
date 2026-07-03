#include <metal_stdlib>
using namespace metal;

constant uint kHistogramBinsDefault = 256;

// RGB Histogram with shared memory optimization
kernel void rgb_histogram(
    texture2d<float, access::read> input [[texture(0)]],
    device atomic_uint* histogram [[buffer(0)]],
    constant uint& binCount [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 tid [[thread_position_in_threadgroup]],
    uint2 tg_size [[threads_per_threadgroup]])
{
    threadgroup atomic_uint localHist[256];

    if (tid.x < binCount) {
        atomic_store_explicit(&localHist[tid.x], 0, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    float4 color = input.read(gid);
    uint r = uint(color.r * 255.0);
    uint g = uint(color.g * 255.0);
    uint b = uint(color.b * 255.0);

    atomic_fetch_add_explicit(&localHist[r], 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&localHist[g], 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&localHist[b], 1, memory_order_relaxed);

    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (tid.x < binCount) {
        uint val = atomic_exchange_explicit(&localHist[tid.x], 0, memory_order_relaxed);
        if (val > 0) {
            atomic_fetch_add_explicit(&histogram[tid.x], val, memory_order_relaxed);
        }
    }
}

// Luma histogram using shared memory
kernel void luma_histogram(
    texture2d<float, access::read> input [[texture(0)]],
    device atomic_uint* histogram [[buffer(0)]],
    constant uint& binCount [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 tid [[thread_position_in_threadgroup]])
{
    threadgroup atomic_uint localHist[256];

    if (tid.x < binCount) {
        atomic_store_explicit(&localHist[tid.x], 0, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    float4 color = input.read(gid);
    float luma = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;
    uint bin = uint(luma * 255.0);

    atomic_fetch_add_explicit(&localHist[bin], 1, memory_order_relaxed);

    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (tid.x < binCount) {
        uint val = atomic_exchange_explicit(&localHist[tid.x], 0, memory_order_relaxed);
        if (val > 0) {
            atomic_fetch_add_explicit(&histogram[tid.x], val, memory_order_relaxed);
        }
    }
}

// Parallel reduction for min/max/average luma
kernel void frame_statistics(
    texture2d<float, access::read> input [[texture(0)]],
    device float* output [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 tid [[thread_position_in_threadgroup]],
    uint2 tg_size [[threads_per_threadgroup]])
{
    threadgroup float localMin[256];
    threadgroup float localMax[256];
    threadgroup float localSum[256];
    threadgroup uint localCount[256];

    float4 color = input.read(gid);
    float luma = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b;

    uint lid = tid.y * tg_size.x + tid.x;

    localMin[lid] = luma;
    localMax[lid] = luma;
    localSum[lid] = luma;
    localCount[lid] = 1;

    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint s = (tg_size.x * tg_size.y) / 2; s > 0; s >>= 1) {
        if (lid < s) {
            localMin[lid] = min(localMin[lid], localMin[lid + s]);
            localMax[lid] = max(localMax[lid], localMax[lid + s]);
            localSum[lid] += localSum[lid + s];
            localCount[lid] += localCount[lid + s];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (lid == 0) {
        output[0] = localMin[0];
        output[1] = localMax[0];
        output[2] = localSum[0] / float(localCount[0]);
    }
}
