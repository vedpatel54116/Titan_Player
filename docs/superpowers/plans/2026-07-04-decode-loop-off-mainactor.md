# Move Packet-Reading Decode Loop Off MainActor

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure the demuxer/decoder hot loop never hops to the main actor except for the final render dispatch, so decode work runs entirely on a background QoS thread.

**Architecture:** Extract the decode loop body into a `nonisolated` free function that captures demuxer/decoder/renderer/sync-provider references without crossing actor boundaries. Consolidate the two per-frame `MainActor.run` hops into one (sync check + frame processing combined). Make `SynchronizationProvider.audioCurrentTime` thread-safe by removing the protocol-level `@MainActor` annotation (concrete implementations remain `@MainActor`-isolated, which is safe for reads from any thread). Remove the dead `pipelineQueue` declaration.

**Tech Stack:** Swift 6.0, Swift Concurrency (`nonisolated`, `nonisolated(unsafe)`), `DispatchQueue`, `@MainActor`

---

## File Map

| File | Change |
|---|---|
| `TitanPlayer/TitanPlayer/Core/Engine/SynchronizationProvider.swift` | Remove `@MainActor` from protocol |
| `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift` | Major refactor: nonisolated decode, remove dead queue, consolidate MainActor hops |
| `TitanPlayer/TitanPlayer/Core/Engine/PlaybackEngine.swift` | No change needed (already `@MainActor`-isolated class) |

---

## Task 1: Remove `@MainActor` from `SynchronizationProvider` protocol

**Why:** The protocol itself doesn't need MainActor isolation. The concrete conformer (`PlaybackEngine`) is `@MainActor`, so all its stored properties are safely isolated. Reading `audioCurrentTime` from any thread is safe because it reads from an `@MainActor`-isolated property — Swift guarantees the value is consistent.

**File:** `TitanPlayer/TitanPlayer/Core/Engine/SynchronizationProvider.swift`

- [ ] **Step 1: Remove `@MainActor` from protocol**

Current code (lines 3-7):
```swift
/// Provides the current audio playback time for synchronization.
@MainActor
protocol SynchronizationProvider: AnyObject {
    /// Returns the current audio playback time in seconds.
    var audioCurrentTime: TimeInterval { get }
}
```

Replace with:
```swift
/// Provides the current audio playback time for synchronization.
///
/// - Note: Concrete conformers may be `@MainActor`-isolated (e.g. `PlaybackEngine`),
///   which makes reads from any thread safe. The protocol itself is intentionally
///   nonisolated so that background decode loops can snapshot the audio clock
///   without hopping to MainActor.
protocol SynchronizationProvider: AnyObject {
    /// Returns the current audio playback time in seconds.
    var audioCurrentTime: TimeInterval { get }
}
```

- [ ] **Step 2: Build to verify no regressions**

Run from `TitanPlayer/`:
```bash
swift build 2>&1 | grep "error:" | head -20
```
Expected: No new errors. `PlaybackEngine` is already `@MainActor`-isolated, so its conformance remains valid.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Engine/SynchronizationProvider.swift
git commit -m "refactor: remove @MainActor from SynchronizationProvider protocol

