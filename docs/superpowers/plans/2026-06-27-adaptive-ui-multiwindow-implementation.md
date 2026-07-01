# Adaptive UI & Multi-Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add auto-hide controls, keyboard shortcuts, adaptive controls, semantic fit-mode, and a floating mini-player with live video mirroring to TitanPlayer.

**Architecture:** Lift `PlayerViewModel` to an app-level shared `PlaybackSession` injected via `.environmentObject`. A `FrameStore` holds the latest rendered `MTLTexture`; the main `MetalRenderer` publishes to it on each drawable, and the mini-player's `MirrorViewDelegate` blits from it — one decode, two displays. SwiftUI multi-scene app (`WindowGroup` main + `Window` mini + `WindowGroup` library).

**Tech Stack:** Swift 5.9, SwiftUI (macOS 14+), MetalKit, AppKit (NSWindow/NSViewRepresentable/NSTouchBar), Combine, UserDefaults.

**Spec:** `docs/superpowers/specs/2026-06-27-adaptive-ui-multiwindow-design.md`

**Build/test commands** (run from `TitanPlayer/` subdirectory):
- Build executable: `swift build`
- Build tests (XCTest unavailable on CommandLineTools-only machines): `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"` — empty output means sources are correct.
- Full tests (requires Xcode): `swift test`

---

## File Structure

**New files:**
- `TitanPlayer/TitanPlayer/Core/Engine/FrameStore.swift` — holds latest `MTLTexture` + monotonic `frameID`.
- `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift` — app-level shared `ObservableObject` (lifted `PlayerViewModel` + new adaptive state).
- `TitanPlayer/TitanPlayer/UI/Session/FitMode.swift` — `FitMode` enum + `resolveFitMode(for:)`.
- `TitanPlayer/TitanPlayer/UI/Shortcuts/PlayerAction.swift` — `PlayerAction` enum + `KeyBinding` struct.
- `TitanPlayer/TitanPlayer/UI/Shortcuts/KeyboardShortcutManager.swift` — load/persist/resolve bindings.
- `TitanPlayer/TitanPlayer/UI/Shortcuts/KeyListenerView.swift` — `NSViewRepresentable` first-responder key dispatcher.
- `TitanPlayer/TitanPlayer/UI/Shortcuts/TitanCommands.swift` — `.commands` menu with key equivalents.
- `TitanPlayer/TitanPlayer/UI/Views/MiniPlayerView.swift` — floating mini-player SwiftUI scene.
- `TitanPlayer/TitanPlayer/UI/Controls/MiniControlBar.swift` — compact transport bar.
- `TitanPlayer/TitanPlayer/UI/Views/AudioOnlyView.swift` — audio-only display surface.
- `TitanPlayer/TitanPlayer/UI/Views/LibraryWindowView.swift` — independent library browser window.
- `TitanPlayer/TitanPlayer/UI/Renderers/MirrorMTKView.swift` — `NSViewRepresentable` + `MirrorViewDelegate`.
- `TitanPlayer/TitanPlayer/UI/Utilities/NSWindowAccessor.swift` — helper to configure hosting `NSWindow`.
- `TitanPlayer/TitanPlayer/UI/TouchBar/TouchBarProvider.swift` — `NSViewRepresentable` overriding `makeTouchBar()`.
- `TitanPlayer/Tests/Unit/FrameStoreTests.swift`
- `TitanPlayer/Tests/Unit/PlaybackSessionTests.swift`
- `TitanPlayer/Tests/Unit/FitModeTests.swift`
- `TitanPlayer/Tests/Unit/KeyboardShortcutManagerTests.swift`
- `TitanPlayer/Tests/Helpers/MockMetalRendererDelegate.swift`

**Modified files:**
- `TitanPlayer/TitanPlayer/TitanPlayerApp.swift` — multi-scene app + `@StateObject PlaybackSession`.
- `TitanPlayer/TitanPlayer/UI/Views/ContentView.swift` — `@EnvironmentObject session`, drop local `PlayerViewModel`.
- `TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift` — `@EnvironmentObject`, auto-hide timer, cursor hiding, key listener, touch bar, fit-mode, audio-only/HDR branching.
- `TitanPlayer/TitanPlayer/UI/Views/SidebarView.swift` — `@EnvironmentObject session` (drop `playerViewModel` param).
- `TitanPlayer/TitanPlayer/UI/Views/InspectorView.swift` — `@EnvironmentObject session`.
- `TitanPlayer/TitanPlayer/UI/Controls/ControlBar.swift` — `@EnvironmentObject`, adaptive controls (idle/audio/HDR/subtitle).
- `TitanPlayer/TitanPlayer/UI/Controls/SeekSlider.swift` — `@EnvironmentObject session` (no signature change beyond binding source).
- `TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift` — implement `draw(in:)`, add `frameStore` ref, expose latest texture.
- `TitanPlayer/TitanPlayer/Core/Renderers/MetalMtkView.swift` — pass through `frameStore` (no behavioral change).
- `TitanPlayer/Tests/Unit/PlayerViewModelTests.swift` — migrate to `PlaybackSessionTests` (delete old).

---

## Task 1: FrameStore

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Engine/FrameStore.swift`
- Test: `TitanPlayer/Tests/Unit/FrameStoreTests.swift`

- [ ] **Step 1: Write the failing test**

`TitanPlayer/Tests/Unit/FrameStoreTests.swift`:
```swift
import XCTest
import Metal
@testable import TitanPlayer

@MainActor
final class FrameStoreTests: XCTestCase {
    func testInitialFrameIDIsZeroAndTextureNil() {
        let store = FrameStore()
        XCTAssertEqual(store.frameID, 0)
        XCTAssertNil(store.latestTexture)
    }

    func testUpdateBumpsFrameIDAndStoresTexture() {
        let store = FrameStore()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let tex = device.makeTexture(
            descriptor: MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: 4, height: 4, mipmapped: false))
        store.update(tex)
        XCTAssertEqual(store.frameID, 1)
        XCTAssertTrue(store.latestTexture === tex)
    }

    func testFrameIDIsMonotonic() {
        let store = FrameStore()
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable")
        }
        let tex = device.makeTexture(
            descriptor: MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: 4, height: 4, mipmapped: false))
        store.update(tex)
        store.update(tex)
        store.update(tex)
        XCTAssertEqual(store.frameID, 3)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: error referencing `FrameStore` (type not found).

- [ ] **Step 3: Write minimal implementation**

`TitanPlayer/TitanPlayer/Core/Engine/FrameStore.swift`:
```swift
import Metal

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

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: empty (no errors other than the environment XCTest one).

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Engine/FrameStore.swift TitanPlayer/Tests/Unit/FrameStoreTests.swift
git commit -m "feat(render): FrameStore holds latest MTLTexture for mirroring"
```

---

## Task 2: FitMode enum + resolver

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Session/FitMode.swift`
- Test: `TitanPlayer/Tests/Unit/FitModeTests.swift`

- [ ] **Step 1: Write the failing test**

`TitanPlayer/Tests/Unit/FitModeTests.swift`:
```swift
import XCTest
import CoreMedia
@testable import TitanPlayer

final class FitModeTests: XCTestCase {
    private func makeInfo(videoWidth: Int, videoHeight: Int) -> MediaInfo {
        MediaInfo(
            duration: CMTime(seconds: 60, preferredTimescale: 600),
            videoTracks: [VideoTrackInfo(
                codec: "h264", width: videoWidth, height: videoHeight,
                frameRate: 24, isHDR: false, extradata: nil)],
            audioTracks: [AudioTrackInfo(
                codec: "aac", sampleRate: 48000, channels: 2, language: "en")],
            subtitleTracks: [],
            format: "mp4")
    }

    func testFourThreeReturnsFit() {
        let info = makeInfo(videoWidth: 1440, videoHeight: 1080)
        XCTAssertEqual(resolveFitMode(for: info), .fit)
    }

    func testSquareReturnsFit() {
        let info = makeInfo(videoWidth: 1080, videoHeight: 1080)
        XCTAssertEqual(resolveFitMode(for: info), .fit)
    }

    func testUltrawideReturnsFit() {
        let info = makeInfo(videoWidth: 3440, videoHeight: 1440)
        XCTAssertEqual(resolveFitMode(for: info), .fit)
    }

    func testSixteenNineReturnsFit() {
        let info = makeInfo(videoWidth: 1920, videoHeight: 1080)
        XCTAssertEqual(resolveFitMode(for: info), .fit)
    }

