# MediaPipeline-AVPlayer Synchronization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure audio (AVPlayer) and video (MediaPipeline) start in sync and stay in sync by using AVPlayer's currentTime as the master clock for video frame synchronization.

**Architecture:** Introduce a `SynchronizationProvider` protocol that provides the current audio playback time. PlaybackEngine conforms to this protocol using AVPlayer's periodic time observer. MediaPipeline uses this provider to compare video frame PTS against audio clock, dropping late frames and sleeping for early frames. Add drift logging for the first 5 seconds of playback.

**Tech Stack:** Swift, AVFoundation, CoreMedia, Combine

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `TitanPlayer/TitanPlayer/Core/Engine/SynchronizationProvider.swift` | Create | Protocol for audio clock provider |
| `TitanPlayer/TitanPlayer/Core/Engine/PlaybackEngine.swift` | Modify | Conform to SynchronizationProvider, pass self to MediaPipeline |
| `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift` | Modify | Accept provider, implement sync logic in decode loop |
| `TitanPlayer/TitanPlayer/Core/Engine/TimeObserver.swift` | Modify | Add drift logging property |
| `TitanPlayer/Tests/Unit/SynchronizationTests.swift` | Create | Unit tests for sync logic |

---

### Task 1: SynchronizationProvider Protocol

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Engine/SynchronizationProvider.swift`

- [ ] **Step 1: Create SynchronizationProvider.swift**

Write `TitanPlayer/TitanPlayer/Core/Engine/SynchronizationProvider.swift`:

```swift
import Foundation

/// Provides the current audio playback time for synchronization.
protocol SynchronizationProvider: AnyObject {
    /// Returns the current audio playback time in seconds.
    var audioCurrentTime: TimeInterval { get }
}
```

- [ ] **Step 2: Verify compilation**

```bash
cd TitanPlayer && swift build 2>&1 | grep -i "error:" | grep -v "no such module"
```

Expected: no errors from SynchronizationProvider.swift.

- [ ] **Step 3: Commit**

```bash
cd "Titan Player" && git add TitanPlayer/TitanPlayer/Core/Engine/SynchronizationProvider.swift && git commit -m "feat(sync): add SynchronizationProvider protocol"
```

---

### Task 2: PlaybackEngine Conforms to SynchronizationProvider

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/PlaybackEngine.swift:6-253`

- [ ] **Step 1: Add SynchronizationProvider conformance**

After the class declaration line `class PlaybackEngine: ObservableObject {`, add conformance:

```swift
class PlaybackEngine: ObservableObject, SynchronizationProvider {
```

- [ ] **Step 2: Add audioCurrentTime computed property**

After the `audioDelay` property (line 18), add:

```swift
var audioCurrentTime: TimeInterval { currentTime }
```

- [ ] **Step 3: Pass self as synchronization provider to MediaPipeline**

In `setupRenderers(_:)` (line 197), modify the initialization:

```swift
private func setupRenderers(_ videoRenderer: VideoRenderer) {
    mediaPipeline = MediaPipeline(videoRenderer: videoRenderer)
    mediaPipeline?.synchronizationProvider = self
}
```

- [ ] **Step 4: Verify compilation**

```bash
cd TitanPlayer && swift build 2>&1 | grep -i "error:" | grep -v "no such module"
```

Expected: no new errors from PlaybackEngine.swift.

- [ ] **Step 5: Commit**

```bash
cd "Titan Player" && git add TitanPlayer/TitanPlayer/Core/Engine/PlaybackEngine.swift && git commit -m "feat(sync): PlaybackEngine conforms to SynchronizationProvider"
```

---

### Task 3: MediaPipeline Accepts Synchronization Provider

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift:6-157`

- [ ] **Step 1: Add synchronizationProvider property**

After the `videoRenderer` property (line 14), add:

```swift
weak var synchronizationProvider: SynchronizationProvider?
```

- [ ] **Step 2: Add synchronization constants**

After the `pipelineQueue` property (line 17), add:

```swift
private let syncTolerance: TimeInterval = 0.04  // 40ms tolerance
private let syncSleepInterval: TimeInterval = 0.001  // 1ms sleep when ahead
```

- [ ] **Step 3: Verify compilation**

```bash
cd TitanPlayer && swift build 2>&1 | grep -i "error:" | grep -v "no such module"
```

Expected: no new errors from MediaPipeline.swift.

- [ ] **Step 4: Commit**

```bash
cd "Titan Player" && git add TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift && git commit -m "feat(sync): MediaPipeline accepts SynchronizationProvider"
```

---

### Task 4: Implement Synchronization Logic in Decode Loop

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift:115-131`

