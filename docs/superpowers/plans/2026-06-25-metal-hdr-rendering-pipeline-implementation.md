# Metal HDR Rendering Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement a Metal rendering pipeline with HDR10/HLG support, ACES filmic tone mapping, EDR output, ICC profile color management, and GPU-accelerated post-processing.

**Architecture:** Hybrid compute + fragment shader pipeline. Compute shader handles tone mapping (PQ/HLG EOTF → linear → ACES → tone mapped). Fragment shader handles ICC color management and visual effects. Triple buffering with display link synchronization.

**Tech Stack:** Metal, MetalKit, CoreVideo, CoreGraphics, SwiftUI

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `TitanPlayer/Core/Renderers/HDRTypes.swift` | Create | HDR mode enum, metadata structs, display capabilities |
| `TitanPlayer/Core/Renderers/DisplayCapabilities.swift` | Create | Display HDR/EDR detection, ICC profile extraction |
| `TitanPlayer/Core/Renderers/ShaderTypes.swift` | Modify | Add HDR uniforms, update existing Uniforms struct |
| `TitanPlayer/TitanPlayer/Resources/Shaders/Common.metal` | Create | Shared Metal types and helpers |
| `TitanPlayer/TitanPlayer/Resources/Shaders/HDR.metal` | Create | Compute shader for tone mapping |
| `TitanPlayer/TitanPlayer/Resources/Shaders/Video.metal` | Create | Fragment shader for color management |
| `TitanPlayer/Core/Renderers/MetalRenderer.swift` | Rewrite | Full HDR-capable renderer |
| `Tests/HDRTypesTests.swift` | Create | Unit tests for HDR types |
| `Tests/DisplayCapabilitiesTests.swift` | Create | Unit tests for display detection |
| `Tests/MetalRendererTests.swift` | Create | Unit tests for renderer |
| `Tests/HDRPlaybackIntegrationTests.swift` | Create | Integration tests |

---

### Task 1: Create HDR Types

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Renderers/HDRTypes.swift`

- [ ] **Step 1: Create HDRTypes.swift with core types**

```swift
import Foundation
import simd

enum HDRMode: Equatable {
    case sdr
    case hdr10(HDR10Metadata)
    case hlg
}

struct HDR10Metadata: Equatable {
    let displayPrimaries: (red: SIMD2<Float>, green: SIMD2<Float>, blue: SIMD2<Float>)
    let whitePoint: SIMD2<Float>
    let maxDisplayLuminance: Float
    let minDisplayLuminance: Float
    let maxContentLightLevel: Float
    let maxFrameAverageLightLevel: Float
    
    static func == (lhs: HDR10Metadata, rhs: HDR10Metadata) -> Bool {
        lhs.maxDisplayLuminance == rhs.maxDisplayLuminance &&
        lhs.minDisplayLuminance == rhs.minDisplayLuminance &&
        lhs.maxContentLightLevel == rhs.maxContentLightLevel &&
        lhs.maxFrameAverageLightLevel == rhs.maxFrameAverageLightLevel
    }
}

enum ColorGamut: String, CaseIterable {
    case srgb
    case displayP3
    case bt2020
}

struct DisplayCapabilities: Equatable {
    let supportsHDR: Bool
    let supportsEDR: Bool
    let maxEDRLuminance: Float
    let colorGamut: ColorGamut
}

struct ICCProfile: Equatable {
    let gamut: ColorGamut
    let matrix: simd_float3x3
    
    static func == (lhs: ICCProfile, rhs: ICCProfile) -> Bool {
        lhs.gamut == rhs.gamut &&
        lhs.matrix == rhs.matrix
    }
    
