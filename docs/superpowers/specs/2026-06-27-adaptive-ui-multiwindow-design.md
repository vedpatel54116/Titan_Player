# Adaptive UI & Multi-Window Design Specification

## Overview

A modern, adaptive user interface for TitanPlayer built on the existing SwiftUI
+ MVVM codebase. Five capabilities are added in this phase:

1. **Auto-hide controls** — timed fade-out of controls during playback (replaces
   the current hover-only behavior), with cursor hiding.
2. **Keyboard shortcuts** — full keyboard navigation with a default binding set,
   editable via `UserDefaults` (no in-app editor).
3. **Adaptive controls** — controls adapt to four playback contexts: idle vs
   loaded, audio-only vs video, HDR vs SDR, subtitle-aware.
4. **Semantic fit-mode** — the video's fit-mode (fit/fill/stretch) is selected
   automatically based on content type, with per-file user override.
5. **Multi-window support** — a floating, always-on-top mini-player that
   mirrors the main playback session, plus independent library-browser windows.

**Target:** macOS 14+ (Sonoma)
**Architecture:** Approach A — shared `PlaybackSession` + `FrameStore` for video
mirroring; one decode path feeding two display targets.

---

## Architecture Overview

### Current State

`TitanPlayerApp` is a single `WindowGroup` hosting `ContentView`.
`PlayerViewModel` is created `@StateObject`-local to `ContentView`, so each
window would get an isolated playback session. The `MetalRenderer` stores a
`pendingFrame` in `render(_:)` but `draw(in:)` is empty (a v1 gap — frames are
not yet submitted to drawables). `MetalMtkView` is an `NSViewRepresentable`
wrapping an `MTKView` whose delegate is the `MetalRenderer`.

### Target State

```
TitanPlayerApp (@StateObject PlaybackSession)
├── WindowGroup "main"          → ContentView (sidebar + PlayerView)
│                                 .environmentObject(session)
├── Window "mini"               → MiniPlayerView (floating, always-on-top)
│                                 .environmentObject(session)
└── WindowGroup "library"       → LibraryWindowView (N independent windows,
    for: URL.self                 each its own LibraryViewModel)
                                 .environmentObject(session)

PlaybackSession (shared, app-level, @MainActor ObservableObject)
├── PlaybackEngine
├── SubtitleManager
├── MetalRenderer (weak ref to FrameStore)
├── FrameStore (latest MTLTexture + frameID)
├── KeyboardShortcutManager
└── all @Published playback state (lifted from PlayerViewModel)

Main window:
  MetalMtkView → MetalRenderer (MTKViewDelegate)
    draw(in:) decodes pendingFrame → toneMappedTexture
             → publishes texture to FrameStore
             → presents to own drawable

Mini window:
  MirrorMTKView → MirrorViewDelegate (MTKViewDelegate)
    draw(in:) reads FrameStore.latestTexture (by frameID compare)
             → blits to own drawable
             → no decode, no re-tone-map
```

---

## Component Design

### PlaybackSession

A new `@MainActor ObservableObject` that lifts `PlayerViewModel` to the
app level. It owns the `PlaybackEngine`, `SubtitleManager`, `MetalRenderer`,
the new `FrameStore`, and a `KeyboardShortcutManager`. All `@Published`
properties currently on `PlayerViewModel` move here, plus new ones for the
adaptive and fit-mode features (listed below).

`PlayerViewModel` is removed. Views switch from
`@ObservedObject var viewModel: PlayerViewModel` to
`@EnvironmentObject var session: PlaybackSession`.
`LibraryViewModel` remains per-library-window (it governs file listing, not
playback).

```swift
@MainActor
final class PlaybackSession: ObservableObject {
    // Existing (lifted from PlayerViewModel)
    @Published var playState: PlaybackState = .idle
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Float = 1.0
    @Published var isMuted: Bool = false
    @Published var mediaInfo: MediaInfo?
    @Published var subtitles: [SubtitleTrack] = []
    @Published var activeSubtitle: SubtitleTrack?
    @Published var currentSubtitleEvents: [SubtitleEvent] = []
    @Published var playbackRate: Float = 1.0
    @Published var audioDelay: TimeInterval = 0
    @Published var renderer: FrameRendering?

    // New — adaptive controls
    @Published var isAudioOnly: Bool = false
    @Published var isHDRContent: Bool = false
    @Published var toneMappingEnabled: Bool = true
    @Published var brightness: Float = 1.0

    // New — subtitle styling
    @Published var subtitleFontSize: Float = 1.0
    @Published var subtitlePosition: SubtitlePosition = .bottom
    @Published var subtitleBackgroundOpacity: Float = 0.6

    // New — semantic fit-mode
    @Published var fitMode: FitMode = .fit
    @Published var fitModeOverride: FitMode? = nil   // nil = use semantic auto

    let frameStore = FrameStore()
    let shortcutManager = KeyboardShortcutManager()

    private let engine: PlaybackEngine
    private let subtitleManager = SubtitleManager()
    // …bindings, openFile, play, pause, seek, etc. lifted from PlayerViewModel
}
```

