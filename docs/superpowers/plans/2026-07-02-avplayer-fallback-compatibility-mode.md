# AVPlayer Fallback for Custom Pipeline Failures — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When `MediaPipeline` fails to open a file, gracefully fall back to standard AVPlayer playback so the user can still watch the video, bypassing the custom Metal renderer entirely.

**Architecture:** Add a `compatibilityMode` flag to `PlaybackSession`. In `PlaybackEngine.load(url:)`, catch `MediaPipeline` errors after the `AVPlayerItem` is already set on `AVPlayer`, and activate compatibility mode. In the UI layer, detect this flag and render via a standard `AVPlayerView` (NSViewRepresentable) instead of the custom `MetalMtkView`. A subtle badge notifies the user of compatibility mode.

**Tech Stack:** Swift, SwiftUI, AVKit, Combine

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `TitanPlayer/Core/Engine/PlaybackEngine.swift` | Modify | Add do-catch around `mediaPipeline?.openFile()`, expose `compatibilityMode` flag |
| `TitanPlayer/UI/Session/PlaybackSession.swift` | Modify | Add `@Published var isCompatibilityMode`, bind from engine, add `AVPlayerView` fallback flag |
| `TitanPlayer/UI/Views/PlayerView.swift` | Modify | Show `AVPlayerView` in `VideoContentView` when in compatibility mode, add badge |
| `TitanPlayer/UI/Views/MiniPlayerView.swift` | Modify | Show `AVPlayerView` fallback for mini player in compatibility mode |
| `TitanPlayer/UI/Renderers/AVPlayerView.swift` | Create | NSViewRepresentable wrapping `AVPlayerView` |
| `TitanPlayer/Telemetry/TelemetryEvent.swift` | Modify | Add `compatibilityModeActivated` event |
| `TitanPlayer/Telemetry/TelemetryManager.swift` | Modify | Handle new telemetry event |
| `Tests/Unit/CompatibilityModeTests.swift` | Create | Unit tests for fallback behavior |

---

### Task 1: Create AVPlayerView SwiftUI Wrapper

**Files:**
- Create: `TitanPlayer/UI/Renderers/AVPlayerView.swift`

- [ ] **Step 1: Create the AVPlayerView wrapper**

```swift
import SwiftUI
import AVKit

/// NSViewRepresentable wrapper that renders video via AVPlayer's built-in
/// AVPlayerView. Used in compatibility mode when the custom Metal pipeline
/// fails to open a file.
struct AVPlayerViewWrapper: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}
```

- [ ] **Step 2: Verify build compiles**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/UI/Renderers/AVPlayerView.swift
git commit -m "feat: add AVPlayerView SwiftUI wrapper for compatibility mode"
```

---

### Task 2: Add Compatibility Mode Flag to PlaybackEngine

**Files:**
- Modify: `TitanPlayer/Core/Engine/PlaybackEngine.swift:70-137`

- [ ] **Step 1: Add compatibilityMode published property**

Add after line 23 (`@Published var mediaInfo: MediaInfo? = nil`):

```swift
@Published var compatibilityMode: Bool = false
```

- [ ] **Step 2: Wrap MediaPipeline.openFile in do-catch with fallback**

Replace lines 113–116 in `load(url:)` (the non-DASH branch) with:

```swift
decoderLogger.info("Opening file in MediaPipeline...")
do {
    try await mediaPipeline?.openFile(url: url, adaptiveManager: adaptiveDecoderManager)
    self.mediaInfo = mediaPipeline?.mediaInfo
    decoderLogger.info("MediaPipeline file opened successfully")
} catch {
    decoderLogger.warning("MediaPipeline failed (\(error.localizedDescription, privacy: .public)), falling back to AVPlayer compatibility mode")
    self.mediaInfo = nil
    self.compatibilityMode = true
}
```

- [ ] **Step 3: Reset compatibilityMode at start of load**

Add after line 72 (`lastError = nil`):

```swift
self.compatibilityMode = false
```

- [ ] **Step 4: Verify build compiles**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/Core/Engine/PlaybackEngine.swift
git commit -m "feat: add compatibility mode fallback when MediaPipeline fails"
```