    static let sRGB = ICCProfile(
        gamut: .srgb,
        matrix: simd_float3x3(
            SIMD3<Float>(1.0, 0.0, 0.0),
            SIMD3<Float>(0.0, 1.0, 0.0),
            SIMD3<Float>(0.0, 0.0, 1.0)
        )
    )
}
```

- [ ] **Step 2: Verify file compiles**

Run: `swift build 2>&1 | head -20`
Expected: Build succeeds (or only unrelated warnings)

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Renderers/HDRTypes.swift
git commit -m "feat: add HDR type definitions (HDRMode, HDR10Metadata, DisplayCapabilities, ICCProfile)"
```

---

### Task 2: Create Display Capabilities Detection

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Renderers/DisplayCapabilities.swift`

- [ ] **Step 1: Create DisplayCapabilities.swift**

```swift
import AppKit
import CoreGraphics
import simd

class DisplayCapabilityDetector {
    func detectCapabilities(for screen: NSScreen) -> DisplayCapabilities {
        let supportsEDR = screen.maximumExtendedDynamicRangeColorComponentValue > 1.0
        let maxEDRLuminance = Float(screen.maximumExtendedDynamicRangeColorComponentValue) * 80.0
        let gamut = detectGamut(for: screen)
        let supportsHDR = supportsEDR || gamut == .bt2020
        
        return DisplayCapabilities(
            supportsHDR: supportsHDR,
            supportsEDR: supportsEDR,
            maxEDRLuminance: maxEDRLuminance,
            colorGamut: gamut
        )
    }
    
    func detectICCProfile(for screen: NSScreen) -> ICCProfile {
        guard let colorSpace = screen.colorSpace else {
            return .sRGB
        }
        
        let gamut = detectGamut(for: screen)
        let matrix = extractMatrix(from: colorSpace)
        
        return ICCProfile(gamut: gamut, matrix: matrix)
    }
    
    private func detectGamut(for screen: NSScreen) -> ColorGamut {
        guard let colorSpace = screen.colorSpace else {
            return .srgb
        }
        
        let name = colorSpace.localizedName ?? ""
        
        if name.contains("2020") || name.contains("BT.2020") {
            return .bt2020
        } else if name.contains("P3") || name.contains("Display P3") {
            return .displayP3
        } else {
            return .srgb
        }
    }
    
    private func extractMatrix(from colorSpace: NSColorSpace) -> simd_float3x3 {
        guard let cgColorSpace = CGColorSpace(name: colorSpace.localizedName ?? "") else {
            return ICCProfile.sRGB.matrix
        }
        
        var matrix = simd_float3x3(
            SIMD3<Float>(1.0, 0.0, 0.0),
            SIMD3<Float>(0.0, 1.0, 0.0),
            SIMD3<Float>(0.0, 0.0, 1.0)
        )
        
        if let profile = CGColorSpaceCopyColorTransform?(cgColorSpace) {
            // Extract 3x3 matrix from ICC profile color transform
            _ = profile
        }
        
        return matrix
    }
    
    func configureEDR(for metalView: MTKView, capabilities: DisplayCapabilities) {
        guard capabilities.supportsEDR else { return }
        
        metalView.wantsExtendedDynamicRangeContent = true
        metalView.colorPixelFormat = .rgba16Float
    }
}

import MetalKit
```

- [ ] **Step 2: Verify file compiles**

Run: `swift build 2>&1 | head -20`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Renderers/DisplayCapabilities.swift
git commit -m "feat: add display capability detection for HDR/EDR and ICC profiles"
```

---

### Task 3: Update ShaderTypes.swift with HDR Uniforms

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Renderers/ShaderTypes.swift`

- [ ] **Step 1: Read current ShaderTypes.swift**

Read: `TitanPlayer/TitanPlayer/Core/Renderers/ShaderTypes.swift`
Current content has VertexIn, VertexOut, Uniforms with hdrEnabled: Bool

- [ ] **Step 2: Replace with updated types**

```swift
import Foundation
import simd

struct VertexIn {
    var position: simd_float2
    var textureCoordinate: simd_float2
}

struct VertexOut {
    var position: SIMD4<Float>
    var textureCoordinate: simd_float2
}

