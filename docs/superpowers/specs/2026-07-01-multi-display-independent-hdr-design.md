# Multi-Display Independent HDR Configuration

**Date:** 2026-07-01
**Status:** Draft
**Extends:** `2026-06-29-multi-display-external-output-design.md`
**Target:** macOS 14+

## Overview

When two displays are connected (e.g., internal SDR + external HDR), the current `MetalRenderer` applies a single set of HDR/EDR settings globally. This causes incorrect tone mapping on at least one display. This spec adds per-display rendering contexts so each display gets independent tone mapping matched to its capabilities.

## Goals & Non-Goals

**Goals**

- Independent HDR tone mapping per display — video plays correctly on both internal (SDR) and external (HDR) displays simultaneously
- No color shift or brightness mismatch between displays
- User can select which display is "primary" (shows main window) vs "secondary" (shows fullscreen video)
- Display configuration persists across app restarts
- Minimal memory/pipeline overhead — shared Metal pipelines, per-target uniforms only

**Non-Goals**

- Multiple independent playback windows per display (separate feature)
- Per-display EQ or volume curves
- Audio routing changes — macOS handles this automatically

## Architecture

```
┌─────────────┐     ┌──────────────────┐     ┌─────────────────────────┐
│ DisplayMgr  │────▶│ PlaybackSession  │────▶│ MetalRenderer            │
│ - primary   │     │ - observes events│     │ - targets: [stableID:   │
│ - secondary │     │ - creates window │     │     DisplayRenderTarget] │
│ - events    │     │ - moves window   │     │ - primary: MTKView      │
└─────────────┘     └──────────────────┘     │ - secondary: CAMetalLayer│
                                              └─────────┬───────────────┘
                                                        │
                                    ┌───────────────────┴──────────────────┐
                                    ▼                                      ▼
                           ┌─────────────┐                     ┌──────────────────┐
                           │ Primary     │                     │ Secondary        │
                           │ MTKView     │                     │ CAMetalLayer     │
                           │ (app window)│                     │ (fullscreen)     │
                           └─────────────┘                     └──────────────────┘
```

## Components

### 1. DisplayRenderTarget (new)

**File:** `Core/Renderers/Displays/DisplayRenderTarget.swift`

```swift
struct DisplayRenderTarget {
    let stableID: String
    let layer: CAMetalLayer
    var capabilities: DisplayCapabilities
    var iccProfile: ICCProfile
    var hdrUniformsBuffer: MTLBuffer
    var toneMappedTexture: MTLTexture?
}
```

Each target owns its own `hdrUniformsBuffer` so tone mapping parameters are independent. The `toneMappedTexture` is lazily allocated/resized when the target's dimensions change.

### 2. MetalRenderer Changes

**File:** `Core/Renderers/MetalRenderer.swift`

**New properties:**
- `private var displayTargets: [String: DisplayRenderTarget]` — keyed by `stableID`
- The existing `hdrUniformsBuffer` / `toneMappedTexture` become the primary target's entries

**New API:**
```swift
func addDisplayTarget(stableID: String, layer: CAMetalLayer, capabilities: DisplayCapabilities, iccProfile: ICCProfile)
func removeDisplayTarget(stableID: String)
func updateDisplayCapabilities(for stableID: String, capabilities: DisplayCapabilities, iccProfile: ICCProfile)
```

**Render path changes:**

In `draw(in:)` (MTKView delegate, primary display):
1. Create input texture from pending frame (once).
2. Run tone mapping compute pass using primary target's uniforms → primary target's `toneMappedTexture`.
3. Render to MTKView drawable (existing path).
4. For each secondary `DisplayRenderTarget`: run tone mapping compute pass with that target's uniforms → render to its `CAMetalLayer.nextDrawable()`.

In `render(pixelBuffer:metadata:to:)` (called by MediaPipeline):
- Same flow — create input texture once, dispatch to all registered targets.

**Per-target tone mapping:**
- Each target's `hdrUniformsBuffer` is updated with its own `DisplayCapabilities.supportsEDR`, `ICCProfile.matrix`, and `maxEDRLuminance`.
- The `hdrMode` (SDR/HDR10/HLG) comes from the source content and is the same across targets — only the display adaptation differs.

### 3. DisplayManager Changes

**File:** `UI/Session/Displays/DisplayManager.swift`

**New properties:**
- `@Published private(set) var primaryDisplay: ExternalDisplayConfig?` — the display showing the main app window
- Computed `secondaryDisplay: ExternalDisplayConfig?` — the non-primary display (if any)
- `private var primaryDisplayStableID: String?` — persisted preference

**New API:**
```swift
func setPrimaryDisplay(stableID: String)
```

**Events addition:**
```swift
enum DisplayChangeEvent {
    case connected(ExternalDisplayConfig)
    case disconnected(stableID: String)
    case refreshed(ExternalDisplayConfig)
    case primaryChanged(ExternalDisplayConfig)  // NEW
}
```

**Behavior:**
- On init: load saved `primaryDisplayStableID` from `PersistedDisplayConfig`. If the display is not connected, default to the built-in display.
- `setPrimaryDisplay()`: updates `primaryDisplay`, persists the choice, emits `.primaryChanged`.
- `secondaryDisplay`: computed as `displays.first(where: { $0.stableID != primaryDisplay?.stableID })`.

### 4. PersistedDisplayConfig Changes

**File:** `Core/Renderers/Displays/PersistedDisplayConfig.swift`

