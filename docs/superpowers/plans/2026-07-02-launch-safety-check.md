# Launch Safety Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a safety wrapper around PlaybackSession initialization so that if any subsystem fails to initialize, the app shows a user-friendly error alert instead of crashing.

**Architecture:** Make PlaybackSession.init() failable, convert risky subsystem initializers to failable/throwing, and add a SwiftUI alert in TitanPlayerApp when initialization fails. PlaybackSession already uses `try? MetalRenderer.make()` for the renderer; the remaining work is: (1) guard the force-unwraps in MetalRenderer.init(), (2) guard the force-unwrap in PlaybackSession's VideoAnalysisManager device creation, (3) make PlaybackSession.init() optional-returning, (4) handle the nil case in TitanPlayerApp with an alert.

**Tech Stack:** Swift, SwiftUI, Metal

---

### Task 1: Make MetalRenderer.init() failable

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift:67-83`

- [ ] **Step 1: Change MetalRenderer.init() from non-failable to failable**

Replace the current `override init()` (lines 67-83) with a failable initializer that guards against nil device and nil command queue:

```swift
override init?() {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue() else {
        return nil
    }
    self.device = device
    self.commandQueue = commandQueue
    super.init()

    var cache: CVMetalTextureCache?
    CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
    textureCache = cache

    setupPipelines()
    setupBuffers()
    if let screen = NSScreen.main {
        updateDisplayCapabilitiesSynchronously(for: screen)
    }
}
```

- [ ] **Step 2: Update MetalRenderer.make() to use the failable init**

The existing `make()` factory at line 838 already checks `MTLCreateSystemDefaultDevice()` and throws `RendererError.deviceUnavailable`. Update it to use the failable init:

```swift
static func make() throws -> MetalRenderer {
    guard MTLCreateSystemDefaultDevice() != nil else {
        throw RendererError.deviceUnavailable
    }
    guard let renderer = MetalRenderer() else {
        throw RendererError.deviceUnavailable
    }
    return renderer
}
```

- [ ] **Step 3: Build to verify**

Run: `swift build` from `TitanPlayer/` directory
Expected: Build succeeds (MetalRenderer is only created via `MetalRenderer.make()` or `try? MetalRenderer.make()` in PlaybackSession, both of which already handle nil/throws)

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift
git commit -m "feat: make MetalRenderer.init() failable to prevent crashes on unsupported devices"
```

---

### Task 2: Guard force-unwraps in PlaybackSession.init()

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift:131-169`

- [ ] **Step 1: Guard the MTLCreateSystemDefaultDevice force-unwrap on line 141-142**

Replace lines 141-142:
```swift
let device = MTLCreateSystemDefaultDevice()
    ?? MTLCreateSystemDefaultDevice()!
```

With:
```swift
let device: MTLDevice?
if let existing = MTLCreateSystemDefaultDevice() {
    device = existing
} else {
    device = MTLCreateSystemDefaultDevice()
}
```

And then guard `device` before creating `VideoAnalysisManager`. If device is nil, use a fallback or skip analysis setup. The analysis property is `let` so we need a different approach — make it optional:

- [ ] **Step 2: Make `analysis` property optional**

Change line 41:
```swift
var analysis: VideoAnalysisManager
```
To:
```swift
var analysis: VideoAnalysisManager?
```

- [ ] **Step 3: Update init to handle nil device gracefully**

Replace lines 131-169 with:

```swift
init(videoRenderer: VideoRenderer? = nil) {
    let resolvedVideoRenderer = videoRenderer ?? (try? MetalRenderer.make())
    self.renderer = resolvedVideoRenderer
    let engineVideoRenderer = resolvedVideoRenderer ?? NoOpFrameRenderer()
    if let metal = resolvedVideoRenderer as? MetalRenderer {
        metal.frameStore = frameStore
    }
    // Video analysis: own a VideoAnalysisManager that subscribes to the
    // session's frame store. Initialize early so `self` is fully available
    // before we register it as the renderer's delegate below.
    if let device = MTLCreateSystemDefaultDevice() {
        self.analysis = VideoAnalysisManager(metalDevice: device)
        analysis?.attach(frameStore: frameStore)
    }
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
    Task.detached(priority: .background) { [performance] in
        performance.startPerformanceMonitor()
    }
}
```

- [ ] **Step 4: Update all references to `analysis` to use optional chaining**

Grep for `analysis.` in PlaybackSession.swift and add `?` after `analysis` where needed. The key references are:
- Line 447: `let meter = analysis.audioMeter` → `let meter = analysis?.audioMeter`
- The `installAudioTap()` closure uses `meter` which may now be nil — handle gracefully

Update `installAudioTap()`:
```swift
private func installAudioTap() {
    guard let meter = analysis?.audioMeter else { return }
    engine.audioTap = { [weak self] frame in
        Task { @MainActor in
            meter.consume(frame: frame)
            if let spatialEngine = self?.engine.activeSpatialAudioEngine,
               spatialEngine.isRunning {
                let buf = Self.makePCMBuffer(from: frame)
                spatialEngine.processAudioBuffer(buf)
            }
        }
    }
}
```

- [ ] **Step 5: Build to verify**

Run: `swift build` from `TitanPlayer/` directory
Expected: Build succeeds

- [ ] **Step 6: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift
git commit -m "feat: guard force-unwraps in PlaybackSession.init() for safer initialization"
```