Computed helpers:
- `var isMediaLoaded: Bool { playState != .idle && playState != .error }`
- `var effectiveFitMode: FitMode { fitModeOverride ?? fitMode }`

### FrameStore

A small, non-`ObservableObject` class owned by `PlaybackSession`. The views
poll it in their `draw(in:)` callbacks — no Combine needed for 60fps frame
data.

```swift
@MainActor
final class FrameStore {
    private(set) var latestTexture: MTLTexture?
    private(set) var frameID: UInt64 = 0

    func update(_ texture: MTLTexture) {
        self.latestTexture = texture
        frameID &+= 1
    }
}
```

Writes occur on the main renderer's `draw(in:)` (main-actor). Reads occur in
the mini's `MirrorViewDelegate.draw(in:)` via a local `lastSeenFrameID`.
`MTLTexture` is safe for concurrent read across command queues when reader
usage is `.shaderRead`; the main renderer's `toneMappedTexture` already has
`usage = [.shaderRead, .shaderWrite]`. No locks required.

### MetalRenderer changes

1. **Fix the empty `draw(in:)`:** it now takes `view.currentDrawable`, consumes
   `pendingFrame`, runs the existing tone-map + render pipeline to produce
   `toneMappedTexture`, publishes that texture to `frameStore.update(...)`,
   then `present(drawable)` + `commit()`.
2. **Weak `frameStore` reference:** set by `PlaybackSession` at construction.
3. **Delegate wiring for HDR detection:** `PlaybackSession` conforms to
   `MetalRendererDelegate` so `renderer(_:didDetectHDRMode:)` sets
   `isHDRContent = (mode != .sdr)`. The delegate callback already exists and
   fires from `updateHDRMode`.

### MirrorMTKView + MirrorViewDelegate

`MirrorMTKView` is a new `NSViewRepresentable` hosting its own `MTKView`
(own drawable, own `preferredFramesPerSecond = 60`), sized small. Its
delegate is a `MirrorViewDelegate: NSObject, MTKViewDelegate` holding a weak
`FrameStore` + the shared `MTLDevice`
(`MTLCreateSystemDefaultDevice()` returns the singleton — no new device) and
its own `MTLCommandQueue` (queues are cheap; avoids cross-queue
serialization).

`draw(in:)`:
1. Compare `frameStore.frameID` to a stored `lastSeenFrameID`. If unchanged,
   blit the cached texture and return (no new work — the view's own frame
   cadence drives redraw).
2. If new: `blitEncoder.copy` from `frameStore.latestTexture` into its own
   drawable, `present`, `commit`. A simple blit — **no** re-tone-map, **no**
   re-decode.
3. If no frame yet (idle/loading): clear to black.

### Window configuration

```swift
@main
struct TitanPlayerApp: App {
    @StateObject private var session = PlaybackSession()

    var body: some Scene {
        WindowGroup("TitanPlayer", id: "main") {
            ContentView()
                .environmentObject(session)
        }
        .commands { TitanCommands(session: session) }

        Window("Mini Player", id: "mini") {
            MiniPlayerView()
                .environmentObject(session)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 320, height: 180)

        WindowGroup("Library", id: "library", for: URL.self) { $folderURL in
            LibraryWindowView(rootFolder: folderURL)
                .environmentObject(session)
        }
    }
}
```

**Mini-player window styling** via an `NSWindowAccessor` helper that walks to
the hosting `NSWindow` and sets:
- `.level = .floating`
- `.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`
- `.isMovable = true`
- `.titleVisibility = .hidden`, `.titlebarAppearsActive = false`

Opening: `Window > Mini Player` menu command → `openWindow(id: "mini")`.

### Lifecycle rules

- **Main window close** → `session.stop()` + release (main is the session
  owner).
