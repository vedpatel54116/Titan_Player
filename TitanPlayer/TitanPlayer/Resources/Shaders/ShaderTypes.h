//
//  ShaderTypes.h
//  TitanPlayer
//
//  Shared C structs between Swift and Metal shaders.
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

#include <simd/simd.h>

// -- Video Vertex -----------------------------------------------------------
typedef struct {
    vector_float2 position;
    vector_float2 textureCoordinate;
} VideoVertex;

// -- Fragment Shader Uniforms -----------------------------------------------
// ICC matrix is applied in compute pass, so fragment only does
// brightness/contrast/saturation.
typedef struct {
    float brightness;
    float contrast;
    float saturation;
    matrix_float3x3 iccMatrix;  // Kept for backward compat, identity in fragment
} Uniforms;

// -- HDR Compute Uniforms ---------------------------------------------------
typedef struct {
    int hdrMode;                    // 0=SDR, 1=PQ, 2=HLG, 3=DolbyVision, 4=HDR10Plus
    int isHDRDisplay;               // 0=SDR display, 1=HDR display
    float displayMaxLuminance;      // Display peak luminance (nits)
    float maxContentLightLevel;     // MaxCLL from static metadata
    float maxFrameAverageLightLevel;// MaxFALL from static metadata
    int useDynamicMetadata;         // 1 if Dolby Vision / HDR10+ metadata present
    float dynamicMaxLuminance;      // Per-frame max luminance
    float dynamicBezierAnchor;      // Bezier curve anchor point
    float dynamicSaturation;        // Per-frame saturation adjustment
    float dynamicBrightness;        // Per-frame brightness adjustment
    matrix_float3x3 iccMatrix;      // ICC color transform (applied in compute)
} HDRUniforms;

// -- Subtitle Uniforms ------------------------------------------------------
typedef struct {
    vector_float2 scale;    // Scale factor for subtitle quad
    vector_float2 offset;   // Position offset (-1 to 1 range)
    float opacity;          // Subtitle opacity (0-1)
} SubtitleUniforms;

#endif /* ShaderTypes_h */
