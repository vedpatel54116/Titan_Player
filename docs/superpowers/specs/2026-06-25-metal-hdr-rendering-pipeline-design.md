# Metal HDR Rendering Pipeline Design

## Overview

Custom Metal rendering pipeline for TitanPlayer with comprehensive HDR support including EDR, HDR10, HLG, ACES filmic tone mapping, ICC profile-based color management, and GPU-accelerated post-processing.

**Target:** macOS 14+ (Sonoma) — required for full EDR API support
**Architecture:** Hybrid compute + fragment shader pipeline
**HDR Formats:** HDR10, HLG
**Tone Mapping:** ACES filmic
**Color Management:** Auto-detect ICC profile from display

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    Input Layer                          │
│  CVPixelBuffer → MTLTexture (YCbCr / RGB)              │
└─────────────────────────┬───────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│              Color Space Detection                      │
│  HDRMetadata parser → HDRMode enum (SDR/HDR10/HLG)     │
│  Display capabilities → EDR support check               │
└─────────────────────────┬───────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│           Compute Shader: Tone Mapping                  │
│  Input: HDR texture (PQ/HLG encoded)                    │
│  Process: PQ/HLG EOTF → Linear → ACES → Tone Mapped    │
│  Output: Linear light texture (SDR or EDR)              │
└─────────────────────────┬───────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│           Fragment Shader: Color Management             │
│  ICC profile LUT or 3x3 matrix transform                │
│  Brightness/contrast/saturation adjustments             │
│  Final gamma encoding for display                       │
└─────────────────────────┬───────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│                    Output                               │
│  CAMetalLayer → Display                                 │
│  EDR metadata for HDR displays                          │
└─────────────────────────────────────────────────────────┘
```

---

## HDR Metadata & Format Detection

### HDR Format Detection

The renderer detects HDR format from two sources:

1. **Container metadata** (from demuxer) — `MediaInfo.hdrMetadata`
2. **Codec-level metadata** (from decoder) — SEI messages in H.265

### Key Types

```swift
enum HDRMode {
    case sdr
    case hdr10(HDR10Metadata)
    case hlg
}

struct HDR10Metadata {
    let displayPrimaries: (red: SIMD2<Float>, green: SIMD2<Float>, blue: SIMD2<Float>)
    let whitePoint: SIMD2<Float>
    let maxDisplayLuminance: Float  // nits
    let minDisplayLuminance: Float  // nits
    let maxContentLightLevel: Float  // CLL
    let maxFrameAverageLightLevel: Float  // FALL
}

struct DisplayCapabilities {
    let supportsHDR: Bool
    let supportsEDR: Bool
    let maxEDRLuminance: Float  // nits
    let colorGamut: ColorGamut  // sRGB, P3, BT.2020
}

enum ColorGamut {
    case srgb
    case displayP3
    case bt2020
}

struct ICCProfile {
    let gamut: ColorGamut
    let matrix: simd_float3x3
}
```

### Display Detection Flow

```swift
func detectDisplayCapabilities(for screen: NSScreen) -> DisplayCapabilities {
    // 1. Check NSScreen.maximumExtendedDynamicRangeColorComponentValue
    // 2. Check CGDisplayCopyColorSpace for gamut
    // 3. Return capabilities
}

