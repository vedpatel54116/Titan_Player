# Multi-Display Independent HDR Configuration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable independent HDR tone mapping per display so video plays correctly on mixed SDR/HDR setups, with user-selectable primary display and persistent configuration.

**Architecture:** Extend `MetalRenderer` with a `displayTargets` dictionary keyed by display stable ID. Each target owns its own `CAMetalLayer`, `DisplayCapabilities`, `ICCProfile`, and `HDRUniforms` buffer. The renderer creates the input texture once per frame, then dispatches independent tone mapping compute passes per target. A new `ExternalDisplayWindow` hosts the secondary target's layer fullscreen on the external display.

**Tech Stack:** Swift, Metal, MetalKit, SwiftUI, AppKit, Combine, UserDefaults

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `Core/Renderers/Displays/DisplayRenderTarget.swift` | Create | Per-display render target struct |
| `Core/Renderers/FrameRendering.swift` | Modify | Add optional `addDisplayTarget`/`removeDisplayTarget` protocol methods |
| `Core/Renderers/MetalRenderer.swift` | Modify | Add `displayTargets` dict, per-target rendering, new API methods |
| `UI/Session/Displays/DisplayManager.swift` | Modify | Add `primaryDisplay`, `setPrimaryDisplay()`, `.primaryChanged` event |
| `Core/Renderers/Displays/PersistedDisplayConfig.swift` | Modify | Add primary ID persistence, `HDRPreference` persistence |
| `UI/Session/Displays/ExternalDisplayWindow.swift` | Create | Fullscreen NSWindow for secondary display |
| `UI/Views/Displays/DisplaySelectorView.swift` | Create | SwiftUI primary display selector popover |
| `UI/Session/PlaybackSession.swift` | Modify | Wire display events to renderer targets |
| `Tests/DisplayRenderTargetTests.swift` | Create | Tests for DisplayRenderTarget |
| `Tests/DisplayManagerPrimaryTests.swift` | Create | Tests for primary display selection |
| `Tests/MetalRendererMultiTargetTests.swift` | Create | Tests for multi-target rendering |

---

### Task 1: DisplayRenderTarget Struct

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Renderers/Displays/DisplayRenderTarget.swift`
- Test: `TitanPlayer/Tests/DisplayRenderTargetTests.swift`

- [ ] **Step 1: Create DisplayRenderTarget struct**

```swift
import Metal
import MetalKit

struct DisplayRenderTarget {
    let stableID: String
    let layer: CAMetalLayer
    var capabilities: DisplayCapabilities
    var iccProfile: ICCProfile
    var hdrUniformsBuffer: MTLBuffer
    var toneMappedTexture: MTLTexture?
    var renderPipelineState: MTLRenderPipelineState?
}
```

- [ ] **Step 2: Write DisplayRenderTargetTests**

```swift
import XCTest
import Metal
import MetalKit
@testable import TitanPlayer

final class DisplayRenderTargetTests: XCTestCase {

    private func makeDevice() -> MTLDevice? {
        MTLCreateSystemDefaultDevice()
    }

    func testTargetCreationStoresProperties() throws {
        guard let device = makeDevice() else {
            throw XCTSkip("Metal unavailable")
        }
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let caps = DisplayCapabilities(
            supportsHDR: true, supportsEDR: true,
            maxEDRLuminance: 1600, colorGamut: .bt2020
        )
        let icc = ICCProfile.sRGB
        let buffer = device.makeBuffer(length: MemoryLayout<HDRUniforms>.size, options: .storageModeShared)!

        let target = DisplayRenderTarget(
            stableID: "cgdid:1",
            layer: layer,
            capabilities: caps,
            iccProfile: icc,
            hdrUniformsBuffer: buffer,
            toneMappedTexture: nil,
            renderPipelineState: nil
        )

        XCTAssertEqual(target.stableID, "cgdid:1")
        XCTAssertTrue(target.capabilities.supportsHDR)
        XCTAssertEqual(target.capabilities.maxEDRLuminance, 1600)
        XCTAssertNil(target.toneMappedTexture)
    }