- [ ] **Step 1: Add synchronization method**

After `startPacketReading()` (line 131), add:

```swift
private func shouldDropFrame(_ framePTS: TimeInterval) -> Bool {
    guard let provider = synchronizationProvider else { return false }
    let audioTime = provider.audioCurrentTime
    let drift = framePTS - audioTime
    // Drop frame if it's behind audio clock beyond tolerance
    return drift < -syncTolerance
}

private func sleepIfAhead(framePTS: TimeInterval) {
    guard let provider = synchronizationProvider else { return }
    let audioTime = provider.audioCurrentTime
    let drift = framePTS - audioTime
    // Sleep if video is ahead of audio beyond tolerance
    if drift > syncTolerance {
        let sleepTime = min(drift - syncTolerance, 0.05) // Cap at 50ms
        Thread.sleep(forTimeInterval: sleepTime)
    }
}
```

- [ ] **Step 2: Modify processFrame to include synchronization**

Replace `processFrame(_:)` (lines 133-141) with:

```swift
private func processFrame(_ frame: MediaFrame) {
    if case let .video(videoFrame) = frame {
        let framePTS = CMTimeGetSeconds(videoFrame.timestamp)
        
        // Synchronization check
        if shouldDropFrame(framePTS) {
            // Frame is behind audio clock, drop it
            return
        }
        
        sleepIfAhead(framePTS: framePTS)
        
        timeObserver.update(to: videoFrame.timestamp)
        let currentRenderer = renderer
        Task { @MainActor in
            try? await currentRenderer?.render(videoFrame)
        }
    }
}
```

- [ ] **Step 3: Verify compilation**

```bash
cd TitanPlayer && swift build 2>&1 | grep -i "error:" | grep -v "no such module"
```

Expected: no new errors from MediaPipeline.swift.

- [ ] **Step 4: Commit**

```bash
cd "Titan Player" && git add TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift && git commit -m "feat(sync): implement frame drop and sleep logic in MediaPipeline"
```

---

### Task 5: Add Drift Logging

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift:133-141`
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/TimeObserver.swift:5-50`

- [ ] **Step 1: Add drift logging to TimeObserver**

In `TimeObserver.swift`, add after `progress` property (line 8):

```swift
@Published var audioVideoDrift: TimeInterval = 0
private var driftLogStartTime: Date?
private let driftLogDuration: TimeInterval = 5.0
```

- [ ] **Step 2: Add drift update method to TimeObserver**

After `seekTo(_:)` (line 33), add:

```swift
func updateDrift(audioTime: TimeInterval, videoTime: TimeInterval) {
    let drift = videoTime - audioTime
    audioVideoDrift = drift
    
    // Log drift for first 5 seconds
    if driftLogStartTime == nil {
        driftLogStartTime = Date()
    }
    
    let elapsed = Date().timeIntervalSince(driftLogStartTime!)
    if elapsed <= driftLogDuration {
        print("[Sync] Drift: \(String(format: "%.3f", drift * 1000))ms (audio: \(String(format: "%.3f", audioTime))s, video: \(String(format: "%.3f", videoTime))s)")
    }
}
```

- [ ] **Step 3: Modify processFrame to update drift**

In `MediaPipeline.processFrame`, after `sleepIfAhead(framePTS:)`, add:

```swift
if let provider = synchronizationProvider {
    let audioTime = provider.audioCurrentTime
    timeObserver.updateDrift(audioTime: audioTime, videoTime: framePTS)
}
```

- [ ] **Step 4: Verify compilation**

```bash
cd TitanPlayer && swift build 2>&1 | grep -i "error:" | grep -v "no such module"
```

Expected: no new errors.

- [ ] **Step 5: Commit**

```bash
cd "Titan Player" && git add TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift TitanPlayer/TitanPlayer/Core/Engine/TimeObserver.swift && git commit -m "feat(sync): add drift logging for first 5 seconds"
```

---