func detectICCProfile(for screen: NSScreen) -> ICCProfile {
    guard let colorSpace = screen.colorSpace else {
        return .sRGB  // Fallback
    }
    
    // Extract 3x3 matrix from ICC profile
    if let profile = CGColorSpace(name: colorSpace.localizedName ?? "") {
        // Get ICC profile data and extract transform matrix
    }
    
    return ICCProfile(
        gamut: detectGamut(colorSpace),
        matrix: extractMatrix(from: colorSpace)
    )
}
```

### EDR Metadata Setup

For EDR-capable displays:
- Set `CAMetalLayer.wantsExtendedDynamicRangeContent = true`
- Configure drawable's `targetEDR` and `targetPeak` values
- Use `.rgba16Float` pixel format for HDR headroom

---

## Compute Shader — Tone Mapping

### Compute Kernel

```metal
kernel void hdrToneMapping(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant HDRUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    float4 input = inputTexture.read(gid);
    float3 color = input.rgb;
    
    // 1. Decode transfer function (PQ or HLG → linear)
    if (uniforms.hdrMode == HDR_MODE_HDR10) {
        color = pqToLinear(color);
    } else if (uniforms.hdrMode == HDR_MODE_HLG) {
        color = hlgToLinear(color);
    }
    
    // 2. Apply BT.2020 to display primaries matrix
    color = uniforms.colorMatrix * color;
    
    // 3. ACES filmic tone mapping
    color = acesToneMap(color);
    
    // 4. SDR gamma encoding (for SDR displays)
    if (!uniforms.isHDRDisplay) {
        color = linearToSRGB(color);
    }
    
    outputTexture.write(float4(color, 1.0), gid);
}
```

### ACES Tone Mapping

```metal
float3 acesToneMap(float3 x) {
    float a = 2.51;
    float b = 0.03;
    float c = 2.43;
    float d = 0.59;
    float e = 0.14;
    return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
}
```

### PQ EOTF (Perceptual Quantizer — HDR10)

```metal
float3 pqToLinear(float3 pq) {
    float m1 = 0.1593017578125;   // 2610/16384
    float m2 = 78.84375;          // 2523/32*128
    float c1 = 0.8359375;         // 3424/4096
    float c2 = 18.8515625;        // 2413/128
    float c3 = 18.6875;           // 2393/128
    
    float3 pqPow = pow(pq, 1.0 / m2);
    float3 num = max(pqPow - c1, 0.0);
    float3 den = c2 - c3 * pqPow;
    return pow(num / den, 1.0 / m1);
}
```

### HLG EOTF (Hybrid Log-Gamma)

```metal
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
```

---

## Fragment Shader — Color Management & Effects

### Fragment Shader

```metal
fragment float4 fragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> toneMappedTexture [[texture(0)]],
    constant Uniforms &uniforms [[buffer(0)]],
    texture2d<float> iccLUT [[texture(1)]]
) {
    float4 color = toneMappedTexture.sample(sampler, in.textureCoordinate);
    
    // 1. ICC color management (3x3 matrix or LUT)
    color.rgb = uniforms.iccMatrix * color.rgb;
    
    // 2. Color adjustments
    color.rgb = adjustBrightness(color.rgb, uniforms.brightness);
    color.rgb = adjustContrast(color.rgb, uniforms.contrast);
    color.rgb = adjustSaturation(color.rgb, uniforms.saturation);
    color.rgb = adjustHue(color.rgb, uniforms.hue);
    
    return color;
}
```

### Color Adjustment Helpers

```metal
float3 adjustBrightness(float3 color, float brightness) {
    return color + brightness;
}

float3 adjustContrast(float3 color, float contrast) {
    return (color - 0.5) * contrast + 0.5;
}

float3 adjustSaturation(float3 color, float saturation) {
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    return lerp(float3(luma), color, saturation);
}
```

---

## Swift Integration & API

### MetalRenderer Class

```swift
class MetalRenderer: NSObject, MTKViewDelegate {
    // Core Metal
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var toneMappingPipeline: MTLComputePipelineState?
    private var fragmentPipeline: MTLRenderPipelineState?
    
    // HDR State
    private var currentHDRMode: HDRMode = .sdr
    private var displayCapabilities: DisplayCapabilities?
    private var iccProfile: ICCProfile?
    
    // Buffers
    private var hdrUniformsBuffer: MTLBuffer?
    private var vertexBuffer: MTLBuffer?
    
    // Textures
    private var toneMappedTexture: MTLTexture?
    
    // Triple buffering
    private var inFlightSemaphore = DispatchSemaphore(value: 3)
    private var frameIndex = 0
    
    init?(metalView: MTKView) {
        // Setup device, queue, pipelines
        // Detect display capabilities
        // Configure EDR if supported
    }
    
    func render(pixelBuffer: CVPixelBuffer, 
                metadata: HDRMetadata?,
                to drawable: CAMetalDrawable) {
        inFlightSemaphore.wait()
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inFlightSemaphore.signal()
        }
        
        // 1. Create texture from pixelBuffer
        guard let inputTexture = createTexture(from: pixelBuffer) else { return }
        
        // 2. Update HDR uniforms
        updateHDRUniforms(metadata: metadata)
        
        // 3. Dispatch compute shader (tone mapping)
        dispatchToneMapping(input: inputTexture, commandBuffer: commandBuffer)
        
        // 4. Render fragment shader (color management + effects)
        renderFragment(commandBuffer: commandBuffer, drawable: drawable)
        