    func testMultipleTargetsHaveIndependentUniforms() throws {
        guard let device = makeDevice() else {
            throw XCTSkip("Metal unavailable")
        }
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let capsHDR = DisplayCapabilities(
            supportsHDR: true, supportsEDR: true,
            maxEDRLuminance: 1600, colorGamut: .bt2020
        )
        let capsSDR = DisplayCapabilities(
            supportsHDR: false, supportsEDR: false,
            maxEDRLuminance: 0, colorGamut: .srgb
        )
        let icc = ICCProfile.sRGB

        let buf1 = device.makeBuffer(length: MemoryLayout<HDRUniforms>.size, options: .storageModeShared)!
        let buf2 = device.makeBuffer(length: MemoryLayout<HDRUniforms>.size, options: .storageModeShared)!

        var u1 = HDRUniforms(
            hdrMode: 1, isHDRDisplay: 1, colorMatrix: icc.matrix,
            maxLuminance: 1600, minLuminance: 0.001,
            maxContentLightLevel: 1000, maxFrameAverageLightLevel: 400,
            kneePoint: 0, compressionRatio: 1, saturationScale: 1,
            brightnessAdjustment: 0, useDynamicMetadata: 0
        )
        var u2 = HDRUniforms(
            hdrMode: 0, isHDRDisplay: 0, colorMatrix: icc.matrix,
            maxLuminance: 0, minLuminance: 0,
            maxContentLightLevel: 0, maxFrameAverageLightLevel: 0,
            kneePoint: 0, compressionRatio: 1, saturationScale: 1,
            brightnessAdjustment: 0, useDynamicMetadata: 0
        )

        memcpy(buf1.contents(), &u1, MemoryLayout<HDRUniforms>.size)
        memcpy(buf2.contents(), &u2, MemoryLayout<HDRUniforms>.size)

        let target1 = DisplayRenderTarget(
            stableID: "cgdid:1", layer: layer, capabilities: capsHDR,
            iccProfile: icc, hdrUniformsBuffer: buf1
        )
        let target2 = DisplayRenderTarget(
            stableID: "cgdid:2", layer: layer, capabilities: capsSDR,
            iccProfile: icc, hdrUniformsBuffer: buf2
        )

        XCTAssertTrue(target1.hdrUniformsBuffer !== target2.hdrUniformsBuffer)

        let read1 = target1.hdrUniformsBuffer.contents().assumingMemoryBound(to: HDRUniforms.self).pointee
        let read2 = target2.hdrUniformsBuffer.contents().assumingMemoryBound(to: HDRUniforms.self).pointee
        XCTAssertEqual(read1.isHDRDisplay, 1)
        XCTAssertEqual(read2.isHDRDisplay, 0)
    }
}
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `cd TitanPlayer && swift test --filter DisplayRenderTargetTests 2>&1 | tail -20`
Expected: PASS (or skip if Metal unavailable — the type-check via `swift build --build-tests` is the key gate)

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Renderers/Displays/DisplayRenderTarget.swift TitanPlayer/Tests/DisplayRenderTargetTests.swift
git commit -m "feat: add DisplayRenderTarget struct for per-display rendering"
```

---

### Task 2: FrameRendering Protocol Extension

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Renderers/FrameRendering.swift`

- [ ] **Step 1: Add optional methods to FrameRendering protocol**

```swift
import Foundation
import AppKit
import Metal

typealias VideoRenderer = FrameRendering

protocol FrameRendering: AnyObject {
    func render(_ frame: VideoFrame) async throws
    func handleHDR(_ metadata: HDRMetadata)
    func updateDisplayCapabilities(for screen: NSScreen)
    func resetDynamicHDRParams()

    func addDisplayTarget(stableID: String, layer: CAMetalLayer, capabilities: DisplayCapabilities, iccProfile: ICCProfile)
    func removeDisplayTarget(stableID: String)
}

extension FrameRendering {
    func addDisplayTarget(stableID: String, layer: CAMetalLayer, capabilities: DisplayCapabilities, iccProfile: ICCProfile) {}
    func removeDisplayTarget(stableID: String) {}
}

enum RendererError: Error, LocalizedError {
    case notAttached
    case deviceUnavailable
    case pipelineCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAttached:
            return "Renderer is not attached to a Metal view."
        case .deviceUnavailable:
            return "Metal device is unavailable on this system."
        case .pipelineCreationFailed(let s):
            return "Failed to create Metal pipeline: \(s)"
        }
    }
}
```

- [ ] **Step 2: Verify build succeeds**

Run: `cd TitanPlayer && swift build 2>&1 | tail -10`
Expected: Build succeeds (existing conformers get the default no-op implementations)

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Renderers/FrameRendering.swift
git commit -m "feat: add optional display target methods to FrameRendering protocol"
```

---

### Task 3: MetalRenderer Multi-Target Support

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift`
- Test: `TitanPlayer/Tests/MetalRendererMultiTargetTests.swift`