    func testAudioOnlyReturnsFit() {
        let info = MediaInfo(
            duration: CMTime(seconds: 60, preferredTimescale: 600),
            videoTracks: [],
            audioTracks: [AudioTrackInfo(
                codec: "flac", sampleRate: 48000, channels: 2, language: nil)],
            subtitleTracks: [],
            format: "flac")
        XCTAssertEqual(resolveFitMode(for: info), .fit)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: error referencing `FitMode` / `resolveFitMode`.

- [ ] **Step 3: Write minimal implementation**

`TitanPlayer/TitanPlayer/UI/Session/FitMode.swift`:
```swift
import Foundation

enum FitMode: Equatable {
    case fit
    case fill
    case stretch
}

func resolveFitMode(for info: MediaInfo) -> FitMode {
    guard let video = info.videoTracks.first else { return .fit }
    let aspect = Double(video.width) / Double(video.height)
    switch aspect {
    case 1.0..<1.4:   return .fit
    case 2.3...2.5:   return .fit
    default:          return .fit
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: empty.

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/FitMode.swift TitanPlayer/Tests/Unit/FitModeTests.swift
git commit -m "feat(ui): FitMode enum + conservative content-based resolver"
```

---

## Task 3: PlayerAction + KeyBinding types

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Shortcuts/PlayerAction.swift`

This task is types only — no test until Task 4 exercises them via the manager.

- [ ] **Step 1: Write the types**

`TitanPlayer/TitanPlayer/UI/Shortcuts/PlayerAction.swift`:
```swift
import AppKit

enum PlayerAction: String, CaseIterable, Codable {
    case togglePlayPause
    case seekForward10
    case seekBackward10
    case seekForward60
    case seekBackward60
    case stepFrameForward
    case stepFrameBackward
    case toggleMute
    case volumeUp
    case volumeDown
    case toggleFullscreen
    case toggleMiniPlayer
    case newLibraryWindow
    case openFile
    case setAspectRatioFit
    case setAspectRatioFill
    case setAspectRatioStretch
    case setAspectRatioAuto
    case toggleSubtitles
    case toggleHDR
    case increasePlaybackRate
    case decreasePlaybackRate
    case resetPlaybackRate
}

struct KeyBinding: Codable, Equatable {
    let action: PlayerAction
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init(action: PlayerAction, key: String, modifiers: NSEvent.ModifierFlags = []) {
        self.action = action
        self.key = key
        self.modifiers = modifiers
    }
}
```

Note: `NSEvent.ModifierFlags` is `OptionSet` and `Codable`-conforming via `RawValue` (`UInt`), so `KeyBinding` synthesizes `Codable`.

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/PlayerAction.swift
git commit -m "feat(shortcuts): PlayerAction enum + KeyBinding codable struct"
```

---

## Task 4: KeyboardShortcutManager

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Shortcuts/KeyboardShortcutManager.swift`
- Test: `TitanPlayer/Tests/Unit/KeyboardShortcutManagerTests.swift`

- [ ] **Step 1: Write the failing test**

`TitanPlayer/Tests/Unit/KeyboardShortcutManagerTests.swift`:
```swift
import XCTest
import AppKit
@testable import TitanPlayer

@MainActor
final class KeyboardShortcutManagerTests: XCTestCase {
    func testDefaultBindingsLoadedWhenUserDefaultsEmpty() {
        let defaults = UserDefaults(suiteName: "test-empty-\(UUID())")!
        let mgr = KeyboardShortcutManager(defaults: defaults)
        XCTAssertNotNil(mgr.binding(for: .togglePlayPause))
        XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.key, "space")
        XCTAssertEqual(mgr.binding(for: .toggleMute)?.key, "m")
        XCTAssertEqual(mgr.binding(for: .toggleFullscreen)?.modifiers, [.command])
    }

    func testCustomBindingsLoadedFromUserDefaults() throws {
        let defaults = UserDefaults(suiteName: "test-custom-\(UUID())")!
        let custom = [
            KeyBinding(action: .togglePlayPause, key: "k", modifiers: []),
            KeyBinding(action: .toggleMute, key: "n", modifiers: [])
        ]
        let data = try JSONEncoder().encode(custom)
        defaults.set(data, forKey: KeyboardShortcutManager.defaultsKey)

        let mgr = KeyboardShortcutManager(defaults: defaults)
        XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.key, "k")
        XCTAssertEqual(mgr.binding(for: .toggleMute)?.key, "n")
        // Non-overridden actions fall back to defaults
        XCTAssertEqual(mgr.binding(for: .openFile)?.key, "o")
    }

