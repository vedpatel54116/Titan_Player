# AdaptiveDecoderManager Fallback Logic Design

**Date:** 2026-07-01
**Status:** Approved
**Scope:** Decoder selection, fallback, and PlaybackEngine integration

---

## Problem

The `AdaptiveDecoderManager` exists as a standalone subsystem with hardware/software decoder selection and fallback logic, but it is not wired into `PlaybackEngine`. The engine currently uses `MediaPipeline` which creates stub decoders (`AVFoundationDecoder` / `FFmpegDecoder`) that don't perform real decoding. Users cannot benefit from hardware-accelerated decoding or automatic fallback.

## Goals

1. When `PlaybackEngine.load(url:)` is called, ask `AdaptiveDecoderManager` to select a decoder based on codec and system state
2. If the hardware decoder fails to initialize (e.g., unsupported profile), automatically fall back to the FFmpeg software decoder
3. If the software decoder also fails, surface a user-facing error via `PlaybackError`
4. Log which decoder was selected for the current file

## Approach

**Fallback in AdaptiveDecoderManager, wired into MediaPipeline** (Approach 1).

- Fallback logic lives in `AdaptiveDecoderManager.configure(for:)` — it already has `getFallbackDecoder()` and the state machine
- `MediaPipeline` accepts an `AdaptiveDecoderManager` and uses it for decoding
- A lightweight adapter bridges `VideoDecoding` → `MediaDecoding` protocol
- `PlaybackEngine` creates the manager and passes it to `MediaPipeline`

---

## Detailed Design

### 1. AdaptiveDecoderManager.configure() — Fallback Logic

Modify `configure(for:)` to catch hardware errors and auto-try software:

```swift
func configure(for track: VideoTrackInfo) async throws {
    currentTrack = track
    let availableDecoders = queryAvailableDecoders(for: track)

    preferenceLock.lock()
    let pref = self.preference
    preferenceLock.unlock()

    let selection = decoderSelector.selectDecoder(
        for: track,
        available: availableDecoders,
        systemState: performanceMonitor.currentSystemState,
        preference: pref
    )

    // Try the selected decoder
    do {
        try await selection.decoder.configure(for: track)
        await stateActor.setActiveDecoder(selection.decoder)
        await stateActor.setState(.decoding(selection.decoder))
        logger.info("Decoder selected: \(String(describing: type(of: selection.decoder)))")
        return
    } catch {
        // If hardware failed, try software fallback
        guard let fallback = getFallbackDecoder(for: selection.decoder) else {
            throw PlaybackError.decodingFailed(error)
        }

        do {
            try await fallback.configure(for: track)
            await stateActor.setActiveDecoder(fallback)
            await stateActor.setState(.decoding(fallback))
            logger.info("Fell back to: \(String(describing: type(of: fallback)))")
            return
        } catch {
            // Both decoders failed
            logger.error("Both decoders failed: \(error.localizedDescription)")
            await stateActor.setState(.error(.softwareFailure))
            throw PlaybackError.decodingFailed(error)
        }
    }
}
```

**New property:**
```swift
var selectedDecoderName: String? {
    get async {
        await stateActor.getActiveDecoder().map { String(describing: type(of: $0)) }
    }
}
```

**New logger:**
```swift
private let logger = Logger(subsystem: "com.titanplayer", category: "Decoder")
```

### 2. VideoDecoding → MediaDecoding Adapter

Create `VideoDecodingAdapter` in `Core/Decoders/VideoDecoder/Manager/`:

```swift
final class VideoDecodingAdapter: MediaDecoding {
    private let decoder: VideoDecoding
    var audioTap: AudioTap?

    init(decoder: VideoDecoding) {
        self.decoder = decoder
    }

    func configure(for track: VideoTrackInfo) async throws {
        try await decoder.configure(for: track)
    }

    func decode(_ packet: MediaPacket) async throws -> MediaFrame {
        let output = try await decoder.decode(packet)
        switch output {
        case .sampleBuffer(let sampleBuffer):
            // Extract pixel buffer from sample buffer for rendering
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                throw DecoderError.noFramesDecoded
            }
            let videoFrame = VideoFrame(
                pixelBuffer: pixelBuffer,
                timestamp: packet.timestamp,
                duration: packet.duration,
                colorSpace: .sRGB
            )
            return .video(videoFrame)
        case .pixelBuffer(let pixelBuffer):
            let videoFrame = VideoFrame(
                pixelBuffer: pixelBuffer,
                timestamp: packet.timestamp,
                duration: packet.duration,
                colorSpace: .sRGB
            )
            return .video(videoFrame)
        }
    }

    func flush() async { await decoder.flush() }
    func reset() async { await decoder.reset() }
}
```

### 3. MediaPipeline Integration

Modify `MediaPipeline.openFile()` to accept an `AdaptiveDecoderManager` and propagate errors:

```swift
func openFile(url: URL, adaptiveManager: AdaptiveDecoderManager? = nil) async throws {
    playState = .loading

    let probeDemuxer = FFmpegDemuxer()
    let info = try await probeDemuxer.open(url: url)

    self.mediaInfo = info
    timeObserver.duration = info.duration.seconds

    if let videoTrack = info.videoTracks.first, let manager = adaptiveManager {
        // Use AdaptiveDecoderManager for real decoding
        // configure() handles hardware→software fallback internally
        try await manager.configure(for: videoTrack)
        demuxer = probeDemuxer
        decoder = VideoDecodingAdapter(decoder: manager.activeDecoder!)
    } else if shouldUseAVFoundation(for: info) {
        probeDemuxer.close()
        let avDemuxer = AVFoundationDemuxer()
        decoder = AVFoundationDecoder()
        _ = try await avDemuxer.open(url: url)
        demuxer = avDemuxer
    } else {
        demuxer = probeDemuxer
        decoder = FFmpegDecoder()
    }

    if let videoTrack = info.videoTracks.first {
        try decoder?.configure(for: videoTrack)
    }

    playState = .paused
}
```