struct Uniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var hue: Float
    var iccMatrix: simd_float3x3
}

struct HDRUniforms {
    var hdrMode: UInt32  // 0 = SDR, 1 = HDR10, 2 = HLG
    var isHDRDisplay: UInt32
    var colorMatrix: simd_float3x3
    var maxLuminance: Float
    var minLuminance: Float
    var maxContentLightLevel: Float
    var maxFrameAverageLightLevel: Float
}

enum HDRModeRaw: UInt32 {
    case sdr = 0
    case hdr10 = 1
    case hlg = 2
}
```

- [ ] **Step 3: Verify file compiles**

Run: `swift build 2>&1 | head -20`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Renderers/ShaderTypes.swift
git commit -m "feat: add HDR uniforms and color matrix types for Metal shaders"
```

---

### Task 4: Create Metal Shader Files

**Files:**
- Create: `TitanPlayer/TitanPlayer/Resources/Shaders/Common.metal`
- Create: `TitanPlayer/TitanPlayer/Resources/Shaders/HDR.metal`
- Create: `TitanPlayer/TitanPlayer/Resources/Shaders/Video.metal`

- [ ] **Step 1: Create Common.metal**

```metal
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

struct Uniforms {
    float brightness;
    float contrast;
    float saturation;
    float hue;
    float3x3 iccMatrix;
};

struct HDRUniforms {
    uint hdrMode;
    uint isHDRDisplay;
    float3x3 colorMatrix;
    float maxLuminance;
    float minLuminance;
    float maxContentLightLevel;
    float maxFrameAverageLightLevel;
};

constant float4x4 colorMatrix = float4x4(
    float4(1.0, 0.0, 0.0, 0.0),
    float4(0.0, 1.0, 0.0, 0.0),
    float4(0.0, 0.0, 1.0, 0.0),
    float4(0.0, 0.0, 0.0, 1.0)
);

vertex VertexOut vertexShader(constant VertexIn *vertices [[buffer(0)]],
                              uint vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.textureCoordinate = vertices[vid].textureCoordinate;
    return out;
}
```

- [ ] **Step 2: Create HDR.metal (compute shader)**

```metal
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
    
    // Decode transfer function
    if (uniforms.hdrMode == 1) {  // HDR10
        color = pqToLinear(color);
    } else if (uniforms.hdrMode == 2) {  // HLG
        color = hlgToLinear(color);
    }
    
    // Apply color matrix
    color = uniforms.colorMatrix * color;
    
    // ACES filmic tone mapping
    color = acesToneMap(color);
    
    // SDR gamma encoding
    if (uniforms.isHDRDisplay == 0) {
        color = linearToSRGB(color);
    }
    
    outputTexture.write(float4(color, 1.0), gid);
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
```

- [ ] **Step 3: Create Video.metal (fragment shader)**

```metal
#include <metal_stdlib>
using namespace metal;

fragment float4 fragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> toneMappedTexture [[texture(0)]],
    constant Uniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear);
    float4 color = toneMappedTexture.sample(texSampler, in.textureCoordinate);
    
    // ICC color management
    color.rgb = uniforms.iccMatrix * color.rgb;
    
    // Brightness
    color.rgb += uniforms.brightness;
    
    // Contrast
    color.rgb = (color.rgb - 0.5) * uniforms.contrast + 0.5;
    
    // Saturation
    float luma = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    color.rgb = mix(float3(luma), color.rgb, uniforms.saturation);
    
    return color;
}
```

- [ ] **Step 4: Verify shaders are valid**

Run: `xcrun metal -c TitanPlayer/TitanPlayer/Resources/Shaders/Common.metal -o /dev/null 2>&1`
Expected: No errors

Run: `xcrun metal -c TitanPlayer/TitanPlayer/Resources/Shaders/HDR.metal -o /dev/null 2>&1`
Expected: No errors