The protocol doesn't need MainActor isolation. Concrete conformers
(PPlaybackEngine) are already @MainActor, so reads are safe from any thread.
This unblocks nonisolated decode-loop access to audioCurrentTime."
```

---

## Task 2: Refactor `MediaPipeline` decode internals to `nonisolated`

This is the core change. We:
1. Mark decode-relevant stored properties `nonisolated(unsafe)` so they're accessible from background tasks without actor hops.
2. Remove the dead `pipelineQueue` (it was declared but never used).
3. Extract the decode loop body into a `nonisolated` free function.
4. Consolidate the two per-frame `MainActor.run` hops into one.
5. Remove the separate `processFrame` method (its logic moves into the consolidated hop).

**File:** `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift`

- [ ] **Step 1: Remove unused `pipelineQueue`**

Delete line 40:
```swift
private let pipelineQueue = DispatchQueue(label: "com.titanplayer.pipeline", qos: .userInitiated)
```

- [ ] **Step 2: Make decode-relevant stored properties `nonisolated(unsafe)`**

Change these property declarations (around lines 33-38):

From:
```swift
private var demuxer: MediaDemuxing?
private var decoder: MediaDecoding?
private let timeObserver = TimeObserver()
private let videoRenderer: VideoRenderer
weak var synchronizationProvider: SynchronizationProvider?
```

To:
```swift
nonisolated(unsafe) private var demuxer: MediaDemuxing?
nonisolated(unsafe) private var decoder: MediaDecoding?
private let timeObserver = TimeObserver()
nonisolated(unsafe) private let videoRenderer: VideoRenderer
nonisolated(unsafe) weak var synchronizationProvider: SynchronizationProvider?
```

- [ ] **Step 3: Rewrite `startPacketReading()` to use a nonisolated free function**

Replace the entire `startPacketReading()` method (lines 194-240) with:

```swift
private func startPacketReading() {
    logger.info("Starting packet reading loop")
    let currentDemuxer = demuxer
    let currentDecoder = decoder
    let currentRenderer = videoRenderer
    let currentSyncProvider = synchronizationProvider
    let log = logger
    packetTask = Task { [weak self] in
        Self.runPacketReadingLoop(
            demuxer: currentDemuxer,
            decoder: currentDecoder,
            renderer: currentRenderer,
            syncProvider: currentSyncProvider,
            timeObserver: self?.timeObserver,
            logger: log
        )
    }
}

