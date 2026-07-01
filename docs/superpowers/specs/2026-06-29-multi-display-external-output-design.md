# Multi-Display & External Output Design

**Date:** 2026-06-29
**Status:** Approved
**Branch:** `feat/multi-display-external-output`
**Target:** macOS 14+

## Overview

Extend TitanPlayer with a first-class multi-display and external-output subsystem:

1. **DisplayManager** — single source of truth for connected displays, observes `NSApplicationDidChangeScreenParameters`, exposes stable IDs and per-display configuration.
2. **ExternalDisplayConfig** — persisted per-display knobs (color space override, HDR enablement, refresh-rate target, custom airplay-audio-sync offset). Round-trips through `UserDefaults` keyed by a stable display identifier.
3. **Display-capability forwarding** — when the player's window moves to a new screen, the `MetalRenderer` is reconfigured to that screen's `colorSpace`, `maximumFramesPerSecond`, and EDR ceiling.
4. **AirPlay 2 routing** — a small `AirPlayController` watches `AVPlayer.externalPlaybackActive` and exposes a SwiftUI `AVRoutePickerView` for user output selection. Audio sync is re-aligned whenever external playback toggles.
5. **Hot-plug handling** — connect/disconnect events debounced; if the active screen disappears, the session falls back to `NSScreen.main` without interrupting playback.

The existing `MetadataPassthroughManager` (in `Core/Renderers/MetadataPassthrough.swift`) already detects external displays, so the spec extends the existing infrastructure rather than replacing it.

## Goals & Non-Goals

**Goals**

- Reliable detection of every connected display, including AirPlay receivers surfaced through `AVPlayer.externalPlaybackActive`
- Per-display configuration that survives app restart (UserDefaults)
- Window-move → color-space/HDR/refresh-rate re-config in the same run loop tick (no frame stalls)
- A small, focused public API surface that does not bleed into `PlaybackSession` plumbing
- Tests for the manager, config, and AirPlay controller using mock screens / mock AVPlayer

**Non-Goals (YAGNI)**

