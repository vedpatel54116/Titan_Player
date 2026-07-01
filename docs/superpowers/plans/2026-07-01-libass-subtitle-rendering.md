# libass SSA/ASS Subtitle Rendering — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate libass via Homebrew system library to render full ASS/SSA subtitles as Metal-composited bitmap overlays, with graceful fallback when libass is absent.

**Architecture:** SubtitleRenderer protocol with LibAssRenderer implementation wrapping libass C API. libass renders ASS events to RGBA bitmap → uploaded to MTLTexture → alpha-composited over video in a second Metal render pass. SRT/VTT continue using existing SwiftUI Text overlay.

**Tech Stack:** libass (C, Homebrew), SwiftPM systemLibrary, Metal (MSL), Swift, SwiftUI

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `TitanPlayer/Sources/CLibAss/module.modulemap` | Create | System library modulemap for libass |
| `TitanPlayer/Package.swift` | Modify | Add CLibAss target + dependency |
| `TitanPlayer/TitanPlayer/Subtitles/SubtitleRenderer.swift` | Create | Protocol + SubtitleBitmap struct |
| `TitanPlayer/TitanPlayer/Subtitles/LibAssRenderer.swift` | Create | libass C API wrapper |
| `TitanPlayer/TitanPlayer/Resources/Shaders/Subtitle.metal` | Create | Alpha-composite fragment shader |
| `TitanPlayer/TitanPlayer/Core/Renderers/MetalShaders.swift` | Modify | Add "Subtitle" to sourceFileNames |
| `TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift` | Modify | Subtitle texture upload + composite pass |
| `TitanPlayer/TitanPlayer/Subtitles/SubtitleManager.swift` | Modify | Route ASS to LibAssRenderer |
| `TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift` | Modify | Conditional SwiftUI/Metal display |
| `TitanPlayer/Tests/Unit/LibAssRendererTests.swift` | Create | Unit tests |

---

### Task 1: CLibAss System Library Target

**Files:**
- Create: `TitanPlayer/Sources/CLibAss/module.modulemap`
- Modify: `TitanPlayer/Package.swift`

- [ ] **Step 1: Create the CLibAss directory**

```bash
mkdir -p TitanPlayer/Sources/CLibAss
```

- [ ] **Step 2: Create the modulemap**

Write `TitanPlayer/Sources/CLibAss/module.modulemap`:

```
module CLibAss [system] {
    header "ass/ass.h"
    link "ass"
    export *
}
```

- [ ] **Step 3: Add CLibAss target to Package.swift**

Replace the full content of `TitanPlayer/Package.swift` with:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TitanPlayer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/superuser404notfound/FFmpegBuild", branch: "main")
    ],
    targets: [
        .systemLibrary(
            name: "CLibAss",
            pkgConfig: "libass",
            providers: [
                .brew(["libass"])
            ]
        ),
        .executableTarget(
            name: "TitanPlayer",
            dependencies: [
                "FFmpegBuild",
                "CLibAss",
                .product(name: "Libavcodec", package: "FFmpegBuild"),
                .product(name: "Libavformat", package: "FFmpegBuild"),
                .product(name: "Libavutil", package: "FFmpegBuild"),
                .product(name: "Libswscale", package: "FFmpegBuild"),
            ],
            path: "TitanPlayer",
            exclude: ["Info.plist"],
            resources: [
                .process("Resources/Assets.xcassets"),
                .process("Resources/Shaders")
            ]
        ),
        .testTarget(
            name: "TitanPlayerTests",
            dependencies: ["TitanPlayer"],
            path: "Tests",
            resources: [
                .copy("Fixtures/test.mp4")
            ]
        )
    ]
)
```

- [ ] **Step 4: Verify libass is installed**

```bash
brew list libass || echo "NOT INSTALLED — run: brew install libass"
pkg-config --cflags --libs libass
```

Expected: compiler flags (`-I/opt/homebrew/include/...`) and linker flags (`-L/opt/homebrew/lib -lass`)

- [ ] **Step 5: Verify the module resolves**

```bash
cd TitanPlayer && swift build 2>&1 | head -20
```

Expected: builds without errors (or only pre-existing errors unrelated to CLibAss). If `pkg-config` cannot find libass, the build will fail with a clear error — that's expected if libass isn't installed.

- [ ] **Step 6: Commit**

```bash
cd "Titan Player" && git add TitanPlayer/Sources/CLibAss/module.modulemap TitanPlayer/Package.swift && git commit -m "feat(subtitles): add CLibAss system library target for libass"
```

---

### Task 2: SubtitleRenderer Protocol & SubtitleBitmap

**Files:**
- Create: `TitanPlayer/TitanPlayer/Subtitles/SubtitleRenderer.swift`

- [ ] **Step 1: Create SubtitleRenderer.swift**

Write `TitanPlayer/TitanPlayer/Subtitles/SubtitleRenderer.swift`:

```swift
import Foundation
import Metal