**New persistence keys:**
- `titanplayer.displays.primaryID.v1` — `String?` (the primary display's stable ID)
- `titanplayer.displays.hdrPrefs.v1` — `[String: HDRPreference]` (per-display HDR override)

```swift
struct HDRPreference: Codable, Equatable {
    let autoDetect: Bool    // true = use detected capabilities
    let forceHDR: Bool      // force HDR tone mapping even if display reports SDR
    let forceSDR: Bool      // force SDR output even if display supports HDR
}
```

**New API:**
```swift
func loadPrimaryDisplayID() -> String?
func savePrimaryDisplayID(_ stableID: String)
func loadHDRPreferences() -> [String: HDRPreference]
func saveHDRPreference(_ pref: HDRPreference, for stableID: String)
```

### 5. ExternalDisplayWindow (new)

**File:** `UI/Session/Displays/ExternalDisplayWindow.swift`

A fullscreen `NSWindow` created on the secondary display:

```swift
@MainActor
final class ExternalDisplayWindow {
    private var window: NSWindow?
    let metalLayer: CAMetalLayer

    func show(on screen: NSScreen)
    func close()
}
```

**Properties:**
- `level = .statusBar + 1` — stays above other windows
- `isOpaque = true`, `backgroundColor = .black`
- `hasShadow = false`
- Contains a plain `NSView` with a `CAMetalLayer` sublayer (not `MTKView` — rendering is driven by the renderer, not the view's display cycle)
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`

### 6. DisplaySelectorView (new)

**File:** `UI/Views/Displays/DisplaySelectorView.swift`

A SwiftUI popover/menu listing connected displays with:
- Display name
- HDR badge (if `hdrSupported`)
- Radio button: "Use as primary"
- EDR luminance info (small text)

Triggered from a toolbar button or menu item in the player controls.

### 7. PlaybackSession Wiring

**File:** `UI/Session/PlaybackSession.swift`

**Observations added:**
- Observe `displayManager.events` for `.connected`, `.disconnected`, `.primaryChanged`.
- On `.connected` (secondary display): create `ExternalDisplayWindow` on that screen, call `metalRenderer.addDisplayTarget()`.
- On `.disconnected`: call `metalRenderer.removeDisplayTarget()`, close the window.
- On `.primaryChanged`: move main window to the new primary screen, swap secondary target.

**Frame routing:**
- No change — `MediaPipeline.processFrame()` calls `renderer.render(frame)` which dispatches to all targets internally.

### 8. FrameRendering Protocol Update

**File:** `Core/Renderers/FrameRendering.swift`

Add optional methods with default implementations:
```swift
func addDisplayTarget(stableID: String, layer: CAMetalLayer, capabilities: DisplayCapabilities, iccProfile: ICCProfile)
func removeDisplayTarget(stableID: String)
```

Default implementations are no-ops so existing conformers (mock renderer, etc.) don't break.

## Error Handling

| Condition | Response |
|---|---|
| Secondary display disconnects mid-playback | `removeDisplayTarget()` called, rendering continues on remaining targets. No frame drops. |
| Primary display disconnects | Auto-promote remaining display to primary. Move main window there. Persist updated preference. |
| Display capabilities change at runtime | `DisplayManager` detects via `didChangeScreenParametersNotification`, re-detects, calls `updateDisplayCapabilities(for:)` on the specific target. |
| App launches with saved primary that's not connected | Fall back to built-in display. Update persisted config. |
| `CAMetalLayer.nextDrawable()` returns nil (layer not visible) | Skip rendering for that target this frame. Continue with other targets. |
| Memory pressure on secondary target | Skip secondary target rendering when frame time exceeds budget (checked via `PerformanceOptimizer`). |

## Testing

- **DisplayRenderTargetTests** — allocate targets, verify uniforms are independent per target.
- **MetalRendererMultiTargetTests** — add two mock targets, verify tone mapping params differ.
- **DisplayManagerPrimaryTests** — set primary, verify persistence, verify fallback on disconnect.
- **ExternalDisplayWindowTests** — verify window placement on correct screen, verify cleanup on close.
- **Integration test** — two mock screens with different capabilities, verify no color shift.

## Files to Modify

| File | Change |
|---|---|
| `Core/Renderers/MetalRenderer.swift` | Add `displayTargets` dict, `addDisplayTarget`, `removeDisplayTarget`, per-target rendering in `draw(in:)` |
| `Core/Renderers/FrameRendering.swift` | Add optional `addDisplayTarget`/`removeDisplayTarget` with default no-op |
| `UI/Session/Displays/DisplayManager.swift` | Add `primaryDisplay`, `setPrimaryDisplay()`, `.primaryChanged` event |
| `Core/Renderers/Displays/PersistedDisplayConfig.swift` | Add primary ID persistence, HDR preference persistence |
| `UI/Session/PlaybackSession.swift` | Observe display events, create/close `ExternalDisplayWindow`, wire targets |

## Files to Create

| File | Purpose |
|---|---|
| `Core/Renderers/Displays/DisplayRenderTarget.swift` | Per-display render target struct |
| `UI/Session/Displays/ExternalDisplayWindow.swift` | Fullscreen window on secondary display |
| `UI/Views/Displays/DisplaySelectorView.swift` | SwiftUI primary display selector |

## Acceptance Criteria

- [ ] Video plays on external display with correct HDR/EDR tone mapping, even if the internal display is SDR
- [ ] No color shift or brightness mismatch between displays
- [ ] Display configuration (primary display, HDR prefs) persists across app restarts
- [ ] User can select primary display via UI
- [ ] Hot-plug: connect/disconnect secondary display during playback without frame drops
- [ ] Primary display disconnect: auto-fallback to remaining display