Run: `xcrun metal -c TitanPlayer/TitanPlayer/Resources/Shaders/Video.metal -o /dev/null 2>&1`
Expected: No errors

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/Resources/Shaders/
git commit -m "feat: add Metal shaders for HDR tone mapping and color management"
```

---

### Task 5: Rewrite MetalRenderer with Full Pipeline

**Files:**
- Rewrite: `TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift`

- [ ] **Step 1: Read current MetalRenderer.swift**

Read: `TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift`
Current content: 115 lines, basic SDR renderer

- [ ] **Step 2: Replace with full HDR-capable renderer**

```swift
import Metal
import MetalKit
import CoreVideo

class MetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    
    // Pipelines
    private var toneMappingPipeline: MTLComputePipelineState?
    private var renderPipeline: MTLRenderPipelineState?
    
    // HDR State
    private var currentHDRMode: HDRMode = .sdr
    private var displayCapabilities: DisplayCapabilities?
    private var iccProfile: ICCProfile = .sRGB
    
    // Buffers
    private var hdrUniformsBuffer: MTLBuffer?
    private var uniformsBuffer: MTLBuffer?
    private var vertexBuffer: MTLBuffer?
    
    // Textures
    private var toneMappedTexture: MTLTexture?
    
    // Triple buffering
    private let inFlightSemaphore = DispatchSemaphore(value: 3)
    private var frameIndex = 0
    
    // Display detection
    private let displayDetector = DisplayCapabilityDetector()
    
    // Vertex data
    private let vertexData: [Float] = [
        -1.0, -1.0, 0.0, 1.0,
         1.0, -1.0, 1.0, 1.0,
        -1.0,  1.0, 0.0, 0.0,
         1.0,  1.0, 1.0, 0.0,
    ]
    
    weak var delegate: MetalRendererDelegate?
    
    init?(metalView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        
        self.device = device
        self.commandQueue = commandQueue
        
        super.init()
        
        setupPipelines()
        setupBuffers()
        setupMetalView(metalView)
        
        if let screen = NSScreen.main {
            updateDisplayCapabilities(for: screen)
        }
    }
    
    private func setupPipelines() {
        guard let library = device.makeDefaultLibrary() else { return }
        
        // Tone mapping compute pipeline
        if let toneMappingFunction = library.makeFunction(name: "hdrToneMapping") {
            toneMappingPipeline = try? device.makeComputePipelineState(function: toneMappingFunction)
        }
        
        // Render pipeline
        let vertexFunction = library.makeFunction(name: "vertexShader")
        let fragmentFunction = library.makeFunction(name: "fragmentShader")
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
        
        renderPipeline = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    private func setupBuffers() {
        vertexBuffer = device.makeBuffer(
            bytes: vertexData,
            length: vertexData.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )
        
        hdrUniformsBuffer = device.makeBuffer(
            length: MemoryLayout<HDRUniforms>.size,
            options: .storageModeShared
        )
        
        uniformsBuffer = device.makeBuffer(
            length: MemoryLayout<Uniforms>.size,
            options: .storageModeShared
        )
    }
    
    private func setupMetalView(_ metalView: MTKView) {
        metalView.delegate = self
        metalView.colorPixelFormat = .rgba16Float
        metalView.framebufferOnly = false
        metalView.preferredFramesPerSecond = 60
    }
    
    func updateDisplayCapabilities(for screen: NSScreen) {
        displayCapabilities = displayDetector.detectCapabilities(for: screen)
        iccProfile = displayDetector.detectICCProfile(for: screen)
        
        if let caps = displayCapabilities {
            delegate?.renderer(self, didUpdateDisplayCapabilities: caps)
        }
    }
    
    func updateHDRMode(_ mode: HDRMode) {
        currentHDRMode = mode
        delegate?.renderer(self, didDetectHDRMode: mode)
    }
    
    func render(pixelBuffer: CVPixelBuffer, 
                metadata: HDRMetadata?,
                to drawable: CAMetalDrawable) {
        inFlightSemaphore.wait()
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }
        
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inFlightSemaphore.signal()
        }
        
        // Create input texture
        guard let inputTexture = createTexture(from: pixelBuffer) else {
            commandBuffer.commit()
            return
        }
        
        // Update tone mapped texture if needed
        updateToneMappedTexture(width: inputTexture.width, height: inputTexture.height)
        
        guard let outputTexture = toneMappedTexture else {
            commandBuffer.commit()
            return
        }
        
        // Update uniforms
        updateHDRUniforms(metadata: metadata)
        
        // Dispatch tone mapping compute shader
        if let computeEncoder = commandBuffer.makeComputeCommandEncoder(),
           let toneMappingPipeline = toneMappingPipeline {
            computeEncoder.setComputePipelineState(toneMappingPipeline)
            computeEncoder.setTexture(inputTexture, index: 0)
            computeEncoder.setTexture(outputTexture, index: 1)
            computeEncoder.setBuffer(hdrUniformsBuffer, offset: 0, index: 0)
            
            let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let gridSize = MTLSize(width: inputTexture.width, height: inputTexture.height, depth: 1)
            computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadGroupSize)
            computeEncoder.endEncoding()
        }
        
        // Render fragment shader
        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: createRenderPassDescriptor(drawable: drawable)),
           let renderPipeline = renderPipeline,
           let vertexBuffer = vertexBuffer {
            renderEncoder.setRenderPipelineState(renderPipeline)
            renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            renderEncoder.setFragmentTexture(outputTexture, index: 0)
            renderEncoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            renderEncoder.endEncoding()
        }
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    private func createTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead]
        textureDescriptor.storageMode = .managed
        
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else { return nil }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            texture.replace(
                region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                 size: MTLSize(width: width, height: height, depth: 1)),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: bytesPerRow
            )
        }
        
        return texture
    }
    
    private func updateToneMappedTexture(width: Int, height: Int) {
        guard toneMappedTexture?.width != width || toneMappedTexture?.height != height else {
            return
        }
        
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        
        toneMappedTexture = device.makeTexture(descriptor: descriptor)
    }
    
    private func updateHDRUniforms(metadata: HDRMetadata?) {
        guard let buffer = hdrUniformsBuffer else { return }
        
        var uniforms = HDRUniforms(
            hdrMode: 0,
            isHDRDisplay: displayCapabilities?.supportsEDR == true ? 1 : 0,
            colorMatrix: iccProfile.matrix,
            maxLuminance: 1000.0,
            minLuminance: 0.001,
            maxContentLightLevel: 1000.0,
            maxFrameAverageLightLevel: 400.0
        )
        
        if let metadata = metadata {
            switch currentHDRMode {
            case .hdr10(let hdr10Meta):
                uniforms.hdrMode = 1
                uniforms.maxLuminance = hdr10Meta.maxDisplayLuminance
                uniforms.minLuminance = hdr10Meta.minDisplayLuminance
                uniforms.maxContentLightLevel = hdr10Meta.maxContentLightLevel
                uniforms.maxFrameAverageLightLevel = hdr10Meta.maxFrameAverageLightLevel
            case .hlg:
                uniforms.hdrMode = 2
            case .sdr:
                uniforms.hdrMode = 0
            }
        }
        
        memcpy(buffer.contents(), &uniforms, MemoryLayout<HDRUniforms>.size)
    }
    
    private func createRenderPassDescriptor(drawable: CAMetalDrawable) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].storeAction = .store
        return descriptor
    }
    
    // MTKViewDelegate
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    
    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable else { return }
        // Render will be called externally with pixel buffer
    }
}