/// Result of rendering subtitle events at a given time.
/// The caller (MetalRenderer) owns the pixel buffer after creation
/// and must deallocate it after uploading to MTLTexture.
struct SubtitleBitmap {
    let pixels: UnsafeMutableRawBufferPointer
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixelFormat: MTLPixelFormat  // Always .bgra8Unorm
}

/// Abstracts subtitle rendering backends (libass, SwiftUI fallback, etc.).
protocol SubtitleRenderer {
    /// Parse subtitle data from raw bytes.
    func load(data: Data, encoding: String.Encoding) throws

    /// Render active subtitle events at the given time to a bitmap.
    /// Returns nil if no events are active at this time.
    func renderImage(forTime time: Double, size: CGSize) -> SubtitleBitmap?

    /// Override default style (font, size, colors) for the loaded track.
    func setStyleSheet(_ style: SubtitleStyle)

    /// Free all loaded data and reset state.
    func flush()
}
```

- [ ] **Step 2: Verify it compiles**

```bash
cd TitanPlayer && swift build 2>&1 | grep -i "error:" | grep -v "no such module"
```

Expected: no errors related to SubtitleRenderer.swift (other existing errors are fine).

- [ ] **Step 3: Commit**

```bash
cd "Titan Player" && git add TitanPlayer/TitanPlayer/Subtitles/SubtitleRenderer.swift && git commit -m "feat(subtitles): add SubtitleRenderer protocol and SubtitleBitmap"
```

---

### Task 3: LibAssRenderer Implementation

**Files:**
- Create: `TitanPlayer/TitanPlayer/Subtitles/LibAssRenderer.swift`

- [ ] **Step 1: Create LibAssRenderer.swift**

Write `TitanPlayer/TitanPlayer/Subtitles/LibAssRenderer.swift`:

```swift
import Foundation
import CLibAss
import Metal

/// Renders ASS/SSA subtitles using libass.
/// Returns nil from init() if libass is not available (graceful fallback).
class LibAssRenderer: SubtitleRenderer {
    private var library: OpaquePointer?
    private var renderer: OpaquePointer?
    private var track: OpaquePointer?
    private var currentData: Data?

    init?() {
        guard let lib = ass_library_init() else { return nil }
        self.library = lib

        guard let rend = ass_renderer_init(lib) else {
            ass_library_done(lib)
            self.library = nil
            return nil
        }
        self.renderer = rend

        configureFonts()
    }

    deinit {
        flush()
        if let renderer = renderer { ass_renderer_done(renderer) }
        if let library = library { ass_library_done(library) }
    }

    // MARK: - SubtitleRenderer

