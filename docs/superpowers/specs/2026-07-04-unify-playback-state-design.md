# Unify Playback State Into Single Source of Truth

**Date:** 2026-07-04
**Status:** Approved
**Author:** opencode

## Problem

`PlaybackEngine.state` and `MediaPipeline.playState` are two independent `@Published` state machines using the same `PlaybackState` enum. They can theoretically drift:
- `MediaPipeline.play()` guards on its own `playState == .paused || .idle`
- If the two state machines get out of sync (e.g., engine says `.playing` but pipeline says `.error`), `MediaPipeline.play()` silently no-ops
- `MediaPipeline.playState` is never read from outside `MediaPipeline.swift` — it's a dead `@Published` property that adds confusion

## Goal

Eliminate the dual state machines. `PlaybackEngine` remains the single `@Published PlaybackState` source. `MediaPipeline` becomes stateless regarding high-level playback, using an internal `PipelinePhase` enum that only reflects decode-loop state.

## Design

### 1. New `PipelinePhase` enum (internal to MediaPipeline)

```swift
// MediaPipeline.swift — internal, not @Published
enum PipelinePhase {
    case idle        // No file loaded or after stop()
    case loading     // openFile/openStream in progress
    case decoding    // Decode loop is running
    case paused      // Decode loop paused (waiting for play command)
    case stopped     // Explicitly stopped
    case error(String)
}
```

- **Internal** — no `@Published`, no `ObservableObject` exposure
- Replaces `@Published var playState: PlaybackState = .idle`
- The decode loop reads `phase` to decide whether to continue reading packets

### 2. Method signatures accept `PlaybackState` from caller

Current:
```swift
func play()  { guard playState == .paused || playState == .idle else { return }; ... }
func pause() { guard playState == .playing else { return }; ... }
func stop()  { playState = .idle; ... }
```

New:
```swift
func play(currentState: PlaybackState)  { phase = .decoding; startPacketReading() }
func pause(currentState: PlaybackState) { phase = .paused }
func stop(currentState: PlaybackState)  { phase = .stopped; cancelTasks() }
```

- **No guards** — MediaPipeline trusts PlaybackEngine as the authority
- The `currentState` parameter is accepted for API consistency and future debugging
- Internal `phase` transitions are driven by method bodies, not by validating the passed state

### 3. PlaybackEngine callers pass `self.state`

```swift
// PlaybackEngine.swift
func play() {
    state = .playing
    mediaPipeline?.play(currentState: state)
}
func pause() {
    state = .paused
    mediaPipeline?.pause(currentState: state)
}
func stop() {
    state = .idle
    mediaPipeline?.stop(currentState: state)
}
```

- Engine remains the single `@Published PlaybackState` source
- No bindings from `engine.$state` to MediaPipeline — the engine calls methods imperatively

### 4. Decode loop uses `phase` internally

```swift
// In startPacketReading()
while phase == .decoding {
    // read packets, process frames
}
```

- `pause()` sets `phase = .paused`, which stops the loop
- `play()` sets `phase = .decoding` and restarts the loop

### 5. openFile/openStream set `phase` directly

```swift
func openFile(...) async throws {
    phase = .loading
    // ... setup demuxer/decoder ...
    phase = .paused  // ready but not decoding yet
}
```

### 6. Test seams unaffected

`processFrameForTest` and `shouldDropFrameForTest` don't reference `playState` — they work with frame data and the `SynchronizationProvider`. They compile without changes.

## Files to Modify

| File | Change |
|------|--------|
| `MediaPipeline.swift` | Replace `@Published var playState` with internal `PipelinePhase`; update `play()`/`pause()`/`stop()` signatures; update decode loop and open methods |
| `PlaybackEngine.swift` | Update calls to `mediaPipeline.play(pause:stop:)(currentState: state)` |
| `PlayState.swift` | No changes — `PlaybackState` enum stays as-is |

## Constraints

- Preserve the `SynchronizationProvider` protocol contract (no changes to `audioCurrentTime`)
- Do not change `PlaybackSession.setupBindings()` consumer side
- `PlaybackSession` continues to mirror `engine.$state` via Combine — unaffected

## Definition of Done

- Grep confirms no remaining references to `mediaPipeline.playState` outside `MediaPipeline.swift`
- Pausing then resuming a file keeps both AVPlayer and the decode loop in lockstep
- No silent no-ops when calling play/pause/stop
- `swift build` compiles cleanly

## Out of Scope

- Changing `PlaybackState` enum itself (it's correct as-is)
- Changing `PlaybackSession` or UI layer
- Changing `SynchronizationProvider` protocol
- Adding new state observation from MediaPipeline to PlaybackEngine
