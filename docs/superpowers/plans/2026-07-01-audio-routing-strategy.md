# Audio Routing Strategy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Strip the dormant `audioRenderer` wiring from `MediaPipeline` and `PlaybackEngine`, making AVPlayer the single source of truth for audio output.

**Architecture:** `MediaPipeline` no longer holds an `AudioRenderer` reference. `PlaybackEngine.init()` drops the `audioRenderer` parameter. `PlaybackSession` stops resolving `AVAudioEngineRenderer` for playback wiring. The `AudioRenderer` protocol and `AVAudioEngineRenderer` concrete type remain for future use (e.g., exotic-codec audio decoding).

**Tech Stack:** Swift, AVFoundation, SwiftPM

---

### Task 1: MediaPipeline — remove audioRenderer

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift:15,124-126`

- [ ] **Remove the `audioRenderer` stored property and init parameter**

Current code (lines 15, 124-126):
```swift
    private let audioRenderer: AudioRenderer
...
    init(videoRenderer: VideoRenderer, audioRenderer: AudioRenderer) {
        self.videoRenderer = videoRenderer
        self.audioRenderer = audioRenderer
    }
```

Replace with:
```swift
    init(videoRenderer: VideoRenderer) {
        self.videoRenderer = videoRenderer
    }
```

---

### Task 2: PlaybackEngine — remove audioRenderer

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/PlaybackEngine.swift:34,46-52,185-186`

- [ ] **Remove the `audioRenderer` stored property**

Remove line 34: `    private let audioRenderer: AudioRenderer`

- [ ] **Remove the `audioRenderer` parameter from `init` and the stored property assignment**

Change lines 46-52:
```swift
    init(videoRenderer: VideoRenderer, audioRenderer: AudioRenderer,
         performanceMonitor: PerformanceMonitor = PerformanceMonitor()) {
        self.videoRenderer = videoRenderer
        self.audioRenderer = audioRenderer
        self.performanceMonitor = performanceMonitor
        self.performanceProbe = EnginePerformanceProbe(monitor: performanceMonitor)
        setupRenderers(videoRenderer, audioRenderer)
```

To:
```swift
    init(videoRenderer: VideoRenderer,
         performanceMonitor: PerformanceMonitor = PerformanceMonitor()) {
        self.videoRenderer = videoRenderer
        self.performanceMonitor = performanceMonitor
        self.performanceProbe = EnginePerformanceProbe(monitor: performanceMonitor)
        setupRenderers(videoRenderer)
```

- [ ] **Update `setupRenderers` signature and body**

Change lines 185-186:
```swift
    private func setupRenderers(_ videoRenderer: VideoRenderer, _ audioRenderer: AudioRenderer) {
        mediaPipeline = MediaPipeline(videoRenderer: videoRenderer, audioRenderer: audioRenderer)
    }
```

To:
```swift
    private func setupRenderers(_ videoRenderer: VideoRenderer) {
        mediaPipeline = MediaPipeline(videoRenderer: videoRenderer)
    }
```

---

### Task 3: PlaybackSession — remove audioRenderer

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift:49-68`

- [ ] **Remove `audioRenderer` init parameter and its resolution**

Current lines 49-51:
```swift
    init(videoRenderer: VideoRenderer? = nil, audioRenderer: AudioRenderer? = nil) {
        let resolvedVideoRenderer = videoRenderer ?? (try? MetalRenderer.make())
        let resolvedAudioRenderer = audioRenderer ?? AVAudioEngineRenderer()
```

Replace with:
```swift
    init(videoRenderer: VideoRenderer? = nil) {
        let resolvedVideoRenderer = videoRenderer ?? (try? MetalRenderer.make())
```

- [ ] **Remove `audioRenderer:` label from engine init call**

Line 65-68:
```swift
        self.engine = PlaybackEngine(
            videoRenderer: engineVideoRenderer,
            audioRenderer: resolvedAudioRenderer
        )
```

Replace with:
```swift
        self.engine = PlaybackEngine(
            videoRenderer: engineVideoRenderer
        )
```

---

### Task 4: Update test files — remove `audioRenderer:` argument

**Files:**
- Modify: `TitanPlayer/Tests/Integration/PlaybackEngineIntegrationTests.swift:7`
- Modify: `TitanPlayer/Tests/Integration/PlaybackPipelineTests.swift:7`
- Modify: `TitanPlayer/Tests/Unit/MediaPipelineRendererRoutingTests.swift:11,33`
- Modify: `TitanPlayer/Tests/Unit/MediaPipelineRateTests.swift:6`
- Modify: `TitanPlayer/Tests/Unit/PlaybackEngineCoreTests.swift:7`
- Modify: `TitanPlayer/Tests/Unit/PlaybackEngineRateTests.swift:7`
- Modify: `TitanPlayer/Tests/Unit/PlaybackEngineGaplessTests.swift:7`
- Modify: `TitanPlayer/Tests/Unit/PlaybackEngineSyncTests.swift:7`
- Modify: `TitanPlayer/Tests/Unit/AnalysisPipelineIntegrationTests.swift:10`
- Modify: `TitanPlayer/Tests/Unit/PlaybackSessionTests.swift:9`
- Modify: `TitanPlayer/Tests/Unit/PlayerActionDispatcherTests.swift:15`
- Modify: `TitanPlayer/Tests/Unit/TouchBarControllerTests.swift:10,67`
- Modify: `TitanPlayer/Tests/AudioTests/AudioIntegrationTests.swift:10,22`

For each file, remove the `audioRenderer: MockAudioRenderer()` argument from `PlaybackEngine(...)` and `MediaPipeline(...)` constructor calls.

Example change (`PlaybackEngineIntegrationTests.swift`):
```swift
// Before:
PlaybackEngine(videoRenderer: MockFrameRenderer(), audioRenderer: MockAudioRenderer())
// After:
PlaybackEngine(videoRenderer: MockFrameRenderer())
```

Example change (`PlaybackPipelineTests.swift`):
```swift
// Before:
MediaPipeline(videoRenderer: MockFrameRenderer(), audioRenderer: MockAudioRenderer())
// After:
MediaPipeline(videoRenderer: MockFrameRenderer())
```

- [ ] **Update PlaybackEngineIntegrationTests.swift**
- [ ] **Update PlaybackPipelineTests.swift**
- [ ] **Update MediaPipelineRendererRoutingTests.swift** (two occurrences)
- [ ] **Update MediaPipelineRateTests.swift**
- [ ] **Update PlaybackEngineCoreTests.swift**
- [ ] **Update PlaybackEngineRateTests.swift**
- [ ] **Update PlaybackEngineGaplessTests.swift**
- [ ] **Update PlaybackEngineSyncTests.swift**
- [ ] **Update AnalysisPipelineIntegrationTests.swift**
- [ ] **Update PlaybackSessionTests.swift**
- [ ] **Update PlayerActionDispatcherTests.swift**
- [ ] **Update TouchBarControllerTests.swift** (two occurrences)
- [ ] **Update AudioIntegrationTests.swift** (two occurrences)

---

### Task 5: Verify build

- [ ] **Build the executable target**

Run: `swift build` (from `TitanPlayer/` directory)
Expected: Build succeeds with no errors

- [ ] **Check test target compilation**

Run: `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: Empty output (no compilation errors in test target aside from the known XCTest environmental limitation)