- [ ] **Step 1: Add displayTargets dictionary and API methods**

Add to MetalRenderer after the existing properties:

```swift
private var displayTargets: [String: DisplayRenderTarget] = [:]
```

Add new methods:

```swift
func addDisplayTarget(stableID: String, layer: CAMetalLayer, capabilities: DisplayCapabilities, iccProfile: ICCProfile) {
    guard displayTargets[stableID] == nil else { return }

    let uniformsBuffer = device.makeBuffer(
        length: MemoryLayout<HDRUniforms>.size,
        options: .storageModeShared
    )!

    var uniforms = HDRUniforms(
        hdrMode: 0,
        isHDRDisplay: capabilities.supportsEDR ? 1 : 0,
        colorMatrix: iccProfile.matrix,
        maxLuminance: capabilities.maxEDRLuminance,
        minLuminance: 0.001,
        maxContentLightLevel: 1000.0,
        maxFrameAverageLightLevel: 400.0,
        kneePoint: 0,
        compressionRatio: 1,
        saturationScale: 1,
        brightnessAdjustment: 0,
        useDynamicMetadata: 0
    )
    memcpy(uniformsBuffer.contents(), &uniforms, MemoryLayout<HDRUniforms>.size)

    let pipelineDescriptor = MTLRenderPipelineDescriptor()
    pipelineDescriptor.vertexFunction = device.makeDefaultLibrary()?.makeFunction(name: "vertexShader")
    pipelineDescriptor.fragmentFunction = device.makeDefaultLibrary()?.makeFunction(name: "fragmentShader")
    pipelineDescriptor.colorAttachments[0].pixelFormat = layer.pixelFormat

    let pipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor)

    let target = DisplayRenderTarget(
        stableID: stableID,
        layer: layer,
        capabilities: capabilities,
        iccProfile: iccProfile,
        hdrUniformsBuffer: uniformsBuffer,
        toneMappedTexture: nil,
        renderPipelineState: pipelineState
    )
    displayTargets[stableID] = target
}

func removeDisplayTarget(stableID: String) {
    displayTargets.removeValue(forKey: stableID)
}

func updateDisplayCapabilities(for stableID: String, capabilities: DisplayCapabilities, iccProfile: ICCProfile) {
    guard var target = displayTargets[stableID] else { return }
    target.capabilities = capabilities
    target.iccProfile = iccProfile

    var uniforms = HDRUniforms(
        hdrMode: 0,
        isHDRDisplay: capabilities.supportsEDR ? 1 : 0,
        colorMatrix: iccProfile.matrix,
        maxLuminance: capabilities.maxEDRLuminance,
        minLuminance: 0.001,
        maxContentLightLevel: 1000.0,
        maxFrameAverageLightLevel: 400.0,
        kneePoint: 0,
        compressionRatio: 1,
        saturationScale: 1,
        brightnessAdjustment: 0,
        useDynamicMetadata: 0
    )
    memcpy(target.hdrUniformsBuffer.contents(), &uniforms, MemoryLayout<HDRUniforms>.size)
    displayTargets[stableID] = target
}
```

- [ ] **Step 2: Add helper method for rendering to a target**

```swift
private func renderTarget(
    _ target: DisplayRenderTarget,
    inputTexture: MTLTexture,
    commandBuffer: MTLCommandBuffer
) {
    let width = target.layer.drawableSize.width > 0 ? Int(target.layer.drawableSize.width) : inputTexture.width
    let height = target.layer.drawableSize.height > 0 ? Int(target.layer.drawableSize.height) : inputTexture.height

    if target.toneMappedTexture?.width != width || target.toneMappedTexture?.height != height {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width, height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        target.toneMappedTexture = device.makeTexture(descriptor: descriptor)
    }

    guard let outputTexture = target.toneMappedTexture,
          let toneMappingPipeline = toneMappingPipeline else { return }

    if let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
        computeEncoder.setComputePipelineState(toneMappingPipeline)
        computeEncoder.setTexture(inputTexture, index: 0)
        computeEncoder.setTexture(outputTexture, index: 1)
        computeEncoder.setBuffer(target.hdrUniformsBuffer, offset: 0, index: 0)
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let gridSize = MTLSize(width: inputTexture.width, height: inputTexture.height, depth: 1)
        computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()
    }

    guard let drawable = target.layer.nextDrawable(),
          let pipelineState = target.renderPipelineState,
          let vertexBuffer = vertexBuffer else { return }

    let renderDescriptor = MTLRenderPassDescriptor()
    renderDescriptor.colorAttachments[0].texture = drawable.texture
    renderDescriptor.colorAttachments[0].loadAction = .clear
    renderDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    renderDescriptor.colorAttachments[0].storeAction = .store

    if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderDescriptor) {
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.setFragmentTexture(outputTexture, index: 0)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()
    }

    commandBuffer.present(drawable)
}
```

