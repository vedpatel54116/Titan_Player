# DASH Streaming — Hybrid FFmpeg + Custom ABR Design

## Overview

Implement DASH (MPEG-DASH) streaming support for Titan Player using a hybrid approach:
- **FFmpeg's built-in DASH demuxer** handles MPD parsing, segment downloading, and demuxing
- **Custom Swift MPD parser** extracts quality metadata for ABR decisions
- **Custom ABR controller** monitors throughput and drives quality switching
- **FFmpeg demuxer restart** handles quality changes by aborting and reopening with new representation URLs

## Motivation

AVFoundation does not support DASH on macOS. The existing `NotImplementedDASHPlayer` stub throws `StreamingError.dashNotSupported`. We need a functional DASH player that:
1. Plays public DASH test streams (e.g., from dashif.org)
2. Keeps video and audio in sync
3. Switches quality without visible stuttering

## Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────┐
│                  StreamingManager                    │
│  load(url:) → detects .mpd → routes to DASHPlayer   │
└──────────────────────┬──────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────┐
│                   DASHPlayerImpl                     │
│  Coordinates: MPDParser, ABRController, Session      │
└──┬────────────┬────────────────┬────────────────────┘
   │            │                │
   ▼            ▼                ▼
MPDParser   DASHABRController   DASHStreamSession
(manifest)  (throughput/ABR)    (FFmpeg lifecycle)
                                    │
                                    ▼
                              FFmpegDemuxer
                              (demux packets)
                                    │
                                    ▼
                              MediaPipeline
                              (decode + render)
```

### New Files

| File | Purpose |
|------|---------|
| `Core/Streaming/DASH/Models/DASHQuality.swift` | Value type for a single representation |
| `Core/Streaming/DASH/Models/MPDManifest.swift` | Value type for parsed MPD structure |
| `Core/Streaming/DASH/MPDParser.swift` | Lightweight XML parser for MPD manifests |
| `Core/Streaming/DASH/DASHABRController.swift` | Throughput monitoring + quality switching logic |
| `Core/Streaming/DASH/DASHStreamSession.swift` | Wraps FFmpegDemuxer for DASH, handles quality switching |
| `Core/Streaming/DASH/DASHPlayerImpl.swift` | Concrete DASHPlayer implementation |

### Modified Files

| File | Change |
|------|--------|
| `Core/Streaming/DASH/DASHPlayer.swift` | Add `streamSession(for:)` method to protocol |
| `Core/Streaming/DASH/DASHPlayerFactory.swift` | Return `DASHPlayerImpl` instead of `NotImplementedDASHPlayer` |
| `Core/Engine/MediaPipeline.swift` | Add `openStream(session:)` method |
| `Core/Engine/PlaybackEngine.swift` | Route `.mpd` URLs through DASH path |
| `Core/Streaming/StreamingManager.swift` | Wire up DASH player, remove error stub |

## Detailed Design

### 1. DASHQuality

```swift
struct DASHQuality: Identifiable, Hashable {
    let id: String               // representation@id or bitrate string
    let bandwidth: Int           // bits per second
    let width: Int?
    let height: Int?
    let codec: String?
    let mimeType: String?
    let segmentTemplate: String? // URL template for segments (if SegmentTemplate)
    let baseUrl: String?         // base URL for segment resolution
}
```

Sorted by bandwidth ascending. The lowest bandwidth is the initial quality.

### 2. MPDManifest

```swift
struct MPDManifest {
    let type: MPDType            // .static or .dynamic
    let mediaPresentationDuration: Double?
    let minBufferTime: Double?
    let videoAdaptations: [AdaptationSet]
    let audioAdaptations: [AdaptationSet]

    struct AdaptationSet {
        let id: String?
        let mimeType: String
        let lang: String?        // for audio
        let representations: [DASHQuality]
    }

