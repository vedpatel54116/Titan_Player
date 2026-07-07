# Remove Thread.sleep from MainActor Packet Loop

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate main-thread stalls by replacing `Thread.sleep(forTimeInterval:)` in `MediaPipeline.processFrame` with cooperative `Task.sleep` in the packet-reading Task, ensuring no main-thread block exceeds 16 ms.

**Architecture:** The sync-drift sleep currently runs inside `MainActor.run { ... }`, blocking the UI. The fix moves the sleep computation into the packet Task (off MainActor) using `Task.sleep(nanoseconds:)`. `processFrame` becomes a pure decision + dispatch function that never sleeps.

**Tech Stack:** Swift 5.9, SwiftPM, async/await, Combine

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift` | Modify | Refactor `startPacketReading`, `processFrame`, `sleepIfAhead`; remove `Thread.sleep` |
| `TitanPlayer/Tests/Unit/SynchronizationTests.swift` | Verify | Existing sync tests must still pass |

No new files created.

---

### Task 1: Refactor `sleepIfAhead` to return sleep duration instead of sleeping

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift:228-237`

- [ ] **Step 1: Replace `sleepIfAhead` with a pure function that computes wait time**

Change `sleepIfAhead(framePTS:)` from a void method that calls `Thread.sleep` to a method that returns an optional `TimeInterval` representing how long the caller should wait. The caller (the packet Task) will perform the actual sleep cooperatively.

Replace:
```swift
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

With:
```swift
    private func computeSyncWait(framePTS: TimeInterval) -> TimeInterval? {
        guard let provider = synchronizationProvider else { return nil }
        let audioTime = provider.audioCurrentTime
        let drift = framePTS - audioTime
        if drift > syncTolerance {
            return min(drift - syncTolerance, 0.05) // Cap at 50ms
        }
        return nil
    }
```

- [ ] **Step 2: Update `processFrame` to remove the `sleepIfAhead` call**

In `processFrame`, remove the `sleepIfAhead(framePTS: framePTS)` call. The sleep will now be handled by the packet Task before dispatching to MainActor.

Replace:
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
            
            if let provider = synchronizationProvider {
                let audioTime = provider.audioCurrentTime
                timeObserver.updateDrift(audioTime: audioTime, videoTime: framePTS)
            }
            
            timeObserver.update(to: videoFrame.timestamp)
            let currentRenderer = renderer
            Task { @MainActor in
                try? await currentRenderer?.render(videoFrame)
            }
        }
    }
```

With:
```swift
    private func processFrame(_ frame: MediaFrame) {
        if case let .video(videoFrame) = frame {
            let framePTS = CMTimeGetSeconds(videoFrame.timestamp)
            
            // Synchronization check
            if shouldDropFrame(framePTS) {
                return
            }
            
            if let provider = synchronizationProvider {
                let audioTime = provider.audioCurrentTime
                timeObserver.updateDrift(audioTime: audioTime, videoTime: framePTS)
            }
            
            timeObserver.update(to: videoFrame.timestamp)
            let currentRenderer = renderer
            Task { @MainActor in
                try? await currentRenderer?.render(videoFrame)
            }
        }
    }
```

- [ ] **Step 3: Verify build compiles**

Run: `swift build` from `TitanPlayer/` directory.
Expected: Build succeeds (no reference to removed `sleepIfAhead` remains).

---

### Task 2: Refactor `startPacketReading` to perform sync sleep cooperatively off MainActor

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift:194-218`

- [ ] **Step 1: Rewrite `startPacketReading` to compute and await sync wait in the packet Task**

The packet Task runs off MainActor. After decoding a frame, it:
1. Checks if the frame should be dropped (via `shouldDropFrame` — needs MainActor access for `synchronizationProvider`).
2. Computes sync wait time (via `computeSyncWait` — also needs MainActor access).
3. Performs the sleep via `Task.sleep(nanoseconds:)` cooperatively.
4. Dispatches frame processing to MainActor.

Since `shouldDropFrame` and `computeSyncWait` read `synchronizationProvider` which is `@MainActor`, we need to `await` them on MainActor. The key insight: we can batch the decision + sleep computation into a single MainActor hop, then sleep off MainActor.

Replace:
```swift
    private func startPacketReading() {
        logger.info("Starting packet reading loop")
        packetTask = Task { [weak self] in
            guard let self = self else { return }
            
            var frameCount = 0
            while !Task.isCancelled {
                guard let packet = try? await self.demuxer?.nextPacket() else {
                    self.logger.info("No more packets available, ending packet reading loop")
                    break
                }
                
                if let frame = try? await self.decoder?.decode(packet) {
                    frameCount += 1
                    if frameCount == 1 {
                        self.logger.info("First frame decoded successfully")
                    }
                    await MainActor.run {
                        self.processFrame(frame)
                    }
                }
            }
            self.logger.info("Packet reading loop ended, total frames decoded: \(frameCount)")
        }
    }
