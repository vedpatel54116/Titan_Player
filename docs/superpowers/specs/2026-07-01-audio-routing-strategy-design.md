# Audio Routing Strategy — Design Document

## Overview

Eliminate the dual audio output risk by establishing AVPlayer as the single source of truth for audio output. The `MediaPipeline`'s dormant `audioRenderer` is removed, and the architecture is documented to prevent future regressions.

## Problem

`PlaybackEngine` creates an `AVPlayer` that naturally outputs audio, while also injecting an `AudioRenderer` into `MediaPipeline`. Although no code path currently routes audio frames to that renderer, the dormant wiring poses a maintenance hazard — any future developer adding `.audio` frame handling to `processFrame()` would unknowingly activate a second audio path, causing echo/duplicate output.

## Approach: AVPlayer as Single Audio Source

AVPlayer handles all audio output. Its AVFoundation-based sync is more robust for standard formats.

### Changes

1. **`MediaPipeline`** — Remove the `audioRenderer` property and its init parameter. The pipeline manages video only.
2. **`PlaybackEngine`** — Remove the `audioRenderer` parameter from `init()` and `setupRenderers()`.
3. **`PlaybackSession`** — Stop resolving/injecting `AVAudioEngineRenderer`.
4. **`AudioRenderer` protocol** — Retained for potential future use (e.g., FFmpeg-based audio decoding for exotic codecs), but no longer wired into any playback path.
5. **Decoders** — The `audioTap` on `MediaDecoding` remains for analysis/visualization purposes only (connected to `LFSAudioMeter`). It is explicitly NOT connected to `AudioRenderer`.
6. **`SpatialEngine`/`AudioEngine`** — Remains injected via `PlaybackEngine.setSpatialAudioEngine()`. When enabled, it operates as an overlay on AVPlayer's audio output (AVAudioEnvironmentNode processes AVPlayer's audio graph). No conflict with this approach.

### Audio Route Decision Matrix

| Scenario | Audio Output | Clock Source |
|----------|-------------|--------------|
| AVFoundation-compatible codec (default path) | AVPlayer | AVPlayer |
| FFmpeg-decoded video codec | AVPlayer (audio track still decoded by AVFoundation player item) | AVPlayer |
| Future: exotic audio codec requiring FFmpeg | New dedicated path (future work, out of scope) | TBD |

### Acceptance Criteria

- No echo or duplicate audio during playback of any format
- Audio sync remains tight (< ±40ms) over 30 minutes
- `MediaPipeline` no longer references any `AudioRenderer` type
- All existing tests pass with `MockAudioRenderer` removed from `MediaPipeline` contexts

### Out of Scope

- Implementing audio frame decoding in the FFmpeg pipeline (the decoders currently produce no `.audio` frames)
- Routing exotic-codec audio through the pipeline
- The `AudioEngine`/spatial audio system — it's already an overlay on AVPlayer's audio graph and not part of this conflict

## Future Considerations

If FFmpeg audio decoding is ever needed (e.g., DTS, TrueHD), a dedicated audio pipeline should be designed at that point — either routing decoded buffers onto AVPlayer's audio queue, or using a separate `AVAudioEngine` instance with explicit muting of AVPlayer's audio tracks.