    enum MPDType {
        case `static`            // VOD
        case dynamic             // live
    }
}
```

### 3. MPDParser

Lightweight XML parser using `XMLParser` (Foundation). No external dependencies.

**Parsing strategy:**
1. Fetch the MPD document via `URLSession`
2. Parse XML to extract `<Period>`, `<AdaptationSet>`, `<Representation>` elements
3. Handle both `SegmentTemplate` and `SegmentList` URL patterns
4. Resolve relative URLs against `BaseURL`
5. Return `MPDManifest`

**Segment URL resolution:**
- `SegmentTemplate` with `$RepresentationID$` and `$Number$` substitutions
- `SegmentList` with explicit `<SegmentURL>` elements
- Fallback to `BaseURL` + index pattern

### 4. DASHABRController

```swift
@MainActor
class DASHABRController: ObservableObject {
    @Published private(set) var currentQuality: DASHQuality
    @Published private(set) var availableQualities: [DASHQuality]

    private var throughputSamples: [Double] = []
    private var lastSwitchTime: Date = .distantPast
    private let cooldownSeconds: TimeInterval = 5.0
    private let switchUpThreshold: Double = 1.5    // 1.5× current bitrate
    private let switchUpConsecutive: Int = 3       // 3 consecutive samples
    private let emaAlpha: Double = 0.3             // smoothing factor
}
```

**Throughput estimation:**
- After each segment download, record: `bytesDownloaded / downloadTimeSeconds`
- Maintain exponential moving average: `ema = α × sample + (1-α) × ema`
- Keep last 10 samples for analysis

**Switch-up logic:**
- If `ema > switchUpThreshold × currentBitrate` for `switchUpConsecutive` consecutive samples → switch up
- Only switch to the next higher quality (not skip levels)

**Switch-down logic:**
- If `ema < currentBitrate` → switch down immediately
- Switch down to the highest quality that fits within `ema × 0.8` (20% safety margin)

**Cooldown:**
- Enforce `cooldownSeconds` between any quality switches to prevent oscillation

### 5. DASHStreamSession

Wraps `FFmpegDemuxer` for DASH playback with quality switching.

```swift
class DASHStreamSession: MediaDemuxing {
    private var demuxer: FFmpegDemuxer?
    private let abrController: DASHABRController
    private var currentQuality: DASHQuality
    private let manifest: MPDManifest
    private(set) var mediaInfo: MediaInfo?

    func open(url: URL) async throws -> MediaInfo   // opens with currentQuality
    func nextPacket() async throws -> MediaPacket
    func switchQuality(to quality: DASHQuality) async throws
    func seek(to time: CMTime) async throws
    func close()
}
```

**Quality switching via FFmpeg restart:**
1. Signal FFmpeg to abort via IO interrupt callback (set interrupt flag)
2. `demuxer.close()`
3. Create new `FFmpegDemuxer`
4. Open with the new representation's segment URL
5. The `MediaPipeline` continues reading from the new demuxer seamlessly

**FFmpeg IO Interrupt:**
- Set an interrupt callback on `AVFormatContext` that checks an atomic boolean
- When switching, set the boolean to `true` → FFmpeg's `avformat_open_input` or `av_read_frame` returns error
- Close and reopen with new URL

### 6. DASHPlayerImpl

```swift
final class DASHPlayerImpl: DASHPlayer {
    private var abrController: DASHABRController?
    private var currentSession: DASHStreamSession?

    func playableAsset(for url: URL) async throws -> AVURLAsset {
        // For protocol conformance; real playback uses streamSession
        throw StreamingError.dashNotSupported(url)
    }

    func streamSession(for url: URL) async throws -> DASHStreamSession {
        let manifest = try await MPDParser.parse(url: url)
        let qualities = manifest.videoAdaptations.first?.representations ?? []
        let lowest = qualities.sorted(by: { $0.bandwidth < $1.bandwidth }).first

        let controller = DASHABRController(qualities: qualities, initial: lowest)
        let session = DASHStreamSession(manifest: manifest, abrController: controller)
        _ = try await session.open(url: url, quality: lowest!)

        self.currentSession = session
        return session
    }

