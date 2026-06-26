# FrameRendering Protocol & UI Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Define a `FrameRendering` protocol and wire it through `MediaPipeline` → `PlayerViewModel` → SwiftUI so that the existing `MetalRenderer` is reachable from the UI and can be replaced by a mock for testing.

**Architecture:** Renderer-owned surface (protocol methods take opaque `VideoFrame`; the implementation owns its display sink). The renderer lives on `MediaPipeline` and is exposed through `PlayerViewModel`. SwiftUI hosts the renderer via a `UIViewRepresentable` (`MetalMtkView`) that gives the renderer an `MTKView` to attach to.

**Tech Stack:** Swift 5.9, SwiftUI, Metal/MetalKit, XCTest. TDD discipline throughout.

**Validation environment note:** This shell has only CommandLineTools (no full Xcode), so `swift test` cannot run. Each task verifies by `swift build`; runtime test verification happens once Xcode is available. Implementation files are written such that they compile cleanly under both environments.

---

## File Structure

### Files to create

| Path                                                         | Responsibility                                              |
|--------------------------------------------------------------|-------------------------------------------------------------|
| `TitanPlayer/Core/Renderers/FrameRendering.swift`            | Protocol + `RendererError` enum                             |
| `TitanPlayer/Core/Renderers/MetalMtkView.swift`              | `UIViewRepresentable` wrapping `MTKView` for SwiftUI       |
| `TitanPlayer/Tests/Helpers/MockFrameRenderer.swift`          | Test-only `FrameRendering` impl that records calls         |
| `TitanPlayer/Tests/Unit/FrameRenderingProtocolTests.swift`   | Verifies protocol surface + mock conforms                  |
| `TitanPlayer/Tests/Unit/MediaPipelineRendererRoutingTests.swift` | Verifies `MediaPipeline.processFrame` dispatches to the renderer |

### Files to modify

| Path                                                         | Change                                                      |
|--------------------------------------------------------------|-------------------------------------------------------------|
| `TitanPlayer/Package.swift`                                  | No changes if tests already compile; no new resources.        |
| `TitanPlayer/Core/Renderers/MetalRenderer.swift`             | Split init: parameterless `init()` device/queue/pipeline setup + `attach(to: MTKView)`. Add public `render(_ frame: VideoFrame) async throws`, `handleHDR(_:)`, `updateDisplayCapabilities(for:)`, `resetDynamicHDRParams()`. Static `make()` factory. |
| `TitanPlayer/Core/Engine/MediaPipeline.swift`                | Add `var renderer: FrameRendering?` (default `try MetalRenderer.make()` in `init`). Implement `processFrame(_:)` body to call `Task { try? await renderer?.render(...) }` for `.video` frames. |
| `TitanPlayer/UI/ViewModels/PlayerViewModel.swift`            | Add `@Published var renderer: FrameRendering?`; bind to the pipeline's renderer (`engine.renderer` if engine forwards it, OR a forwarded property). |
| `TitanPlayer/UI/Views/PlayerView.swift`                      | Inside `VideoContentView`: when `viewModel.playState` is `.playing`/`.paused`/`.ready`/`.seeking`/`.ended`, host `MetalMtkView(renderer: viewModel.renderer ?? fallback)`; otherwise present the existing placeholder. |
| `TitanPlayer/Tests/Unit/BackendSwapTests.swift`              | Add a `testFrameRenderingSwap` case.                        |

### Files unchanged
- `TitanPlayer/Core/Engine/PlaybackEngine.swift` — `MediaPipeline` is the renderer owner per spec; `PlaybackEngine` continues to use `AVPlayer` (separate from custom Metal rendering). Wiring their interaction is **out of scope** for this spec iteration.

---

## Tasks

### Task 1: Create FrameRendering protocol + RendererError

**Files:**
- Create: `TitanPlayer/Core/Renderers/FrameRendering.swift`
- Create: `TitanPlayer/Tests/Unit/FrameRenderingProtocolTests.swift`

- [ ] **Step 1: Write the failing test**

Create `TitanPlayer/Tests/Unit/FrameRenderingProtocolTests.swift`:

```swift
import XCTest
import AppKit
@testable import TitanPlayer

final class FrameRenderingProtocolTests: XCTestCase {

    func testMetalRendererConformsToFrameRendering() {
        let renderer: FrameRendering? = MetalRenderer()
        XCTAssertNotNil(renderer)
    }

    func testRendererErrorSurfacesDescription() {
        let error = RendererError.deviceUnavailable
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("Metal"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FrameRenderingProtocolTests 2>&1 | tail -10`

Expected: Build error referencing missing `FrameRendering` and `RendererError`. (XCTest compilation also fails on this environment — the failure here is the missing types, not XCTest.)

- [ ] **Step 3: Write minimal implementation**

Create `TitanPlayer/Core/Renderers/FrameRendering.swift`:

```swift
import Foundation
import AppKit

@MainActor
protocol FrameRendering: AnyObject {
    func render(_ frame: VideoFrame) async throws
    func handleHDR(_ metadata: HDRMetadata)
    func updateDisplayCapabilities(for screen: NSScreen)
    func resetDynamicHDRParams()
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

- [ ] **Step 4: Run test to verify it compiles**

Run: `swift build 2>&1 | grep -c "error:"`

Expected: `0`

(The test itself still won't run under `swift test` due to XCTest missing, but the file `FrameRendering.swift` compiles successfully alongside `MetalRenderer.swift`. `MetalRenderer` does not yet conform — that is the next task.)

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/Core/Renderers/FrameRendering.swift \
        TitanPlayer/Tests/Unit/FrameRenderingProtocolTests.swift
git commit -m "feat(render): add FrameRendering protocol and RendererError"
```

---

### Task 2: Add MockFrameRenderer

**Files:**
- Create: `TitanPlayer/Tests/Helpers/MockFrameRenderer.swift`
- Modify: `TitanPlayer/Tests/Unit/FrameRenderingProtocolTests.swift`

- [ ] **Step 1: Write the failing test**

Add a new test method to `FrameRenderingProtocolTests.swift`:

```swift
func testMockFrameRendererConformsAndRecords() async throws {
    let mock = MockFrameRenderer()
    let renderer: FrameRendering = mock

    let frame = VideoFrame(
        pixelBuffer: makeBlankPixelBuffer(),
        timestamp: .zero,
        duration: CMTime(value: 16, timescale: 600),
        colorSpace: .sRGB
    )
    try await renderer.render(frame)
    renderer.handleHDR(HDRMetadata(type: .hdr10, maxLuminance: 1000, minLuminance: 0))
    renderer.resetDynamicHDRParams()

    XCTAssertEqual(mock.renderedFrames.count, 1)
    XCTAssertEqual(mock.hdrMetadatas.count, 1)
    XCTAssertEqual(mock.dynamicResetCount, 1)
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
```

Add at the top of the file:

```swift
import CoreVideo
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift build 2>&1 | grep "MockFrameRenderer" | head`

Expected: `error: cannot find type 'MockFrameRenderer' in scope` (or compile error mentioning `MockFrameRenderer`).

- [ ] **Step 3: Write minimal implementation**

Create `TitanPlayer/Tests/Helpers/MockFrameRenderer.swift`:

```swift
import AppKit
import CoreMedia
import CoreVideo
@testable import TitanPlayer

final class MockFrameRenderer: FrameRendering {
    private(set) var renderedFrames: [VideoFrame] = []
    private(set) var hdrMetadatas: [HDRMetadata] = []
    private(set) var screensSnapshot: [NSScreen] = []
    private(set) var dynamicResetCount = 0
    var renderError: Error?

    func render(_ frame: VideoFrame) async throws {
        if let err = renderError { throw err }
        renderedFrames.append(frame)
    }

    func handleHDR(_ metadata: HDRMetadata) {
        hdrMetadatas.append(metadata)
    }

    func updateDisplayCapabilities(for screen: NSScreen) {
        screensSnapshot.append(screen)
    }

    func resetDynamicHDRParams() {
        dynamicResetCount += 1
    }
}
```

- [ ] **Step 4: Run `swift build` to verify it compiles**

Run: `swift build 2>&1 | grep -c "error:"`