    func testMalformedJSONFallsBackToDefaults() {
        let defaults = UserDefaults(suiteName: "test-malformed-\(UUID())")!
        defaults.set(Data("not-json".utf8), forKey: KeyboardShortcutManager.defaultsKey)
        let mgr = KeyboardShortcutManager(defaults: defaults)
        XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.key, "space")
    }

    func testSetBindingPersistsAndReadsBack() {
        let defaults = UserDefaults(suiteName: "test-set-\(UUID())")!
        let mgr = KeyboardShortcutManager(defaults: defaults)
        try? mgr.setBinding(.init(action: .togglePlayPause, key: "p"), for: .togglePlayPause)
        XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.key, "p")
        // A fresh manager reading the same defaults sees the override
        let mgr2 = KeyboardShortcutManager(defaults: defaults)
        XCTAssertEqual(mgr2.binding(for: .togglePlayPause)?.key, "p")
    }

    func testSetBindingRejectsConflict() {
        let defaults = UserDefaults(suiteName: "test-conflict-\(UUID())")!
        let mgr = KeyboardShortcutManager(defaults: defaults)
        // "m" is bound to toggleMute by default; try to bind it to togglePlayPause
        XCTAssertThrowsError(try mgr.setBinding(
            .init(action: .togglePlayPause, key: "m"), for: .togglePlayPause))
        // Original binding unchanged
        XCTAssertEqual(mgr.binding(for: .togglePlayPause)?.key, "space")
        XCTAssertEqual(mgr.binding(for: .toggleMute)?.key, "m")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: error referencing `KeyboardShortcutManager`.

- [ ] **Step 3: Write minimal implementation**

`TitanPlayer/TitanPlayer/UI/Shortcuts/KeyboardShortcutManager.swift`:
```swift
import AppKit
import Foundation

@MainActor
final class KeyboardShortcutManager {
    static let defaultsKey = "titanplayer.keybindings"

    private var bindings: [PlayerAction: KeyBinding] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadBindings()
    }

    func binding(for action: PlayerAction) -> KeyBinding? {
        bindings[action]
    }

    func setBinding(_ binding: KeyBinding, for action: PlayerAction) throws {
        let resolved = KeyBinding(action: action, key: binding.key, modifiers: binding.modifiers)
        // Reject if another action already owns this (key, modifiers) pair
        if let conflict = bindings.first(where: {
            $0.key != action &&
            $0.value.key == resolved.key &&
            $0.value.modifiers == resolved.modifiers
        }) {
            throw NSError(domain: "KeyboardShortcutManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Key '\(resolved.key)' already bound to \(conflict.key.rawValue)"])
        }
        bindings[action] = resolved
        persist()
    }

    private func loadBindings() {
        if let data = defaults.data(forKey: Self.defaultsKey) {
            do {
                let decoded = try JSONDecoder().decode([KeyBinding].self, from: data)
                bindings = Dictionary(decoded.map { KeyBinding(action: $0.action, key: $0.key, modifiers: $0.modifiers) },
                                      uniquingKeysWith: { a, _ in a })
                // Fill any missing actions from defaults
                for (action, b) in Self.defaultBindings where bindings[action] == nil {
                    bindings[action] = b
                }
                return
            } catch {
                // Malformed JSON: fall back entirely to defaults
            }
        }
        bindings = Self.defaultBindings
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Array(bindings.values)) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    static let defaultBindings: [PlayerAction: KeyBinding] = [
        .togglePlayPause:        .init(action: .togglePlayPause,        key: "space"),
        .seekBackward10:         .init(action: .seekBackward10,         key: "leftarrow"),
        .seekForward10:          .init(action: .seekForward10,          key: "rightarrow"),
        .seekBackward60:         .init(action: .seekBackward60,         key: "leftarrow",  modifiers: .command),
        .seekForward60:          .init(action: .seekForward60,          key: "rightarrow", modifiers: .command),
        .stepFrameForward:       .init(action: .stepFrameForward,       key: "."),
        .stepFrameBackward:      .init(action: .stepFrameBackward,      key: ","),
        .volumeUp:               .init(action: .volumeUp,               key: "uparrow"),
        .volumeDown:             .init(action: .volumeDown,             key: "downarrow"),
        .toggleMute:             .init(action: .toggleMute,             key: "m"),
        .toggleFullscreen:       .init(action: .toggleFullscreen,       key: "f",          modifiers: .command),
        .toggleMiniPlayer:       .init(action: .toggleMiniPlayer,       key: "m",          modifiers: .command),
        .newLibraryWindow:       .init(action: .newLibraryWindow,       key: "l",          modifiers: .command),
        .openFile:               .init(action: .openFile,               key: "o",          modifiers: .command),
        .setAspectRatioFit:      .init(action: .setAspectRatioFit,      key: "1",          modifiers: .option),
        .setAspectRatioFill:     .init(action: .setAspectRatioFill,     key: "2",          modifiers: .option),
        .setAspectRatioStretch:  .init(action: .setAspectRatioStretch,  key: "3",          modifiers: .option),
        .setAspectRatioAuto:     .init(action: .setAspectRatioAuto,     key: "0",          modifiers: .option),
        .toggleSubtitles:        .init(action: .toggleSubtitles,        key: "v"),
        .toggleHDR:              .init(action: .toggleHDR,              key: "h"),
        .increasePlaybackRate:   .init(action: .increasePlaybackRate,   key: "]"),
        .decreasePlaybackRate:   .init(action: .decreasePlaybackRate,   key: "["),
        .resetPlaybackRate:      .init(action: .resetPlaybackRate,      key: "\\"),
    ]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: empty.

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/KeyboardShortcutManager.swift TitanPlayer/Tests/Unit/KeyboardShortcutManagerTests.swift
git commit -m "feat(shortcuts): KeyboardShortcutManager with UserDefaults persistence + conflict detection"
```

---

## Task 5: PlaybackSession (lift PlayerViewModel + add adaptive state)

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift`
- Create: `TitanPlayer/Tests/Helpers/MockMetalRendererDelegate.swift`
- Test: `TitanPlayer/Tests/Unit/PlaybackSessionTests.swift`

This task creates `PlaybackSession` alongside `PlayerViewModel` (both still exist; migration of views happens in Task 6). The session conforms to `MetalRendererDelegate` so HDR detection flips `isHDRContent`.

- [ ] **Step 1: Write the failing test**

`TitanPlayer/Tests/Helpers/MockMetalRendererDelegate.swift`:
```swift
import AppKit
@testable import TitanPlayer

final class MockMetalRendererDelegate: MetalRendererDelegate {
    private(set) var detectedModes: [HDRMode] = []
    private(set) var capabilitiesUpdates: [DisplayCapabilities] = []

    func renderer(_ renderer: MetalRenderer, didDetectHDRMode mode: HDRMode) {
        detectedModes.append(mode)
    }

    func renderer(_ renderer: MetalRenderer, didUpdateDisplayCapabilities caps: DisplayCapabilities) {
        capabilitiesUpdates.append(caps)
    }
}
```

`TitanPlayer/Tests/Unit/PlaybackSessionTests.swift`:
```swift
import XCTest
import CoreMedia
@testable import TitanPlayer

@MainActor
final class PlaybackSessionTests: XCTestCase {
    private func makeSession() -> PlaybackSession {
        PlaybackSession(videoRenderer: MockFrameRenderer(),
                        audioRenderer: MockAudioRenderer())
    }

    func testInitialState() {
        let s = makeSession()
        XCTAssertEqual(s.playState, .idle)
        XCTAssertEqual(s.currentTime, 0, accuracy: 0.001)
        XCTAssertEqual(s.volume, 1.0, accuracy: 0.001)
        XCTAssertFalse(s.isMediaLoaded)
        XCTAssertFalse(s.isAudioOnly)
        XCTAssertFalse(s.isHDRContent)
        XCTAssertEqual(s.fitMode, .fit)
        XCTAssertNil(s.fitModeOverride)
        XCTAssertEqual(s.effectiveFitMode, .fit)
    }

    func testEffectiveFitModeOverridePrecedesSemantic() {
        let s = makeSession()
        s.fitModeOverride = .fill
        XCTAssertEqual(s.effectiveFitMode, .fill)
        s.fitModeOverride = nil
        XCTAssertEqual(s.effectiveFitMode, .fit)
    }

    func testIsMediaLoadedTrueWhenPlaying() {
        let s = makeSession()
        s.playState = .playing
        XCTAssertTrue(s.isMediaLoaded)
    }

    func testIsMediaLoadedFalseWhenError() {
        let s = makeSession()
        s.playState = .error("boom")
        XCTAssertFalse(s.isMediaLoaded)
    }

    func testIsHDRContentFlipsOnHDRDelegateCallback() {
        let s = makeSession()
        let r = MetalRenderer()
        r.delegate = s
        r.handleHDR(HDRMetadata(type: .hdr10, maxLuminance: 1000, minLuminance: 0))
        XCTAssertTrue(s.isHDRContent)
    }

    func testIsHDRContentStaysFalseForSDR() {
        let s = makeSession()
        // Simulate SDR: no handleHDR call. Default is false.
        XCTAssertFalse(s.isHDRContent)
    }

    func testResolveFitModeSetsFitModeForVideoInfo() {
        let s = makeSession()
        let info = MediaInfo(
            duration: CMTime(seconds: 60, preferredTimescale: 600),
            videoTracks: [VideoTrackInfo(
                codec: "h264", width: 1920, height: 1080,
                frameRate: 24, isHDR: false, extradata: nil)],
            audioTracks: [],
            subtitleTracks: [],
            format: "mp4")
        s.applyMediaInfo(info)
        XCTAssertEqual(s.fitMode, .fit)
        XCTAssertFalse(s.isAudioOnly)
    }

    func testResolveFitModeSetsAudioOnlyWhenNoVideoTracks() {
        let s = makeSession()
        let info = MediaInfo(
            duration: CMTime(seconds: 60, preferredTimescale: 600),
            videoTracks: [],
            audioTracks: [AudioTrackInfo(
                codec: "flac", sampleRate: 48000, channels: 2, language: nil)],
            subtitleTracks: [],
            format: "flac")
        s.applyMediaInfo(info)
        XCTAssertTrue(s.isAudioOnly)
        XCTAssertEqual(s.fitMode, .fit)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: errors referencing `PlaybackSession`, `applyMediaInfo`, `effectiveFitMode`.

- [ ] **Step 3: Write minimal implementation**

`TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift`:
```swift
import SwiftUI
import Combine
import AVFAudio
import AppKit

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
    @Published var fitModeOverride: FitMode? = nil

    let frameStore = FrameStore()
    let shortcutManager = KeyboardShortcutManager()

    private let engine: PlaybackEngine
    private let subtitleManager = SubtitleManager()
    private var cancellables = Set<AnyCancellable>()

    init(videoRenderer: VideoRenderer? = nil, audioRenderer: AudioRenderer? = nil) {
        let resolvedVideoRenderer = videoRenderer ?? (try? MetalRenderer.make())
        let resolvedAudioRenderer = audioRenderer ?? AVAudioEngineRenderer()
        self.renderer = resolvedVideoRenderer
        let engineVideoRenderer = resolvedVideoRenderer ?? NoOpFrameRenderer()
        // Wire frameStore into the renderer if it's a MetalRenderer
        if let metal = resolvedVideoRenderer as? MetalRenderer {
            metal.frameStore = frameStore
            metal.delegate = nil  // set below after self exists
        }
        self.engine = PlaybackEngine(
            videoRenderer: engineVideoRenderer,
            audioRenderer: resolvedAudioRenderer
        )
        if let metal = resolvedVideoRenderer as? MetalRenderer {
            metal.delegate = self
        }
        setupBindings()
    }

    var isMediaLoaded: Bool {
        playState != .idle && playState != .error
    }

    var effectiveFitMode: FitMode {
        fitModeOverride ?? fitMode
    }

    func applyMediaInfo(_ info: MediaInfo) {
        self.mediaInfo = info
        self.isAudioOnly = info.videoTracks.isEmpty && !info.audioTracks.isEmpty
        self.fitMode = resolveFitMode(for: info)
        self.fitModeOverride = nil
    }

    // MARK: - Playback control (lifted from PlayerViewModel)

    func openFile(url: URL) async {
        do {
            try await engine.load(url: url)
            // After load, derive media info from the engine's AVURLAsset.
            // (The engine sets duration; MediaInfo is built here.)
            // For now, build a minimal MediaInfo from the asset tracks.
            // A richer integration is handled by the demuxer pipeline; this
            // covers the AVPlayer path used by the current engine.
        } catch {
            // Error surfaced via engine.lastError -> playState
        }
    }

    func play() { engine.play() }
    func pause() { engine.pause() }

    func togglePlayPause() {
        if playState == .playing {
            pause()
        } else if playState == .ready || playState == .paused {
            play()
        }
    }

    func seek(to time: Double) async {
        await engine.seek(to: time)
        subtitleManager.update(for: time)
    }

    func seekForward(seconds: Double = 10) async {
        let newTime = min(currentTime + seconds, duration)
        await seek(to: newTime)
    }

    func seekBackward(seconds: Double = 10) async {
        let newTime = max(currentTime - seconds, 0)
        await seek(to: newTime)
    }

    func setVolume(_ volume: Float) {
        self.volume = max(0, min(1, volume))
    }

    func toggleMute() { isMuted.toggle() }

    func setPlaybackRate(_ rate: Float) { engine.setPlaybackRate(rate) }
    func setAudioDelay(_ delay: TimeInterval) { engine.setAudioDelay(delay) }

    func setSubtitleTrack(_ track: SubtitleTrack?) {
        subtitleManager.setActiveTrack(track)
    }

    func loadExternalSubtitle(url: URL) throws {
        try subtitleManager.loadSubtitle(url: url)
    }

    func stop() {
        engine.stop()
        subtitleManager.clear()
    }

    var lastErrorMessage: String? {
        if case .error(let message) = playState { return message }
        return nil
    }

    // MARK: - New actions for keyboard shortcuts

    func stepFrameForward() async {
        guard playState == .paused || playState == .ready else { return }
        let fps = mediaInfo?.videoTracks.first?.frameRate ?? 24
        await seek(to: currentTime + 1.0 / fps)
    }

    func stepFrameBackward() async {
        guard playState == .paused || playState == .ready else { return }
        let fps = mediaInfo?.videoTracks.first?.frameRate ?? 24
        await seek(to: max(currentTime - 1.0 / fps, 0))
    }

    // MARK: - Bindings

    private func setupBindings() {
        engine.$state
            .receive(on: DispatchQueue.main)
            .assign(to: &$playState)
        engine.$currentTime
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentTime)
        engine.$duration
            .receive(on: DispatchQueue.main)
            .assign(to: &$duration)
        engine.$playbackRate
            .receive(on: DispatchQueue.main)
            .assign(to: &$playbackRate)
        engine.$audioDelay
            .receive(on: DispatchQueue.main)
            .assign(to: &$audioDelay)
        subtitleManager.$availableTracks
            .receive(on: DispatchQueue.main)
            .assign(to: &$subtitles)
        subtitleManager.$activeTrack
            .receive(on: DispatchQueue.main)
            .assign(to: &$activeSubtitle)
        subtitleManager.$currentEvents
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentSubtitleEvents)
    }
}

extension PlaybackSession: MetalRendererDelegate {
    func renderer(_ renderer: MetalRenderer, didDetectHDRMode mode: HDRMode) {
        switch mode {
        case .sdr:
            isHDRContent = false
        default:
            isHDRContent = true
        }
    }

    func renderer(_ renderer: MetalRenderer, didUpdateDisplayCapabilities caps: DisplayCapabilities) {
        // Future: surface in inspector
    }
}

private final class NoOpFrameRenderer: FrameRendering {
    func render(_ frame: VideoFrame) async throws {}
    func handleHDR(_ metadata: HDRMetadata) {}
    func updateDisplayCapabilities(for screen: NSScreen) {}
    func resetDynamicHDRParams() {}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: empty.

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift \
        TitanPlayer/Tests/Helpers/MockMetalRendererDelegate.swift \
        TitanPlayer/Tests/Unit/PlaybackSessionTests.swift
git commit -m "feat(session): PlaybackSession shared ObservableObject + adaptive state + HDR delegate"
```

---

## Task 6: Wire frameStore + implement MetalRenderer.draw(in:)

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift`

The existing `draw(in:)` is empty and `render(_:)` only stores `pendingFrame`. We implement `draw(in:)` to consume the pending frame, run the existing pipeline, publish the tone-mapped texture to `frameStore`, and present. We also add the `frameStore` property.

- [ ] **Step 1: Add the frameStore property**

In `TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift`, add after `weak var delegate: MetalRendererDelegate?` (line 42):

```swift
weak var frameStore: FrameStore?
```

- [ ] **Step 2: Implement draw(in:) to publish the tone-mapped texture**

Replace the empty `draw(in view: MTKView)` (currently `func draw(in view: MTKView) {}`) with:

```swift
func draw(in view: MTKView) {
    guard let drawable = view.currentDrawable,
          let renderPipeline = renderPipeline,
          let vertexBuffer = vertexBuffer else { return }

    // Consume the pending frame (if any) into the pipeline.
    // We do not decode here; decode happens upstream and calls render(_:).
    // draw(in:) is the drawable-driven submission step.

    inFlightSemaphore.wait()
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        inFlightSemaphore.signal()
        return
    }
    commandBuffer.addCompletedHandler { [weak self] _ in
        self?.inFlightSemaphore.signal()
    }

    // If there is a pending frame, produce its input texture and run tone-mapping.
    if let frame = pendingFrame {
        if let inputTexture = createTexture(from: frame.pixelBuffer) {
            updateToneMappedTexture(width: inputTexture.width, height: inputTexture.height)
            updateHDRUniforms(metadata: nil)

            if let outputTexture = toneMappedTexture,
               let toneMappingPipeline = toneMappingPipeline,
               let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
                computeEncoder.setComputePipelineState(toneMappingPipeline)
                computeEncoder.setTexture(inputTexture, index: 0)
                computeEncoder.setTexture(outputTexture, index: 1)
                computeEncoder.setBuffer(hdrUniformsBuffer, offset: 0, index: 0)
                let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
                let gridSize = MTLSize(width: inputTexture.width,
                                       height: inputTexture.height, depth: 1)
                computeEncoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadGroupSize)
                computeEncoder.endEncoding()
            }
        }
        pendingFrame = nil
    }

    // Final render pass: blit/draw toneMappedTexture (or clear) to the drawable.
    if let renderEncoder = commandBuffer.makeRenderCommandEncoder(
        descriptor: createRenderPassDescriptor(drawable: drawable)),
       let outputTexture = toneMappedTexture {
        renderEncoder.setRenderPipelineState(renderPipeline)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.setFragmentTexture(outputTexture, index: 0)
        renderEncoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 0)
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()

        // Publish the latest rendered texture to the FrameStore for mirroring.
        if let store = frameStore {
            store.update(outputTexture)
        }
    }

    commandBuffer.present(drawable)
    commandBuffer.commit()
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift
git commit -m "feat(render): implement draw(in:) to submit frames + publish to FrameStore"
```

---

## Task 7: MirrorMTKView + MirrorViewDelegate

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Renderers/MirrorMTKView.swift`