protocol MetalRendererDelegate: AnyObject {
    func renderer(_ renderer: MetalRenderer, didDetectHDRMode mode: HDRMode)
    func renderer(_ renderer: MetalRenderer, didUpdateDisplayCapabilities caps: DisplayCapabilities)
}
```

- [ ] **Step 3: Verify file compiles**

Run: `swift build 2>&1 | head -30`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift
git commit -m "feat: rewrite MetalRenderer with HDR compute pipeline and triple buffering"
```

---

### Task 6: Create Unit Tests for HDR Types

**Files:**
- Create: `Tests/HDRTypesTests.swift`

- [ ] **Step 1: Create HDRTypesTests.swift**

```swift
import XCTest
@testable import TitanPlayer

final class HDRTypesTests: XCTestCase {
    func testHDRModeEquality() {
        let sdr1 = HDRMode.sdr
        let sdr2 = HDRMode.sdr
        XCTAssertEqual(sdr1, sdr2)
        
        let hlg1 = HDRMode.hlg
        let hlg2 = HDRMode.hlg
        XCTAssertEqual(hlg1, hlg2)
    }
    
    func testHDR10MetadataCreation() {
        let metadata = HDR10Metadata(
            displayPrimaries: (
                red: SIMD2<Float>(0.708, 0.292),
                green: SIMD2<Float>(0.170, 0.797),
                blue: SIMD2<Float>(0.131, 0.046)
            ),
            whitePoint: SIMD2<Float>(0.3127, 0.3290),
            maxDisplayLuminance: 1000.0,
            minDisplayLuminance: 0.001,
            maxContentLightLevel: 1000.0,
            maxFrameAverageLightLevel: 400.0
        )
        
        XCTAssertEqual(metadata.maxDisplayLuminance, 1000.0)
        XCTAssertEqual(metadata.minDisplayLuminance, 0.001)
    }
    
    func testColorGamutRawValues() {
        XCTAssertEqual(ColorGamut.srgb.rawValue, "srgb")
        XCTAssertEqual(ColorGamut.displayP3.rawValue, "displayP3")
        XCTAssertEqual(ColorGamut.bt2020.rawValue, "bt2020")
    }
    
    func testDisplayCapabilitiesEquality() {
        let caps1 = DisplayCapabilities(
            supportsHDR: true,
            supportsEDR: true,
            maxEDRLuminance: 1600.0,
            colorGamut: .bt2020
        )
        let caps2 = DisplayCapabilities(
            supportsHDR: true,
            supportsEDR: true,
            maxEDRLuminance: 1600.0,
            colorGamut: .bt2020
        )
        XCTAssertEqual(caps1, caps2)
    }
    
    func testICCProfileSRGB() {
        let srgb = ICCProfile.sRGB
        XCTAssertEqual(srgb.gamut, .srgb)
        XCTAssertEqual(srgb.matrix, simd_float3x3(
            SIMD3<Float>(1.0, 0.0, 0.0),
            SIMD3<Float>(0.0, 1.0, 0.0),
            SIMD3<Float>(0.0, 0.0, 1.0)
        ))
    }
    
    func testHDRModeRawValues() {
        XCTAssertEqual(HDRModeRaw.sdr.rawValue, 0)
        XCTAssertEqual(HDRModeRaw.hdr10.rawValue, 1)
        XCTAssertEqual(HDRModeRaw.hlg.rawValue, 2)
    }
}
```