- **Mini window close** → no-op on playback; just removes the mirror view.
- **Library window close** → disposes that browser only; playback unaffected.
- Opening a media item from a library window plays it in the shared session;
  main + mini windows reflect it automatically.

---

## Auto-Hide Controls

Replaces the current hover-only behavior in `PlayerView` with a timed
auto-hide:

- A `DispatchWorkItem` 3-second timer. Any mouse move, tap, or keypress in the
  player area calls `revealControls()` which cancels the pending timer and
  schedules a new one; the timer fires `showControls = false` only if
  `playState == .playing`.
- Play state → `.playing`: start the 3s timer.
- Play state → `.paused` / `.idle` / `.error`: cancel timer, force
  `showControls = true` (controls stay visible when not playing).
- **Cursor hiding:** when `showControls == false && playState == .playing`,
  `NSCursor.hide()` is called; otherwise `NSCursor.unhide()`. Scoped to
  `PlayerView` so it affects only the video area, not the whole app.
- The mini-player uses the same timer logic on its own `MiniControlBar`.

---

## Semantic Fit-Mode

`FitMode` is computed once from `MediaInfo` at `load(url:)` time and published.

```swift
enum FitMode: Equatable { case fit, fill, stretch }

func resolveFitMode(for info: MediaInfo) -> FitMode {
    guard let video = info.videoTracks.first else { return .fit }
    let aspect = Double(video.width) / Double(video.height)
    switch aspect {
    case 1.0..<1.4:   return .fit   // 4:3, square → letterbox, never crop
    case 2.3...2.5:   return .fit   // ultrawide/cinematic → preserve
    default:          return .fit   // default safe
    }
}
```

**Policy is intentionally conservative:** nearly everything maps to `.fit` to
avoid surprise cropping. The semantic guarantee is that **4:3 and ultrawide
are explicitly protected from auto-fill** (fill would lose content). A future
heuristic could auto-fill 16:9 on 16:9 screens; we start conservative and
correct.

**Application:** `VideoContentView` (main) and `MirrorMTKView` (mini) apply
`effectiveFitMode` via `.aspectRatio(contentMode: ...)` (`.fit` / `.fill`).
`.stretch` ignores aspect in the `MTKView` layout (rare, menu-only).

**User override:** a `View > Aspect` menu (Fit / Fill / Stretch / Auto). Selecting
"Auto" clears the override (`fitModeOverride = nil`); the others set it. The
override persists in `UserDefaults` keyed by the file URL so reopening
remembers the choice. `effectiveFitMode` returns `fitModeOverride ?? fitMode`.

---

## Adaptive Controls

Four contexts change which controls appear. All are driven by `PlaybackSession`
`@Published` state the views already observe.

### 1. Idle vs loaded

Formalize via `session.isMediaLoaded`. `ControlBar` and `MiniControlBar` gate
on it: when `!isMediaLoaded`, hide seek slider + transport + volume; show only
the open-file affordance. No new state beyond the computed property.

### 2. Audio-only vs video

`@Published var isAudioOnly: Bool`, set at `load(url:)` from `MediaInfo`:
`info.videoTracks.isEmpty && !info.audioTracks.isEmpty`.

When `isAudioOnly == true`:
- `VideoContentView` replaces the Metal view with a new **`AudioOnlyView`**:
  large `Image(systemName: "music.note")` or album-art placeholder, title,
  artist (from metadata if present), big transport. The `MetalMtkView` is not
  attached; the renderer stays nil-safe via the existing `NoOpFrameRenderer`
  path.
- Mini-player shows the same `AudioOnlyView` (smaller) instead of
  `MirrorMTKView`.
- Controls (transport/seek/volume) are identical — audio uses the same engine;
  only the display surface differs.

### 3. HDR vs SDR

`@Published var isHDRContent: Bool`, set when
`MetalRenderer.handleHDR(_:)` is called with a non-`.sdr` `HDRMetadata.type`.
The renderer already classifies HDR10/HLG/DolbyVision; `PlaybackSession`
conforms to `MetalRendererDelegate` and flips `isHDRContent` in
`renderer(_:didDetectHDRMode:)`.

When `isHDRContent == true`, `ControlBar` shows:
- An "HDR" badge (SF Symbol `sparkles` + label).
- A tone-map toggle bound to `@Published var toneMappingEnabled: Bool`
  (default `true`).