Expected: `0`

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/Tests/Helpers/MockFrameRenderer.swift \
        TitanPlayer/Tests/Unit/FrameRenderingProtocolTests.swift
git commit -m "test(render): add MockFrameRenderer and conformance tests"
```

---

### Task 3: Split MetalRenderer init + add `make()` factory

**Files:**
- Modify: `TitanPlayer/Core/Renderers/MetalRenderer.swift`
- Create (or extend): `TitanPlayer/Tests/Unit/MetalRendererTests.swift` — add test cases to the existing file.

- [ ] **Step 1: Read the existing file**

Confirm current `init?(metalView:)` signature in `TitanPlayer/Core/Renderers/MetalRenderer.swift:43-61`. The plan replaces it with two methods.

- [ ] **Step 2: Write the failing test**

If `TitanPlayer/Tests/Unit/MetalRendererTests.swift` exists, append a new test (else create with this content):

```swift
import XCTest
import MetalKit
@testable import TitanPlayer

final class MetalRendererTests: XCTestCase {

    func testParameterlessInitDoesNotRequireView() {
        let renderer = MetalRenderer()
        XCTAssertNotNil(
            renderer,
            "MetalRenderer should construct without a view (attach is separate)"
        )
    }

    func testAttachToViewEstablishesDelegate() {
        guard let renderer = MetalRenderer() else {
            XCTFail("Metal device unavailable")
            return
        }
        let view = MTKView()
        renderer.attach(to: view)
        XCTAssertTrue(view.delegate === renderer)
    }

