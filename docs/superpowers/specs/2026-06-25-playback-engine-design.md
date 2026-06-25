# PlaybackEngine Design Spec

## Overview

Core playback engine for TitanPlayer supporting gapless playback, variable rates, and A/V sync correction. Orchestrates AVPlayer (primary) and MediaPipeline/FFmpeg (fallback) backends.

## Architecture

```
┌─────────────────────────────────────────────┐
│              PlaybackEngine                  │
│  @Published state, currentTime, duration    │
│  @Published playbackRate                    │
│                                             │
│  ┌─────────────┐    ┌──────────────────┐   │
│  │  AVPlayer   │    │  MediaPipeline   │   │
│  │  (primary)  │    │  (FFmpeg fallback)│   │
│  └─────────────┘    └──────────────────┘   │
│         │                    │              │
│         └────────┬───────────┘              │
│                  ▼                          │
│         ┌──────────────┐                    │
│         │  AudioClock  │                    │
│         │  (sync ref)  │                    │
│         └──────────────┘                    │
│                                             │
│  onNextTrack: (() -> URL?)?                │
└─────────────────────────────────────────────┘
```

- `PlaybackEngine` owns both `AVPlayer` and `MediaPipeline`
- `load()` probes format, selects backend automatically
- AVPlayer path: uses AVPlayer for everything (video + audio)
- FFmpeg path: MediaPipeline decodes, MetalRenderer displays video, custom audio output
- `AudioClock` provides unified time reference for both paths
- `onNextTrack` callback for playlist advancement

## State Machine

```swift
enum PlaybackState: Equatable {
    case idle           // No item loaded
    case loading        // Asset loading, tracks not ready
    case ready          // Item loaded, ready to play
    case playing        // Actively playing
    case paused         // Paused
    case ended          // Playback finished
    case seeking        // Seek in progress
    case error(String)  // Error with message
}
```

### Transitions

- `idle → loading` — `load()` called
- `loading → ready` — tracks loaded successfully
- `loading → error` — load failed
- `ready → playing` — `play()` called
- `playing → paused` — `pause()` called
- `playing → ended` — playback reached end
- `ended → ready` — `seek(to: 0)` or new `load()`
- `paused → playing` — `play()` called
- Any → `seeking` — `seek()` called
- `seeking → playing/paused` — seek completed

## Gapless Playback

### Chapter Gapless

- On AVPlayer: Use AVPlayerItem boundary time observer to detect chapter boundaries
- Pre-fetch next chapter's AVPlayerItem and insert into player's queue via AVPlayer.insert(_:after:)
- On FFmpeg: Pre-demux next chapter's packets, buffer in MediaPipeline

### Playlist Gapless

- `onNextTrack` callback returns next URL (or nil to stop)
- Engine pre-loads next item while current plays (pipeline prefetch)
- On AVPlayer: Pre-create next AVPlayerItem, swap at boundary (AVPlayer, not AVQueuePlayer, for simplicity)
- On FFmpeg: Overlap decode - start decoding next file before current ends, crossfade audio buffers

### Chapter Detection

- From MediaInfo.chapters (if available from demuxer)
- Fallback: chapter timestamps from MP4 atoms or MKV chapters

### Crossfade Option

- Optional short crossfade (configurable, default 0ms for true gapless)
- When enabled, mix last N frames of outgoing with first N frames of incoming

## Playback Rate & Pitch Correction

### Rate Range

0.25x to 4x, configurable in 0.05x increments

### AVPlayer Path

- `AVPlayer.rate = playbackRate` — AVPlayer handles rate natively
- Pitch correction: AVPlayer preserves pitch by default when rate changes
- No additional work needed

### FFmpeg Path

- Rate change requires resampling audio at different speed
- Use libavresample or manual resampling to adjust playback rate
- Pitch correction: Use WSOLA (Waveform Similarity Overlap-Add) or Phase Vocoding
- Video frames: Drop/duplicate frames or adjust frame timestamps

### Rate Change API

```swift
func setPlaybackRate(_ rate: Float) {
    let clampedRate = max(0.25, min(4.0, rate))
    playbackRate = clampedRate
    player.rate = clampedRate  // AVPlayer path
    // FFmpeg path: adjust resampler and frame schedule
}
```

### Time Tracking Adjustment

- `currentTime` updates must account for rate
- `TimeObserver` uses system clock scaled by rate for AVPlayer
- FFmpeg path: track timestamps directly from decoded frames

## A/V Sync Correction

### Sync Mechanism

- Audio clock is master reference (audio drives timing)
- Video frames rendered relative to audio clock
- Sync correction adjusts video display time to match audio

### Audio Delay Adjustment

- Configurable offset: ±0.1s (±100ms) precision
- Stored as `audioDelay: Double` property
- Applied to audio output timing (shift audio earlier/later)

### AVPlayer Path

- `AVPlayer.currentItem.audioTimePitchAlgorithm` set for rate handling
- Sync handled internally by AVPlayer
- Audio delay via AVPlayerItem configuration

### FFmpeg Path

- Audio clock: Track decoded audio playback position
- Video sync: Compare video frame timestamp to audio clock
- Correction: Hold/drop/advance video frames to match audio
- Drift detection: Sample audio clock periodically, adjust frame schedule

### Sync Tolerance

- Target: ±40ms (broadcast standard)
- Warning threshold: >50ms drift
- Correction: Immediate frame adjustment, no visible stutter

## Error Handling

### Error Types

```swift
enum PlaybackError: Error, LocalizedError {
    case invalidURL
    case assetLoadFailed(Error)
    case noPlayableTracks
    case decodingFailed(Error)
    case audioOutputFailed(Error)
    case rateNotSupported
    case seekFailed
}
```

### Error Propagation

- `PlaybackEngine.state` set to `.error(message)` on failure
- Errors logged to unified logging system
- `@Published var lastError: PlaybackError?` for UI consumption

### Recovery

- `load()` clears previous error state
- `stop()` resets to idle, clears error
- User can retry failed operation

## Validation Criteria

- Plays common formats (MP4, MOV, MKV) without stuttering
- A/V sync remains accurate within ±40ms over 30 minutes
- Memory usage stable during 4K playback (<500MB)
- CPU usage <5% during 4K H.264 playback on M1

## Files to Create/Modify

### New Files

- `Core/Engine/PlaybackEngine.swift` — Main engine class
- `Core/Engine/PlaybackState.swift` — State machine enum
- `Core/Engine/AudioClock.swift` — Unified time reference
- `Core/Engine/PlaybackError.swift` — Error types
- `Core/Engine/AudioRenderer.swift` — Audio output protocol + AVAudioEngine implementation

### Modified Files

- `Core/Engine/MediaPipeline.swift` — Add gapless prefetch, rate support
- `Core/Engine/TimeObserver.swift` — Integrate with AudioClock
- `UI/ViewModels/PlayerViewModel.swift` — Update to use PlaybackEngine
