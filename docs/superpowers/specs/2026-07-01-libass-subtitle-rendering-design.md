# libass SSA/ASS Subtitle Rendering — Design Spec

## Overview

Integrate libass via a Homebrew system library to render full ASS/SSA subtitle files
(positioning, colors, fonts, animations, karaoke, drawing commands) as bitmap overlays
composited in Metal. SRT/VTT continue using the existing SwiftUI Text path.

## Decisions

| Decision | Choice |
|----------|--------|
| Rendering layer | Metal texture overlay (not SwiftUI Image) |
| libass dependency | System library via Homebrew (`brew install libass`) |
| ASS styling scope | Full ASS spec (libass handles natively) |
| Fallback behavior | Graceful — ASS shows "libass not installed" message, SRT/VTT still work |
| Architecture | SubtitleRenderer protocol + LibAssRenderer implementation |

## Architecture

```
SubtitleManager
├── ASS/SSA files → LibAssRenderer (libass C API) → bitmap → Metal subtitle texture
└── SRT/VTT files → SwiftUI Text overlay (existing, unchanged)
```

## New Files

### 1. `Sources/CLibAss/module.modulemap`

System library modulemap for libass. Uses pkgConfig for discovery — SwiftPM invokes
`pkg-config --cflags libass` and `pkg-config --libs libass` to resolve header and link
paths at build time. This automatically handles Apple Silicon (`/opt/homebrew`) vs
Intel (`/usr/local`) differences.

```
module CLibAss [system] {
    header "ass/ass.h"
    link "ass"
    export *
}
```

The `header` path is relative; pkgConfig provides the include directory via
`other-swift-flags` / `c-settings` from the pkgConfig output.

### 2. `Subtitles/SubtitleRenderer.swift`

Protocol definition for subtitle renderers.

```swift
protocol SubtitleRenderer {
    func load(data: Data, encoding: String.Encoding) throws
    func renderImage(forTime time: Double, size: CGSize) -> SubtitleBitmap?
    func setStyleSheet(_ style: SubtitleStyle)
    func flush()
}

struct SubtitleBitmap {
    let pixels: UnsafeMutableRawBufferPointer  // RGBA, caller owns memory after creation
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixelFormat: MTLPixelFormat  // .bgra8Unorm for Metal upload
}
// Memory contract: LibAssRenderer allocates the pixel buffer. The caller
// (MetalRenderer) must deallocate it after uploading to MTLTexture.
// SubtitleBitmap is a value type; pixels are not copied on assignment.
```

### 3. `Subtitles/LibAssRenderer.swift`

Full libass wrapper implementing `SubtitleRenderer`.

**Lifecycle:**
- `init?()` — calls `ass_library_init()`, `ass_renderer_init()`, configures font
  directories from system paths. Returns `nil` if libass not available.
- `load(data:encoding:)` — calls `ass_read_data()` to parse ASS/SSA from raw bytes
- `renderImage(forTime:size:)` — calls `ass_render_frame()`, composites resulting
  `ASS_Image` linked list into a single RGBA buffer
- `flush()` — frees current track, resets renderer state

**Font configuration:**
- `ass_set_fonts_dir()` — points to `~/Library/Fonts`, `/Library/Fonts`,
  `/System/Library/Fonts`
- `ass_set_font_provider()` — optional custom provider for app-bundled fonts
- Default font family: "Arial" (configurable via `setStyleSheet`)

**`setStyleSheet` behavior:**
- Overrides default font family, size scale, and colors for the entire track
- Calls `ass_set_style_overrides()` with a semi-colon delimited style string
- Example: `setStyleSheet(.init(fontName: "Helvetica", fontSize: 28))`
  → `"FontName=Helvetica;Fontsize=28"`
- Called once when track is loaded, not per-frame

**Performance:**
- `renderImage()` only re-renders when subtitle events change (not every frame)
- The `ASS_Renderer` internally caches glyph textures
- Expected overhead: < 2% CPU on M-series Macs

### 4. `Resources/Shaders/Subtitle.metal`

New Metal fragment shader for alpha-composited subtitle overlay.

```metal
#include <metal_stdlib>
using namespace metal;

struct SubtitleVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

fragment float4 subtitleFragment(SubtitleVertexOut in [[stage_in]],
                                  texture2d<float> videoTexture [[texture(0)]],
                                  texture2d<float> subtitleTexture [[texture(1)]],
                                  sampler texSampler [[sampler(0)]]) {
    float4 video = videoTexture.sample(texSampler, in.texCoord);
    float4 subtitle = subtitleTexture.sample(texSampler, in.texCoord);
    return mix(video, subtitle, subtitle.a);
}
```

The shader performs simple alpha compositing: subtitle pixels blend over video pixels.
Subtitle texture uses `bgra8Unorm` pixel format, matching the libass RGBA output
(channel-swizzled).