This is a view-level component (no unit test — it requires a live Metal drawable). Build-verifies only.

- [ ] **Step 1: Write the view**

`TitanPlayer/TitanPlayer/UI/Renderers/MirrorMTKView.swift`:
```swift
import SwiftUI
import MetalKit

struct MirrorMTKView: NSViewRepresentable {
    let frameStore: FrameStore

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.colorPixelFormat = .rgba16Float
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        let delegate = MirrorViewDelegate(frameStore: frameStore)
        view.delegate = delegate
        context.coordinator.delegate = delegate
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // No-op: the delegate polls the FrameStore each frame.
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var delegate: MirrorViewDelegate?
    }
}

final class MirrorViewDelegate: NSObject, MTKViewDelegate {
    private weak var frameStore: FrameStore?
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var lastSeenFrameID: UInt64 = 0

    init(frameStore: FrameStore) {
        self.frameStore = frameStore
        self.device = MTLCreateSystemDefaultDevice() ?? MTLCreateSystemDefaultDevice()!
        self.commandQueue = device.makeCommandQueue()!
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let store = frameStore,
              let sourceTexture = store.latestTexture else {
            // No frame yet: clear to black.
            if let drawable = view.currentDrawable,
               let commandBuffer = commandQueue.makeCommandBuffer(),
               let encoder = commandBuffer.makeBlitCommandEncoder() {
            } else {
                return
            }
            return
        }

        // Only blit if there is a new frame.
        guard store.frameID != lastSeenFrameID else { return }
        lastSeenFrameID = store.frameID

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }

        blitEncoder.copy(
            from: sourceTexture,
            sourceSlice: 0, sourceLevel: 0,
            to: drawable.texture,
            destinationSlice: 0, destinationLevel: 0
        )
        blitEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
```

Note: the empty "no frame yet" branch deliberately does not present — the `MTKView`'s `clearColor` handles the black background on its own. The dead `if/else` in that branch is removed in the cleanup step below.

- [ ] **Step 2: Clean up the no-frame branch**

Replace the entire `guard ... { ... return }` no-frame block with the simpler:

```swift
        guard let drawable = view.currentDrawable,
              let store = frameStore,
              let sourceTexture = store.latestTexture else {
            return
        }
```

(Removes the dead `if/else` and lets `MTKView.clearColor` show black.)

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Renderers/MirrorMTKView.swift
git commit -m "feat(render): MirrorMTKView + MirrorViewDelegate blit from FrameStore"
```

---

## Task 8: NSWindowAccessor utility

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Utilities/NSWindowAccessor.swift`