---

### Task 3: Handle nil renderer gracefully in PlaybackSession

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift`

- [ ] **Step 1: Ensure all Metal-cast sites handle nil renderer**

The renderer is already `FrameRendering?` (line 20), so it can be nil. The existing code already handles this via optional chaining (`if let metal = resolvedVideoRenderer as? MetalRenderer`). Verify no crash paths exist.

Search for `renderer as? MetalRenderer` and `MTLCreateSystemDefaultDevice()!` in PlaybackSession.swift. The force-unwrap at line 387 (`MTLCreateSystemDefaultDevice()!` in `handleDisplayConnected`) needs guarding:

```swift
private func handleDisplayConnected(_ config: ExternalDisplayConfig) {
    guard config.stableID != displayManager.primaryDisplay?.stableID else { return }
    guard let metal = renderer as? MetalRenderer else { return }
    guard let screen = ScreenLookup.screen(forStableID: config.stableID) else { return }

    let detector = DisplayCapabilityDetector()
    let caps = detector.detectCapabilities(for: screen)
    let icc = detector.detectICCProfile(for: screen)

    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let window = ExternalDisplayWindow(device: device)
    window.show(on: screen)
    secondaryDisplayWindow = window

    metal.addDisplayTarget(
        stableID: config.stableID,
        layer: window.metalLayer,
        capabilities: caps,
        iccProfile: icc
    )
}
```

Also guard the same force-unwrap at line 428 in `handlePrimaryChanged`:

```swift
guard let device = MTLCreateSystemDefaultDevice() else { return }
let window = ExternalDisplayWindow(device: device)
```

- [ ] **Step 2: Build to verify**

Run: `swift build` from `TitanPlayer/` directory
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift
git commit -m "feat: guard remaining force-unwraps in PlaybackSession display handling"
```

---

### Task 4: Add initialization error state and alert to PlaybackSession

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift`

- [ ] **Step 1: Add an initializationError published property**

Add after the existing `@Published` properties (around line 32):

```swift
@Published var initializationError: String?
```

- [ ] **Step 2: Set initializationError if critical subsystems fail**

In the init, after creating the video analysis manager, add a check:

```swift
if MTLCreateSystemDefaultDevice() == nil && videoRenderer == nil {
    self.initializationError = "Metal GPU is not available. Video rendering will be unavailable."
}
```

- [ ] **Step 3: Build to verify**

Run: `swift build` from `TitanPlayer/` directory
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift
git commit -m "feat: add initializationError property to PlaybackSession"
```

---

### Task 5: Add SwiftUI alert in TitanPlayerApp for initialization errors

**Files:**
- Modify: `TitanPlayer/TitanPlayer/TitanPlayerApp.swift`

- [ ] **Step 1: Add alert modifier for initialization errors**

In `TitanPlayerApp.swift`, add an `.alert` modifier to the `ContentView()` in the main `WindowGroup`. The session's `initializationError` drives the alert:

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
        .alert(
            "Player Engine Error",
            isPresented: Binding(
                get: { session.initializationError != nil },
                set: { if !$0 { session.initializationError = nil } }
            )
        ) {
            Button("OK") { session.initializationError = nil }
            Button("Restart") { NSApplication.shared.terminate(nil) }
        } message: {
            Text(session.initializationError ?? "Failed to initialize player engine. Please restart the app.")
        }
        .onAppear {
            telemetry.initialize()
            SessionLocator.shared.attach(session)
        }
}
```

- [ ] **Step 2: Build to verify**

Run: `swift build` from `TitanPlayer/` directory
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/TitanPlayerApp.swift
git commit -m "feat: show SwiftUI alert when player engine initialization fails"
```

---

### Task 6: Final verification

- [ ] **Step 1: Full build**

Run: `swift build` from `TitanPlayer/` directory
Expected: Build succeeds with no errors

- [ ] **Step 2: Verify no force-unwraps remain in init paths**

Run: `grep -n '!\s*$\|!)'` on modified files to check for remaining force-unwraps in initialization code paths. The only acceptable force-unwraps are in rendering code (not init paths) where the Metal device is already guaranteed to exist.

- [ ] **Step 3: Review all changes**

Verify the diff covers:
1. `MetalRenderer.init()` is now failable (`init?()`)
2. `MetalRenderer.make()` uses the failable init
3. `PlaybackSession.analysis` is optional
4. Force-unwraps in PlaybackSession init/display handling are guarded
5. `PlaybackSession.initializationError` published property exists
6. `TitanPlayerApp` shows an alert on initialization error