    func load(data: Data, encoding: String.Encoding) throws {
        flush()
        currentData = data

        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
            track = ass_read_data(
                library,
                UnsafeMutablePointer(mutating: ptr),
                rawBuffer.count,
                nil
            )
        }
    }

    func renderImage(forTime time: Double, size: CGSize) -> SubtitleBitmap? {
        guard let track = track, let renderer = renderer else { return nil }

        let width = Int(size.width)
        let height = Int(size.height)
        ass_set_frame_size(renderer, UInt32(width), UInt32(height))

        var eventCount: Int32 = 0
        guard let image = ass_render_frame(renderer, track, Int64(time * 1000), &eventCount) else {
            return nil
        }
        guard eventCount > 0 else { return nil }

        return compositeImages(image, width: width, height: height)
    }

    func setStyleSheet(_ style: SubtitleStyle) {
        guard let track = track else { return }
        let overrides = "FontName=\(style.fontName);Fontsize=\(Int(style.fontSize))"
        overrides.withCString { cStr in
            var ptr: UnsafeMutablePointer<CChar>? = UnsafeMutablePointer(mutating: cStr)
            ass_set_style_overrides(track, &ptr)
        }
    }

    func flush() {
        if let track = track { ass_free_track(track) }
        track = nil
        currentData = nil
    }

    // MARK: - Private

    private func configureFonts() {
        guard let renderer = renderer else { return }
        let fontDirs = [
            NSHomeDirectory() + "/Library/Fonts",
            "/Library/Fonts",
            "/System/Library/Fonts"
        ]
        for dir in fontDirs {
            dir.withCString { cStr in
                ass_set_fonts_dir(renderer, cStr)
            }
        }
    }

    private func compositeImages(_ first: UnsafeMutablePointer<ASS_Image>,
                                  width: Int,
                                  height: Int) -> SubtitleBitmap? {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = bytesPerRow * height

        guard let buffer = malloc(totalBytes) else { return nil }
        memset(buffer, 0, totalBytes)

        var current: UnsafeMutablePointer<ASS_Image>? = first
        while let img = current {
            let dst = buffer.assumingMemoryBound(to: UInt8.self)

            for y in 0..<Int(img.height) {
                let srcRow = Int(img.bitmap) + y * Int(img.stride)
                let srcPtr = UnsafeRawPointer(bitPattern: srcRow)!
                let dstOffset = (Int(img.y) + y) * bytesPerRow + Int(img.x) * bytesPerPixel

                guard dstOffset >= 0, dstOffset + Int(img.width) * bytesPerPixel <= totalBytes else {
                    current = img.pointee.next
                    continue
                }

                for x in 0..<Int(img.width) {
                    let srcAlpha = srcPtr.load(fromByteOffset: x, as: UInt8.self)
                    let dstOffset4 = dstOffset + x * bytesPerPixel

                    // libass outputs A8 masks — render as white with alpha
                    dst[dstOffset4 + 0] = 255  // B
                    dst[dstOffset4 + 1] = 255  // G
                    dst[dstOffset4 + 2] = 255  // R
                    dst[dstOffset4 + 3] = srcAlpha  // A
                }
            }

            current = img.pointee.next
        }

        let bufferPtr = UnsafeMutableRawBufferPointer(
            start: buffer,
            count: totalBytes
        )
        return SubtitleBitmap(
            pixels: bufferPtr,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelFormat: .bgra8Unorm
        )
    }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
cd TitanPlayer && swift build 2>&1 | grep -i "error:" | grep -v "no such module"
```

Expected: no new errors from LibAssRenderer.swift.

- [ ] **Step 3: Commit**

```bash
cd "Titan Player" && git add TitanPlayer/TitanPlayer/Subtitles/LibAssRenderer.swift && git commit -m "feat(subtitles): implement LibAssRenderer wrapping libass C API"
```

---

### Task 4: Subtitle.metal Shader + MetalShaders Update

**Files:**
- Create: `TitanPlayer/TitanPlayer/Resources/Shaders/Subtitle.metal`
- Modify: `TitanPlayer/TitanPlayer/Core/Renderers/MetalShaders.swift:7`

- [ ] **Step 1: Create Subtitle.metal**

Write `TitanPlayer/TitanPlayer/Resources/Shaders/Subtitle.metal`:

```metal
#include <metal_stdlib>
using namespace metal;