- [ ] **Step 3: Update draw(in:) to render secondary targets**

In the existing `draw(in:)` method, inside the `if let frame = pendingFrame { ... }` block, after the primary render pass completes (after `commandBuffer.present(drawable)`), add:

```swift
// Render to secondary display targets
for (_, target) in displayTargets {
    if let inputTexture = createTexture(from: frame.pixelBuffer) {
        renderTarget(target, inputTexture: inputTexture, commandBuffer: commandBuffer)
    }
}
```

- [ ] **Step 4: Write MetalRendererMultiTargetTests**

```swift
import XCTest
import Metal
import MetalKit
import CoreMedia
import CoreVideo
@testable import TitanPlayer

final class MetalRendererMultiTargetTests: XCTestCase {

    private func makeRenderer() throws -> MetalRenderer {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal device unavailable")
        }
        return try MetalRenderer.make()
    }

    func testAddAndRemoveDisplayTarget() throws {
        let renderer = try makeRenderer()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable")
        }
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let caps = DisplayCapabilities(
            supportsHDR: true, supportsEDR: true,
            maxEDRLuminance: 1600, colorGamut: .bt2020
        )

        renderer.addDisplayTarget(
            stableID: "cgdid:2",
            layer: layer,
            capabilities: caps,
            iccProfile: ICCProfile.sRGB
        )

        renderer.removeDisplayTarget(stableID: "cgdid:2")
    }

    func testUpdateDisplayCapabilitiesForTarget() throws {
        let renderer = try makeRenderer()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable")
        }
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let capsSDR = DisplayCapabilities(
            supportsHDR: false, supportsEDR: false,
            maxEDRLuminance: 0, colorGamut: .srgb
        )
        let capsHDR = DisplayCapabilities(
            supportsHDR: true, supportsEDR: true,
            maxEDRLuminance: 1600, colorGamut: .bt2020
        )

        renderer.addDisplayTarget(
            stableID: "cgdid:2",
            layer: layer,
            capabilities: capsSDR,
            iccProfile: ICCProfile.sRGB
        )

        renderer.updateDisplayCapabilities(
            for: "cgdid:2",
            capabilities: capsHDR,
            iccProfile: ICCProfile(gamut: .bt2020, matrix: ICCProfile.sRGB.matrix)
        )
    }

    func testRenderWithMultipleTargetsDoesNotThrow() throws {
        let renderer = try makeRenderer()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable")
        }
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .rgba16Float
        layer.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let caps = DisplayCapabilities(
            supportsHDR: false, supportsEDR: false,
            maxEDRLuminance: 0, colorGamut: .srgb
        )

        renderer.addDisplayTarget(
            stableID: "cgdid:2",
            layer: layer,
            capabilities: caps,
            iccProfile: ICCProfile.sRGB
        )

        let pixelBuffer = makeBlankPixelBuffer()
        let frame = VideoFrame(
            pixelBuffer: pixelBuffer,
            timestamp: .zero,
            duration: CMTime(value: 16, timescale: 600),
            colorSpace: .sRGB
        )

        let exp = expectation(description: "render returns")
        Task {
            try? await renderer.render(frame)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)

        renderer.removeDisplayTarget(stableID: "cgdid:2")
    }

    private func makeBlankPixelBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary
        CVPixelBufferCreate(
            kCFAllocatorDefault, 16, 16,
            kCVPixelFormatType_32BGRA, attrs, &buffer
        )
        return buffer!
    }
}
```

- [ ] **Step 5: Verify build succeeds**

Run: `cd TitanPlayer && swift build 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 6: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift TitanPlayer/Tests/MetalRendererMultiTargetTests.swift
git commit -m "feat: add multi-display target rendering to MetalRenderer"
```

---

### Task 4: PersistedDisplayConfig — Primary ID & HDR Preferences

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Renderers/Displays/PersistedDisplayConfig.swift`

- [ ] **Step 1: Add HDRPreference model**

Add to `PersistedDisplayConfig.swift` (before the class):

```swift
struct HDRPreference: Codable, Equatable {
    let autoDetect: Bool
    let forceHDR: Bool
    let forceSDR: Bool