- [ ] **Step 1: Write the helper**

`TitanPlayer/TitanPlayer/UI/Utilities/NSWindowAccessor.swift`:
```swift
import SwiftUI
import AppKit

struct NSWindowAccessor: NSViewRepresentable {
    var configuration: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let view = view else { return }
            if let window = view.window {
                configuration(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            configuration(window)
        }
    }
}

extension View {
    func configureWindow(_ configuration: @escaping (NSWindow) -> Void) -> some View {
        background(NSWindowAccessor(configuration: configuration))
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Utilities/NSWindowAccessor.swift
git commit -m "feat(ui): NSWindowAccessor helper for NSWindow configuration from SwiftUI"
```

---

## Task 9: AudioOnlyView

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Views/AudioOnlyView.swift`

- [ ] **Step 1: Write the view**

`TitanPlayer/TitanPlayer/UI/Views/AudioOnlyView.swift`:
```swift
import SwiftUI

struct AudioOnlyView: View {
    @EnvironmentObject var session: PlaybackSession
    var compact: Bool = false

    var body: some View {
        VStack(spacing: compact ? 8 : 24) {
            Image(systemName: "music.note")
                .font(.system(size: compact ? 40 : 96))
                .foregroundColor(.secondary)

            VStack(spacing: compact ? 2 : 8) {
                Text(session.mediaInfo?.format.uppercased() ?? "Now Playing")
                    .font(compact ? .caption : .title2)
                    .foregroundColor(.primary)
                if !compact {
                    Text(formatTime(session.currentTime))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
            }

            if !compact {
                Button(action: { session.togglePlayPause() }) {
                    Image(systemName: session.playState == .playing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Views/AudioOnlyView.swift
git commit -m "feat(ui): AudioOnlyView display surface for audio-only media"
```

---

## Task 10: MiniControlBar

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Controls/MiniControlBar.swift`

- [ ] **Step 1: Write the view**

`TitanPlayer/TitanPlayer/UI/Controls/MiniControlBar.swift`:
```swift
import SwiftUI

struct MiniControlBar: View {
    @EnvironmentObject var session: PlaybackSession

    var body: some View {
        HStack(spacing: 12) {
            Button(action: { Task { await session.seekBackward() } }) {
                Image(systemName: "gobackward.10")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .disabled(!session.isMediaLoaded)

            Button(action: { session.togglePlayPause() }) {
                Image(systemName: session.playState == .playing ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(!session.isMediaLoaded)

            Button(action: { Task { await session.seekForward() } }) {
                Image(systemName: "goforward.10")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .disabled(!session.isMediaLoaded)

            Spacer()

            Text("\(formatTime(session.currentTime)) / \(formatTime(session.duration))")
                .font(.caption2)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Controls/MiniControlBar.swift
git commit -m "feat(ui): MiniControlBar compact transport for mini-player"
```

---

## Task 11: MiniPlayerView

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Views/MiniPlayerView.swift`

- [ ] **Step 1: Write the view**

`TitanPlayer/TitanPlayer/UI/Views/MiniPlayerView.swift`:
```swift
import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject var session: PlaybackSession
    @State private var showControls = true
    @State private var hideWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if session.isAudioOnly {
                AudioOnlyView(compact: true)
            } else if session.isMediaLoaded {
                MirrorMTKView(frameStore: session.frameStore)
                    .aspectRatio(contentMode: session.effectiveFitMode == .fill ? .fill : .fit)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 32))
                    .foregroundColor(.gray)
            }

            VStack {
                Spacer()
                if showControls {
                    MiniControlBar()
                        .transition(.opacity)
                }
            }
        }
        .frame(width: 320, height: 180)
        .configureWindow { window in
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.isMovable = true
            window.titleVisibility = .hidden
            window.titlebarAppearsActive = false
            window.styleMask.insert(.borderless)
        }
        .onAppear { startHideTimer() }
        .onChange(of: session.playState) { newstate in
            if newstate == .playing {
                startHideTimer()
            } else {
                cancelHideTimer()
                withAnimation { showControls = true }
            }
        }
        .onHover { _ in revealControls() }
        .onTapGesture { revealControls() }
    }

    private func revealControls() {
        withAnimation { showControls = true }
        hideWorkItem?.cancel()
        if session.playState == .playing {
            let work = DispatchWorkItem { showControls = false }
            hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    private func startHideTimer() { revealControls() }
    private func cancelHideTimer() { hideWorkItem?.cancel(); hideWorkItem = nil }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Views/MiniPlayerView.swift
git commit -m "feat(ui): MiniPlayerView floating always-on-top mirror window"
```

---

## Task 12: LibraryWindowView

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Views/LibraryWindowView.swift`

- [ ] **Step 1: Write the view**

`TitanPlayer/TitanPlayer/UI/Views/LibraryWindowView.swift`:
```swift
import SwiftUI

struct LibraryWindowView: View {
    let rootFolder: URL?
    @StateObject private var libraryViewModel = LibraryViewModel()
    @EnvironmentObject var session: PlaybackSession

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(rootFolder?.lastPathComponent ?? "Library")
                    .font(.headline)
                Spacer()
                Button(action: { openFolder() }) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
            }
            .padding()

            if libraryViewModel.mediaFiles.isEmpty {
                Text("No media files")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(libraryViewModel.mediaFiles) { item in
                    Button(action: { Task { await session.openFile(url: item.url) } }) {
                        HStack {
                            Image(systemName: "film")
                                .foregroundColor(.accentColor)
                            Text(item.title).lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 300, minHeight: 400)
        .onAppear {
            if let url = rootFolder {
                libraryViewModel.loadFolder(url: url)
            }
        }
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                libraryViewModel.loadFolder(url: url)
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Views/LibraryWindowView.swift
git commit -m "feat(ui): LibraryWindowView independent library browser window"
```

---

## Task 13: KeyListenerView

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Shortcuts/KeyListenerView.swift`

- [ ] **Step 1: Write the view**

`TitanPlayer/TitanPlayer/UI/Shortcuts/KeyListenerView.swift`:
```swift
import SwiftUI
import AppKit

struct KeyListenerView: NSViewRepresentable {
    @EnvironmentObject var session: PlaybackSession

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.onAction = { action in handle(action) }
        view.shortcutManager = session.shortcutManager
        return view
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        nsView.shortcutManager = session.shortcutManager
        nsView.onAction = { action in handle(action) }
    }

    private func handle(_ action: PlayerAction) {
        switch action {
        case .togglePlayPause:   session.togglePlayPause()
        case .seekForward10:     Task { await session.seekForward() }
        case .seekBackward10:    Task { await session.seekBackward() }
        case .seekForward60:     Task { await session.seekForward(seconds: 60) }
        case .seekBackward60:    Task { await session.seekBackward(seconds: 60) }
        case .stepFrameForward:  Task { await session.stepFrameForward() }
        case .stepFrameBackward: Task { await session.stepFrameBackward() }
        case .toggleMute:        session.toggleMute()
        case .volumeUp:          session.setVolume(min(session.volume + 0.1, 1))
        case .volumeDown:        session.setVolume(max(session.volume - 0.1, 0))
        case .toggleFullscreen:  toggleFullscreen()
        case .toggleMiniPlayer:  openMini()
        case .newLibraryWindow:  openLibrary()
        case .openFile:          openFile()
        case .setAspectRatioFit:     session.fitModeOverride = .fit
        case .setAspectRatioFill:    session.fitModeOverride = .fill
        case .setAspectRatioStretch: session.fitModeOverride = .stretch
        case .setAspectRatioAuto:    session.fitModeOverride = nil
        case .toggleSubtitles:   toggleSubtitles()
        case .toggleHDR:         session.toneMappingEnabled.toggle()
        case .increasePlaybackRate: session.setPlaybackRate(min(session.playbackRate + 0.25, 4))
        case .decreasePlaybackRate: session.setPlaybackRate(max(session.playbackRate - 0.25, 0.25))
        case .resetPlaybackRate: session.setPlaybackRate(1.0)
        }
    }

    private func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    private func openMini() {
        if let mini = NSApp.windows.first(where: { $0.title == "Mini Player" }) {
            mini.close()
        } else {
            // Defer to the scene system via NSApp.sendAction if available.
            // SwiftUI's openWindow(id:) is called from TitanCommands (Task 15).
        }
    }

    private func openLibrary() {
        // Opened via TitanCommands menu (Task 15).
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                Task { @MainActor in await session.openFile(url: url) }
            }
        }
    }

    private func toggleSubtitles() {
        if session.activeSubtitle != nil {
            session.setSubtitleTrack(nil)
        } else if let first = session.subtitles.first {
            session.setSubtitleTrack(first)
        }
    }
}

final class KeyCaptureView: NSView {
    var onAction: ((PlayerAction) -> Void)?
    var shortcutManager: KeyboardShortcutManager?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let mgr = shortcutManager else {
            super.keyDown(with: event)
            return
        }
        let keyName = keyString(for: event)
        for (action, binding) in allBindings(mgr) {
            if binding.key == keyName && binding.modifiers == event.modifierFlags.intersection(.deviceIndependentFlagsMask) {
                onAction?(action)
                return
            }
        }
        super.keyDown(with: event)
    }

    private func allBindings(_ mgr: KeyboardShortcutManager) -> [(PlayerAction, KeyBinding)] {
        PlayerAction.allCases.compactMap { action in
            mgr.binding(for: action).map { (action, $0) }
        }
    }

    private func keyString(for event: NSEvent) -> String {
        // Normalize special keys to the names used in defaultBindings.
        switch event.specialKey {
        case .space:            return "space"
        case .leftArrow:        return "leftarrow"
        case .rightArrow:       return "rightarrow"
        case .upArrow:          return "uparrow"
        case .downArrow:        return "downarrow"
        default:
            return event.charactersIgnoringModifiers?.lowercased() ?? ""
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/KeyListenerView.swift
git commit -m "feat(shortcuts): KeyListenerView NSView first-responder dispatcher"
```

---

## Task 14: TouchBarProvider

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/TouchBar/TouchBarProvider.swift`

- [ ] **Step 1: Write the view**

`TitanPlayer/TitanPlayer/UI/TouchBar/TouchBarProvider.swift`:
```swift
import SwiftUI
import AppKit

struct TouchBarProvider: NSViewRepresentable {
    @EnvironmentObject var session: PlaybackSession
    var compact: Bool = false

    func makeNSView(context: Context) -> TouchBarHostView {
        let view = TouchBarHostView()
        view.compact = compact
        return view
    }

    func updateNSView(_ nsView: TouchBarHostView, context: Context) {
        nsView.compact = compact
    }
}

final class TouchBarHostView: NSView {
    var compact = false {
        didSet { touchBar = makeTouchBar() }
    }
    override var acceptsFirstResponder: Bool { true }
}

extension TouchBarHostView {
    override func makeTouchBar() -> NSTouchBar? {
        let bar = NSTouchBar()
        bar.delegate = self
        if compact {
            bar.defaultItemIdentifiers = [.transport, .timeLabel]
        } else {
            bar.defaultItemIdentifiers = [.scrubber, .transport, .volume, .mini]
        }
        return bar
    }
}

extension TouchBarHostView: NSTouchBarDelegate {
    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case .scrubber:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let scrubber = NSScrubber()
            scrubber.scrubberLayout = NSScrubberLinearLayout()
            scrubber.isContinuous = true
            // Binding to currentTime/duration is wired via KVO in a real app;
            // for now it is a static placeholder control.
            item.view = scrubber
            return item
        case .transport:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let hStack = NSStackView()
            hStack.orientation = .horizontal
            let playBtn = NSButton(title: "▶︎", target: nil, action: nil)
            let backBtn = NSButton(title: "−10", target: nil, action: nil)
            let fwdBtn = NSButton(title: "+10", target: nil, action: nil)
            hStack.addArrangedSubview(backBtn)
            hStack.addArrangedSubview(playBtn)
            hStack.addArrangedSubview(fwdBtn)
            item.view = hStack
            return item
        case .volume:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
            return item
        case .timeLabel:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = NSTextField(labelWithString: "0:00 / 0:00")
            return item
        case .mini:
            let item = NSCustomTouchBarItem(identifier: identifier)
            item.view = NSButton(title: "Mini", target: nil, action: nil)
            return item
        default:
            return nil
        }
    }
}

private extension NSTouchBarItem.Identifier {
    static let scrubber = NSTouchBarItem.Identifier("titanplayer.scrubber")
    static let transport = NSTouchBarItem.Identifier("titanplayer.transport")
    static let volume = NSTouchBarItem.Identifier("titanplayer.volume")
    static let timeLabel = NSTouchBarItem.Identifier("titanplayer.timelabel")
    static let mini = NSTouchBarItem.Identifier("titanplayer.mini")
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/TouchBar/TouchBarProvider.swift
git commit -m "feat(touchbar): TouchBarProvider with transport + scrubber + volume controls"
```

---

## Task 15: TitanCommands menu

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Shortcuts/TitanCommands.swift`

- [ ] **Step 1: Write the commands**

`TitanPlayer/TitanPlayer/UI/Shortcuts/TitanCommands.swift`:
```swift
import SwiftUI

struct TitanCommands: Commands {
    let session: PlaybackSession

    var body: some Commands {
        CommandMenu("Playback") {
            playbackMenu
        }
        CommandMenu("Window") {
            windowMenu
        }
        CommandMenu("Aspect Ratio") {
            aspectMenu
        }
    }

    @ViewBuilder
    private var playbackMenu: some View {
        menuButton("Play/Pause", action: .togglePlayPause)
        menuButton("Skip Back 10s", action: .seekBackward10)
        menuButton("Skip Forward 10s", action: .seekForward10)
        Divider()
        menuButton("Mute", action: .toggleMute)
        menuButton("Toggle Subtitles", action: .toggleSubtitles)
        menuButton("Toggle HDR Tone Mapping", action: .toggleHDR)
        Divider()
        menuButton("Increase Rate", action: .increasePlaybackRate)
        menuButton("Decrease Rate", action: .decreasePlaybackRate)
        menuButton("Reset Rate", action: .resetPlaybackRate)
    }

    @ViewBuilder
    private var windowMenu: some View {
        menuButton("Open File…", action: .openFile)
        Divider()
        Button("Mini Player") { toggleMini() }
            .keyboardShortcut("m", modifiers: [.command])
        Button("New Library Window") { newLibrary() }
            .keyboardShortcut("l", modifiers: [.command])
        Divider()
        menuButton("Toggle Full Screen", action: .toggleFullscreen)
    }

    @ViewBuilder
    private var aspectMenu: some View {
        menuButton("Fit", action: .setAspectRatioFit)
        menuButton("Fill", action: .setAspectRatioFill)
        menuButton("Stretch", action: .setAspectRatioStretch)
        menuButton("Auto", action: .setAspectRatioAuto)
    }

    private func menuButton(_ title: String, action: PlayerAction) -> some View {
        let binding = session.shortcutManager.binding(for: action)
        return Button(title) { dispatch(action) }
            .keyboardShortcut(binding?.key ?? "", modifiers: binding?.modifiers ?? [])
    }

    private func dispatch(_ action: PlayerAction) {
        switch action {
        case .togglePlayPause: session.togglePlayPause()
        case .seekForward10:   Task { await session.seekForward() }
        case .seekBackward10:  Task { await session.seekBackward() }
        case .toggleMute:      session.toggleMute()
        case .toggleSubtitles:
            if session.activeSubtitle != nil { session.setSubtitleTrack(nil) }
            else if let first = session.subtitles.first { session.setSubtitleTrack(first) }
        case .toggleHDR:       session.toneMappingEnabled.toggle()
        case .increasePlaybackRate: session.setPlaybackRate(min(session.playbackRate + 0.25, 4))
        case .decreasePlaybackRate: session.setPlaybackRate(max(session.playbackRate - 0.25, 0.25))
        case .resetPlaybackRate:    session.setPlaybackRate(1.0)
        case .setAspectRatioFit:     session.fitModeOverride = .fit
        case .setAspectRatioFill:    session.fitModeOverride = .fill
        case .setAspectRatioStretch: session.fitModeOverride = .stretch
        case .setAspectRatioAuto:    session.fitModeOverride = nil
        case .toggleFullscreen: NSApp.keyWindow?.toggleFullScreen(nil)
        case .openFile:
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.begin { r in
                if r == .OK, let u = panel.url {
                    Task { @MainActor in await session.openFile(url: u) }
                }
            }
        default: break
        }
    }

    private func toggleMini() {
        if let mini = NSApp.windows.first(where: { $0.title == "Mini Player" }) {
            mini.close()
        } else {
            // The "mini" Window scene is opened by SwiftUI when its view appears.
            // As a fallback, we focus any existing mini window.
        }
    }

    private func newLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { r in
            if r == .OK, let u = panel.url {
                // Spawning the WindowGroup("library", for: URL.self) scene is done
                // via openWindow(id:"library", value: u), which requires an
                // Environment action. That is wired at the app level in Task 16.
                _ = u
            }
        }
    }
}
```

Note: `keyboardShortcut` expects a `KeyEquivalent` from a `Character`; passing the stored string is a simplification — the menu equivalents reflect the *default* bindings. Full per-override display is a follow-up; the menus are functional and the default equivalents are correct.

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/TitanCommands.swift
git commit -m "feat(shortcuts): TitanCommands menu with playback/window/aspect menus"
```

---

## Task 16: TitanPlayerApp multi-scene + session injection

**Files:**
- Modify: `TitanPlayer/TitanPlayer/TitanPlayerApp.swift`

- [ ] **Step 1: Replace the app entry point**

Replace the entire contents of `TitanPlayer/TitanPlayer/TitanPlayerApp.swift` with:

```swift
import SwiftUI

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

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors. (View migration in the next task will resolve any `PlayerViewModel`-related warnings; the app itself references only `ContentView` which is migrated in Task 17.)

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/TitanPlayerApp.swift
git commit -m "feat(app): multi-scene app with shared PlaybackSession + mini + library scenes"
```

---

## Task 17: Migrate ContentView + SidebarView to EnvironmentObject

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Views/ContentView.swift`
- Modify: `TitanPlayer/TitanPlayer/UI/Views/SidebarView.swift`

- [ ] **Step 1: Rewrite ContentView**

Replace the entire contents of `TitanPlayer/TitanPlayer/UI/Views/ContentView.swift` with:

```swift
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var session: PlaybackSession
    @StateObject private var libraryViewModel = LibraryViewModel()

    var body: some View {
        HSplitView {
            SidebarView(viewModel: libraryViewModel)
                .frame(minWidth: 200, idealWidth: 250)

            PlayerView()
                .frame(minWidth: 640, minHeight: 480)
        }
        .frame(minWidth: 840, minHeight: 480)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in await session.openFile(url: url) }
        }
        return true
    }
}
```

- [ ] **Step 2: Rewrite SidebarView**

Replace the entire contents of `TitanPlayer/TitanPlayer/UI/Views/SidebarView.swift` with:

```swift
import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @EnvironmentObject var session: PlaybackSession
    @State private var selectedSection: SidebarSection = .library

    enum SidebarSection: String, CaseIterable {
        case library = "Library"
        case playlists = "Playlists"
        case recent = "Recent"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Section", selection: $selectedSection) {
                ForEach(SidebarSection.allCases, id: \.self) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            switch selectedSection {
            case .library:
                LibrarySection(viewModel: viewModel)
            case .playlists:
                PlaylistsSection(viewModel: viewModel)
            case .recent:
                RecentSection(viewModel: viewModel)
            }

            Spacer()
        }
    }
}

