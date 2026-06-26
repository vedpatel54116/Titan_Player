# FrameRendering Protocol & UI Wiring — Design Specification

## Overview

This sub-project closes the **FrameRendering protocol gap** identified during the 2026-06-26 TitanPlayer validation cycle. The original `2026-06-25-titanplayer-design.md` declares a `FrameRendering` protocol but no implementation conforms to it; `MetalRenderer` is an orphan class never instantiated by the UI, and `MediaPipeline.processFrame(_:)` is a no-op stub. This spec defines a renderer-owned `FrameRendering` surface, conforms `MetalRenderer`, wires the renderer into `PlayerView`, and connects `MediaPipeline` to the renderer.

**Target:** macOS 14+
**Component scope:** `Core/Renderers/`, `Core/Engine/MediaPipeline.swift`, `UI/Views/PlayerView.swift`, `UI/ViewModels/PlayerViewModel.swift`
**Out of scope:** Multiple swap libraries (MetalAOV renderer, software-fallback renderer), display-side async stream, frame timing / catchup policy beyond `inFlightSemaphore`.

---

## Architecture Overview

### Where this fits

```
┌─────────────────────────────────────────────┐
│                 UI Layer                    │
│  PlayerView → MetalMtkView (UIViewRepresentable) │
│  PlayerViewModel @Published renderer: FrameRendering │
├─────────────────────────────────────────────┤
│              Core Engine                    │
│  MediaPipeline.renderer: FrameRendering     │
│  MediaPipeline.processFrame(_:) → renderer.render(_:) │
├─────────────────────────────────────────────┤
│              Renderers                      │
│  FrameRendering (protocol)                  │
│  ├─ MetalRenderer (production, in-tree)     │
│  └─ MockFrameRenderer (test, in Tests/)    │
└─────────────────────────────────────────────┘
```

The renderer is **owned by `MediaPipeline`** (one per playback session). It is **surfaced to the UI** through `PlayerViewModel` so SwiftUI can host the MTKView. The View does not create, configure Metal state, or know about Metal — it only ever asks for an opaque `FrameRendering` and wraps its view.

---

## Protocol Surface

```swift
// Core/Renderers/FrameRendering.swift
protocol FrameRendering: AnyObject {
    func render(_ frame: VideoFrame) async throws
    func handleHDR(_ metadata: HDRMetadata)
    func updateDisplayCapabilities(for screen: NSScreen)
    func resetDynamicHDRParams()
}
```

### Method contracts

- `render(_:)`: Accepts a decoded `VideoFrame` and submits it to the implementation's display pipeline. Async because the implementation may call into Metal semaphores that block; throwing so swap-out implementations can surface failures. Implementations may coalesce frames: if a new frame arrives before a drawable is presented, the new frame replaces the queued one (latest-wins backpressure). All `FrameRendering` methods are isolated to `@MainActor` (the renderer flushes UI state on each call; `MetalRenderer's draw(in:)` is already called by AppKit on the main thread).
- `handleHDR(_:)`: Updates HDR mode metadata **without** rendering. Idempotent. Implies `currentHDRMode` already updated by the time the next `render(_:)` executes HDR-uniform update logic.
- `updateDisplayCapabilities(for:)`: Refreshes display-side state (HDR caps, EDR, ICC profile). Called when the host screen changes. Idempotent.
- `resetDynamicHDRParams()`: Clears any dynamic tone-mapping overrides so subsequent renders use static metadata only.

### Errors

```swift
enum RendererError: Error, LocalizedError {
    case notAttached
    case deviceUnavailable
    case pipelineCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAttached: return "Renderer is not attached to a Metal view."
        case .deviceUnavailable: return "Metal device is unavailable on this system."
        case .pipelineCreationFailed(let s): return "Failed to create Metal pipeline: \(s)"
        }
    }
}
```

### Relationship to existing types

`FrameRendering` references only types that already exist in `Core/Decoders/Protocols/SharedTypes.swift` (`VideoFrame`, `HDRMetadata`) and `AppKit` (`NSScreen`). No new codec types.

---

## MetalRenderer Conformance

### Refactor

Today's `MetalRenderer.init?(metalView:)` constructs device, queue, pipelines, **and** binds to a view. We split it:

- `init()` — fails with `deviceUnavailable` if `MTLCreateSystemDefaultDevice()` returns nil. Sets up pipeline states + buffers from `device.makeDefaultLibrary()`. **No view binding.**
- `attach(to view: MTKView)` — sets `view.delegate = self`, configures color pixel format, framebuffer-only, preferred FPS.
- `detach()` — clear `view.delegate`, nil-out queued frame.

The renderer exposes a single internal "pending frame" slot. When `render(_:)` is called, it stores the latest `VideoFrame`. The renderer's `draw(in:)` (inherited from `MTKViewDelegate`) checks the slot and, if present, runs the existing triple-buffered compute pipeline + render pass against the next CAMetalDrawable. Identical pipeline internals to today.

### Method mapping

| Protocol                           | MetalRenderer            |
|------------------------------------|--------------------------|
| `render(_:)`                       | New: stores frame + returns; `draw(in:)` consumes |
| `handleHDR(_:)`                    | Calls `updateHDRMode(_)` |
| `updateDisplayCapabilities(for:)` | Direct proxy to existing method |
| `resetDynamicHDRParams()`         | Direct proxy              |

`MetalRenderer.init()` returns Optional. To preserve call-site ergonomics, expose a static factory:

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

Callers (`MediaPipeline`) construct via `try MetalRenderer.make()`. Tests construct directly through `init` and accept Optional.

### Backpressure

The pending-frame slot is a `var pendingFrame: VideoFrame?` (atomic via Swift's main-actor isolation — `FrameRendering` methods all run on `@MainActor`). `draw(in:)` reads it with a serial swap. No queue. The `inFlightSemaphore` (already triple-buffered) is what blocks producers in practice.

---

## SwiftUI Integration

### New file: `Core/Renderers/MetalMtkView.swift`

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
        // Future: re-attach if renderer identity changed. v1 no-op.
    }
}
```

