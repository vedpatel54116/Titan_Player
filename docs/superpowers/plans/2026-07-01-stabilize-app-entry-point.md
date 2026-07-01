# Stabilize Main App Entry Point — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the app so it launches cleanly, displays a Metal-rendered window with a placeholder, and has no immediate crashes from SwiftUI or Metal initialization.

**Architecture:** Three targeted fixes: (1) remove the phantom `audioRenderer` argument from PlaybackEngine init, (2) make MetalRendererDelegate methods @MainActor to satisfy Swift 6 isolation, (3) enforce window minimum size and default title. Placeholder UI already exists in `VideoContentView`.

**Tech Stack:** Swift, SwiftUI, MetalKit, Combine

---

## Files Modified

| File | Change |
|------|--------|
| `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift` | Fix PlaybackEngine init call (remove audioRenderer arg) |
| `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift` | Add @MainActor to MetalRendererDelegate conformance |
| `TitanPlayer/TitanPlayer/TitanPlayerApp.swift` | Set window title to "Titan Player", add defaultSize constraint |
| `TitanPlayer/TitanPlayer/UI/Views/ContentView.swift` | Ensure minimum frame is 800x450 |
| `TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift` | Verify placeholder text says "Drop a file here to play" |

---

### Task 1: Fix PlaybackEngine init call in PlaybackSession

The build error `extra argument 'audioRenderer' in call` at `PlaybackSession.swift:148` is caused by passing `audioRenderer:` to `PlaybackEngine.init`, which only accepts `videoRenderer:` and `performanceMonitor:`.

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift:146-149`

- [ ] **Step 1: Write the failing test**

No test needed — this is a compile error fix. The build currently fails.

- [ ] **Step 2: Verify build fails**

Run: `cd "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer" && swift build 2>&1 | grep "error:" | head -5`
Expected: `extra argument 'audioRenderer' in call`

- [ ] **Step 3: Fix the PlaybackEngine init call**

In `PlaybackSession.swift`, line 146-149, change:

```swift
self.engine = PlaybackEngine(
    videoRenderer: engineVideoRenderer,
    audioRenderer: resolvedAudioRenderer
)
```

To:

```swift
self.engine = PlaybackEngine(
    videoRenderer: engineVideoRenderer
)
```

The `resolvedAudioRenderer` variable and its creation (lines 133, 134) become unused after this change. Remove the local variables `resolvedAudioRenderer` and `engineVideoRenderer` if they are only used for this call. Specifically:

- Line 133: `let resolvedAudioRenderer = audioRenderer ?? AVAudioEngineRenderer()` — remove
- Line 134: `let resolvedVideoRenderer = videoRenderer ?? (try? MetalRenderer.make())` — keep (used for `self.renderer`)
- Line 135: `self.renderer = resolvedVideoRenderer` — keep
- Line 136: `let engineVideoRenderer = resolvedVideoRenderer ?? NoOpFrameRenderer()` — keep (used for engine init)

After the fix, `resolvedAudioRenderer` is no longer referenced. Remove it and the `audioRenderer` parameter from `init`:

```swift
init(videoRenderer: VideoRenderer? = nil) {
    let resolvedVideoRenderer = videoRenderer ?? (try? MetalRenderer.make())
    self.renderer = resolvedVideoRenderer
    let engineVideoRenderer = resolvedVideoRenderer ?? NoOpFrameRenderer()
    if let metal = resolvedVideoRenderer as? MetalRenderer {
        metal.frameStore = frameStore
    }
    let device = MTLCreateSystemDefaultDevice()
        ?? MTLCreateSystemDefaultDevice()!
    self.analysis = VideoAnalysisManager(metalDevice: device)
    analysis.attach(frameStore: frameStore)
    self.engine = PlaybackEngine(
        videoRenderer: engineVideoRenderer
    )
    self.displayManager = DisplayManager()
    self.airPlayController = AirPlayController(monitor: engine.avPlayer)
    self.streaming = StreamingManager.makeDefault()
    self.performance = PerformanceOptimizer.makeDefault()
    if let metal = resolvedVideoRenderer as? MetalRenderer {
        metal.delegate = self
    }
    installAudioTap()
    setupBindings()
    installKeyMonitor()
    installDisplayBindings()
    SessionLocator.shared.attach(self)
    NotificationCenter.default.addObserver(
        self,
        selector: #selector(applicationWillTerminate),
        name: NSApplication.willTerminateNotification,
        object: nil
    )
}
```

- [ ] **Step 4: Verify build succeeds**

Run: `cd "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer" && swift build 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: empty (no errors)