```

With:
```swift
    private func startPacketReading() {
        logger.info("Starting packet reading loop")
        packetTask = Task { [weak self] in
            guard let self = self else { return }
            
            var frameCount = 0
            while !Task.isCancelled {
                guard let packet = try? await self.demuxer?.nextPacket() else {
                    self.logger.info("No more packets available, ending packet reading loop")
                    break
                }
                
                if let frame = try? await self.decoder?.decode(packet) {
                    frameCount += 1
                    if frameCount == 1 {
                        self.logger.info("First frame decoded successfully")
                    }
                    
                    // Compute sync decisions on MainActor, then sleep cooperatively off MainActor
                    let syncAction = await MainActor.run { () -> (shouldDrop: Bool, syncWait: TimeInterval?) in
                        if case let .video(videoFrame) = frame {
                            let framePTS = CMTimeGetSeconds(videoFrame.timestamp)
                            let drop = self.shouldDropFrame(framePTS)
                            let wait = self.computeSyncWait(framePTS: framePTS)
                            return (drop, wait)
                        }
                        return (false, nil)
                    }
                    
                    if syncAction.shouldDrop {
                        continue
                    }
                    
                    if let waitTime = syncAction.syncWait, waitTime > 0 {
                        let nanoseconds = UInt64(waitTime * 1_000_000_000)
                        try? await Task.sleep(nanoseconds: nanoseconds)
                        
                        // Re-check cancellation after sleeping
                        if Task.isCancelled { break }
                    }
                    
                    await MainActor.run {
                        self.processFrame(frame)
                    }
                }
            }
            self.logger.info("Packet reading loop ended, total frames decoded: \(frameCount)")
        }
    }
```

- [ ] **Step 2: Verify build compiles**

Run: `swift build` from `TitanPlayer/` directory.
Expected: Build succeeds.

---

### Task 3: Remove `Thread.sleep` import dependency

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift:1`

- [ ] **Step 1: Check if `Thread.sleep` or any other `Thread` usage exists in MediaPipeline.swift**

Grep confirmed only one usage (line 235) which is now removed. The `import Foundation` statement is still needed for other Foundation types (`URL`, `TimeInterval`, etc.), so no import changes are needed — `Foundation` already covers everything.

No action needed — `import Foundation` stays. `Thread.sleep` is gone.

- [ ] **Step 2: Verify no `Thread` references remain**

Run: `grep -n "Thread" TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift`
Expected: No output (no Thread references).

---

### Task 4: Run existing tests to verify no regressions

**Files:**
- Test: `TitanPlayer/Tests/Unit/SynchronizationTests.swift`

- [ ] **Step 1: Run synchronization tests**

Run: `swift test --filter SynchronizationTests` from `TitanPlayer/` directory.
Expected: All 4 tests pass.

- [ ] **Step 2: Run all unit tests**

Run: `swift test` from `TitanPlayer/` directory.
Expected: All tests pass.

- [ ] **Step 3: Verify Thread.sleep is completely gone from MediaPipeline.swift**

Run: `grep -c "Thread.sleep" TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift`
Expected: `0`

---

### Task 5: Verify build succeeds with no warnings in the modified file

**Files:**
- Verify: `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift`

- [ ] **Step 1: Full build**

Run: `swift build 2>&1` from `TitanPlayer/` directory.
Expected: Build succeeds with no errors. Check output for any warnings in MediaPipeline.swift.

- [ ] **Step 2: Confirm preserved constants**

Grep for `syncTolerance` and `syncSleepInterval` in MediaPipeline.swift to confirm they are still present and unchanged.

Run: `grep -n "syncTolerance\|syncSleepInterval" TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift`
Expected: Lines showing both constants with original values (0.04 and 0.001).

---

## Self-Review Checklist

1. **Spec coverage:** ✓
   - Move sync-drift sleep out of MainActor.run → Task 2
   - processFrame does only decision + update + dispatch → Task 1 Step 2
   - Refactor startPacketReading for cooperative awaiting → Task 2
   - Remove Thread.sleep import if unused → Task 3 (confirmed only usage removed)
   - Preserve syncTolerance and syncSleepInterval → Verified in constants (lines 41-42), untouched
   - Keep shouldDropFrame logic intact → Only the call site moved, logic unchanged

2. **Placeholder scan:** ✓ No TBD/TODO placeholders.

3. **Type consistency:** ✓ `computeSyncWait` returns `TimeInterval?`, `syncAction` tuple uses `(shouldDrop: Bool, syncWait: TimeInterval?)`, all types match existing code.