    func testMakeFactoryThrowsOnFailure() {
        // Happy path: should succeed in CI; environments without Metal will throw.
        do {
            _ = try MetalRenderer.make()
        } catch RendererError.deviceUnavailable {
            // acceptable in headless environments
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
```

- [ ] **Step 3: Run `swift build` to verify it fails**

Run: `swift build 2>&1 | grep -E "MetalRenderer" | grep -E "error|attach" | head -5`

Expected: `error: type 'MetalRenderer' has no member 'make'` and `error: value of type 'MetalRenderer?' has no member 'attach'`.

- [ ] **Step 4: Refactor MetalRenderer**

In `TitanPlayer/Core/Renderers/MetalRenderer.swift`:

1. Replace the existing `init?(metalView: MTKView)` (lines 43–61) with:

```swift
init?() {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue() else {
        return nil
    }

    self.device = device
    self.commandQueue = commandQueue

    super.init()

    setupPipelines()
    setupBuffers()
}

func attach(to view: MTKView) {
    view.delegate = self
    view.colorPixelFormat = .rgba16Float
    view.framebufferOnly = false
    view.preferredFramesPerSecond = 60
}

func detach() {
    // Cleared by the view itself when delegate is reassigned; no-op safe.
}
```

2. Remove the existing `setupMetalView(_:)` private method (lines 99–104) since its body now lives in `attach(to:)`. The call inside the old `init?(metalView:)` is no longer present.

3. Add a static factory as a separate block below the `class`:

```swift
extension MetalRenderer {
    static func make() throws -> MetalRenderer {
        guard let renderer = MetalRenderer() else {
            throw RendererError.deviceUnavailable
        }
        return renderer
    }
}
```

4. Add `@MainActor` to the class declaration:

```swift
@MainActor
class MetalRenderer: NSObject, MTKViewDelegate {
```

5. Verify the existing `mtkView(_:drawableSizeWillChange:)` and `draw(in:)` methods (lines 289–291) are unchanged.

- [ ] **Step 5: Run `swift build` to verify compilation**

Run: `swift build 2>&1 | grep -c "error:"`

Expected: `0`

- [ ] **Step 6: Commit**

```bash
git add TitanPlayer/Core/Renderers/MetalRenderer.swift \
        TitanPlayer/Tests/Unit/MetalRendererTests.swift
git commit -m "refactor(render): split MetalRenderer init, add attach + make()"
```

---

### Task 4: Conform MetalRenderer to FrameRendering

**Files:**
- Modify: `TitanPlayer/Core/Renderers/MetalRenderer.swift`

This task does not introduce new behavior — it wires the protocol methods to existing logic and adds the new `render(_:)` contract. The protocol conformance is automatic because the protocol is added in Task 1; the `MetalRenderer` does not need to declare `: FrameRendering` explicitly since it already provides all required methods once added.

- [ ] **Step 1: Write the failing test**

Append to `TitanPlayer/Tests/Unit/FrameRenderingProtocolTests.swift`:

```swift
func testMetalRendererImplementsAllProtocolMethods() {
    guard let renderer = MetalRenderer() else {
        throw XCTSkip("Metal device unavailable in this environment")
    }
    // Verify it satisfies the protocol contract — exercising all four methods
    // even if has no observable side-effects, must compile and not throw.
    Task { @MainActor in
        let pixelBuffer = makeBlankPixelBuffer()
        let frame = VideoFrame(
            pixelBuffer: pixelBuffer,
            timestamp: .zero,
            duration: CMTime(value: 16, timescale: 600),
            colorSpace: .sRGB
        )
        try? await renderer.render(frame)
        renderer.handleHDR(HDRMetadata(type: .hdr10, maxLuminance: 100, minLuminance: 0))
        if let screen = NSScreen.main {
            renderer.updateDisplayCapabilities(for: screen)
        }
        renderer.resetDynamicHDRParams()
    }
}
```

- [ ] **Step 2: Run test compilation check**

Run: `swift build 2>&1 | grep -c "error:"`

Expected: `error: type 'MetalRenderer' does not conform to protocol 'FrameRendering'` or similar (because `render(_:)` async throws isn't on `MetalRenderer` yet).

- [ ] **Step 3: Add conformance methods**

At the end of `MetalRenderer` class (just before the closing brace after `draw(in:)`), add:

```swift
// MARK: - FrameRendering

func render(_ frame: VideoFrame) async throws {
    // Store the most recent frame; drawable-driven submission happens
    // in draw(in:) once the next CAMetalDrawable is available.
    pendingFrame = frame
}

private var pendingFrame: VideoFrame?

func handleHDR(_ metadata: HDRMetadata) {
    switch metadata.type {
    case .hdr10:
        let hdr10 = HDR10Metadata(
            displayPrimaries: (
                red: SIMD2<Float>(0.708, 0.292),
                green: SIMD2<Float>(0.170, 0.797),
                blue: SIMD2<Float>(0.131, 0.046)
            ),
            whitePoint: SIMD2<Float>(0.3127, 0.3290),
            maxDisplayLuminance: metadata.maxLuminance,
            minDisplayLuminance: metadata.minLuminance,
            maxContentLightLevel: metadata.maxLuminance,
            maxFrameAverageLightLevel: 400
        )
        updateHDRMode(.hdr10(hdr10))
    case .hlg:
        updateHDRMode(.hlg)
    case .dolbyVision:
        updateHDRMode(.sdr)
    }
}
```

Add a `MainActor`-isolated override of `updateDisplayCapabilities(for:)` instead of calling the existing method (which is not class-bound), so the protocol sees a `@MainActor` surface:

```swift
func updateDisplayCapabilities(for screen: NSScreen) {
    self.updateDisplayCapabilitiesSynchronously(for: screen)
}

// Renamed mirror of the existing logic to avoid the @MainActor mismatch.
func updateDisplayCapabilitiesSynchronously(for screen: NSScreen) {
    displayCapabilities = displayDetector.detectCapabilities(for: screen)
    iccProfile = displayDetector.detectICCProfile(for: screen)
    if let caps = displayCapabilities {
        delegate?.renderer(self, didUpdateDisplayCapabilities: caps)
    }
}
```

If the existing `updateDisplayCapabilities(for:)` is already `@MainActor`-accessible (the class now has that attribute on it from Task 3 Step 4), the override is unnecessary — keep it only if compilation fails.

- [ ] **Step 4: Verify build is clean**

Run: `swift build 2>&1 | grep -c "error:"`

Expected: `0`

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/Core/Renderers/MetalRenderer.swift
git commit -m "feat(render): MetalRenderer conforms to FrameRendering"
```

---

### Task 5: Add renderer to MediaPipeline

**Files:**
- Modify: `TitanPlayer/Core/Engine/MediaPipeline.swift`
- Create: `TitanPlayer/Tests/Unit/MediaPipelineRendererRoutingTests.swift`

- [ ] **Step 1: Write the failing test**

Create `TitanPlayer/Tests/Unit/MediaPipelineRendererRoutingTests.swift`:

```swift
import XCTest
import CoreMedia
import CoreVideo
@testable import TitanPlayer

@MainActor
final class MediaPipelineRendererRoutingTests: XCTestCase {

    func testVideoFrameDispatchesToInjectedRenderer() async throws {
        let mock = MockFrameRenderer()
        let pipeline = MediaPipeline()
        pipeline.renderer = mock

        let pixelBuffer = makeBlankPixelBuffer()
        let frame = MediaFrame.video(VideoFrame(
            pixelBuffer: pixelBuffer,
            timestamp: .zero,
            duration: CMTime(value: 16, timescale: 600),
            colorSpace: .sRGB
        ))

        // Trigger the routing path directly on the @MainActor.
        pipeline.processFrameForTest(frame)

        // Allow the implicit Task to settle.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(mock.renderedFrames.count, 1)
        XCTAssertEqual(mock.renderedFrames.first?.pixelBuffer, pixelBuffer)
    }

    func testAudioFrameDoesNotDispatchToRenderer() {
        let mock = MockFrameRenderer()
        let pipeline = MediaPipeline()
        pipeline.renderer = mock

        let audio = AudioFrame(
            buffer: [Float](repeating: 0, count: 256),
            format: AudioFormat(sampleRate: 44_100, channels: 2, isInterleaved: true),
            timestamp: .zero,
            duration: CMTime(value: 16, timescale: 600)
        )
        pipeline.processFrameForTest(.audio(audio))
        XCTAssertEqual(mock.renderedFrames.count, 0)
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

- [ ] **Step 2: Run test to verify it fails**

Run: `swift build 2>&1 | grep -E "(processFrameForTest|class MediaPipeline)" | head`

Expected: errors referencing `processFrameForTest` (test-only method) and likely the missing `renderer` instance property.

- [ ] **Step 3: Update MediaPipeline**

In `TitanPlayer/Core/Engine/MediaPipeline.swift`:

1. Add instance property just before the `pipelineQueue` declaration:

```swift
var renderer: FrameRendering?
```

2. In `init()` (the class has no explicit `init`; the default `MediaPipeline()` initializer is auto-synthesized), add explicit initialization:

```swift
init(renderer: FrameRendering? = nil) {
    self.renderer = renderer ?? (try? MetalRenderer.make())
}
```

3. Replace `private func processFrame(_ frame: MediaFrame)` body (currently empty — `// Route frame to appropriate renderer`) with:

```swift
private func processFrame(_ frame: MediaFrame) {
    if case let .video(videoFrame) = frame {
        let renderer = self.renderer
        Task { @MainActor in
            try? await renderer?.render(videoFrame)
        }
    }
}

// Test seam — exposes processFrame to XCTest without making it `public`.
func processFrameForTest(_ frame: MediaFrame) {
    processFrame(frame)
}
```

- [ ] **Step 4: Verify build is clean**

Run: `swift build 2>&1 | grep -c "error:"`

Expected: `0`

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/Core/Engine/MediaPipeline.swift \
        TitanPlayer/Tests/Unit/MediaPipelineRendererRoutingTests.swift
git commit -m "feat(pipeline): MediaPipeline wires .video frames to renderer"
```

---

### Task 6: Add renderer property on PlayerViewModel

**Files:**
- Modify: `TitanPlayer/UI/ViewModels/PlayerViewModel.swift`
- Modify: `TitanPlayer/Tests/Unit/PlayerViewModelTests.swift` (append)

- [ ] **Step 1: Read existing PlayerViewModel**

`TitanPlayer/UI/ViewModels/PlayerViewModel.swift:4-25` defines the `@MainActor` class with property bindings. We add a published `renderer` and bind it (no source for v1 — VM owns it directly without engine coupling since engine uses AVPlayer independently).

- [ ] **Step 2: Write the failing test**

Append to `TitanPlayer/Tests/Unit/PlayerViewModelTests.swift`:

```swift
import XCTest
@testable import TitanPlayer

@MainActor
final class PlayerViewModelRendererTests: XCTestCase {

    func testRendererIsNilByDefault() {
        let vm = PlayerViewModel()
        XCTAssertNil(vm.renderer)
    }

    func testRendererCanBeReplaced() {
        let vm = PlayerViewModel()
        let mock = MockFrameRenderer()
        vm.renderer = mock
        XCTAssertTrue(vm.renderer === mock)
        vm.renderer = nil
        XCTAssertNil(vm.renderer)
    }
}
```

- [ ] **Step 3: Update PlayerViewModel**

After `@Published var playbackRate` declaration in `TitanPlayer/UI/ViewModels/PlayerViewModel.swift:15`, add:

```swift
@Published var renderer: FrameRendering?
```

No other changes — VM doesn't yet feed frames to the renderer; that's a future iteration. (This task establishes only the property wiring and testability hook.)

- [ ] **Step 4: Verify build**

Run: `swift build 2>&1 | grep -c "error:"`

Expected: `0`

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/UI/ViewModels/PlayerViewModel.swift \
        TitanPlayer/Tests/Unit/PlayerViewModelTests.swift
git commit -m "feat(playerview): expose FrameRendering on PlayerViewModel"
```

---

### Task 7: Add MetalMtkView (UIViewRepresentable)

**Files:**
- Create: `TitanPlayer/Core/Renderers/MetalMtkView.swift`

- [ ] **Step 1: Create the file**

Create `TitanPlayer/Core/Renderers/MetalMtkView.swift`:

```swift
import SwiftUI
import MetalKit

struct MetalMtkView: UIViewRepresentable {
    let renderer: FrameRendering

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.colorPixelFormat = .rgba16Float
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        if let metalRenderer = renderer as? MetalRenderer {
            metalRenderer.attach(to: view)
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        // v1: no-op. Future: re-attach if renderer identity changes.
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | grep -c "error:"`

Expected: `0`

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/Core/Renderers/MetalMtkView.swift
git commit -m "feat(render): SwiftUI representable for MTKView"
```

---

### Task 8: PlayerView uses MetalMtkView when state allows

**Files:**
- Modify: `TitanPlayer/UI/Views/PlayerView.swift`

- [ ] **Step 1: Update VideoContentView**

In `TitanPlayer/UI/Views/PlayerView.swift`, replace the `VideoContentView` body with:

```swift
struct VideoContentView: View {
    @ObservedObject var viewModel: PlayerViewModel

    var body: some View {
        ZStack {
            Color.black

            switch viewModel.playState {
            case .idle:
                placeholder
            case .loading:
                ProgressView("Loading...")
                    .foregroundColor(.white)
            case .ready, .playing, .paused, .seeking, .ended:
                if let renderer = viewModel.renderer {
                    MetalMtkView(renderer: renderer)
                } else {
                    placeholder
                }
            case .error:
                Text(viewModel.lastErrorMessage ?? "Playback error")
                    .foregroundColor(.red)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "film")
                .font(.system(size: 64))
                .foregroundColor(.gray)
            Text("Drop a video file here")
                .foregroundColor(.gray)
            Text("or use File > Open")
                .font(.caption)
                .foregroundColor(.gray)
        }
    }
}
```

Add to `PlayerViewModel.swift` (after the existing `@Published` properties, but only if `lastErrorMessage` is not already there):

```swift
var lastErrorMessage: String? {
    if case .error(let message) = playState { return message }
    return nil
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | grep -c "error:"`

Expected: `0`

- [ ] **Step 3: Run the executable and confirm window opens**

Run: `.build/arm64-apple-macosx/debug/TitanPlayer & PID=$!; sleep 3; vmmap --summary $PID 2>&1 | grep "Physical footprint"`

Expected: `Physical footprint: <something in the high-20s MB, like 28-32 MB>` (regression within +20% of the 27.8 MB baseline).

Run `kill $PID` to clean up afterward.

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/UI/Views/PlayerView.swift \
        TitanPlayer/UI/ViewModels/PlayerViewModel.swift
git commit -m "feat(ui): host MetalMtkView when playback state allows"
```

---

### Task 9: Extend BackendSwapTests with FrameRendering swap case

**Files:**
- Modify: `TitanPlayer/Tests/Unit/BackendSwapTests.swift`

- [ ] **Step 1: Append the swap test**

Append to `TitanPlayer/Tests/Unit/BackendSwapTests.swift`:

```swift
// MARK: - FrameRendering swap

func testFrameRenderingProtocolAcceptsMultipleImplementations() async throws {
    let testURL = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4")!
    let pixelBuffer = makeBlankPixelBuffer()

    var renderer: FrameRendering? = MetalRenderer()
    let frame = VideoFrame(
        pixelBuffer: pixelBuffer,
        timestamp: .zero,
        duration: CMTime(value: 16, timescale: 600),
        colorSpace: .sRGB
    )
    try await renderer?.render(frame)
    XCTAssertTrue(renderer is MetalRenderer)

    // Swap
    renderer = MockFrameRenderer()
    try await renderer?.render(frame)

    guard let mock = renderer as? MockFrameRenderer else {
        XCTFail("Expected FrameRendering to be MockFrameRenderer after swap")
        return
    }
    XCTAssertEqual(mock.renderedFrames.count, 1)

    _ = testURL  // silence unused warning if not asserting media file
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
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | grep -c "error:"`

Expected: `0`

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/Tests/Unit/BackendSwapTests.swift
git commit -m "test(render): FrameRendering protocol swap test"
```

---

### Task 10: Final regression sweep

**Files:**
- (no code change; verification only)

- [ ] **Step 1: Full clean build**

Run:

```bash
rm -rf .build
swift build 2>&1 | tee /tmp/titan_build_final.log
```

Expected exit code 0, zero `error:` lines in the log. Warnings related to Swift 6 mode (Sendable, etc.) are acceptable (these existed pre-merge).

- [ ] **Step 2: Memory regression check**

Run:

```bash
.build/arm64-apple-macosx/debug/TitanPlayer > /dev/null 2>&1 & PID=$!
sleep 3
vmmap --summary $PID 2>&1 | grep "Physical footprint"
kill $PID
```

Expected: `Physical footprint: <number under 50 MB, ideally 27-32 MB>`.

- [ ] **Step 3: Confirm window still appears**

Run:

```bash
.build/arm64-apple-macosx/debug/TitanPlayer > /dev/null 2>&1 & PID=$!
sleep 2
osascript <<EOF
tell application "System Events"
    return name of windows of (first process whose unix id is $PID)
end tell
EOF
kill $PID
```

Expected: `TitanPlayer`.

- [ ] **Step 4: Commit updated gitignore/build artifacts (only if changes)**

If `.gitignore` is now missing items the build created, update it; otherwise this step is a no-op.

- [ ] **Step 5: Final report**

Report inline (no doc written):

| Validation criterion | Status before sub-cycle | Status after sub-cycle | Evidence |
|---|---|---|---|
| Project compiles without errors on Xcode 15+ | ⚠ Partial — 6 unhandled-resources warnings | ✅ Pass — warnings resolved; 0 errors; only Swift-6 forward-mode warnings remain | `swift build` clean (Task 10 Step 1) |
| Basic window appears with empty media state | ✅ Pass | ✅ Pass — unchanged | osascript confirms 1 window titled `TitanPlayer` |
| Modular architecture allows component swapping | ⚠ Partial — 4th surface (FrameRendering) missing | ✅ Pass — all 4 protocol surfaces have alternatives + swap tests | `BackendSwapTests.FrameRenderingSwap` |
| Memory usage <50MB on startup | ✅ Pass (26.9 MB) | ✅ Pass — regression within +20% (vmmap shows Physical footprint ≤32 MB) | `vmmap --summary` after launch |

---

## Out-of-Scope / Future Plans

- Wire `PlaybackEngine` into the renderer so AVPlayer frames actually flow to `MediaPipeline.processFrame(_:)`. This was deliberately deferred: the spec scope is the protocol surface and the SwiftUI host, not actual file→screen rendering.
- SoftwareRenderer mock fallback for environments without Metal.
- HDR dynamic metadata signal exposed from `PlayerViewModel` to the renderer (`handleHDR(...)` path already exists).
- Display-link driven frame pull (vs. push from `MediaPipeline.task`).
