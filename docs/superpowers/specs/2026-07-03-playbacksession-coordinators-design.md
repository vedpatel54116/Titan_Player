# PlaybackSession Coordinator Extraction

## Goal

Reduce PlaybackSession from 533 lines to <400 by extracting two focused coordinators while preserving all public API surface.

## Extracted Components

### 1. DisplayCoordinator

Owns display/AirPlay/external-window lifecycle. Moves:
- `displayManager`, `airPlayController`, `secondaryDisplayWindow` stored properties
- `installDisplayBindings()` body and all `handleDisplay*` methods
- Combine subscriptions for display events and AirPlay delay offset

```swift
@MainActor final class DisplayCoordinator {
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
    ) { ... }

    func teardown() {
        secondaryDisplayWindow?.close()
        secondaryDisplayWindow = nil
        cancellables.removeAll()
    }
}
```

**PlaybackSession preserved API:**
- `let displayCoordinator: DisplayCoordinator` (new stored property)
- `var displayManager: DisplayManager { displayCoordinator.displayManager }`
- `var airPlayController: AirPlayController { displayCoordinator.airPlayController }`

### 2. PlaybackTelemetryCoordinator

Owns performance/analysis adapter registration and monitor startup. Moves:
- `perf.registerAdapter(...)` calls (3 adapters)
- `Task.detached { performance.startPerformanceMonitor() }`

```swift
@MainActor final class PlaybackTelemetryCoordinator {
    let performance: PerformanceOptimizer
    let analysis: VideoAnalysisManager?

    init(metalRenderer: MetalRenderer?, engine: PlaybackEngine, streaming: StreamingManager) {
        self.performance = PerformanceOptimizer.makeDefault()
        if let metal = metalRenderer {
            self.analysis = VideoAnalysisManager(metalDevice: /* device */)
            performance.registerAdapter(RenderAdapter(target: metal))
        }
        performance.registerAdapter(DecoderAdapter(target: engine.adaptiveDecoderManager))
        performance.registerAdapter(StreamingAdapter(target: streaming))
    }

    func startMonitor() {
        Task.detached(priority: .background) { [performance] in
            performance.startPerformanceMonitor()
        }
    }
}
```

**PlaybackSession preserved API:**
- `var analysis: VideoAnalysisManager? { telemetryCoordinator.analysis }`
- `var performance: PerformanceOptimizer { telemetryCoordinator.performance }`

### 3. PlaybackSession (Facade)

Remains `@MainActor ObservableObject` with all `@Published` properties unchanged. Init composes the two coordinators. All existing call sites work unchanged.

## Constraints Met

- No @Published property names or public method signatures change
- `SessionLocator.shared.attach(self)` still receives PlaybackSession
- Both coordinators are `@MainActor`, use `[weak self]` / `[weak engine]` to avoid retain cycles
- `stop()` calls `displayCoordinator.teardown()`

## Files to Create/Modify

| Action | File |
|--------|------|
| Create | `TitanPlayer/UI/Session/Displays/DisplayCoordinator.swift` |
| Create | `TitanPlayer/Core/Performance/PlaybackTelemetryCoordinator.swift` |
| Modify | `TitanPlayer/UI/Session/PlaybackSession.swift` |