- Multiple independent playback windows per display (out of scope; that's "second screen" mode, a separate feature)
- Mac-as-AirPlay-receiver (not possible without system entitlements; we are a sender)
- Rec.2020 / Dolby Vision content negotiation above what `MetadataPassthroughManager` already does (we forward what's already there)
- Per-display EQ or independent volume curves (a downstream feature if the design ever calls for it)
- A custom AirPlay 2 protocol stack (we use `AVRoutePickerView` + `AVPlayer.allowsExternalPlayback`)

## Architecture & Data Flow

```
┌────────────────────────────── DisplayManager ──────────────────────────────┐
│ @Published var displays: [ExternalDisplayConfig]                            │
│ @Published var activeDisplay: ExternalDisplayConfig?                        │
│ Combine publisher: DisplayChangeEvent { connected, disconnected, changed }  │
└──┬────────────────────────┬───────────────────────────┬─────────────────────┘
   │ owns                   │ publishes                 │ owns
   ▼                        ▼                           ▼
┌─────────────────┐  ┌──────────────────────┐  ┌────────────────────┐
│ PersistedConfig │  │ PlaybackSession      │  │ AirPlayController  │
│ (UserDefaults)  │  │  - renderer reconfig │  │  - route detection │
│                 │  │  - full-screen target│  │  - audio sync      │
└─────────────────┘  └──────────────────────┘  └──────────┬─────────┘
                                                          ▼
                                              ┌─────────────────────────┐
                                              │ AVRoutePickerView       │
                                              │ (NSViewRepresentable)   │
                                              └─────────────────────────┘
```

**DisplayManager** observes `NSApplicationDidChangeScreenParameters` and reconciles `NSScreen.screens` with the most recent snapshot. Each screen is converted into an `ExternalDisplayConfig` via `DisplayCapabilityDetector.detectCapabilities(for:)` (reuse). Stable IDs are `CGDirectDisplayID` with a name+resolution fallback (AirPlay receivers do not expose a `CGDirectDisplayID`).

**Active display** is recomputed whenever the session's main window moves. `NSWindow.didChangeScreenNotification` is observed on the window to push the new screen into `PlaybackSession`, which calls `MetalRenderer.updateDisplayCapabilities(synchronouslyFor:)`.

**AirPlayController** wraps `AVPlayer.externalPlaybackActive` via a Combine bridge on `AVPlayer.currentItem?.observe(\.externalMetadata, …)` plus `AVPlayer.observe(\AVPlayer.externalPlaybackActive, options: .new)`. Audio sync is maintained by re-aligning `engine.setAudioDelay` to the offset reported the first time external playback goes active (default 80 ms for AirPlay; user-overridable).

**DisplayRoutePickerView** is an `NSViewRepresentable` over `AVRoutePickerView` with `prioritizesVideoDevices = true` and `routesAreUnavailableHandler` returning false so the menu always opens.

## Components

| Component | File | Public API summary |
|---|---|---|
| `ExternalDisplayConfig` | `Core/Renderers/Displays/ExternalDisplayConfig.swift` | Codable struct: stableID, displayName, colorGamut, colorSpaceName, refreshRate, hdrSupported, lastSeenAt. Round-trips through `PersistedDisplayConfig`. |
| `PersistedDisplayConfig` | `Core/Renderers/Displays/PersistedDisplayConfig.swift` | `[String: ExternalDisplayConfigSnapshot]` backed by `UserDefaults` under `titanplayer.displays.config.v1`; load, save, merge. |
| `DisplayManager` | `UI/Session/Displays/DisplayManager.swift` | `init(notificationCenter: defaults:)`, `displays`, `activeDisplay`, `setActive(screen:)`, `recordWindow(_:)`. |
| `AirPlayController` | `UI/Session/Displays/AirPlayController.swift` | `init(player:)`, `isExternalPlaybackActive` (Combine), `currentAudioDelayOffset`, `reset()`; emits `AirPlayChangeEvent{ started, stopped, route }`. |
| `DisplayRoutePickerView` | `UI/Views/Displays/DisplayRoutePickerView.swift` | `NSViewRepresentable` wrapping `AVRoutePickerView`. |
| `DisplayManagerTests` | `Tests/DisplayManagerTests.swift` | Snapshot reconciliation, hot-plug activation, persistence round-trip. |
| `AirPlayControllerTests` | `Tests/AirPlayControllerTests.swift` | State transitions with mock `AVPlayer`. |
| `ExternalDisplayConfigTests` | `Tests/ExternalDisplayConfigTests.swift` | Codable round-trip. |

### DisplayManager details

- Stable ID rules: prefer `CGDirectDisplayID` cast from `NSScreen.deviceDescription[\"NSScreenNumber\"]`. For screens without that key (AirPlay receivers), build a composite id of `name|frame.size|en`.
- Hot-plug behavior: events are debounced with `DispatchQueue.main` + 250 ms coalesce so a single unplug/replug cycle emits at most one `disconnected` and one `connected`.
- Persistence: on every `displays` mutation, we merge with `PersistedDisplayConfig` so disconnect rewrites preserve the last-seen snapshot (we keep the last config forever — only `lastSeenAt` updates).

### AirPlayController details

- We do NOT observe `AVRoutePickerView`'s internal state; we observe `AVPlayer.externalPlaybackActive` directly so audio re-sync is automatic whether the user picked the route from the route picker, programmatic APIs, or system controls.
- Audio delay default: 0.08 s when external playback begins, reverted to 0 when it stops. The session can override via `setAudioDelayOffset(TimeInterval)`.

### DisplayRoutePickerView details

- Wraps `AVRoutePickerView` in `NSViewRepresentable` with `prioritizesVideoDevices = true`.
- Exposes a SwiftUI `init(pickerTintColor: NSColor)` so the host can match the route icon to the surrounding chrome.

## Integration Touchpoints

| Existing | Where | Change |
|---|---|---|
| `PlaybackSession` | `UI/Session/PlaybackSession.swift:43` | Owns one `DisplayManager` and one `AirPlayController`. Forwards `displayManager.activeDisplay` to `MetalRenderer.updateDisplayCapabilitiesSynchronously(for:)` when it changes. |
| `PlaybackEngine` | `Core/Engine/PlaybackEngine.swift:22` | Exposes `AVPlayer` as `internal` (or via a thin accessor) so `AirPlayController` can observe it without tearing encapsulation. |
| `MetalRenderer` | `Core/Renderers/MetalRenderer.swift:68` | Already calls `updateDisplayCapabilitiesSynchronously(for:)` — DisplayManager's wiring reuses this. |
| `KeyboardShortcutManager` | `UI/Shortcuts/KeyboardShortcutManager.swift` | New `PlayerAction.toggleAirPlayRouting` bound to **⇧⌘A** as the default. (YAGNI: skip if it bloats the dispatch table.) |
| `DisplayCapabilityDetector` | `Core/Renderers/DisplayCapabilities.swift:6` | Reused unchanged for `colorSpace`, `maximumFramesPerSecond`, EDR ceiling. |

## Data Model

```swift
struct ExternalDisplayConfig: Codable, Hashable, Identifiable {
    let stableID: String                 // CGDisplayID-as-string or composite name+size|enum
    let displayName: String              // NSScreen.localizedName or AirPlay receiver name
    let colorSpaceName: String?          // NSColorSpace.localizedName when present
    let colorGamut: ColorGamut           // srgb | displayP3 | bt2020
    let refreshRate: Float               // NSScreen.maximumFramesPerSecond
    let hdrSupported: Bool               // computed from EDR ceiling + gamut
    let maxEDRLuminance: Float           // EDR ceiling in nits
    let lastSeenAt: Date                 // monotonic update when re-detected
    var id: String { stableID }

    var isAirPlayReceiver: Bool {
        !stableID.hasPrefix("cgdid:")    // AirPlay receivers don't expose a CGDirectDisplayID
    }
}
```

`PersistedDisplayConfig` lives at `UserDefaults` key `titanplayer.displays.config.v1`, value = JSON `[String: ExternalDisplayConfig]`. The "v1" suffix lets a future schema bump be detected without polluting production data.

## Error Handling

| Condition | Response |
|---|---|
| `NSScreen.screens` is empty (no displays) | Log + emit `disconnected` event for all known displays; PlaybackSession ignores further reconfiguration until a screen reappears. |
| Stable ID collision after AirPlay receiver joins | Composite id includes `enum` from `CGDisplay` enumeration, namespaced against `airplay:`. |
| `AVPlayer.externalPlaybackActive` toggles mid-playback | `AirPlayController` queues a single audio-delay update on the main actor. No seek; just a buffer repump. |
| Display detects HDR but session reports SDR content | Treat as SDR; do not reallocate render targets. |
| Persistence write fails (UserDefaults full / process sandbox) | Log a warning and continue in-memory. `displays` are still valid for the current run; lost config surfaces in the next launch's `merge` step. |

## Testing

- **ExternalDisplayConfigTests** — Codable decode/encode round-trip on a fixture with NSScreen fields and stable id; `isAirPlayReceiver` predicate.
- **DisplayManagerTests** — feed a custom `DisplayProviding` protocol a list of fake screens; assert hot-plug merge and disconnect-clear behavior; assert persisted merge after a second launch (test injects `UserDefaults(suiteName:)` to scope state).
- **AirPlayControllerTests** — wrap a `MockAVPlayer` whose `externalPlaybackActive` toggles; assert `currentAudioDelayOffset` transitions (0 → 0.08 → 0) and that `setAudioDelayOffset` is sticky.
- All tests skip on environments where `XCTest` is unavailable (matches AGENTS.md CommandLineTools limitation; the test target type-checks through `swift build --build-tests`).

## Out-of-Scope Reminders

- Per-display video windows (would require multiple `AVPlayer` pipelines — separate spec)
- Manually overriding AirPlay 2 audio codec or bitrate
- Persisting AirPlay receiver names (they are ephemeral; we record the last-seen name in `displayName` only for fallback identity)