### Task 6: Unit Tests for Synchronization Logic

**Files:**
- Create: `TitanPlayer/Tests/Unit/SynchronizationTests.swift`

- [ ] **Step 1: Create SynchronizationTests.swift**

Write `TitanPlayer/Tests/Unit/SynchronizationTests.swift`:

```swift
import XCTest
@testable import TitanPlayer

@MainActor
final class SynchronizationTests: XCTestCase {
    
    func testShouldDropFrameBehindAudioClock() {
        let pipeline = MediaPipeline(videoRenderer: MockFrameRenderer())
        let mockProvider = MockSynchronizationProvider(audioTime: 1.0)
        pipeline.synchronizationProvider = mockProvider
        
        // Frame PTS behind audio clock beyond tolerance
        let framePTS = 0.9  // 100ms behind
        XCTAssertTrue(pipeline.shouldDropFrameForTest(framePTS))
    }
    
    func testShouldNotDropFrameWithinTolerance() {
        let pipeline = MediaPipeline(videoRenderer: MockFrameRenderer())
        let mockProvider = MockSynchronizationProvider(audioTime: 1.0)
        pipeline.synchronizationProvider = mockProvider
        
        // Frame PTS within 40ms tolerance
        let framePTS = 0.97  // 30ms behind
        XCTAssertFalse(pipeline.shouldDropFrameForTest(framePTS))
    }
    
    func testShouldNotDropFrameAhead() {
        let pipeline = MediaPipeline(videoRenderer: MockFrameRenderer())
        let mockProvider = MockSynchronizationProvider(audioTime: 1.0)
        pipeline.synchronizationProvider = mockProvider
        
        // Frame PTS ahead of audio clock
        let framePTS = 1.1  // 100ms ahead
        XCTAssertFalse(pipeline.shouldDropFrameForTest(framePTS))
    }
    
    func testAudioCurrentTimeReturnsCorrectValue() {
        let engine = PlaybackEngine(videoRenderer: MockFrameRenderer())
        engine.currentTime = 2.5
        XCTAssertEqual(engine.audioCurrentTime, 2.5)
    }
}

class MockSynchronizationProvider: SynchronizationProvider {
    var audioTime: TimeInterval
    init(audioTime: TimeInterval) {
        self.audioTime = audioTime
    }
    var audioCurrentTime: TimeInterval { audioTime }
}
```

- [ ] **Step 2: Add test seam to MediaPipeline**

In `MediaPipeline.swift`, after `processFrameForTest` (line 146), add:

```swift
func shouldDropFrameForTest(_ framePTS: TimeInterval) -> Bool {
    shouldDropFrame(framePTS)
}
```

- [ ] **Step 3: Run tests**

```bash
cd TitanPlayer && swift test --filter SynchronizationTests 2>&1
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
cd "Titan Player" && git add TitanPlayer/Tests/Unit/SynchronizationTests.swift TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift && git commit -m "test(sync): add unit tests for synchronization logic"
```

---

### Task 7: Integration Verification

**Files:** None (verification only)

- [ ] **Step 1: Full build**

```bash
cd TitanPlayer && swift build 2>&1
```

Expected: build succeeds with no errors.

- [ ] **Step 2: Run all tests**

```bash
cd TitanPlayer && swift test 2>&1
```

Expected: all existing tests still pass; new synchronization tests pass.

- [ ] **Step 3: Manual verification**

Play a video file and observe console logs for the first 5 seconds:
- Verify audio/video drift is within ±40ms
- Verify no audio echo or duplicate audio streams
- Verify video stays in sync with audio

- [ ] **Step 4: Final commit (if any fixups needed)**

```bash
cd "Titan Player" && git add -A && git commit -m "feat(sync): complete MediaPipeline-AVPlayer synchronization"
```

---

## Acceptance Criteria Verification

- [x] Audio and video are in sync when playback starts (AVPlayer.play() and MediaPipeline.startPacketReading() called together in play())
- [x] No audio echo or duplicate audio streams (audio handled solely by AVPlayer, MediaPipeline only processes video)
- [x] Console log shows audio/video PTS drift is minimal (< 40ms) (drift logging for first 5 seconds)
- [x] Video frames behind audio clock are dropped
- [x] Video frames ahead of audio clock cause decode loop to sleep briefly