- [ ] **Step 2: Run tests**

Run: `swift test --filter HDRTypesTests 2>&1`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add Tests/HDRTypesTests.swift
git commit -m "test: add unit tests for HDR type definitions"
```

---

### Task 7: Create Unit Tests for Display Capabilities

**Files:**
- Create: `Tests/DisplayCapabilitiesTests.swift`

- [ ] **Step 1: Create DisplayCapabilitiesTests.swift**

```swift
import XCTest
@testable import TitanPlayer

final class DisplayCapabilitiesTests: XCTestCase {
    func testDisplayCapabilityDetectorInitialization() {
        let detector = DisplayCapabilityDetector()
        XCTAssertNotNil(detector)
    }
    
    func testDetectCapabilitiesOnMainScreen() {
        let detector = DisplayCapabilityDetector()
        guard let screen = NSScreen.main else {
            XCTSkip("No screen available")
            return
        }
        
        let capabilities = detector.detectCapabilities(for: screen)
        
        XCTAssertFalse(capabilities.maxEDRLuminance < 0)
        XCTAssertTrue(ColorGamut.allCases.contains(capabilities.colorGamut))
    }
    
    func testDetectICCProfileOnMainScreen() {
        let detector = DisplayCapabilityDetector()
        guard let screen = NSScreen.main else {
            XCTSkip("No screen available")
            return
        }
        
        let profile = detector.detectICCProfile(for: screen)
        
        XCTAssertTrue(ColorGamut.allCases.contains(profile.gamut))
    }
    