- A brightness slider (`@Published var brightness: Float`, 0...1) calling
  `renderer.updateDynamicHDRParams(...)`.

When SDR: badge, toggle, and slider all hidden.

**Mini-player:** HDR badge only (no tone-map controls — too small). Tapping
the badge focuses the main window's inspector.

### 4. Subtitle-aware controls

`session.subtitles` / `session.activeSubtitle` already exist. When
`!subtitles.isEmpty`, `ControlBar` shows the existing subtitle `Menu` **plus**
a subtitle-styling popover:
- Font size `Stepper` → `subtitleFontSize`
- Position `Picker` (top/bottom) → `subtitlePosition`
- Background opacity `Slider` → `subtitleBackgroundOpacity`

These feed `SubtitleOverlay` rendering; user prefs override the per-event
style. When `subtitles.isEmpty`: subtitle button and styling popover hidden.

### Mini-player control bar

`MiniControlBar` is a separate, compact bar: play/pause + seek-back/forward +
time only. It does **not** show volume, subtitle menus, HDR controls, or
subtitle styling — those are main-window-only. Its controls auto-hide on the
same 3s timer.

All adaptive state lives on `PlaybackSession` as `@Published`, so main + mini
stay in sync automatically (both observe the same object).

---

## Keyboard Shortcuts

**Customization model:** default set, editable via `UserDefaults` (no in-app
editor). Users rebind via `defaults write com.titanplayer.TitanPlayer ...`.

### Types

```swift
enum PlayerAction: String, CaseIterable {
    case togglePlayPause, seekForward10, seekBackward10,
         seekForward60, seekBackward60,
         stepFrameForward, stepFrameBackward,
         toggleMute, volumeUp, volumeDown,
         toggleFullscreen, toggleMiniPlayer, newLibraryWindow, openFile,
         setAspectRatioFit, setAspectRatioFill, setAspectRatioStretch,
         toggleSubtitles, toggleHDR,
         increasePlaybackRate, decreasePlaybackRate, resetPlaybackRate
}

struct KeyBinding: Codable, Equatable {
    let action: PlayerAction
    let key: String                    // "space", "f", "j", …
    let modifiers: NSEvent.ModifierFlags
}
```

### KeyboardShortcutManager

`@MainActor`, loads bindings from `UserDefaults` key
`"titanplayer.keybindings"` (JSON `[KeyBinding]`); falls back to
`defaultBindings` if missing or malformed. Exposes:
- `binding(for: PlayerAction) -> KeyBinding?`
- `setBinding(_:for:)` — validates against duplicate `(key, modifiers)` pairs,
  refuses conflicts, persists to `UserDefaults`.

### Default bindings

