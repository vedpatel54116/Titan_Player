#ifndef AnalysisShaderTypes_h
#define AnalysisShaderTypes_h

#include <simd/simd.h>

typedef struct {
    uint32_t binCount;
} HistogramParams;

typedef struct {
    float minLuma;
    float maxLuma;
    float averageLuma;
    float padding;
} FrameStats;

#endif /* AnalysisShaderTypes_h */