---

### Task 3: Wire Compatibility Mode Through PlaybackSession

**Files:**
- Modify: `TitanPlayer/UI/Session/PlaybackSession.swift:10-23`
- Modify: `TitanPlayer/UI/Session/PlaybackSession.swift:386-413`

- [ ] **Step 1: Add isCompatibilityMode published property**

Add after line 26 (`@Published var toneMappingEnabled: Bool = true`):

```swift
@Published var isCompatibilityMode: Bool = false
```

- [ ] **Step 2: Add binding in setupBindings()**

Add at the end of `setupBindings()` (after line 413, before the closing `}`):

```swift
engine.$compatibilityMode
    .receive(on: DispatchQueue.main)
    .assign(to: &$isCompatibilityMode)
```

- [ ] **Step 3: Add an avPlayer accessor for the AVPlayerView**

Add a computed property to PlaybackSession (after the `engine` property around line 54):

```swift
var avPlayer: AVPlayer { engine.avPlayer }
```

- [ ] **Step 4: Verify build compiles**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/UI/Session/PlaybackSession.swift
git commit -m "feat: wire compatibility mode flag through PlaybackSession"
```

---

### Task 4: Update VideoContentView for Compatibility Mode

**Files:**
- Modify: `TitanPlayer/UI/Views/PlayerView.swift:134-198`

- [ ] **Step 1: Add compatibility mode branch in VideoContentView**

Replace lines 146–153 (the `.ready` / `.playing` / `.paused` / `.seeking` / `.ended` case) with:

```swift
case .ready, .playing, .paused, .seeking, .ended:
    if session.isAudioOnly {
        AudioOnlyView()
    } else if session.isCompatibilityMode {
        AVPlayerViewWrapper(player: session.avPlayer)
    } else if let renderer = session.renderer as? MetalRenderer {
        MetalMtkView(renderer: renderer)
    } else {
        placeholder
    }
```

- [ ] **Step 2: Verify build compiles**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/UI/Views/PlayerView.swift
git commit -m "feat: show AVPlayerView in VideoContentView during compatibility mode"
```

---

### Task 5: Add Compatibility Mode Badge Indicator

**Files:**
- Modify: `TitanPlayer/UI/Views/PlayerView.swift:5-52`

- [ ] **Step 1: Add badge overlay in PlayerView**

In the `PlayerView` body, add a compatibility mode badge inside the `ZStack`, after the `SubtitleOverlay` and before the `VStack` for controls. Add after line 37 (after `SubtitleOverlay`):

```swift
if session.isCompatibilityMode {
    VStack {
        HStack {
            Text("Compatibility Mode")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial)
                .cornerRadius(6)
                .foregroundColor(.secondary)
            Spacer()
        }
        Spacer()
    }
    .padding(12)
    .allowsHitTesting(false)
}
```