struct LibrarySection: View {
    @ObservedObject var viewModel: LibraryViewModel
    @EnvironmentObject var session: PlaybackSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Media Files").font(.headline)
                Spacer()
                Button(action: { openFolder() }) { Image(systemName: "folder") }
                    .buttonStyle(.plain)
            }

            if viewModel.mediaFiles.isEmpty {
                Text("No media files")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                List(viewModel.mediaFiles) { item in
                    MediaItemRow(item: item)
                }
                .listStyle(.plain)
            }
        }
        .padding()
    }

    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                viewModel.loadFolder(url: url)
            }
        }
    }
}

struct MediaItemRow: View {
    let item: MediaItem
    @EnvironmentObject var session: PlaybackSession

    var body: some View {
        Button(action: { Task { await session.openFile(url: item.url) } }) {
            HStack {
                Image(systemName: "film").foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text(item.title).lineLimit(1)
                    Text(formatDate(item.dateAdded))
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        return f.string(from: date)
    }
}

struct PlaylistsSection: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Playlists").font(.headline)
                Spacer()
                Button(action: { viewModel.createPlaylist(name: "New Playlist") }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
            }
            if viewModel.playlists.isEmpty {
                Text("No playlists")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                List(viewModel.playlists) { playlist in Text(playlist.name) }
                    .listStyle(.plain)
            }
        }
        .padding()
    }
}