        // 5. Present
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    func updateDisplayCapabilities(for screen: NSScreen) {
        displayCapabilities = detectDisplayCapabilities(for: screen)
        iccProfile = detectICCProfile(for: screen)
    }
}
```

### MetalRendererDelegate Protocol

```swift
protocol MetalRendererDelegate: AnyObject {
    func renderer(_ renderer: MetalRenderer, 
                  didDetectHDRMode mode: HDRMode)
    func renderer(_ renderer: MetalRenderer, 
                  didUpdateDisplayCapabilities caps: DisplayCapabilities)
}
```

### Integration with PlayerView

```swift
struct PlayerView: NSViewRepresentable {
    @Binding var pixelBuffer: CVPixelBuffer?
    @Binding var hdrMetadata: HDRMetadata?
    
    func makeNSView(context: Context) -> MTKView {
        let metalView = MTKView()
        metalView.delegate = context.coordinator.renderer
        metalView.colorPixelFormat = .rgba16Float  // For HDR
        metalView.wantsExtendedDynamicRangeContent = true
        return metalView
    }
}
```

---

## Performance Targets

| Metric | Target | How to Achieve |
|--------|--------|----------------|
| GPU usage during 4K HDR | <20% on M1 | Single compute pass + efficient fragment shader |
| Frame drops | 0 during 4K HDR | Triple buffering, display link sync |
| Color accuracy | Delta E <2 | ACES tone mapping + ICC profile support |
| Memory overhead | <50MB additional | Efficient texture management, no unnecessary copies |

### Triple Buffering

```swift
private var inFlightSemaphore = DispatchSemaphore(value: 3)

func render(...) {
    inFlightSemaphore.wait()
    
    let commandBuffer = commandQueue.makeCommandBuffer()
    commandBuffer.addCompletedHandler { [weak self] _ in
        self?.inFlightSemaphore.signal()
    }
    
    // ... encode commands ...
    
    commandBuffer.present(drawable)
    commandBuffer.commit()
}
```

### Display Link Synchronization

```swift
let displayLink = CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
CVDisplayLinkSetOutputCallback(displayLink, { 
    (displayLink, now, outputTime, flagsIn, flagsOut, userInfo) -> CVReturn in
    // Trigger render at display refresh rate
    return kCVReturnSuccess
}, &context)
```

---

## Validation Criteria

1. **HDR10 content** displays correctly on EDR-capable displays (Pro Display XDR, MacBook Pro)
2. **HLG content** displays correctly with proper EOTF conversion
3. **Tone mapping** produces good SDR results (natural highlights, no clipping)
4. **Color accuracy** within Delta E <2 (measured with X-Rite i1Display)
5. **No frame drops** during 4K HDR playback at 60fps
6. **GPU usage <20%** during 4K HDR on M1 (measured with Instruments)
7. **EDR metadata** correctly propagated to HDR displays
8. **ICC profiles** correctly applied for color-managed workflow

---

## Testing Approach

### Unit Tests

```swift
class HDRMetadataTests: XCTestCase {
    func testPQToLinear() { ... }
    func testHLGToLinear() { ... }
    func testACESCurve() { ... }
    func testICCDetection() { ... }
}

class MetalRendererTests: XCTestCase {
    func testSDRRendering() { ... }
    func testHDR10Rendering() { ... }
    func testHLGRendering() { ... }
    func testToneMappingAccuracy() { ... }
    func testDisplayCapabilities() { ... }
}
```

### Integration Tests

```swift
class HDRPlaybackIntegrationTests: XCTestCase {
    func testHDR10Playback() { ... }
    func testHLGPlayback() { ... }
    func testSDRToHDRTransition() { ... }
    func testDisplaySwitch() { ... }
}
```

---

## File Structure

```
TitanPlayer/TitanPlayer/Core/Renderers/
├── MetalRenderer.swift          # Main renderer class
├── ShaderTypes.swift            # Shared Swift/Metal types
├── HDRMetadata.swift            # HDR format detection
├── DisplayCapabilities.swift    # Display capability detection
├── ICCProfileManager.swift      # ICC profile handling
└── Shaders/
    ├── HDR.metal                # Compute shader (tone mapping)
    ├── Video.metal              # Fragment shader (color mgmt)
    └── Common.metal             # Shared shader utilities
```
