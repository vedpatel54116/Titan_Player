# Swift 6 Strict Concurrency Audit — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Migrate to Swift 6 strict concurrency, make all `@unchecked Sendable` types properly Sendable or documented, fix the `Task.detached` capture hazard, and keep the build green at every step.

**Architecture:** Replace `@unchecked Sendable` with real thread-safety mechanisms (actors, `OSAllocatedUnfairLock`, `NSLock`). Fix the non-Sendable capture in `PlaybackTelemetryCoordinator.startMonitor()`. Bump toolchain to 6.0. Preserve all `@MainActor` annotations on UI-facing classes.

**Tech Stack:** Swift 6, SwiftPM, `OSAllocatedUnfairLock`, Swift actors, `NSLock`.

---

### Task 1: Bump Swift tools version to 6.0

**Files:**
- Modify: `TitanPlayer/Package.swift:1`
- Modify: `TitanPlayer/project.yml:16`

- [ ] **Step 1: Update Package.swift tools version**

Change line 1 of `Package.swift` from:
```swift
// swift-tools-version:5.9
```
to:
```swift
// swift-tools-version:6.0
```

- [ ] **Step 2: Update project.yml Swift version**

Change line 16 of `project.yml` from:
```yaml
SWIFT_VERSION: "5.9"
```
to:
```yaml
SWIFT_VERSION: "6.0"
```

- [ ] **Step 3: Verify build still passes (Swift 5 mode still active until language flag set)**

Run: `swift build` from `TitanPlayer/` directory
Expected: BUILD SUCCEEDED (no language mode flag yet)

---

### Task 2: Fix AdaptiveQualityController — replace @unchecked Sendable with actor

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Performance/AdaptiveQualityController.swift`

`AdaptiveQualityController` has mutable state (`lastActionTimes`, `lastSWSwitchTime`) with no synchronization. Convert to an actor for real Sendable conformance.

- [ ] **Step 1: Convert AdaptiveQualityController to an actor**

Replace the entire content of `AdaptiveQualityController.swift` with:

```swift
import Foundation
import CoreGraphics