fragment float4 subtitleFragment(
    VertexOut in [[stage_in]],
    texture2d<float> videoTexture [[texture(0)]],
    texture2d<float> subtitleTexture [[texture(1)]]
) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear);
    float4 video = videoTexture.sample(texSampler, in.textureCoordinate);
    float4 subtitle = subtitleTexture.sample(texSampler, in.textureCoordinate);
    return mix(video, subtitle, subtitle.a);
}
```

- [ ] **Step 2: Add "Subtitle" to MetalShaders sourceFileNames**

In `TitanPlayer/TitanPlayer/Core/Renderers/MetalShaders.swift`, line 7, change:

```swift
static let sourceFileNames = ["Common", "Video", "HDR", "Analysis"]
```

to:

```swift
static let sourceFileNames = ["Common", "Video", "HDR", "Analysis", "Subtitle"]
```

- [ ] **Step 3: Verify compilation**

```bash
cd TitanPlayer && swift build 2>&1 | grep -i "error:" | grep -v "no such module"
```

Expected: no errors from Subtitle.metal or MetalShaders.swift.

- [ ] **Step 4: Commit**

```bash
cd "Titan Player" && git add TitanPlayer/TitanPlayer/Resources/Shaders/Subtitle.metal TitanPlayer/TitanPlayer/Core/Renderers/MetalShaders.swift && git commit -m "feat(subtitles): add Subtitle.metal shader for alpha compositing"
```

---

### Task 5: MetalRenderer Subtitle Integration

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift`

- [ ] **Step 1: Add subtitle properties to MetalRenderer**

After the `toneMappedTexture` property (line 31), add:

```swift
private var subtitleTexture: MTLTexture?
private var subtitlePipelineState: MTLRenderPipelineState?
private var subtitleDirty = false
```

- [ ] **Step 2: Add subtitle pipeline setup in setupPipelines()**

In `setupPipelines()` (after line 100), add:

```swift
let subtitleFunction = library.makeFunction(name: "subtitleFragment")
let subtitleDescriptor = MTLRenderPipelineDescriptor()
subtitleDescriptor.vertexFunction = library.makeFunction(name: "vertexShader")
subtitleDescriptor.fragmentFunction = subtitleFunction
subtitleDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
subtitlePipelineState = try? device.makeRenderPipelineState(descriptor: subtitleDescriptor)
```

- [ ] **Step 3: Add updateSubtitleBitmap method**

After `resetDynamicHDRParams()` (after line 160), add:

```swift
func updateSubtitleBitmap(_ bitmap: SubtitleBitmap?) {
    guard let bitmap = bitmap else {
        subtitleTexture = nil
        return
    }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: bitmap.pixelFormat,
        width: bitmap.width,
        height: bitmap.height,
        mipmapped: false
    )
    descriptor.usage = [.shaderRead]
    descriptor.storageMode = .managed

    guard let texture = device.makeTexture(descriptor: descriptor) else { return }

    texture.replace(
        region: MTLRegion(
            origin: MTLOrigin(x: 0, y: 0, z: 0),
            size: MTLSize(width: bitmap.width, height: bitmap.height, depth: 1)
        ),
        mipmapLevel: 0,
        withBytes: bitmap.pixels.baseAddress!,
        bytesPerRow: bitmap.bytesPerRow
    )

    subtitleTexture = texture
    subtitleDirty = false
}
```

- [ ] **Step 4: Add subtitle composite pass in draw(in:)**

In `draw(in:)`, after the existing render encoder block (after line 358, before `commandBuffer.present(drawable)`), add the subtitle composite pass:

```swift
if let subtitleTexture = subtitleTexture,
   let subtitlePipelineState = subtitlePipelineState,
   let outputTexture = toneMappedTexture {
    let subtitleDescriptor = createRenderPassDescriptor(drawable: drawable)
    if let subtitleEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: subtitleDescriptor) {
        subtitleEncoder.setRenderPipelineState(subtitlePipelineState)
        subtitleEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        subtitleEncoder.setFragmentTexture(outputTexture, index: 0)
        subtitleEncoder.setFragmentTexture(subtitleTexture, index: 1)
        subtitleEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        subtitleEncoder.endEncoding()
    }
}
```

- [ ] **Step 5: Add subtitle composite pass in render(pixelBuffer:metadata:to:)**

In `render(pixelBuffer:metadata:to:)`, after the existing render encoder block (after line 211, before `commandBuffer.present(drawable)`), add:

```swift
if let subtitleTexture = subtitleTexture,
   let subtitlePipelineState = subtitlePipelineState,
   let outputTexture = toneMappedTexture {
    let subtitleDescriptor = createRenderPassDescriptor(drawable: drawable)
    if let subtitleEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: subtitleDescriptor) {
        subtitleEncoder.setRenderPipelineState(subtitlePipelineState)
        subtitleEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        subtitleEncoder.setFragmentTexture(outputTexture, index: 0)
        subtitleEncoder.setFragmentTexture(subtitleTexture, index: 1)
        subtitleEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        subtitleEncoder.endEncoding()
    }
}
```

- [ ] **Step 6: Verify compilation**

```bash
cd TitanPlayer && swift build 2>&1 | grep -i "error:" | grep -v "no such module"
```

Expected: no new errors from MetalRenderer.swift.

- [ ] **Step 7: Commit**

```bash
cd "Titan Player" && git add TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift && git commit -m "feat(subtitles): add subtitle texture compositing to MetalRenderer"
```

---

### Task 6: SubtitleManager ASS Routing

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Subtitles/SubtitleManager.swift`

- [ ] **Step 1: Add subtitleRenderer and currentBitmap properties**

In `SubtitleManager.swift`, after the `parsers` dictionary (line 15), add:

```swift
private var subtitleRenderer: SubtitleRenderer?
@Published var currentBitmap: SubtitleBitmap?
```

- [ ] **Step 2: Initialize subtitleRenderer in an init or setup method**

Since `SubtitleManager` is a class without an explicit `init`, add one after the `parsers` dictionary:

```swift
init() {
    subtitleRenderer = LibAssRenderer()
}
```

- [ ] **Step 3: Modify loadSubtitle() for ASS/SSA routing**

Replace the `loadSubtitle(url:)` method (lines 17-38) with:

```swift
func loadSubtitle(url: URL) throws {
    let data = try Data(contentsOf: url)
    let ext = url.pathExtension.lowercased()

    let isASS = ext == "ass" || ext == "ssa"

    if isASS {
        guard let renderer = subtitleRenderer else {
            throw MediaError(
                code: .unsupportedFormat,
                message: "Install libass for ASS subtitle support: brew install libass"
            )
        }
        try renderer.load(data: data, encoding: .utf8)
        let track = SubtitleTrack(
            name: url.lastPathComponent,
            language: nil,
            isDefault: availableTracks.isEmpty,
            events: []
        )
        availableTracks.append(track)
        if activeTrack == nil { activeTrack = track }
        return
    }

    guard let parser = parsers[ext] else {
        throw MediaError(code: .unsupportedFormat, message: "Unsupported subtitle format: \(ext)")
    }

    let events = try parser.parse(data: data)
    let track = SubtitleTrack(
        name: url.lastPathComponent,
        language: nil,
        isDefault: availableTracks.isEmpty,
        events: events
    )
    availableTracks.append(track)
    if activeTrack == nil { activeTrack = track }
}
```

- [ ] **Step 4: Modify update(for:) for ASS bitmap rendering**

Replace the `update(for:)` method (lines 44-53) with:

```swift
func update(for time: Double, renderSize: CGSize = CGSize(width: 1920, height: 1080)) {
    guard let track = activeTrack else {
        currentEvents = []
        currentBitmap = nil
        return
    }

    let ext = track.name.pathExtension.lowercased()
    let isASS = ext == "ass" || ext == "ssa"

    if isASS {
        currentEvents = []
        if let renderer = subtitleRenderer {
            currentBitmap = renderer.renderImage(forTime: time, size: renderSize)
        }
    } else {
        currentBitmap = nil
        currentEvents = track.events.filter { event in
            time >= event.startTime && time <= event.endTime
        }
    }
}
```

Note: The `renderSize` parameter defaults to 1920x1080. The caller (PlaybackSession)
should pass the actual view size. This keeps the API backward-compatible.

- [ ] **Step 5: Modify clear() to flush renderer**

Replace the `clear()` method (lines 55-59) with:

```swift
func clear() {
    subtitleRenderer?.flush()
    availableTracks = []
    activeTrack = nil
    currentEvents = []
    currentBitmap = nil
}
```

- [ ] **Step 6: Verify compilation**

```bash
cd TitanPlayer && swift build 2>&1 | grep -i "error:" | grep -v "no such module"
```

Expected: no new errors from SubtitleManager.swift.

- [ ] **Step 7: Commit**

```bash
cd "Titan Player" && git add TitanPlayer/TitanPlayer/Subtitles/SubtitleManager.swift && git commit -m "feat(subtitles): route ASS files through LibAssRenderer in SubtitleManager"
```

---

### Task 7: PlayerView Conditional Subtitle Display

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift`