    var currentVariants: [StreamingQuality] {
        get async {
            abrController?.availableQualities.map { q in
                .variant(
                    resolution: CGSize(width: q.width ?? 0, height: q.height ?? 0),
                    bitrate: Double(q.bandwidth),
                    codec: q.codec
                )
            } ?? []
        }
    }
}
```

### 7. Protocol Changes

**DASHStreamSession conforms to MediaDemuxing:**

`DASHStreamSession` implements the `MediaDemuxing` protocol (`open(url:)`, `nextPacket()`, `seek(to:)`, `close()`), delegating to its internal `FFmpegDemuxer`. This allows `MediaPipeline` to use it as a drop-in demuxer.

**DASHPlayer protocol — add stream session method:**

```swift
protocol DASHPlayer: AnyObject {
    func playableAsset(for url: URL) async throws -> AVURLAsset
    func streamSession(for url: URL) async throws -> DASHStreamSession
    var currentVariants: [StreamingQuality] { get async }
}
```

**MediaPipeline — add stream session entry point:**

Since `DASHStreamSession` conforms to `MediaDemuxing`, the pipeline can use it directly:

```swift
func openStream(session: DASHStreamSession) async {
    playState = .loading
    do {
        let info = try await session.open(url: session.manifestURL)
        self.mediaInfo = info
        timeObserver.duration = info.duration.seconds

        self.demuxer = session  // DASHStreamSession is a MediaDemuxing
        if let videoTrack = info.videoTracks.first {
            decoder = FFmpegDecoder()
            try decoder?.configure(for: videoTrack)
        }
        playState = .paused
    } catch {
        playState = .error(error.localizedDescription)
    }
}
```

The existing `startPacketReading()` loop calls `demuxer?.nextPacket()` which now goes through `DASHStreamSession.nextPacket()` → `FFmpegDemuxer.nextPacket()`. Quality switches happen asynchronously via the ABR controller calling `session.switchQuality()`.

### 8. PlaybackEngine Routing

```swift
func load(url: URL) async throws {
    state = .loading
    lastError = nil

    if url.pathExtension.lowercased() == "mpd" {
        // DASH path
        let dashPlayer = DASHPlayerFactory.player(for: url)
        let session = try await dashPlayer.streamSession(for: url)
        await mediaPipeline?.openStream(session: session)
        self.mediaInfo = mediaPipeline?.mediaInfo
        self.state = .ready
    } else {
        // Existing path (HLS/local)
        let asset = AVURLAsset(url: url)
        // ... existing code
    }
}
```

### 9. StreamingManager Wiring

```swift
case .mpd:
    let dashPlayer = DASHPlayerFactory.player(for: url)
    // Store dashPlayer reference for quality control
    streamingState = .ready
    currentQuality = .auto
    availableQualities = []
```

## Error Handling

| Error | Handling |
|-------|----------|
| Invalid MPD XML | `StreamingError.assetLoadFailed("Invalid MPD manifest")` |
| Network failure during segment download | FFmpeg retries internally; after 3 failures, propagate error |
| Quality switch failure | Stay at current quality, log warning, continue playback |
| No video representations found | `StreamingError.dashNotSupported(url)` |
| Seek in live stream | Clamp to live edge |

## Testing Strategy

### Unit Tests
- `MPDParserTests`: Parse real MPD documents, verify structure extraction
- `DASHABRControllerTests`: Verify throughput estimation, switch decisions, cooldown
- `DASHQualityTests`: Value type equality, sorting

### Integration Tests
- `DASHPlayerImplTests`: End-to-end with a public test stream (mock network)
- `DASHStreamSessionTests`: Quality switching lifecycle

### Acceptance Criteria Validation
- Playback of `https://dash.akamaized.net/akamai/test/bbb_30fps/bbb_30fps.mpd` works
- Video and audio remain in sync
- Quality switches without stuttering (observable via `currentQuality` changes)

## Constraints

- macOS 14+ target (existing project requirement)
- Swift Concurrency (`async/await`) throughout
- No new external dependencies (uses Foundation `XMLParser`)
- FFmpeg must include DASH format support (verify via `avformat -formats | grep dash`)
- Must not break existing HLS and local file playback
