# PlaybackSession Coordinator Extraction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract DisplayCoordinator and PlaybackTelemetryCoordinator from PlaybackSession, reducing it from 533 lines to <400 while preserving all public API.

**Architecture:** Two new `@MainActor` coordinator classes own display/AirPlay/external-window and performance/analysis adapter logic respectively. PlaybackSession becomes a thin facade that composes the coordinators and delegates via computed properties.

**Tech Stack:** Swift, SwiftUI, Combine, Metal

---

## File Map

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `TitanPlayer/TitanPlayer/UI/Session/Displays/DisplayCoordinator.swift` | Display manager, AirPlay controller, external display window, display bindings |
| Create | `TitanPlayer/TitanPlayer/Core/Performance/PlaybackTelemetryCoordinator.swift` | Performance optimizer, video analysis manager, adapter registration, monitor startup |
| Modify | `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift` | Facade: @Published properties, engine wiring, coordinators composition |

---

### Task 1: Create DisplayCoordinator

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Session/Displays/DisplayCoordinator.swift`

- [ ] **Step 1: Create DisplayCoordinator with all display logic**

```swift
import Combine
import AppKit
import Metal

@MainActor
final class DisplayCoordinator {
    let displayManager: DisplayManager
    let airPlayController: AirPlayController

    private var secondaryDisplayWindow: ExternalDisplayWindow?
    private var cancellables = Set<AnyCancellable>()

    init(airPlayPlayer: AVPlayer) {
        self.displayManager = DisplayManager()
        self.airPlayController = AirPlayController(monitor: airPlayPlayer)
    }

    func installDisplayBindings(
        renderer: FrameRendering?,
        engine: PlaybackEngine
    ) {
        displayManager.$activeDisplay
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak renderer] config in
                guard let screen = ScreenLookup.screen(forStableID: config.stableID),
                      let metal = renderer as? MetalRenderer else { return }
                metal.updateDisplayCapabilitiesAsynchronously(for: screen)
            }
            .store(in: &cancellables)

        displayManager.events
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .connected(let config):
                    self.handleDisplayConnected(config, renderer: renderer)
                case .disconnected(let stableID):
                    self.handleDisplayDisconnected(stableID, renderer: renderer)
                case .primaryChanged(let config):
                    self.handlePrimaryChanged(config, renderer: renderer)
                case .refreshed:
                    break
                }
            }
            .store(in: &cancellables)

        airPlayController.$currentAudioDelayOffset
            .removeDuplicates()
            .sink { [weak engine] offset in
                engine?.setAudioDelay(offset)
            }
            .store(in: &cancellables)
    }

    func teardown() {
        secondaryDisplayWindow?.close()
        secondaryDisplayWindow = nil
        cancellables.removeAll()
    }

    // MARK: - Private

    private func handleDisplayConnected(
        _ config: ExternalDisplayConfig,
        renderer: FrameRendering?
    ) {
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

    private func handleDisplayDisconnected(
        _ stableID: String,
        renderer: FrameRendering?
    ) {
        guard let metal = renderer as? MetalRenderer else { return }
        metal.removeDisplayTarget(stableID: stableID)

        secondaryDisplayWindow?.close()
        secondaryDisplayWindow = nil
    }

    private func handlePrimaryChanged(
        _ config: ExternalDisplayConfig,
        renderer: FrameRendering?
    ) {
        if let screen = ScreenLookup.screen(forStableID: config.stableID),
           let window = NSApp.keyWindow ?? NSApp.windows.first {
            window.setFrameOrigin(screen.frame.origin)
        }

        guard let metal = renderer as? MetalRenderer else { return }

        if let oldSecondary = displayManager.secondaryDisplay {
            metal.removeDisplayTarget(stableID: oldSecondary.stableID)
            secondaryDisplayWindow?.close()
            secondaryDisplayWindow = nil
        }

        if let secondary = displayManager.secondaryDisplay,
           let screen = ScreenLookup.screen(forStableID: secondary.stableID) {
            let detector = DisplayCapabilityDetector()
            let caps = detector.detectCapabilities(for: screen)
            let icc = detector.detectICCProfile(for: screen)

            guard let device = MTLCreateSystemDefaultDevice() else { return }
            let window = ExternalDisplayWindow(device: device)
            window.show(on: screen)
            secondaryDisplayWindow = window

            metal.addDisplayTarget(
                stableID: secondary.stableID,
                layer: window.metalLayer,
                capabilities: caps,
                iccProfile: icc
            )
        }
    }
}
```

- [ ] **Step 2: Verify build compiles**

Run from `TitanPlayer/` directory:
```bash
swift build 2>&1 | tail -20
```
Expected: Build succeeds (DisplayCoordinator is created but not yet used — no errors expected).

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/Displays/DisplayCoordinator.swift
git commit -m "feat: add DisplayCoordinator"
```

---

### Task 2: Create PlaybackTelemetryCoordinator

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Performance/PlaybackTelemetryCoordinator.swift`

- [ ] **Step 1: Create PlaybackTelemetryCoordinator**

```swift
import Metal

@MainActor
final class PlaybackTelemetryCoordinator {
    let performance: PerformanceOptimizer
    let analysis: VideoAnalysisManager?