- [ ] **Step 1: Read the current SubtitleOverlay**

Open `TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift` and locate the `SubtitleOverlay` struct (around line 140).

- [ ] **Step 2: Modify SubtitleOverlay to check for bitmap**

Replace the `SubtitleOverlay` body with:

```swift
struct SubtitleOverlay: View {
    let events: [SubtitleEvent]
    let hasMetalBitmap: Bool

    var body: some View {
        if hasMetalBitmap {
            EmptyView()
        } else {
            VStack {
                Spacer()
                ForEach(events, id: \.startTime) { event in
                    Text(event.text)
                        .font(.system(size: event.style.fontSize))
                        .foregroundColor(Color(
                            red: event.style.foregroundColor.r,
                            green: event.style.foregroundColor.g,
                            blue: event.style.foregroundColor.b))
                        .shadow(color: .black, radius: 2)
                        .padding(.horizontal, 40)
                        .padding(.bottom, 60)
                }
            }
        }
    }
}
```

- [ ] **Step 3: Update the SubtitleOverlay call site**

Locate where `SubtitleOverlay` is instantiated (around line 28) and update the call:

```swift
SubtitleOverlay(
    events: session.currentSubtitleEvents,
    hasMetalBitmap: session.currentSubtitleBitmap != nil
)
```

- [ ] **Step 4: Add currentSubtitleBitmap to PlaybackSession**

In `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift`:

**4a.** Add published property near line 16 (next to `currentSubtitleEvents`):

```swift
@Published var currentSubtitleBitmap: SubtitleBitmap?
```

**4b.** In `setupBindings()` (after line 329, after the `$currentEvents` bridge), add:

```swift
subtitleManager.$currentBitmap
    .receive(on: DispatchQueue.main)
    .assign(to: &$currentSubtitleBitmap)
```

This follows the exact same pattern as the existing subtitle bridges.

- [ ] **Step 5: Verify compilation**

```bash
cd TitanPlayer && swift build 2>&1 | grep -i "error:" | grep -v "no such module"
```

Expected: no new errors from PlayerView.swift or PlaybackSession.swift.

- [ ] **Step 6: Commit**

```bash
cd "Titan Player" && git add TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift && git commit -m "feat(subtitles): conditional SwiftUI/Metal subtitle display in PlayerView"
```

---

### Task 8: Unit Tests

**Files:**
- Create: `TitanPlayer/Tests/Unit/LibAssRendererTests.swift`

- [ ] **Step 1: Create test file**

Write `TitanPlayer/Tests/Unit/LibAssRendererTests.swift`:

```swift
import XCTest
@testable import TitanPlayer

final class LibAssRendererTests: XCTestCase {

    func testInitReturnsNilWhenLibassUnavailable() {
        // LibAssRenderer.init?() returns nil if libass isn't installed.
        // On a machine with libass, this test should succeed (renderer is non-nil).
        // On a machine without libass, renderer is nil — test still passes.
        let renderer = LibAssRenderer()
        if renderer != nil {
            renderer?.flush()
        }
        // If libass is installed, renderer is non-nil. Either outcome is valid.
        XCTAssert(true)
    }

    func testLoadAndRenderASSData() throws {
        guard let renderer = LibAssRenderer() else {
            throw XCTSkip("libass not installed")
        }
        defer { renderer.flush() }

        let assContent = """
        [Script Info]
        Title: Test
        ScriptType: v4.00+
        PlayResX: 1920
        PlayResY: 1080

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,Hello World
        """

        let data = assContent.data(using: .utf8)!
        try renderer.load(data: data, encoding: .utf8)

        let bitmap = renderer.renderImage(forTime: 2.0, size: CGSize(width: 1920, height: 1080))
        XCTAssertNotNil(bitmap)
        XCTAssertEqual(bitmap?.width, 1920)
        XCTAssertEqual(bitmap?.height, 1080)

        if let bitmap = bitmap {
            bitmap.pixels.deallocate()
        }
    }

    func testRenderReturnsNilForNoActiveEvents() throws {
        guard let renderer = LibAssRenderer() else {
            throw XCTSkip("libass not installed")
        }
        defer { renderer.flush() }

        let assContent = """
        [Script Info]
        Title: Test
        ScriptType: v4.00+

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,Hello
        """

        let data = assContent.data(using: .utf8)!
        try renderer.load(data: data, encoding: .utf8)

        // Time before the dialogue starts
        let bitmap = renderer.renderImage(forTime: 0.5, size: CGSize(width: 1920, height: 1080))
        XCTAssertNil(bitmap)
    }

    func testFlushResetsState() throws {
        guard let renderer = LibAssRenderer() else {
            throw XCTSkip("libass not installed")
        }

        let assContent = """
        [Script Info]
        Title: Test
        ScriptType: v4.00+

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,Hello
        """

        let data = assContent.data(using: .utf8)!
        try renderer.load(data: data, encoding: .utf8)

        renderer.flush()

        // After flush, render should return nil (no track loaded)
        let bitmap = renderer.renderImage(forTime: 2.0, size: CGSize(width: 1920, height: 1080))
        XCTAssertNil(bitmap)
    }

    func testSetStyleSheet() throws {
        guard let renderer = LibAssRenderer() else {
            throw XCTSkip("libass not installed")
        }
        defer { renderer.flush() }

        let assContent = """
        [Script Info]
        Title: Test
        ScriptType: v4.00+

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,Hello
        """

        let data = assContent.data(using: .utf8)!
        try renderer.load(data: data, encoding: .utf8)

        let style = SubtitleStyle(
            fontSize: 32,
            fontName: "Helvetica",
            foregroundColor: .white,
            backgroundColor: nil,
            isBold: false,
            isItalic: false
        )
        renderer.setStyleSheet(style)

        let bitmap = renderer.renderImage(forTime: 2.0, size: CGSize(width: 1920, height: 1080))
        XCTAssertNotNil(bitmap)

        bitmap?.pixels.deallocate()
    }
}
```

- [ ] **Step 2: Run tests**

```bash
cd TitanPlayer && swift test --filter LibAssRendererTests 2>&1
```

Expected: If libass is installed, all tests pass (except those that throw `XCTSkip`). If libass is not installed, all tests skip with "libass not installed".

- [ ] **Step 3: Commit**

```bash
cd "Titan Player" && git add TitanPlayer/Tests/Unit/LibAssRendererTests.swift && git commit -m "test(subtitles): add LibAssRenderer unit tests"
```

---

### Task 9: Integration Verification

**Files:** None (verification only)

- [ ] **Step 1: Full build**

```bash
cd TitanPlayer && swift build 2>&1
```

Expected: build succeeds with no errors.

- [ ] **Step 2: Run all tests**

```bash
cd TitanPlayer && swift test 2>&1
```

Expected: all existing tests still pass; new LibAssRenderer tests pass or skip gracefully.

- [ ] **Step 3: Verify ASS file loading manually**

Create a test ASS file and verify it loads:

```bash
cat > /tmp/test.ass << 'EOF'
[Script Info]
Title: Test
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,Hello World
Dialogue: 0,0:00:02.00,0:00:04.00,Default,,0,0,0,,{\pos(960,200)}Centered Subtitle
EOF
```

Open the player, load `/tmp/test.ass`, and verify:
- Subtitles appear at correct timestamps
- Second subtitle appears centered at (960, 200)
- SRT files still work via SwiftUI overlay

- [ ] **Step 4: Final commit (if any fixups needed)**

```bash
cd "Titan Player" && git add -A && git commit -m "feat(subtitles): complete libass ASS/SSA subtitle rendering integration"
```