- [ ] **Step 5: Commit**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player" && git add TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift && git commit -m "fix: remove phantom audioRenderer arg from PlaybackEngine init"
```

---

### Task 2: Fix MetalRendererDelegate isolation

The `MetalRendererDelegate` protocol methods are nonisolated by default, but `PlaybackSession` is `@MainActor`, causing the conformance error at lines 522-532.

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Renderers/FrameRendering.swift:641-644`

- [ ] **Step 1: Add @MainActor to MetalRendererDelegate**

In `FrameRendering.swift`, find the `MetalRendererDelegate` protocol (line 641) and add `@MainActor`:

```swift
@MainActor
protocol MetalRendererDelegate: AnyObject {
    func renderer(_ renderer: MetalRenderer, didDetectHDRMode mode: HDRMode)
    func renderer(_ renderer: MetalRenderer, didUpdateDisplayCapabilities caps: DisplayCapabilities)
}
```

- [ ] **Step 2: Verify build succeeds**

Run: `cd "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer" && swift build 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: empty

- [ ] **Step 3: Commit**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player" && git add TitanPlayer/TitanPlayer/Core/Renderers/FrameRendering.swift && git commit -m "fix: mark MetalRendererDelegate as @MainActor for isolation conformance"
```

---

### Task 3: Set window title and minimum size

The window title is "TitanPlayer" (no space) and the window has no explicit minimum size constraint. Enforce "Titan Player" and 800×450.

**Files:**
- Modify: `TitanPlayer/TitanPlayer/TitanPlayerApp.swift:9`
- Modify: `TitanPlayer/TitanPlayer/UI/Views/ContentView.swift:16`

- [ ] **Step 1: Update window title and add defaultSize**

In `TitanPlayerApp.swift`, line 9, change:

```swift
WindowGroup("TitanPlayer", id: "main") {
```

To:

```swift
WindowGroup("Titan Player", id: "main") {
```

And add a `.defaultSize` modifier after the closing brace of the WindowGroup (after line 24, before `.commands`):

```swift
WindowGroup("Titan Player", id: "main") {
    ContentView()
        .environmentObject(session)
        .environmentObject(telemetry)
        .sheet(isPresented: Binding(
            get: { telemetry.needsConsentPrompt },
            set: { _ in }
        )) {
            PrivacyConsentDialog()
                .environmentObject(telemetry)
        }
        .onAppear {
            telemetry.initialize()
            SessionLocator.shared.attach(session)
        }
}
.defaultSize(width: 960, height: 540)
.commands {
```

- [ ] **Step 2: Update ContentView minimum frame**

In `ContentView.swift`, line 16, change:

```swift
.frame(minWidth: 840, minHeight: 480)
```

To:

```swift
.frame(minWidth: 800, minHeight: 450)
```

- [ ] **Step 3: Verify build succeeds**

Run: `cd "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer" && swift build 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: empty

- [ ] **Step 4: Commit**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player" && git add TitanPlayer/TitanPlayer/TitanPlayerApp.swift TitanPlayer/TitanPlayer/UI/Views/ContentView.swift && git commit -m "fix: set window title to 'Titan Player' and enforce 800x450 minimum size"
```

---

### Task 4: Verify placeholder UI text

The placeholder in `PlayerView.swift` currently says "Drop a video file here". The acceptance criteria specify "Drop a file here to play".

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift:137`

- [ ] **Step 1: Update placeholder text**

In `PlayerView.swift`, line 137, change:

```swift
Text("Drop a video file here").foregroundColor(.gray)
```

To:

```swift
Text("Drop a file here to play").foregroundColor(.gray)
```

- [ ] **Step 2: Verify build succeeds**

Run: `cd "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer" && swift build 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: empty

- [ ] **Step 3: Commit**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player" && git add TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift && git commit -m "fix: update placeholder text to 'Drop a file here to play'"
```

---

### Task 5: Run full build verification

- [ ] **Step 1: Full clean build**

Run: `cd "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer" && swift build 2>&1 | tail -20`
Expected: `Build complete!`

- [ ] **Step 2: Run tests (build only, no test execution)**

Run: `cd "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer" && swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: empty (no compilation errors, only the environmental XCTest module issue)

---

## Acceptance Criteria Verification

| Criteria | How Verified |
|----------|-------------|
| App launches with black MTKView background | MetalMtkView sets `Color.black` as background in VideoContentView; MTKView renders to CAMetalDrawable with black clear color |
| "Drop a file here" placeholder visible | VideoContentView.placeholder shows when `session.playState == .idle` (default state) |
| No immediate crashes on launch | PlaybackEngine init fixed, MetalRendererDelegate isolation fixed, window constraints set |
| Window has minimum 800×450 | ContentView.frame(minWidth: 800, minHeight: 450) |
| Window title is "Titan Player" | WindowGroup("Titan Player") |