actor AdaptiveQualityController {
    private var lastActionTimes: [QualityAction: Date] = [:]
    private let cooldown: TimeInterval = 5.0
    private let decoderSwitchCooldown: TimeInterval = 10.0
    private let swDecodeEstimator = SWDecodeEstimator()
    private var lastSWSwitchTime: Date?

    init() {}

    func evaluate(
        systemState: SystemState,
        prediction: ResourcePrediction,
        metrics: PerformanceMetrics,
        mode: PowerMode,
        settings: CurrentPlaybackSettings
    ) -> [QualityAction] {
        var actions: [QualityAction] = []
        var seen = Set<QualityAction>()

        func add(_ a: QualityAction, cooldown: TimeInterval) {
            guard seen.insert(a).inserted else { return }
            if let lastTime = lastActionTimes[a] {
                guard Date().timeIntervalSince(lastTime) >= cooldown else { return }
            }
            lastActionTimes[a] = Date()
            if case .preferHardware(false) = a {
                lastSWSwitchTime = Date()
            }
            actions.append(a)
        }

        let now = Date()

        func isOnCooldown(_ a: QualityAction) -> Bool {
            guard let lastTime = lastActionTimes[a] else { return false }
            return now.timeIntervalSince(lastTime) < decoderSwitchCooldown
        }

        let pixels = Int(settings.resolution.width * settings.resolution.height)

        // Rule 1 — decoder bias
        let cpuHigh = systemState.cpuUsage > 0.70
        let thermalHot = systemState.thermalState != .nominal
        let isDegraded = metrics.isDegraded || metrics.frameDropRate > 0.05

        if isDegraded,
           settings.decoderIsHW {
            add(.preferHardware(false), cooldown: decoderSwitchCooldown)
        } else if cpuHigh && thermalHot && settings.decoderIsHW {
            if swDecodeEstimator.shouldPreferSW(
                codec: "unknown",
                resolution: settings.resolution,
                hwDecodeTime: metrics.averageDecodeTime
            ) {
                add(.preferHardware(false), cooldown: decoderSwitchCooldown)
            } else {
                add(.downscaleRenderTo(.p1080), cooldown: cooldown)
            }
        } else if mode == .battery, settings.decoderIsHW {
            add(.preferHardware(false), cooldown: decoderSwitchCooldown)
        }
        let swCooldownSatisfied: Bool = {
            guard let lastSW = lastSWSwitchTime else { return true }
            return Date().timeIntervalSince(lastSW) >= decoderSwitchCooldown
        }()

        if mode == .performance,
           !settings.decoderIsHW,
           systemState.thermalState == .nominal,
           !cpuHigh,
           systemState.cpuUsage < 0.50,
           swCooldownSatisfied,
           !isOnCooldown(.preferHardware(true)) {
            add(.preferHardware(true), cooldown: decoderSwitchCooldown)
        }

        // Rule 2 — render resolution cap
        let highRisk = prediction.thermalRiskScore > 0.7
        if (highRisk || mode == .battery),
           let cap = ResolutionCap.p1080.maxPixels,
           pixels > cap {
            add(.downscaleRenderTo(.p1080), cooldown: cooldown)
        }
        if mode == .battery,
           let cap = ResolutionCap.p720.maxPixels,
           pixels > cap {
            add(.downscaleRenderTo(.p720), cooldown: cooldown)
        }

        // Rule 3 — streaming bitrate cap
        let streamingHighRisk = prediction.thermalRiskScore > 0.5
        if streamingHighRisk, settings.isStreaming {
            add(.streamPreferBitrate(min(settings.currentBitrate, 5_000_000)), cooldown: cooldown)
        }
        if mode == .battery, settings.isStreaming {
            add(.streamPreferBitrate(min(settings.currentBitrate, 2_500_000)), cooldown: cooldown)
        }

        // Rule 4 — audio complexity
        if (mode == .battery || prediction.thermalRiskScore > 0.6),
           settings.audioEngineActive {
            add(.reduceAudioComplexity(.simplified), cooldown: cooldown)
        }

        // Rule 5 — prefetch deferral
        if metrics.frameDropRate > 0.05 {
            add(.deferPrefetch(seconds: 2), cooldown: cooldown)
        }

        return actions
    }
}
```

- [ ] **Step 2: Update callers to await the actor**

The only caller is `PerformanceOptimizer.optimizeForCurrentState()` at `PerformanceOptimizer.swift:101`. Change:
```swift
let actions = controller.evaluate(
    systemState: systemState,
    prediction: prediction,
    metrics: metrics,
    mode: mode,
    settings: settings
)
```
to:
```swift
let actions = await controller.evaluate(
    systemState: systemState,
    prediction: prediction,
    metrics: metrics,
    mode: mode,
    settings: settings
)
```

Since `optimizeForCurrentState()` is already `@MainActor`, and the `controller` property is declared as `let controller = AdaptiveQualityController()`, we need to change the property type to `let controller: AdaptiveQualityController = AdaptiveQualityController()`.

- [ ] **Step 3: Run swift build**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED

---

### Task 3: Fix PlaybackTelemetryCoordinator Task.detached capture

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Performance/PlaybackTelemetryCoordinator.swift`

The `Task.detached` at line 33 captures `performance` (a `@MainActor PerformanceOptimizer`) across an isolation boundary. Since `startPerformanceMonitor()` is `nonisolated`, we can just call it directly without Task.detached, or use `@MainActor` Task.

- [ ] **Step 1: Replace Task.detached with a MainActor-isolated Task**

Replace the `startMonitor()` method:

```swift
func startMonitor() {
    Task { @MainActor in
        performance.startPerformanceMonitor()
    }
}
```

This preserves the intent (start monitoring asynchronously) while keeping the capture on the correct isolation domain.

- [ ] **Step 2: Run swift build**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED

---