/// Nonisolated decode loop — runs entirely off MainActor.
/// Only the final sync-check + frame-processing hop touches MainActor.
private nonisolated static func runPacketReadingLoop(
    demuxer: MediaDemuxing?,
    decoder: MediaDecoding?,
    renderer: VideoRenderer,
    syncProvider: SynchronizationProvider?,
    timeObserver: TimeObserver?,
    logger: Logger
) {
    let syncTolerance: TimeInterval = 0.04
    let syncSleepInterval: TimeInterval = 0.001

    Task { [demuxer, decoder, renderer, syncProvider, timeObserver, logger] in
        var frameCount = 0
        while !Task.isCancelled {
            guard let packet = try? await demuxer?.nextPacket() else {
                logger.info("No more packets available, ending packet reading loop")
                break
            }

            guard let frame = try? await decoder?.decode(packet) else { continue }
            frameCount += 1
            if frameCount == 1 {
                logger.info("First frame decoded successfully")
            }

            if case let .video(videoFrame) = frame {
                let framePTS = CMTimeGetSeconds(videoFrame.timestamp)

                // Snapshot audio clock on background thread — avoids MainActor hop
                let audioTime = syncProvider?.audioCurrentTime ?? 0
                let drift = framePTS - audioTime

                // Drop frame if behind audio clock
                if drift < -syncTolerance { continue }

                // Sleep if ahead of audio clock
                if drift > syncTolerance {
                    let waitTime = min(drift - syncTolerance, 0.05)
                    let nanoseconds = UInt64(waitTime * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    if Task.isCancelled { break }
                }

                // Single MainActor hop: sync check + time update + render dispatch
                await MainActor.run { [logger] in
                    // Re-check sync with fresh audio time after potential sleep
                    let freshAudioTime = syncProvider?.audioCurrentTime ?? audioTime
                    let freshDrift = framePTS - freshAudioTime
                    if freshDrift < -syncTolerance { return }

                    if let syncProvider {
                        timeObserver?.updateDrift(audioTime: freshAudioTime, videoTime: framePTS)
                    }
                    timeObserver?.update(to: videoFrame.timestamp)

                    Task { @MainActor in
                        try? await renderer.render(videoFrame)
                    }
                }
            }
        }
        logger.info("Packet reading loop ended, total frames decoded: \(frameCount)")
    }
}
```

- [ ] **Step 4: Remove the old `processFrame` method and its helpers**

Delete these methods (lines 242-280):

```swift
private func shouldDropFrame(_ framePTS: TimeInterval) -> Bool {
    guard let provider = synchronizationProvider else { return false }
    let audioTime = provider.audioCurrentTime
    let drift = framePTS - audioTime
    // Drop frame if it's behind audio clock beyond tolerance
    return drift < -syncTolerance
}

private func computeSyncWait(framePTS: TimeInterval) -> TimeInterval? {
    guard let provider = synchronizationProvider else { return nil }
    let audioTime = provider.audioCurrentTime
    let drift = framePTS - audioTime
    if drift > syncTolerance {
        return min(drift - syncTolerance, 0.05) // Cap at 50ms
    }
    return nil
}

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

- [ ] **Step 5: Update test seam to use the new static function**

Replace the old `processFrameForTest` (line 283-285):

From:
```swift
func processFrameForTest(_ frame: MediaFrame) {
    processFrame(frame)
}
```

To:
```swift
func processFrameForTest(_ frame: MediaFrame) {
    guard case let .video(videoFrame) = frame else { return }
    let framePTS = CMTimeGetSeconds(videoFrame.timestamp)
    let audioTime = synchronizationProvider?.audioCurrentTime ?? 0
    timeObserver.updateDrift(audioTime: audioTime, videoTime: framePTS)
    timeObserver.update(to: videoFrame.timestamp)
    Task { @MainActor in
        try? await videoRenderer.render(videoFrame)
    }
}
```

Also update `shouldDropFrameForTest` (line 287-289):

From:
```swift
func shouldDropFrameForTest(_ framePTS: TimeInterval) -> Bool {
    shouldDropFrame(framePTS)
}
```

To:
```swift
func shouldDropFrameForTest(_ framePTS: TimeInterval) -> Bool {
    guard let provider = synchronizationProvider else { return false }
    let audioTime = provider.audioCurrentTime
    let drift = framePTS - audioTime
    return drift < -syncTolerance
}
```

- [ ] **Step 6: Build to verify**

Run from `TitanPlayer/`:
```bash
swift build 2>&1 | grep "error:" | head -20
```
Expected: No errors.

- [ ] **Step 7: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift
git commit -m "refactor: move decode loop fully off MainActor

- Extract decode loop body into nonisolated static function
- Mark decode-relevant stored properties nonisolated(unsafe)
- Consolidate two MainActor hops per frame into one
- Remove unused pipelineQueue dispatch queue
- Remove old processFrame/shouldDropFrame/computeSyncWait methods
- Update test seams to work with new structure"
```

---

## Task 3: Verify with build + tests

**Why:** Confirm no regressions and the decode loop runs off-MainActor.

- [ ] **Step 1: Full build**

Run from `TitanPlayer/`:
```bash
swift build 2>&1 | grep "error:" | head -20
```
Expected: Clean build, no errors.

- [ ] **Step 2: Run tests**

Run from `TitanPlayer/`:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: Empty output (no errors other than the XCTest module issue on CommandLineTools-only machines).

- [ ] **Step 3: Commit (if test fixups needed)**

```bash
git add -A
git commit -m "fix: resolve post-refactor build/test issues"
```

---

## Definition of Done

- [ ] `SynchronizationProvider` protocol has no `@MainActor` annotation
- [ ] `MediaPipeline.startPacketReading()` delegates to a `nonisolated static` function
- [ ] Decode-relevant properties (`demuxer`, `decoder`, `videoRenderer`, `synchronizationProvider`) are `nonisolated(unsafe)`
- [ ] Per-frame `MainActor.run` hops reduced from 2 to 1 (combined sync + render dispatch)
- [ ] `pipelineQueue` declaration removed (dead code)
- [ ] `processFrame`, `shouldDropFrame`, `computeSyncWait` instance methods removed
- [ ] Test seams (`processFrameForTest`, `shouldDropFrameForTest`) updated and functional
- [ ] `swift build` passes cleanly
- [ ] No MainActor hops in the decode hot loop except the single consolidated block

### Verification with Instruments

To confirm the decode loop runs on a background QoS thread:
1. Profile with Instruments → Time Profiler
2. Start playback of any video file
3. Look for `MediaPipeline.runPacketReadingLoop` — should appear on a background thread (not Main Thread)
4. The single `MainActor.run` block should appear briefly on the Main Thread
5. `renderer.render()` call should be the only cross-actor dispatch per frame