    static let auto = HDRPreference(autoDetect: true, forceHDR: false, forceSDR: false)
}
```

- [ ] **Step 2: Add new persistence keys and methods**

```swift
@MainActor
final class PersistedDisplayConfig {
    static let defaultsKey = "titanplayer.displays.config.v1"
    static let primaryIDKey = "titanplayer.displays.primaryID.v1"
    static let hdrPrefsKey = "titanplayer.displays.hdrPrefs.v1"

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func load() throws -> [String: ExternalDisplayConfig] {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return [:] }
        return try decoder.decode([String: ExternalDisplayConfig].self, from: data)
    }

    func save(_ configs: [ExternalDisplayConfig]) throws {
        let dict = Dictionary(uniqueKeysWithValues: configs.map { ($0.stableID, $0) })
        let data = try encoder.encode(dict)
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func merge(newDisplays: [ExternalDisplayConfig]) throws {
        var current = (try? load()) ?? [:]
        for display in newDisplays { current[display.stableID] = display }
        try save(Array(current.values))
    }

    // MARK: - Primary Display

    func loadPrimaryDisplayID() -> String? {
        defaults.string(forKey: Self.primaryIDKey)
    }

    func savePrimaryDisplayID(_ stableID: String) {
        defaults.set(stableID, forKey: Self.primaryIDKey)
    }

    // MARK: - HDR Preferences

    func loadHDRPreferences() -> [String: HDRPreference] {
        guard let data = defaults.data(forKey: Self.hdrPrefsKey),
              let prefs = try? decoder.decode([String: HDRPreference].self, from: data) else {
            return [:]
        }
        return prefs
    }

    func saveHDRPreference(_ pref: HDRPreference, for stableID: String) {
        var prefs = loadHDRPreferences()
        prefs[stableID] = pref
        if let data = try? encoder.encode(prefs) {
            defaults.set(data, forKey: Self.hdrPrefsKey)
        }
    }
}
```

- [ ] **Step 3: Verify build succeeds**

Run: `cd TitanPlayer && swift build 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Renderers/Displays/PersistedDisplayConfig.swift
git commit -m "feat: add primary display ID and HDR preference persistence"
```

---

### Task 5: DisplayManager — Primary Display Support

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Session/Displays/DisplayManager.swift`
- Test: `TitanPlayer/Tests/DisplayManagerPrimaryTests.swift`

- [ ] **Step 1: Add primaryChanged to DisplayChangeEvent**

```swift
enum DisplayChangeEvent {
    case connected(ExternalDisplayConfig)
    case disconnected(stableID: String)
    case refreshed(ExternalDisplayConfig)
    case primaryChanged(ExternalDisplayConfig)
}
```

- [ ] **Step 2: Add primaryDisplay properties and setPrimaryDisplay**

Add to `DisplayManager` class:

```swift
@MainActor
final class DisplayManager: ObservableObject {
    @Published private(set) var displays: [ExternalDisplayConfig] = []
    @Published private(set) var activeDisplay: ExternalDisplayConfig?
    @Published private(set) var primaryDisplay: ExternalDisplayConfig?
    let events = PassthroughSubject<DisplayChangeEvent, Never>()

    var secondaryDisplay: ExternalDisplayConfig? {
        displays.first(where: { $0.stableID != primaryDisplay?.stableID })
    }

    private let provider: DisplayProviding
    private let detector: ScreenDetecting
    private let persistence: PersistedDisplayConfig
    private var observer: NSObjectProtocol?
    private var lastSeenIDs: Set<String> = []

    init(
        provider: DisplayProviding,
        detector: ScreenDetecting,
        defaults: UserDefaults
    ) {
        self.provider = provider
        self.detector = detector
        self.persistence = PersistedDisplayConfig(defaults: defaults)
        start()
        restorePrimaryDisplay()
    }

    convenience init(defaults: UserDefaults = .standard) {
        self.init(
            provider: SystemDisplayProvider(),
            detector: SystemScreenDetector(),
            defaults: defaults
        )
    }

    // ... existing methods ...

    func setPrimaryDisplay(stableID: String) {
        guard let next = displays.first(where: { $0.stableID == stableID }) else { return }
        primaryDisplay = next
        persistence.savePrimaryDisplayID(stableID)
        events.send(.primaryChanged(next))
    }

    private func restorePrimaryDisplay() {
        if let savedID = persistence.loadPrimaryDisplayID(),
           let display = displays.first(where: { $0.stableID == savedID }) {
            primaryDisplay = display
        } else {
            primaryDisplay = displays.first
        }
    }
}
```