### Task 4: Make PerformanceOptimizer properly Sendable

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Performance/PerformanceOptimizer.swift`

`PerformanceOptimizer` is `@MainActor` so it is implicitly Sendable (all stored properties are isolated to MainActor). No changes needed — verify the compiler is happy.

- [ ] **Step 1: Verify PerformanceOptimizer compiles**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED — @MainActor classes are implicitly Sendable in Swift 6.

---

### Task 5: Audit and document PlaybackHistory @unchecked Sendable

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Performance/PlaybackHistory.swift`

`PlaybackHistory` uses `NSLock` to protect all mutable state. This is a valid pattern — add a justification comment.

- [ ] **Step 1: Add justification comment**

Change line 41 from:
```swift
final class PlaybackHistory: @unchecked Sendable {
```
to:
```swift
// SAFETY: All mutable state is protected by `lock` (NSLock). Access is
// serialised, so this type is safe to share across concurrency domains.
final class PlaybackHistory: @unchecked Sendable {
```

- [ ] **Step 2: Run swift build**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED

---

### Task 6: Audit and document PerformanceMonitor @unchecked Sendable

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Utilities/PerformanceMonitor.swift`

`PerformanceMonitor` uses `NSLock` for all mutable state. Add a justification comment.

- [ ] **Step 1: Add justification comment**

Change line 43 from:
```swift
class PerformanceMonitor: @unchecked Sendable {
```
to:
```swift
// SAFETY: All mutable state is protected by `lock` (NSLock). Access is
// serialised, so this type is safe to share across concurrency domains.
class PerformanceMonitor: @unchecked Sendable {
```

- [ ] **Step 2: Run swift build**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED

---

### Task 7: Audit and document LFSAudioMeter @unchecked Sendable

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Analysis/LFSAudioMeter.swift`

`LFSAudioMeter` uses a `DispatchQueue` for all audio processing. The `@MainActor` `metering` property is accessed via `Task { @MainActor in }`. Add a justification comment.

- [ ] **Step 1: Add justification comment**

Change line 8 from:
```swift
final class LFSAudioMeter: @unchecked Sendable {
```
to:
```swift
// SAFETY: Audio processing runs on a serial DispatchQueue. The @MainActor
// `metering` property is updated via `Task { @MainActor in }`. All other
// mutable state is accessed only from the serial queue.
final class LFSAudioMeter: @unchecked Sendable {
```

- [ ] **Step 2: Run swift build**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED

---

### Task 8: Audit and document HLSPlayer @unchecked Sendable

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Streaming/HLS/HLSPlayer.swift`

`HLSPlayer` has a `cachedAssets` dictionary with no synchronization. It should either use a lock or become an actor. Since it's a simple cache, make it an actor.

- [ ] **Step 1: Convert HLSPlayer to an actor**

Replace the entire content of `HLSPlayer.swift` with:

```swift
import AVFoundation
import Foundation

protocol HLSPlayerProtocol: AnyObject {
    func makeAsset(url: URL) -> AVURLAsset
    func purge()
}

actor HLSPlayer: HLSPlayerProtocol {
    private var cachedAssets: [String: AVURLAsset] = [:]

    func makeAsset(url: URL) -> AVURLAsset {
        let key = url.absoluteString
        if let cached = cachedAssets[key] { return cached }
        let options: [String: Any] = [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ]
        let asset = AVURLAsset(url: url, options: options)
        cachedAssets[key] = asset
        return asset
    }

    func purge() {
        cachedAssets.removeAll()
    }
}
```

- [ ] **Step 2: Update callers to await the actor**

Check for callers of `HLSPlayer.makeAsset(url:)` and `purge()`. These are async calls on an actor, so callers must `await`.

- [ ] **Step 3: Run swift build**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED

---

### Task 9: Audit and document FFmpegFrameBox @unchecked Sendable

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegSendable.swift`

`FFmpegFrameBox` wraps an `UnsafeMutablePointer<AVFrame>` and frees it on deinit. This is a valid ownership pattern for a boxed C pointer — the pointer is owned by exactly one instance. Add a justification comment.

- [ ] **Step 1: Add justification comment**

Change line 7 from:
```swift
final class FFmpegFrameBox: @unchecked Sendable {
```
to:
```swift
// SAFETY: This box owns a single AVFrame pointer and frees it in deinit.
// The pointer is not shared — it is transferred across isolation boundaries
// as an owning reference. No concurrent mutation occurs after init.
final class FFmpegFrameBox: @unchecked Sendable {
```

- [ ] **Step 2: Run swift build**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED

---

### Task 10: Audit and document DecoderOutput @unchecked Sendable

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Protocols/DecoderCapabilities.swift`

`DecoderOutput` wraps `CMSampleBuffer` and `CVImageBuffer` which are reference types. These are thread-safe reference types (Core Foundation objects). Add a justification comment.

- [ ] **Step 1: Add justification comment**

Change line 27 from:
```swift
enum DecoderOutput: @unchecked Sendable {
```
to:
```swift
// SAFETY: Cases wrap CMSampleBuffer and CVImageBuffer, which are
// Core Foundation reference types that are inherently thread-safe.
enum DecoderOutput: @unchecked Sendable {
```

- [ ] **Step 2: Run swift build**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED

---

### Task 11: Audit and document AdaptiveDecoderManager @unchecked Sendable

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Manager/AdaptiveDecoderManager.swift`

`AdaptiveDecoderManager` has `OSAllocatedUnfairLock` for `preference` and a `DecoderStateActor` for active decoder state. The `hardwareDecoder`, `softwareDecoder`, `currentState`, `currentTrack` are protected by the state actor or accessed from `@MainActor` callers. Add a justification comment.

- [ ] **Step 1: Add justification comment**

Change line 15 from:
```swift
class AdaptiveDecoderManager: @unchecked Sendable {
```
to:
```swift
// SAFETY: Thread safety is provided by:
// - `preferenceLock` (OSAllocatedUnfairLock) for the preference field
// - `stateActor` (DecoderStateActor) for activeDecoder and currentState
// - hardwareDecoder/softwareDecoder are only accessed from async methods
//   that are serialised by the stateActor's coordination.
class AdaptiveDecoderManager: @unchecked Sendable {
```

- [ ] **Step 2: Run swift build**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED

---

### Task 12: Audit and document FFmpegSoftwareDecoder @unchecked Sendable

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Software/FFmpegSoftwareDecoder.swift`

`FFmpegSoftwareDecoder` uses `OSAllocatedUnfairLock` for all mutable state. Add a justification comment.

- [ ] **Step 1: Add justification comment**

Change line 38 from:
```swift
final class FFmpegSoftwareDecoder: VideoDecoding, @unchecked Sendable {
```
to:
```swift
// SAFETY: All mutable state is protected by `lock` (OSAllocatedUnfairLock).
// All access paths acquire the lock before reading or writing.
final class FFmpegSoftwareDecoder: VideoDecoding, @unchecked Sendable {
```

- [ ] **Step 2: Run swift build**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED

---

### Task 13: Audit and document VideoToolboxDecoder @unchecked Sendable

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Hardware/VideoToolboxDecoder.swift`

`VideoToolboxDecoder` uses `OSAllocatedUnfairLock` for all mutable state. Add a justification comment.

- [ ] **Step 1: Add justification comment**

Change line 9 from:
```swift
final class VideoToolboxDecoder: VideoDecoding, @unchecked Sendable {
```
to:
```swift
// SAFETY: All mutable state is protected by `lock` (OSAllocatedUnfairLock).
// The VTDecompressionSession callback runs on an internal VideoToolbox
// thread and only touches state under the lock or via continuation resume.
final class VideoToolboxDecoder: VideoDecoding, @unchecked Sendable {
```

- [ ] **Step 2: Document SessionData @unchecked Sendable**

Change line 83 from:
```swift
private struct SessionData: @unchecked Sendable {
```
to:
```swift
// SAFETY: This is a snapshot of lock-protected state, captured and
// transferred atomically within `submitPacket`. No concurrent mutation.
private struct SessionData: @unchecked Sendable {
```

- [ ] **Step 3: Run swift build**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED

---

### Task 14: Audit MockSentrySDK @unchecked Sendable (test only)

**Files:**
- Modify: `TitanPlayer/Tests/Unit/TelemetryManagerTests.swift`

`MockSentrySDK` is a test-only mock. Test mocks don't need real thread safety. Add a justification comment.

- [ ] **Step 1: Add justification comment**

Change line 5 from:
```swift
final class MockSentrySDK: SentrySDKProtocol, @unchecked Sendable {
```
to:
```swift
// SAFETY: Test-only mock. Accessed only from @MainActor test methods.
final class MockSentrySDK: SentrySDKProtocol, @unchecked Sendable {
```

- [ ] **Step 2: Run swift build**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED

---

### Task 15: Verify FrameStore, MediaPipeline, PlaybackEngine

**Files:**
- Read: `TitanPlayer/TitanPlayer/Core/Engine/FrameStore.swift`
- Read: `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift`
- Read: `TitanPlayer/TitanPlayer/Core/Engine/PlaybackEngine.swift`

These are all `@MainActor` classes. In Swift 6, `@MainActor` classes are implicitly Sendable. No changes needed — verify the compiler is happy.

- [ ] **Step 1: Verify these classes compile**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED — @MainActor classes are implicitly Sendable in Swift 6.

---

### Task 16: Enable Swift 6 language mode and fix remaining diagnostics

**Files:**
- Modify: `TitanPlayer/Package.swift`

Now that all known concurrency issues are fixed, enable Swift 6 language mode.

- [ ] **Step 1: Uncomment and enable strict concurrency in Package.swift**

In `Package.swift`, replace the commented-out swiftSettings block (lines 32-36) with:

```swift
swiftSettings: [
    .swiftLanguageMode(.v6)
],
```

- [ ] **Step 2: Run swift build to find remaining diagnostics**

Run: `swift build` from `TitanPlayer/`
Expected: May produce new diagnostics. Fix each one before proceeding.

- [ ] **Step 3: Fix any remaining diagnostics**

Common fixes:
- Add `@preconcurrency import` for frameworks that don't have complete Sendable conformances
- Add `@Sendable` to closures that cross isolation boundaries
- Use `nonisolated(unsafe)` for properties that are safely accessed from a single thread

- [ ] **Step 4: Run swift build until clean**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED with zero warnings.

---

### Task 17: Run tests

- [ ] **Step 1: Run swift test**

Run: `swift test --parallel` from `TitanPlayer/`
Expected: All tests PASS.

- [ ] **Step 2: If tests fail, fix and re-run**

Fix any test failures (likely just import changes or await requirements) and re-run.

---

### Task 18: Verify @unchecked Sendable audit is complete

- [ ] **Step 1: Grep for remaining @unchecked Sendable**

Run: `grep -rn "@unchecked Sendable" TitanPlayer/`
Expected: Every entry has a `// SAFETY:` comment above it.

- [ ] **Step 2: Final build verification**

Run: `swift build` from `TitanPlayer/`
Expected: BUILD SUCCEEDED with zero warnings.

---

### Task 19: Commit and create PR

- [ ] **Step 1: Create branch and commit**

```bash
git checkout -b refactor/swift6-concurrency-audit
git add -A
git commit -m "refactor: migrate to Swift 6 strict concurrency and audit Sendable"
```

- [ ] **Step 2: Push and create PR**

```bash
git push -u origin refactor/swift6-concurrency-audit
gh pr create --title "refactor: Swift 6 strict concurrency audit" --body "Bumps to swift-tools-version:6.0, makes PerformanceOptimizer/AdaptiveQualityController properly Sendable, removes unjustified @unchecked Sendable, and fixes all Swift 6 diagnostics." --base main
```