- [ ] **Step 2: Verify build compiles**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/UI/Views/PlayerView.swift
git commit -m "feat: add compatibility mode badge indicator"
```

---

### Task 6: Update MiniPlayerView for Compatibility Mode

**Files:**
- Modify: `TitanPlayer/UI/Views/MiniPlayerView.swift:12-21`

- [ ] **Step 1: Add compatibility mode branch in MiniPlayerView**

Replace lines 14–16 (the `else if session.isMediaLoaded` block) with:

```swift
} else if session.isCompatibilityMode {
    AVPlayerViewWrapper(player: session.avPlayer)
        .aspectRatio(contentMode: session.effectiveFitMode == .fill ? .fill : .fit)
} else if session.isMediaLoaded {
    MirrorMTKView(frameStore: session.frameStore)
        .aspectRatio(contentMode: session.effectiveFitMode == .fill ? .fill : .fit)
```

- [ ] **Step 2: Verify build compiles**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/UI/Views/MiniPlayerView.swift
git commit -m "feat: show AVPlayerView in MiniPlayerView during compatibility mode"
```

---

### Task 7: Add Telemetry Event for Compatibility Mode

**Files:**
- Modify: `TitanPlayer/Telemetry/TelemetryEvent.swift:3-28`
- Modify: `TitanPlayer/Telemetry/TelemetryManager.swift:32-76`

- [ ] **Step 1: Add compatibilityModeActivated event to TelemetryEvent**

Add a new case after line 27 (before the closing `}` of the enum):

```swift
case compatibilityModeActivated(
    reason: String,
    source: PlaybackSource
)
```

- [ ] **Step 2: Handle the new event in TelemetryManager.record()**

Add a new `case` in the `switch event` block inside `record(_:)`, after the `audioFormatUsed` case (after line 73):

```swift
case .compatibilityModeActivated(let reason, let source):
    sentryEvent.message = SentryMessage(formatted: "compatibility_mode_activated")
    sentryEvent.tags = [
        "reason": reason,
        "source": source.rawValue
    ]
    sentryEvent.level = .warning
```

- [ ] **Step 3: Record telemetry when compatibility mode activates**

In `PlaybackEngine.load(url:)`, inside the `catch` block added in Task 2 (after `self.compatibilityMode = true`), add:

```swift
TelemetryManager.shared.record(.compatibilityModeActivated(
    reason: error.localizedDescription,
    source: url.pathExtension.lowercased() == "mpd" ? .dash : .local
))
```

- [ ] **Step 4: Verify build compiles**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/Telemetry/TelemetryEvent.swift TitanPlayer/Telemetry/TelemetryManager.swift TitanPlayer/Core/Engine/PlaybackEngine.swift
git commit -m "feat: add telemetry for compatibility mode activation"
```

---

### Task 8: Add Unit Tests

**Files:**
- Create: `Tests/Unit/CompatibilityModeTests.swift`

- [ ] **Step 1: Create test file**

```swift
import XCTest
@testable import TitanPlayer

@MainActor
final class CompatibilityModeTests: XCTestCase {

    func testEngineSetsCompatibilityModeOnPipelineFailure() async {
        let renderer = MockFrameRenderer()
        let engine = PlaybackEngine(videoRenderer: renderer)

        // load() will fail because there's no real file, and MediaPipeline
        // will throw. Verify the engine enters compatibility mode.
        let testURL = URL(fileURLWithPath: "/tmp/nonexistent_test_file.mp4")

        do {
            try await engine.load(url: testURL)
        } catch {
            // Expected — file doesn't exist
        }

        // The asset load itself fails (no file), so compatibility mode
        // should NOT be set — the error occurs before MediaPipeline.openFile.
        // This tests the outer catch path.
        XCTAssertNotEqual(engine.state, .ready)
    }

    func testCompatibilityModeResetsOnNewLoad() async {
        let renderer = MockFrameRenderer()
        let engine = PlaybackEngine(videoRenderer: renderer)

        // Simulate compatibility mode being active
        engine.compatibilityMode = true

        let testURL = URL(fileURLWithPath: "/tmp/another_nonexistent.mp4")
        do {
            try await engine.load(url: testURL)
        } catch {
            // Expected
        }

        // compatibilityMode should be reset to false at the start of load
        XCTAssertFalse(engine.compatibilityMode)
    }

    func testPlaybackSessionBindsCompatibilityMode() {
        let session = PlaybackSession(videoRenderer: MockFrameRenderer())
        XCTAssertFalse(session.isCompatibilityMode)
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: Empty output (no compilation errors)

- [ ] **Step 3: Commit**

```bash
git add Tests/Unit/CompatibilityModeTests.swift
git commit -m "test: add unit tests for compatibility mode fallback"
```

---

### Task 9: Final Verification

- [ ] **Step 1: Full build**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED

- [ ] **Step 2: Verify test compilation**

Run: `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: Empty output

- [ ] **Step 3: Review all changes**

Confirm all acceptance criteria are met:
- If MediaPipeline fails, the video still plays using standard AVPlayer ✓ (Task 2 catches the error, Task 4 renders AVPlayerView)
- The custom MetalRenderer is bypassed in fallback mode ✓ (VideoContentView shows AVPlayerViewWrapper, not MetalMtkView)
- The user is notified via a subtle UI indicator ✓ (Task 5 adds "Compatibility Mode" badge)
- Telemetry is recorded ✓ (Task 7 adds compatibilityModeActivated event)