**Key change:** `openFile()` is now `throws` so errors propagate to `PlaybackEngine`. This ensures `PlaybackEngine.load()` catches `PlaybackError.decodingFailed` and sets `lastError` for the UI.

### 4. PlaybackEngine.load() Integration

```swift
private let adaptiveDecoderManager = AdaptiveDecoderManager()

func load(url: URL) async throws {
    state = .loading
    lastError = nil

    do {
        if url.pathExtension.lowercased() == "mpd" {
            // ... existing DASH path (unchanged)
        } else {
            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)

            guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
                throw PlaybackError.noPlayableTracks
            }

            let durationValue = try await asset.load(.duration)
            self.duration = CMTimeGetSeconds(durationValue)

            self.player.replaceCurrentItem(with: item)

            try await mediaPipeline?.openFile(url: url, adaptiveManager: adaptiveDecoderManager)
            self.mediaInfo = mediaPipeline?.mediaInfo

            // Log decoder selection
            if let decoderName = await adaptiveDecoderManager.selectedDecoderName {
                logger.info("Selected decoder: \(decoderName) for \(url.lastPathComponent)")
            }

            self.state = .ready
        }
    } catch {
        self.state = .error(error.localizedDescription)
        self.lastError = (error as? PlaybackError) ?? .assetLoadFailed(error)
        // ... existing telemetry
        throw error
    }
}
```

### 5. Error Handling

The error chain:

1. `VideoToolboxDecoder.configure()` throws `DecoderError.hardwareFailure` or `.unsupportedCodec`
2. `AdaptiveDecoderManager.configure()` catches it, tries `FFmpegSoftwareDecoder`
3. If software also fails, throws `PlaybackError.decodingFailed(error)`
4. `PlaybackEngine.load()` catches `PlaybackError`, sets `lastError` and `state = .error`
5. UI reads `lastError` and displays alert via existing `PlayerView` error display

**PlaybackError** already has `.decodingFailed(Error)` — no new cases needed.

### 6. Logging

Using `os.Logger`:
- Subsystem: `com.titanplayer`
- Category: `Decoder`
- Events: decoder selection, fallback triggers, both-failures

```swift
private let logger = Logger(subsystem: "com.titanplayer", category: "Decoder")

// On successful selection:
logger.info("Selected decoder: \(decoderName) for \(filename)")

// On fallback:
logger.warning("Hardware decoder failed for \(filename), falling back to software: \(error)")

// On both failing:
logger.error("Both decoders failed for \(filename): \(error)")
```

---

## File Changes

| File | Action | Description |
|------|--------|-------------|
| `Core/Decoders/VideoDecoder/Manager/AdaptiveDecoderManager.swift` | Modify | Add fallback in `configure()`, add `selectedDecoderName`, add `os.Logger` |
| `Core/Decoders/VideoDecoder/Manager/VideoDecodingAdapter.swift` | **Create** | Bridge `VideoDecoding` → `MediaDecoding` (~30 lines) |
| `Core/Engine/MediaPipeline.swift` | Modify | Make `openFile()` throwing, accept `AdaptiveDecoderManager`, use adapter |
| `Core/Engine/PlaybackEngine.swift` | Modify | Create manager, pass to pipeline, log selection |
| `Tests/Integration/PlaybackPipelineTests.swift` | Modify | Update `openFile()` calls to `try await` (now throwing) |
| `Tests/VideoDecoderTests/Manager/AdaptiveDecoderManagerTests.swift` | **Create** | Tests for fallback logic |

---

## Testing

### Acceptance Criteria Coverage

1. **H.264 plays with hardware decoder:**
   - Test: `configure(for: h264Track)` → `selectedDecoderName == "VideoToolboxDecoder"`
   - Test: `DecoderSelector` scores hardware higher for H.264

2. **Obscure file falls back to software:**
   - Test: Mock `HardwareCapabilities` to reject mpeg2 → `configure()` falls back to `FFmpegSoftwareDecoder`
   - Test: Simulate `VideoToolboxDecoder.configure()` throwing → manager catches and tries software

3. **UI shows error if both fail:**
   - Test: Both decoders fail → `configure()` throws `PlaybackError.decodingFailed`
   - Test: `PlaybackEngine.lastError` is set

### Test Approach

Use protocol-based mocking. Create `MockVideoDecoder` conforming to `VideoDecoding` that can be configured to fail on `configure()` or `decode()`. Inject into `AdaptiveDecoderManager` to control failure scenarios without real VideoToolbox/FFmpeg.

---

## Risks

1. **Protocol bridge complexity:** The `VideoDecodingAdapter` converts `DecoderOutput` → `MediaFrame`. If output formats diverge, this could break. Mitigated by the adapter being simple and testable.

2. **Thread safety:** `AdaptiveDecoderManager` uses `DecoderStateActor` (Swift actor). `MediaPipeline` runs on a dispatch queue. The adapter must be safe to call from either context. Mitigated by the underlying decoders being `@unchecked Sendable` with lock protection.

3. **Performance:** Adding a manager layer adds one more indirection in the decode hot path. The overhead is negligible (one async call per packet) compared to actual decode time.