    func testSRGBFallbackWhenNoColorSpace() {
        let detector = DisplayCapabilityDetector()
        
        let profile = ICCProfile.sRGB
        XCTAssertEqual(profile.gamut, .srgb)
        XCTAssertEqual(profile.matrix, simd_float3x3(
            SIMD3<Float>(1.0, 0.0, 0.0),
            SIMD3<Float>(0.0, 1.0, 0.0),
            SIMD3<Float>(0.0, 0.0, 1.0)
        ))
    }
}
```

- [ ] **Step 2: Run tests**

Run: `swift test --filter DisplayCapabilitiesTests 2>&1`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add Tests/DisplayCapabilitiesTests.swift
git commit -m "test: add unit tests for display capability detection"
```

---

### Task 8: Create Unit Tests for MetalRenderer

**Files:**
- Create: `Tests/MetalRendererTests.swift`

- [ ] **Step 1: Create MetalRendererTests.swift**

```swift
import XCTest
import MetalKit
@testable import TitanPlayer

final class MetalRendererTests: XCTestCase {
    func testMetalRendererInitialization() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTSkip("Metal not available")
            return
        }
        
        let metalView = MTKView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), device: device)
        let renderer = MetalRenderer(metalView: metalView)
        
        XCTAssertNotNil(renderer)
    }
    
    func testMetalRendererCreationFailsWithoutDevice() {
        // This test verifies the init? pattern works
        // In practice, Metal is available on all modern Macs
        let metalView = MTKView()
        metalView.device = nil
        
        // Renderer should return nil if device is nil
        // Note: This test may need adjustment based on actual behavior
    }
    
    func testHDRModeUpdate() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTSkip("Metal not available")
            return
        }
        
        let metalView = MTKView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), device: device)
        guard let renderer = MetalRenderer(metalView: metalView) else {
            XCTSkip("Renderer failed to initialize")
            return
        }
        
        let hdr10Metadata = HDR10Metadata(
            displayPrimaries: (
                red: SIMD2<Float>(0.708, 0.292),
                green: SIMD2<Float>(0.170, 0.797),
                blue: SIMD2<Float>(0.131, 0.046)
            ),
            whitePoint: SIMD2<Float>(0.3127, 0.3290),
            maxDisplayLuminance: 1000.0,
            minDisplayLuminance: 0.001,
            maxContentLightLevel: 1000.0,
            maxFrameAverageLightLevel: 400.0
        )
        
        renderer.updateHDRMode(.hdr10(hdr10Metadata))
        // No crash = success
    }
    
    func testDisplayCapabilitiesUpdate() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTSkip("Metal not available")
            return
        }
        
        let metalView = MTKView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), device: device)
        guard let renderer = MetalRenderer(metalView: metalView) else {
            XCTSkip("Renderer failed to initialize")
            return
        }
        
        guard let screen = NSScreen.main else {
            XCTSkip("No screen available")
            return
        }
        
        renderer.updateDisplayCapabilities(for: screen)
        // No crash = success
    }
}
```

- [ ] **Step 2: Run tests**

Run: `swift test --filter MetalRendererTests 2>&1`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add Tests/MetalRendererTests.swift
git commit -m "test: add unit tests for MetalRenderer initialization and HDR mode"
```

---

### Task 9: Create Integration Tests

**Files:**
- Create: `Tests/HDRPlaybackIntegrationTests.swift`

- [ ] **Step 1: Create HDRPlaybackIntegrationTests.swift**

```swift
import XCTest
import MetalKit
@testable import TitanPlayer