### 5. `Tests/Unit/LibAssRendererTests.swift`

Unit tests covering:
- `LibAssRenderer` initialization (with/without libass)
- Loading ASS data and rendering at known timestamps
- Verifying bitmap dimensions match requested size
- Flush and reload behavior
- Graceful fallback when libass is absent

## Modified Files

### 6. `Package.swift`

Add `CLibAss` system library target and dependency:

```swift
// New target — pkgConfig resolves header/link paths automatically
.systemLibrary(
    name: "CLibAss",
    pkgConfig: "libass",
    providers: [
        .brew(["libass"])
    ]
)

// Add to TitanPlayer executable target dependencies
.dependencies: [..., "CLibAss"]
```

### 7. `Subtitles/SubtitleManager.swift`

Key changes:

- Add `private var subtitleRenderer: SubtitleRenderer?` — initialized to
  `LibAssRenderer()` (nil if libass unavailable)
- Add `@Published var currentBitmap: SubtitleBitmap?` — for Metal overlay
- In `loadSubtitle()`: detect ASS/SSA extension, call `subtitleRenderer.load(data:)`
- In `update(for:)`: if active track is ASS/SSA, call `subtitleRenderer.renderImage()`
  and update `currentBitmap`; otherwise clear bitmap (use SwiftUI path)
- `clear()` calls `subtitleRenderer?.flush()` and sets `currentBitmap = nil`

### 8. `Core/Renderers/MetalRenderer.swift`

Key changes:

- Add `private var subtitleTexture: MTLTexture?` — GPU texture for subtitle bitmap
- Add `private var subtitlePipelineState: MTLRenderPipelineState?` — pipeline for
  subtitle compositing pass
- New method `updateSubtitleBitmap(_ bitmap: SubtitleBitmap?)` — uploads RGBA buffer
  to `MTLTexture` (only when bitmap changes, via dirty flag)
- In `render()` pipeline: add second render pass that composites `subtitleTexture`
  over the video frame using `Subtitle.metal` fragment shader
- When `subtitleTexture` is nil, skip the subtitle pass (zero overhead for non-ASS)

### 9. `UI/Views/PlayerView.swift`

Conditional subtitle display:

```swift
// In SubtitleOverlay
if subtitleManager.currentBitmap != nil {
    // Hide SwiftUI overlay — Metal handles rendering
    EmptyView()
} else {
    // Existing SwiftUI Text overlay for SRT/VTT
    existingSubtitleOverlay
}
```

## Data Flow

```
1. User loads .ass file
   → SubtitleManager.loadSubtitle(url:)
   → Detects .ass extension
   → Calls subtitleRenderer.load(data:)
   → libass parses ASS events internally

2. Playback tick (every frame)
   → SubtitleManager.update(for: currentTime)
   → Calls subtitleRenderer.renderImage(forTime:size:)
   → libass renders active events to RGBA bitmap
   → Returns SubtitleBitmap

3. Metal render loop
   → MetalRenderer.updateSubtitleBitmap(bitmap)
   → Uploads RGBA to MTLTexture (if changed)
   → Render pass 2: alpha-composite subtitle over video
   → Output to drawable
```

## Fallback Behavior

When libass is not installed (`LibAssRenderer.init()` returns nil):

- `SubtitleManager.subtitleRenderer` is `nil`
- ASS/SSA files show "Install libass for ASS subtitle support" message
- SRT/VTT files continue working via SwiftUI Text overlay
- `currentBitmap` is always `nil`, so Metal subtitle pass is skipped

## Performance Budget

| Component | CPU overhead |
|-----------|-------------|
| libass `ass_render_frame()` | < 1% (M1 Pro) |
| RGBA → MTLTexture upload | < 0.5% (once per event change) |
| Metal alpha-composite pass | < 0.3% (single full-screen quad) |
| **Total** | **< 2%** |

libass re-renders only when subtitle events change (typically 1-4 times per second),
not on every frame. The Metal composite pass is a single textured quad draw call.

## Acceptance Criteria

1. Complex ASS subtitles (e.g., anime opening themes) render with correct positioning,
   colors, fonts, and styling tags (`{\pos(x,y)}`, `{\c&H...&}`, `{\fn...}`, `{\fs...}`)
2. Full ASS spec support: karaoke (`\k`, `\kf`), drawing (`\p`), transforms (`\t`),
   clip regions (`\clip`), rotation (`\frx`, `\fry`, `\frz`)
3. Subtitle rendering has minimal impact on performance (< 2% CPU overhead)
4. External .ass files load correctly via "Load External Subtitle" button
5. SRT/VTT files continue working via SwiftUI overlay (no regression)
6. Graceful fallback when libass is not installed (clear error message)
7. Unit tests pass for LibAssRenderer
8. Build succeeds with `swift build` on macOS 14+