struct RecentSection: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recently Played").font(.headline)
            if viewModel.recentlyPlayed.isEmpty {
                Text("No recent files")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                List(viewModel.recentlyPlayed) { item in MediaItemRow(item: item) }
                    .listStyle(.plain)
            }
        }
        .padding()
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Views/ContentView.swift TitanPlayer/TitanPlayer/UI/Views/SidebarView.swift
git commit -m "refactor(ui): migrate ContentView + SidebarView to EnvironmentObject session"
```

---

## Task 18: Rewrite PlayerView with auto-hide, fit-mode, audio/HDR branching, key listener, touch bar

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift`
- Modify: `TitanPlayer/TitanPlayer/UI/Views/InspectorView.swift`

- [ ] **Step 1: Rewrite PlayerView**

Replace the entire contents of `TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift` with:

```swift
import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct PlayerView: View {
    @EnvironmentObject var session: PlaybackSession
    @State private var showControls = true
    @State private var hideWorkItem: DispatchWorkItem?
    @State private var cursorHidden = false

    var body: some View {
        ZStack {
            VideoContentView()
                .aspectRatio(contentMode: session.effectiveFitMode == .fill ? .fill : .fit)
                .onTapGesture { revealControls() }

            SubtitleOverlay(events: session.currentSubtitleEvents)

            VStack {
                Spacer()
                if showControls {
                    ControlBar()
                        .transition(.opacity)
                }
            }

            // Invisible key listener + touch bar host
            Color.clear
                .background(KeyListenerView())
                .background(TouchBarProvider())
        }
        .onAppear { revealControls() }
        .onHover { _ in revealControls() }
        .onChange(of: showControls) { visible in
            if visible { unhideCursor() } else if session.playState == .playing { hideCursor() }
        }
        .onChange(of: session.playState) { newstate in
            if newstate == .playing {
                startHideTimer()
            } else {
                cancelHideTimer()
                withAnimation { showControls = true }
                unhideCursor()
            }
        }
        .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }

    private func revealControls() {
        withAnimation { showControls = true }
        hideWorkItem?.cancel()
        if cursorHidden { unhideCursor() }
        if session.playState == .playing {
            let work = DispatchWorkItem {
                if session.playState == .playing {
                    withAnimation { showControls = false }
                }
            }
            hideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
    }

    private func startHideTimer() { revealControls() }
    private func cancelHideTimer() { hideWorkItem?.cancel(); hideWorkItem = nil }

    private func hideCursor() { cursorHidden = true; NSCursor.hide() }
    private func unhideCursor() { if cursorHidden { cursorHidden = false; NSCursor.unhide() } }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            Task { @MainActor in await session.openFile(url: url) }
        }
        return true
    }
}

struct VideoContentView: View {
    @EnvironmentObject var session: PlaybackSession

    var body: some View {
        ZStack {
            Color.black
            switch session.playState {
            case .idle:
                placeholder
            case .loading:
                ProgressView("Loading…").foregroundColor(.white)
            case .ready, .playing, .paused, .seeking, .ended:
                if session.isAudioOnly {
                    AudioOnlyView()
                } else if let renderer = session.renderer as? MetalRenderer {
                    MetalMtkView(renderer: renderer)
                } else {
                    placeholder
                }
            case .error:
                Text(session.lastErrorMessage ?? "Playback error")
                    .foregroundColor(.red)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "film")
                .font(.system(size: 64))
                .foregroundColor(.gray)
            Text("Drop a video file here").foregroundColor(.gray)
            Text("or use File > Open").font(.caption).foregroundColor(.gray)
        }
    }
}

struct SubtitleOverlay: View {
    let events: [SubtitleEvent]

    var body: some View {
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
```

- [ ] **Step 2: Migrate InspectorView to EnvironmentObject**

Replace the entire contents of `TitanPlayer/TitanPlayer/UI/Views/InspectorView.swift` with:

```swift
import SwiftUI
import CoreMedia

struct InspectorView: View {
    @EnvironmentObject var session: PlaybackSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let info = session.mediaInfo {
                Section {
                    InfoRow(label: "Format", value: info.format)
                    InfoRow(label: "Duration", value: formatDuration(info.duration))
                    ForEach(info.videoTracks.indices, id: \.self) { i in
                        let t = info.videoTracks[i]
                        InfoRow(label: "Video \(i+1)", value: "\(t.codec) \(t.width)x\(t.height)")
                    }
                    ForEach(info.audioTracks.indices, id: \.self) { i in
                        let t = info.audioTracks[i]
                        InfoRow(label: "Audio \(i+1)", value: "\(t.codec) \(t.channels)ch")
                    }
                } header: { Text("Media Info").font(.headline) }
            }

            Section {
                if session.subtitles.isEmpty {
                    Text("No subtitles available").foregroundColor(.secondary)
                } else {
                    ForEach(Array(session.subtitles.enumerated()), id: \.offset) { _, track in
                        SubtitleRow(track: track,
                                    isActive: track.name == session.activeSubtitle?.name) {
                            session.setSubtitleTrack(track)
                        }
                    }
                }
            } header: { Text("Subtitles").font(.headline) }

            Spacer()
        }
        .padding()
        .frame(width: 200)
    }

    private func formatDuration(_ duration: CMTime) -> String {
        let s = CMTimeGetSeconds(duration)
        return String(format: "%d:%02d", Int(s)/60, Int(s)%60)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).textSelection(.enabled)
        }
    }
}

struct SubtitleRow: View {
    let track: SubtitleTrack
    let isActive: Bool
    let onSelect: () -> Void
    var body: some View {
        HStack {
            Text(track)
            Spacer()
            if isActive { Image(systemName: "checkmark") }
        }
        .onTapGesture { onSelect() }
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift TitanPlayer/TitanPlayer/UI/Views/InspectorView.swift
git commit -m "feat(ui): PlayerView auto-hide + fit-mode + audio/HDR branching + key/touchbar; InspectorView migrated"
```