### PlayerView update

`PlayerView.swift`'s `VideoContentView` body currently shows `Color.black` for the idle state and `ProgressView` for loading. Replace per `playState`:

- `.idle` → existing placeholder (no renderer wired yet)
- `.loading` → existing progress
- `.paused` / `.playing` / `.seeking` / `.ended` → `MetalMtkView(renderer: viewModel.renderer)` behind a fallback `Color.black` so the view is always tappable

The View does not know the concrete renderer type; if the protocol default `attach(to:)` is missing for non-Metal implementations, no-op in `MetalMtkView` (animates empty). This keeps the seam testable.

### PlayerViewModel update

Add:

```swift
@MainActor class PlayerViewModel: ObservableObject {
    // existing properties...
    @Published var renderer: FrameRendering?
}
```

`init` constructs `MediaPipeline()`, then `MediaPipeline` constructs `MetalRenderer()?.makeAttached()` lazily on first render. For tests, `PlayerViewModel` is constructed with an injected `MediaPipeline` whose `renderer` is `MockFrameRenderer`.

---

## MediaPipeline Wiring

`MediaPipeline.processFrame(_ frame: MediaFrame)` becomes:

```swift
@MainActor
private func processFrame(_ frame: MediaFrame) {
    guard let renderer = renderer else { return }
    if case let .video(videoFrame) = frame {
        Task { try? await renderer.render(videoFrame) }
    }
}
```

New instance variable:

```swift
var renderer: FrameRendering?
```

Constructed in `init()`:

```swift
var renderer: FrameRendering? = MetalRenderer()
```

Tests inject `MockFrameRenderer`. `MediaPipeline` does **not** own the MTKView; it only feeds frames. Lifecycle: created when pipeline is created, replaced when pipeline is replayed or test-constructed.

---

## MockFrameRenderer (Tests-only)

New file `Tests/Helpers/MockFrameRenderer.swift`:

```swift
final class MockFrameRenderer: FrameRendering {
    private(set) var renderedFrames: [VideoFrame] = []
    private(set) var hdrMetadatas: [HDRMetadata] = []
    private(set) var screensSnapshot: [NSScreen?] = []
    var dynamicResetCount = 0
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

Tests verify:
- `MockFrameRenderer` is acceptable as a `FrameRendering?` property (Swift assignment).
- A swap test assigns `MetalRenderer()` then `MockFrameRenderer()` to the same `FrameRendering?` and exercises both — exactly mirroring `BackendSwapTests` for the other protocols.
- A pipeline test feeds a `MediaFrame.video(...)` into `MediaPipeline.processFrame(_:)` and asserts `mockFrameRenderer.renderedFrames.count == 1`.

---

## Test Plan

### Unit tests (`Tests/Unit/`)

| File                              | Purpose                                              |
|-----------------------------------|------------------------------------------------------|
| `FrameRenderingProtocolTests.swift` | Test protocol conformance to `MetalRenderer` and `MockFrameRenderer`; verify `Mock` records calls. |
| `MediaPipelineRendererRoutingTests.swift` | Inject `MockFrameRenderer`, feed a synthetic `.video(MediaFrame)`, assert exactly one renderer.render call. |
| `PlayerViewModelRendererTests.swift` | Verify VM exposes `renderer` and forwards HDR metadata via `handleHDR`. |
| `BackendSwapTests.swift` (extend) | Add FrameRendering case (MetalRenderer ↔ MockFrameRenderer). |

### Integration tests (`Tests/Integration/`)

| File                              | Purpose                                              |
|-----------------------------------|------------------------------------------------------|
| `RenderPipelineIntegrationTests.swift` | Open a test media, run for one frame, verify `renderedFrames` recorded by an injected `MockFrameRenderer` via a stub `MediaPipeline` replacement. |

### Verification

`swift build` must succeed. `swift test` is environment-blocked on this machine (XCTest missing — full Xcode required). Tests are written to validate as soon as the validation environment can run them.

---

## Validation Criteria

- [ ] `swift build` produces zero errors on macOS 14+
- [ ] `FrameRenderingProtocolTests`, `MediaPipelineRendererRoutingTests`, `PlayerViewModelRendererTests`, `BackendSwapTests.FrameRenderingSwap` all compile and pass under Xcode 15+
- [ ] `MetalMtkView` appears in SwiftUI's view tree when `viewModel.renderer != nil`
- [ ] `MediaPipeline.processFrame(_:)` invokes `renderer.render(_:)` exactly once per `.video` frame
- [ ] Memory at idle remains <50 MB (`vmmap --summary` Physical footprint). **Regression check**: must not regress the 27.8 MB baseline measured during the 2026-06-26 validation cycle.
- [ ] Behavior-preserving refactor: no rendered-frame visual behavior exceeds the existing implementation. Verify by line-count of `MetalRenderer` deltas — net line change must remain under +20% of existing 297-line file.

---

## Success Criteria

1. `Core/Renderers/FrameRendering.swift` defines the protocol as specified.
2. `MetalRenderer` conforms and remains the production renderer. Its public API does not regress: every method present today (init, render(pixelBuffer:metadata:to:), updateDisplayCapabilities, updateHDRMode, updateDynamicHDRParams, resetDynamicHDRParams, attach-to-view) is preserved either as protocol surface or as direct caller.
3. `MediaPipeline.processFrame(_:)` is no longer empty and dispatches to the renderer.
4. `PlayerView` shows a Metal-rendered view when a file is loaded.
5. Mock-based swap test proves renderer can be replaced without pipeline rewiring.

---

## Implementation Order

Each step follows TDD discipline: write the failing test first, then minimal implementation, then verify.

1. **Protocol first (TDD):** write `FrameRendering` protocol skeleton in a placeholder file; write `FrameRenderingProtocolTests` (compile-only) asserting one production + one mock conform; red. Green by adding protocol + mock stubs.
2. **`RendererError`:** declared alongside the protocol.
3. **MetalRenderer refactor:** write the unmocked-attach test (verify that `MetalRenderer` instance can be created without a view). Split `init?(metalView:)` into `init()` + `attach(to:)`. Conform `MetalRenderer` to `FrameRendering`. Confirm existing `MetalRendererTests` still pass.
4. **`MockFrameRenderer`:** add to test target with full conformance + recording.
5. **MediaPipeline wiring:** Write `MediaPipelineRendererRoutingTests` that injects `MockFrameRenderer` and feeds a synthetic `.video` `MediaFrame`. Make `processFrame(_:)` dispatch.
6. **PlayerViewModel property:** add `@Published var renderer`. Test that VM exposes it.
7. **MetalMtkView:** `UIViewRepresentable` wrapper.
8. **PlayerView integration:** use `MetalMtkView` conditionally on `viewModel.renderer != nil`.
9. **BackendSwapTests extension:** add FrameRendering swap case (MetalRenderer ↔ MockFrameRenderer via a `FrameRendering?` slot).
10. **Final `swift build` + `MetalRendererTests` regression** verification.

---

## Out-of-Scope / Deferred

- Display-link driven frame pull (vs. push)
- AsyncStream-based renderer interface
- Software-fallback renderer (e.g., CoreGraphics)
- Per-frame telemetry / dropped-frame counter
- HDR dynamic metadata signal wiring into PlaybackEngine
- Multi-renderer (e.g., offscreen metal for snapshotting)

These are tracked as follow-up ideas; none block this sub-cycle's validation criteria.