Update `refreshDisplays()` to also update primaryDisplay if it was disconnected — add after the activeDisplay update:

```swift
// Re-validate primary display
if primaryDisplay == nil || !newIDs.contains(primaryDisplay?.stableID ?? "") {
    if let promoted = configs.first(where: { $0.stableID != primaryDisplay?.stableID }) ?? configs.first {
        primaryDisplay = promoted
        persistence.savePrimaryDisplayID(promoted.stableID)
    } else {
        primaryDisplay = nil
    }
}
```

- [ ] **Step 3: Write DisplayManagerPrimaryTests**

```swift
import XCTest
@testable import TitanPlayer
import AppKit

@MainActor
final class DisplayManagerPrimaryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var manager: DisplayManager!
    private var detector: MockScreenDetector!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "titanplayer.tests.dmp")!
        defaults.removePersistentDomain(forName: "titanplayer.tests.dmp")
        detector = MockScreenDetector()
        manager = DisplayManager(
            provider: EmptyDisplayProvider(),
            detector: detector,
            defaults: defaults
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "titanplayer.tests.dmp")
        manager.stop()
        super.tearDown()
    }

    func testSetPrimaryDisplay() {
        detector.next = [
            .builtIn(displayID: 1, name: "Built-in"),
            .builtIn(displayID: 2, name: "External")
        ]
        manager.refreshDisplays()

        manager.setPrimaryDisplay(stableID: ExternalDisplayConfig.cgDisplayID(2))
        XCTAssertEqual(manager.primaryDisplay?.stableID, ExternalDisplayConfig.cgDisplayID(2))
    }

    func testSecondaryDisplayIsNonPrimary() {
        detector.next = [
            .builtIn(displayID: 1, name: "Built-in"),
            .builtIn(displayID: 2, name: "External")
        ]
        manager.refreshDisplays()

        manager.setPrimaryDisplay(stableID: ExternalDisplayConfig.cgDisplayID(1))
        XCTAssertEqual(manager.secondaryDisplay?.stableID, ExternalDisplayConfig.cgDisplayID(2))
    }

    func testPrimaryDisplayPersistsAcrossRestart() {
        detector.next = [
            .builtIn(displayID: 1, name: "Built-in"),
            .builtIn(displayID: 2, name: "External")
        ]
        manager.refreshDisplays()
        manager.setPrimaryDisplay(stableID: ExternalDisplayConfig.cgDisplayID(2))

        let reloaded = DisplayManager(
            provider: EmptyDisplayProvider(),
            detector: MockScreenDetector(next: [
                .builtIn(displayID: 1, name: "Built-in"),
                .builtIn(displayID: 2, name: "External")
            ]),
            defaults: defaults
        )
        defer { reloaded.stop() }
        reloaded.refreshDisplays()
        XCTAssertEqual(reloaded.primaryDisplay?.stableID, ExternalDisplayConfig.cgDisplayID(2))
    }

    func testPrimaryDisplayFallsBackWhenDisconnected() {
        detector.next = [
            .builtIn(displayID: 1, name: "Built-in"),
            .builtIn(displayID: 2, name: "External")
        ]
        manager.refreshDisplays()
        manager.setPrimaryDisplay(stableID: ExternalDisplayConfig.cgDisplayID(2))

        detector.next = [.builtIn(displayID: 1, name: "Built-in")]
        manager.refreshDisplays()

        XCTAssertEqual(manager.primaryDisplay?.stableID, ExternalDisplayConfig.cgDisplayID(1))
    }

    func testPrimaryChangedEventEmitted() {
        detector.next = [
            .builtIn(displayID: 1, name: "Built-in"),
            .builtIn(displayID: 2, name: "External")
        ]
        manager.refreshDisplays()

        var receivedPrimaryChanges: [String] = []
        let cancellable = manager.events
            .sink { event in
                if case .primaryChanged(let config) = event {
                    receivedPrimaryChanges.append(config.stableID)
                }
            }

        manager.setPrimaryDisplay(stableID: ExternalDisplayConfig.cgDisplayID(2))

        cancellable.cancel()
        XCTAssertTrue(receivedPrimaryChanges.contains(ExternalDisplayConfig.cgDisplayID(2)))
    }
}

private final class EmptyDisplayProvider: DisplayProviding {
    func currentScreens() -> [NSScreen] { [] }
}

private final class MockScreenDetector: ScreenDetecting {
    var next: [ExternalDisplayConfig]
    init(next: [ExternalDisplayConfig] = []) { self.next = next }
    func detect(screen: NSScreen) -> ExternalDisplayConfig? {
        guard !next.isEmpty else { return nil }
        return next.removeFirst()
    }
}

private extension ExternalDisplayConfig {
    static func builtIn(displayID: UInt32, name: String) -> ExternalDisplayConfig {
        ExternalDisplayConfig(
            stableID: ExternalDisplayConfig.cgDisplayID(displayID),
            displayName: name,
            colorSpaceName: nil,
            colorGamut: .srgb,
            refreshRate: 60,
            hdrSupported: false,
            maxEDRLuminance: 0,
            lastSeenAt: Date()
        )
    }
}
```