| Action | Key |
|---|---|
| togglePlayPause | space |
| seekBackward10 | ← |
| seekForward10 | → |
| seekBackward60 | ⌘← |
| seekForward60 | ⌘→ |
| stepFrameForward | . (period) |
| stepFrameBackward | , (comma) |
| volumeUp | ↑ |
| volumeDown | ↓ |
| toggleMute | m |
| toggleFullscreen | ⌘F |
| toggleMiniPlayer | ⌘M |
| newLibraryWindow | ⌘L |
| openFile | ⌘O |
| setAspectRatioFit | ⌥1 |
| setAspectRatioFill | ⌥2 |
| setAspectRatioStretch | ⌥3 |
| toggleSubtitles | v |
| toggleHDR | h |
| increasePlaybackRate | ] |
| decreasePlaybackRate | [ |
| resetPlaybackRate | \\ |

### Wiring

A `KeyListenerView` (`NSViewRepresentable`) is placed via
`.background { KeyListenerView(session: session) }` on `PlayerView` and
`MiniPlayerView`. It hosts an invisible `NSView` that becomes first responder
and overrides `keyDown(with:)`. SwiftUI's `onKeyPress` (macOS 14+) covers most
cases, but `NSEvent` monitoring is the reliable fallback for keys like space
and arrows that SwiftUI sometimes swallows. The listener resolves the event to
a `PlayerAction` via `shortcutManager` and dispatches to `session` methods
(most already exist: `togglePlayPause`, `seekForward`, etc.; a few new:
`stepFrame`, `toggleFullscreen`, `toggleMiniPlayer` → `openWindow(id:)`).

### Menu integration

`TitanCommands` (the `.commands { }` modifier on the main scene) exposes the
same `PlayerAction`s as `CommandMenuButton`s. Each menu item shows its current
key equivalent read from `shortcutManager`, so the displayed equivalent matches
any `UserDefaults` override.

---

## Touch Bar

Included for the shrinking audience of Touch Bar MacBooks. The APIs compile on
macOS 14+ and are inert on hardware without a Touch Bar — `makeTouchBar()` is
only called by the system when the hardware is present, so there is zero cost
on modern Macs.

### TouchBarProvider

An `NSViewRepresentable` attached to `PlayerView` (and a compact variant for
`MiniPlayerView`) overrides `makeTouchBar() -> NSTouchBar?`:

**Main:**
- `NSScrubber` for seek position (bound to `session.currentTime` /
  `session.duration`).
- Transport buttons: play/pause, ±10s.
- Volume slider.
- "Mini" button (opens the mini-player).

**Mini:**
- Transport buttons + time label only.

### State sync

AppKit controls use `bind:` to `PlaybackSession`'s `@Published` properties via
a small `ObservableObject` bridge, or Combine subscriptions updated in
`updateNSView`. Kept minimal — Touch Bar is a nice-to-have; we do not
over-invest.

---

## Error Handling

- **Mini opens before any frame:** `MirrorViewDelegate.draw` clears to black;
  shows first frame when `FrameStore` is populated.
- **Main window closed, mini still open:** session is stopped per the
  lifecycle rule; `FrameStore.latestTexture` retains the last frame — mini
  shows a static last frame (correct: playback ended).
- **Audio-only file loaded in mini:** `AudioOnlyView` shown instead of
  `MirrorMTKView`; no Metal work.
- **Renderer unavailable** (`MTLCreateSystemDefaultDevice() == nil`):
  `MetalRenderer.make()` throws; `PlaybackSession` falls back to
  `NoOpFrameRenderer` as today; video area shows the placeholder, audio still
  plays.
- **Shortcut conflict on `setBinding`:** refused with a thrown error; existing
  binding unchanged.
- **Malformed `UserDefaults` bindings JSON:** manager falls back to
  `defaultBindings`, logs a warning.

---

## Testing Strategy

### Unit tests

- `FrameStore`: `frameID` monotonic increase; `latestTexture` updated on
  write; concurrent read during write does not crash.
- `KeyboardShortcutManager`: load defaults when `UserDefaults` empty; load
  custom bindings; reject malformed JSON → fallback; reject duplicate
  `(key, modifiers)` on `setBinding`; round-trip encode/decode `KeyBinding`.
- `PlaybackSession.resolveFitMode`: 4:3 → `.fit`; ultrawide → `.fit`; square
  → `.fit`; default → `.fit`; audio-only (no video track) → `.fit`.
- `PlaybackSession.isAudioOnly` / `isHDRContent`: set correctly from
  `MediaInfo` / `HDRMetadata`.
- `effectiveFitMode`: override takes precedence; nil returns semantic default.

### Integration tests

- Load a video file → `isMediaLoaded` true, `fitMode` set, controls visible.
- Load an audio file → `isAudioOnly` true, `AudioOnlyView` shown.
- Play → after 3s, `showControls` false (simulated via timer injection).
- HDR content → `isHDRContent` true, tone-map controls present.

### Manual verification

- Mini-player opens floating, always-on-top; video mirrors the main window in
  real time; closing mini does not stop playback; closing main stops
  playback.
- Keyboard shortcuts: each default binding triggers the correct action; a
  `defaults write` override is respected after relaunch.
- Touch Bar: on supported hardware, controls appear and reflect playback
  state; on unsupported hardware, no effect.

---

## Validation Criteria

- [ ] Controls auto-hide after 3s during playback; cursor hides with them
- [ ] Controls remain visible when paused, idle, or error
- [ ] Keyboard shortcuts function as expected; overrides via `UserDefaults`
      persist
- [ ] Mini-player mirrors the main video in real time (one decode, two
      displays)
- [ ] Mini-player is floating and always-on-top; closing it does not stop
      playback
- [ ] Independent library windows can be spawned and close without affecting
      playback
- [ ] UI adapts: idle vs loaded, audio-only vs video, HDR vs SDR,
      subtitle-aware
- [ ] Fit-mode auto-selects conservatively; 4:3 and ultrawide never auto-fill;
      user override persists per-file
- [ ] Touch Bar controls work on supported hardware; inert elsewhere
- [ ] UI adapts to different screen sizes (main window resizable; mini
      fixed-size)