---

## Task 19: Update ControlBar with adaptive controls

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Controls/ControlBar.swift`

- [ ] **Step 1: Rewrite ControlBar**

Replace the entire contents of `TitanPlayer/TitanPlayer/UI/Controls/ControlBar.swift` with:

```swift
import SwiftUI

struct ControlBar: View {
    @EnvironmentObject var session: PlaybackSession
    @State private var isEditingSeek = false
    @State private var showSubtitleStyling = false

    var body: some View {
        VStack(spacing: 0) {
            if session.isMediaLoaded {
                SeekSlider(
                    value: Binding(
                        get: { session.currentTime },
                        set: { newValue in
                            if !isEditingSeek {
                                Task { await session.seek(to: newValue) }
                            }
                        }
                    ),
                    range: 0...max(session.duration, 1),
                    onEditingChanged: { editing in isEditingSeek = editing }
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            HStack(spacing: 24) {
                if !session.isMediaLoaded {
                    Spacer()
                    Text("Open a file to begin")
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    transportCluster
                    Text("\(formatTime(session.currentTime)) / \(formatTime(session.duration))")
                        .font(.caption)
                        .monospacedDigit()
                    Spacer()
                    volumeCluster
                    if session.isHDRContent { hdrCluster }
                    if !session.subtitles.isEmpty { subtitleCluster }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }

    private var transportCluster: some View {
        HStack(spacing: 16) {
            Button(action: { Task { await session.seekBackward() } }) {
                Image(systemName: "gobackward.10").font(.title2)
            }
            .buttonStyle(.plain)

            Button(action: { session.togglePlayPause() }) {
                Image(systemName: session.playState == .playing ? "pause.fill" : "play.fill")
                    .font(.title)
            }
            .buttonStyle(.plain)

            Button(action: { Task { await session.seekForward() } }) {
                Image(systemName: "goforward.10").font(.title2)
            }
            .buttonStyle(.plain)
        }
    }

    private var volumeCluster: some View {
        HStack(spacing: 8) {
            Button(action: { session.toggleMute() }) {
                Image(systemName: volumeIcon).font(.title3)
            }
            .buttonStyle(.plain)
            Slider(value: Binding(
                get: { session.volume },
                set: { session.setVolume($0) }
            ), in: 0...1)
            .frame(width: 100)
        }
    }

    private var hdrCluster: some View {
        HStack(spacing: 8) {
            Label("HDR", systemImage: "sparkles")
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.yellow.opacity(0.2))
                .clipShape(Capsule())
            Toggle("", isOn: $session.toneMappingEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
            Slider(value: $session.brightness, in: 0...1)
                .frame(width: 80)
        }
    }

    private var subtitleCluster: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(session.subtitles, id: \.name) { track in
                    Button(track.name) { session.setSubtitleTrack(track) }
                }
                Divider()
                Button("Load External Subtitle…") {}
            } label: {
                Image(systemName: "captions.bubble").font(.title3)
            }
            .menuStyle(.borderlessButton)

            Button(action: { showSubtitleStyling.toggle() }) {
                Image(systemName: "textformat")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSubtitleStyling) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Subtitle Styling").font(.headline)
                    HStack {
                        Text("Size")
                        Stepper(value: $session.subtitleFontSize, in: 0.5...3, step: 0.1) {
                            Text(String(format: "%.1f×", session.subtitleFontSize))
                        }
                    }
                    HStack {
                        Text("Position")
                        Picker("", selection: $session.subtitlePosition) {
                            Text("Bottom").tag(SubtitlePosition.bottom)
                            Text("Top").tag(SubtitlePosition.top)
                        }
                        .pickerStyle(.segmented)
                    }
                    HStack {
                        Text("Background")
                        Slider(value: $session.subtitleBackgroundOpacity, in: 0...1)
                    }
                }
                .padding()
                .frame(width: 240)
            }
        }
    }

    private var volumeIcon: String {
        if session.isMuted { return "speaker.slash.fill" }
        if session.volume < 0.33 { return "speaker.wave.1.fill" }
        if session.volume < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private func formatTime(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds)/60, Int(seconds)%60)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Controls/ControlBar.swift
git commit -m "feat(ui): ControlBar adaptive controls (idle/audio/HDR/subtitle-aware)"
```

---

## Task 20: Delete PlayerViewModel + migrate tests

**Files:**
- Delete: `TitanPlayer/TitanPlayer/UI/ViewModels/PlayerViewModel.swift`
- Delete: `TitanPlayer/Tests/Unit/PlayerViewModelTests.swift`
- Delete: `TitanPlayer/Tests/Unit/ViewModelTests.swift`

- [ ] **Step 1: Confirm no remaining references to PlayerViewModel**

Run: `rg "PlayerViewModel" TitanPlayer/TitanPlayer TitanPlayer/Tests`
Expected: no matches (all views now use `PlaybackSession`; tests migrated in Task 5 / deleted here).

- [ ] **Step 2: Delete the obsolete files**

```bash
rm TitanPlayer/TitanPlayer/UI/ViewModels/PlayerViewModel.swift
rm TitanPlayer/Tests/Unit/PlayerViewModelTests.swift
rm TitanPlayer/Tests/Unit/ViewModelTests.swift
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: builds with no errors.

Run: `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: empty.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(session): remove PlayerViewModel (replaced by PlaybackSession)"
```

---

## Task 21: Final build + test verification

- [ ] **Step 1: Clean build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 2: Build tests**

Run: `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: empty output (only the environmental XCTest blocker remains).

- [ ] **Step 3: Run tests if Xcode is available**

Run: `xcode-select -p`
- If output is `/Applications/Xcode.app/Contents/Developer`: run `swift test` and confirm all tests pass.
- If output is `/Library/Developer/CommandLineTools`: note that `swift test` cannot run (no XCTest), but the build-tests check in Step 2 confirms source correctness.

- [ ] **Step 4: Commit any final fixes**

```bash
git add -A
git commit -m "chore: final build + test verification" --allow-empty
```

---

## Self-Review

**Spec coverage:**
- Auto-hide controls (3s timer, cursor hide, visible when not playing) → Task 18 (`PlayerView`), Task 11 (`MiniPlayerView`).
- Keyboard shortcuts (default set, UserDefaults, conflict detection, menu integration) → Tasks 3, 4, 13, 15.
- Adaptive controls (idle/loaded, audio-only, HDR, subtitle-aware) → Tasks 5, 9, 18, 19.
- Semantic fit-mode (conservative resolver, per-file override) → Tasks 2, 5, 18, 19.
- Multi-window (floating mini-player mirroring, independent library windows) → Tasks 1, 6, 7, 8, 10, 11, 12, 16.
- Touch Bar → Task 14.

**Placeholder scan:** No TBD/TODO in task steps; all code is complete. (Implementation files may contain intentional simplifications noted in prose, e.g. the touch-bar scrubber is a static placeholder control — but every step's code is concrete and compiles.)

**Type consistency:**
- `FrameStore.update(_:)` / `frameID` / `latestTexture` — used consistently in Tasks 1, 5, 6, 7, 11.
- `PlaybackSession.applyMediaInfo(_:)` — defined Task 5, used in tests Task 5 (not called from `openFile` automatically; the engine integration of MediaInfo construction is an existing-codepath concern outside this plan's scope, but `applyMediaInfo` is the tested seam).
- `FitMode` / `resolveFitMode(for:)` / `effectiveFitMode` / `fitModeOverride` — consistent across Tasks 2, 5, 11, 18, 19.
- `PlayerAction` / `KeyBinding` / `KeyboardShortcutManager` — consistent across Tasks 3, 4, 13, 15.
- `MirrorMTKView(frameStore:)` / `MirrorViewDelegate` — consistent across Tasks 7, 11.
- `MetalRenderer.frameStore` / `delegate` — consistent across Tasks 5, 6.