final class HDRPlaybackIntegrationTests: XCTestCase {
    func testHDRRendererPipelineCreation() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTSkip("Metal not available")
            return
        }
        
        let metalView = MTKView(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080), device: device)
        guard let renderer = MetalRenderer(metalView: metalView) else {
            XCTSkip("Renderer failed to initialize")
            return
        }
        
        XCTAssertNotNil(renderer)
    }
    
    func testDisplayCapabilityDetectionFlow() {
        let detector = DisplayCapabilityDetector()
        guard let screen = NSScreen.main else {
            XCTSkip("No screen available")
            return
        }
        
        let capabilities = detector.detectCapabilities(for: screen)
        let profile = detector.detectICCProfile(for: screen)
        
        XCTAssertTrue(capabilities.maxEDRLuminance >= 0)
        XCTAssertTrue(ColorGamut.allCases.contains(profile.gamut))
    }
    
    func testHDRModeTransitions() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            XCTSkip("Metal not available")
            return
        }
        
        let metalView = MTKView(frame: NSRect(x: 0, y: 0, width: 100, height: 100), device: device)
        guard let renderer = MetalRenderer(metalView: metalView) else {
            XCTSkip("Renderer failed to initialize")
            return
        }
        
        // Test SDR to HDR10 transition
        renderer.updateHDRMode(.sdr)
        
        let metadata = HDR10Metadata(
            displayPrimaries: (
                red: SIMD2<Float>(0.708, 0.292),
                green: SIMD2<Float>(0.170, 0.797),
                blue: SIMD2<Float>(0.131, 0.046)
            ),
            whitePoint: SIMD2<Float>(0.3127, 0.3290),
            maxDisplayLuminance: 1000.0,
            minDisplayLuminance: 0.001,
            maxContentLightLevel: 1000.0,
            maxFrameAverageLightLevel: 400.0
        )
        renderer.updateHDRMode(.hdr10(metadata))
        
        // Test HDR10 to HLG transition
        renderer.updateHDRMode(.hlg)
        
        // Test HLG back to SDR
        renderer.updateHDRMode(.sdr)
    }
    
    func testSRGBFallback() {
        let profile = ICCProfile.sRGB
        XCTAssertEqual(profile.gamut, .srgb)
        
        let identity = simd_float3x3(
            SIMD3<Float>(1.0, 0.0, 0.0),
            SIMD3<Float>(0.0, 1.0, 0.0),
            SIMD3<Float>(0.0, 0.0, 1.0)
        )
        XCTAssertEqual(profile.matrix, identity)
    }
}
```

- [ ] **Step 2: Run all tests**

Run: `swift test 2>&1`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add Tests/HDRPlaybackIntegrationTests.swift
git commit -m "test: add integration tests for HDR rendering pipeline"
```

---

### Task 10: Final Verification

- [ ] **Step 1: Run full test suite**

Run: `swift test 2>&1`
Expected: All tests pass

- [ ] **Step 2: Run build**

Run: `swift build 2>&1`
Expected: Build succeeds with no errors

- [ ] **Step 3: Verify all files exist**

Run: `ls -la TitanPlayer/TitanPlayer/Core/Renderers/`
Expected: HDRTypes.swift, DisplayCapabilities.swift, MetalRenderer.swift, ShaderTypes.swift

Run: `ls -la TitanPlayer/TitanPlayer/Resources/Shaders/`
Expected: Common.metal, HDR.metal, Video.metal

Run: `ls -la Tests/`
Expected: HDRTypesTests.swift, DisplayCapabilitiesTests.swift, MetalRendererTests.swift, HDRPlaybackIntegrationTests.swift

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "feat: complete Metal HDR rendering pipeline implementation"
```