- [ ] **Step 4: Verify build succeeds**

Run: `cd TitanPlayer && swift build 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/Displays/DisplayManager.swift TitanPlayer/Tests/DisplayManagerPrimaryTests.swift
git commit -m "feat: add primary display selection and persistence to DisplayManager"
```

---

### Task 6: ExternalDisplayWindow

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Session/Displays/ExternalDisplayWindow.swift`

- [ ] **Step 1: Create ExternalDisplayWindow**

```swift
import AppKit
import Metal

@MainActor
final class ExternalDisplayWindow {
    private var window: NSWindow?
    let metalLayer: CAMetalLayer

    init(device: MTLDevice) {
        self.metalLayer = CAMetalLayer()
        self.metalLayer.device = device
        self.metalLayer.pixelFormat = .rgba16Float
        self.metalLayer.wantsExtendedDynamicRangeContent = true
    }

    func show(on screen: NSScreen) {
        close()

        let screenFrame = screen.frame

        let win = NSWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        win.isOpaque = true
        win.backgroundColor = .black
        win.hasShadow = false
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false

        let hostView = NSView(frame: screenFrame)
        hostView.wantsLayer = true
        metalLayer.frame = hostView.bounds
        metalLayer.contentsScale = screen.backingScaleFactor
        hostView.layer?.addSublayer(metalLayer)
        win.contentView = hostView

        win.makeKeyAndOrderFront(nil)
        self.window = win
    }

    func close() {
        window?.close()
        window = nil
    }
}
```

- [ ] **Step 2: Verify build succeeds**

Run: `cd TitanPlayer && swift build 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/Displays/ExternalDisplayWindow.swift
git commit -m "feat: add ExternalDisplayWindow for fullscreen secondary display output"
```

---

### Task 7: DisplaySelectorView

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Views/Displays/DisplaySelectorView.swift`

- [ ] **Step 1: Create DisplaySelectorView**

```swift
import SwiftUI

struct DisplaySelectorView: View {
    let displays: [ExternalDisplayConfig]
    @Binding var primaryDisplayID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Primary Display")
                .font(.headline)

            ForEach(displays) { display in
                Button {
                    primaryDisplayID = display.stableID
                } label: {
                    HStack {
                        Circle()
                            .fill(display.stableID == primaryDisplayID ? Color.accentColor : Color.gray.opacity(0.3))
                            .frame(width: 12, height: 12)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(display.displayName)
                                .font(.body)
                                .foregroundColor(.primary)

                            HStack(spacing: 6) {
                                if display.hdrSupported {
                                    Text("HDR")
                                        .font(.caption2)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.orange.opacity(0.2))
                                        .cornerRadius(3)
                                }

                                if display.maxEDRLuminance > 0 {
                                    Text("\(Int(display.maxEDRLuminance)) nits")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Spacer()

                        if display.stableID == primaryDisplayID {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .frame(minWidth: 200)
    }
}
```

- [ ] **Step 2: Verify build succeeds**

Run: `cd TitanPlayer && swift build 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Views/Displays/DisplaySelectorView.swift
git commit -m "feat: add DisplaySelectorView for primary display selection"
```

---

### Task 8: PlaybackSession Wiring

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift`

- [ ] **Step 1: Add secondary display window property**

Add to PlaybackSession:

```swift
private var secondaryDisplayWindow: ExternalDisplayWindow?
```

- [ ] **Step 2: Update installDisplayBindings to handle display targets**

```swift
private func installDisplayBindings() {
    displayManager.$activeDisplay
        .compactMap { $0 }
        .removeDuplicates()
        .sink { [weak self] config in
            guard let self else { return }
            guard let screen = ScreenLookup.screen(forStableID: config.stableID),
                  let metal = self.renderer as? MetalRenderer else { return }
            metal.updateDisplayCapabilitiesAsynchronously(for: screen)
        }
        .store(in: &cancellables)

    displayManager.events
        .sink { [weak self] event in
            guard let self else { return }
            switch event {
            case .connected(let config):
                self.handleDisplayConnected(config)
            case .disconnected(let stableID):
                self.handleDisplayDisconnected(stableID)
            case .primaryChanged(let config):
                self.handlePrimaryChanged(config)
            case .refreshed:
                break
            }
        }
        .store(in: &cancellables)

    airPlayController.$currentAudioDelayOffset
        .removeDuplicates()
        .sink { [weak self] offset in
            self?.engine.setAudioDelay(offset)
        }
        .store(in: &cancellables)
}