    init(
        metalRenderer: MetalRenderer?,
        engine: PlaybackEngine,
        streaming: StreamingManager,
        frameStore: FrameStore
    ) {
        let perf = PerformanceOptimizer.makeDefault()
        var analysisManager: VideoAnalysisManager?

        if let metal = metalRenderer {
            perf.registerAdapter(RenderAdapter(target: metal))
            if let device = MTLCreateSystemDefaultDevice() {
                let mgr = VideoAnalysisManager(metalDevice: device)
                mgr.attach(frameStore: frameStore)
                analysisManager = mgr
            }
        }
        perf.registerAdapter(DecoderAdapter(target: engine.adaptiveDecoderManager))
        perf.registerAdapter(StreamingAdapter(target: streaming))

        self.performance = perf
        self.analysis = analysisManager
    }

    func startMonitor() {
        Task.detached(priority: .background) { [performance] in
            performance.startPerformanceMonitor()
        }
    }
}
```

- [ ] **Step 2: Verify build compiles**

Run from `TitanPlayer/` directory:
```bash
swift build 2>&1 | tail -20
```
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Performance/PlaybackTelemetryCoordinator.swift
git commit -m "feat: add PlaybackTelemetryCoordinator"
```

---

### Task 3: Wire coordinators into PlaybackSession

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift`

- [ ] **Step 1: Replace stored properties with coordinators and add computed property accessors**

Replace the collaborator declarations block (lines 43-58) with:

```swift
    let frameStore = FrameStore()
    let shortcutManager = KeyboardShortcutManager()
    let displayCoordinator: DisplayCoordinator
    let telemetryCoordinator: PlaybackTelemetryCoordinator

    var displayManager: DisplayManager { displayCoordinator.displayManager }
    var airPlayController: AirPlayController { displayCoordinator.airPlayController }
    var analysis: VideoAnalysisManager? { telemetryCoordinator.analysis }
    var performance: PerformanceOptimizer { telemetryCoordinator.performance }
    let streaming: StreamingManager

    private var keyMonitorToken: Any?

    private let engine: PlaybackEngine
    var avPlayer: AVPlayer { engine.avPlayer }
    private let subtitleManager = SubtitleManager()
    private let bookmarks = BookmarkStore()
    private var cancellables = Set<AnyCancellable>()
```

- [ ] **Step 2: Update init to compose coordinators**

Replace the init body (lines 96-143) with:

```swift
    init(videoRenderer: VideoRenderer? = nil) {
        let resolvedVideoRenderer = videoRenderer ?? (try? MetalRenderer.make())
        self.renderer = resolvedVideoRenderer
        let engineVideoRenderer = resolvedVideoRenderer ?? NoOpFrameRenderer()
        if let metal = resolvedVideoRenderer as? MetalRenderer {
            metal.frameStore = frameStore
        }
        self.engine = PlaybackEngine(videoRenderer: engineVideoRenderer)
        self.streaming = StreamingManager.makeDefault()

        self.displayCoordinator = DisplayCoordinator(airPlayPlayer: engine.avPlayer)
        self.telemetryCoordinator = PlaybackTelemetryCoordinator(
            metalRenderer: resolvedVideoRenderer as? MetalRenderer,
            engine: engine,
            streaming: streaming,
            frameStore: frameStore
        )

        if let metal = resolvedVideoRenderer as? MetalRenderer {
            metal.delegate = self
        }
        if MTLCreateSystemDefaultDevice() == nil && videoRenderer == nil {
            self.initializationError = "Metal GPU is not available. Video rendering will be unavailable."
        }
        installAudioTap()
        setupBindings()
        installKeyMonitor()
        displayCoordinator.installDisplayBindings(renderer: renderer, engine: engine)
        SessionLocator.shared.attach(self)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        telemetryCoordinator.startMonitor()
    }
```

- [ ] **Step 3: Remove `installDisplayBindings()` and display handler methods**

Delete the following methods from PlaybackSession.swift (they now live in DisplayCoordinator):
- `private func installDisplayBindings()` (lines 315-349)
- `private func handleDisplayConnected(...)` (lines 351-371)
- `private func handleDisplayDisconnected(...)` (lines 373-379)
- `private func handlePrimaryChanged(...)` (lines 381-413)

- [ ] **Step 4: Update `stop()` to teardown display coordinator**

Replace `stop()` (lines 252-259) with:

```swift
    func stop() {
        engine.stop()
        subtitleManager.clear()
        performance.observe(settings: nil)
        stopAccessingCurrentResource()
        displayCoordinator.teardown()
    }
```

- [ ] **Step 5: Verify build succeeds**

Run from `TitanPlayer/` directory:
```bash
swift build 2>&1 | tail -20
```
Expected: Build succeeds with no errors.

- [ ] **Step 6: Run tests**

```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: Empty output (no compilation errors beyond environmental XCTest issue).

- [ ] **Step 7: Verify line count**

```bash
wc -l TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift
```
Expected: < 400 lines.

- [ ] **Step 8: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift
git commit -m "refactor: extract DisplayCoordinator and PlaybackTelemetryCoordinator

PlaybackSession now composes two coordinators:
- DisplayCoordinator: display/AirPlay/external window management
- PlaybackTelemetryCoordinator: performance optimizer + analysis adapters

All @Published properties and public API remain unchanged."
```

---

### Task 4: Final verification and PR

- [ ] **Step 1: Full build**

```bash
swift build
```
Expected: `Build complete!`

- [ ] **Step 2: Run test compilation check**

```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: Empty output.

- [ ] **Step 3: Push and create PR**

```bash
git push -u origin refactor/playbacksession-coordinators
gh pr create \
  --title "refactor: split PlaybackSession into coordinators" \
  --body "Extracts DisplayCoordinator (display/AirPlay/external window) and PlaybackTelemetryCoordinator (performance/analysis adapters) from PlaybackSession. PlaybackSession remains the SwiftUI facade." \
  --base main
```