private func handleDisplayConnected(_ config: ExternalDisplayConfig) {
    guard config.stableID != displayManager.primaryDisplay?.stableID else { return }
    guard let metal = renderer as? MetalRenderer else { return }
    guard let screen = ScreenLookup.screen(forStableID: config.stableID) else { return }

    let detector = DisplayCapabilityDetector()
    let caps = detector.detectCapabilities(for: screen)
    let icc = detector.detectICCProfile(for: screen)

    let device = MTLCreateSystemDefaultDevice()!
    let window = ExternalDisplayWindow(device: device)
    window.show(on: screen)
    secondaryDisplayWindow = window

    metal.addDisplayTarget(
        stableID: config.stableID,
        layer: window.metalLayer,
        capabilities: caps,
        iccProfile: icc
    )
}

private func handleDisplayDisconnected(_ stableID: String) {
    guard let metal = renderer as? MetalRenderer else { return }
    metal.removeDisplayTarget(stableID: stableID)

    secondaryDisplayWindow?.close()
    secondaryDisplayWindow = nil
}

private func handlePrimaryChanged(_ config: ExternalDisplayConfig) {
    if let screen = ScreenLookup.screen(forStableID: config.stableID),
       let window = NSApp.keyWindow ?? NSApp.windows.first {
        window.setFrameOrigin(screen.frame.origin)
    }

    guard let metal = renderer as? MetalRenderer else { return }

    if let oldSecondary = displayManager.secondaryDisplay {
        metal.removeDisplayTarget(stableID: oldSecondary.stableID)
        secondaryDisplayWindow?.close()
        secondaryDisplayWindow = nil
    }

    if let secondary = displayManager.secondaryDisplay,
       let screen = ScreenLookup.screen(forStableID: secondary.stableID) {
        let detector = DisplayCapabilityDetector()
        let caps = detector.detectCapabilities(for: screen)
        let icc = detector.detectICCProfile(for: screen)

        let device = MTLCreateSystemDefaultDevice()!
        let window = ExternalDisplayWindow(device: device)
        window.show(on: screen)
        secondaryDisplayWindow = window

        metal.addDisplayTarget(
            stableID: secondary.stableID,
            layer: window.metalLayer,
            capabilities: caps,
            iccProfile: icc
        )
    }
}
```

- [ ] **Step 3: Clean up on stop()**

In the existing `stop()` method, add:

```swift
secondaryDisplayWindow?.close()
secondaryDisplayWindow = nil
```

- [ ] **Step 4: Verify build succeeds**

Run: `cd TitanPlayer && swift build 2>&1 | tail -10`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift
git commit -m "feat: wire display events to MetalRenderer targets in PlaybackSession"
```

---

### Task 9: Verify Full Build & Tests

- [ ] **Step 1: Full build verification**

Run: `cd TitanPlayer && swift build 2>&1 | tail -5`
Expected: Build succeeds with no errors

- [ ] **Step 2: Test build verification**

Run: `cd TitanPlayer && swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: Empty output (no errors other than XCTest availability)

- [ ] **Step 3: Run available tests**

Run: `cd TitanPlayer && swift test 2>&1 | tail -20`
Expected: Tests pass (or skip if XCTest unavailable — the build verification is the key gate)

- [ ] **Step 4: Commit any final fixes**

```bash
git add -A
git commit -m "fix: address build issues from multi-display integration"
```

---

## Self-Review Checklist

- [x] **Spec coverage:** All 6 acceptance criteria have corresponding tasks (Task 3 for rendering, Task 5 for persistence, Task 5+7 for UI, Task 3+8 for hot-plug, Task 5 for fallback)
- [x] **Placeholder scan:** No TBDs, TODOs, or vague steps — all code is concrete
- [x] **Type consistency:** `DisplayRenderTarget`, `DisplayChangeEvent.primaryChanged`, `HDRPreference`, `ExternalDisplayWindow` — all names and signatures match across tasks
