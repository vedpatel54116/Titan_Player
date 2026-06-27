# Video Decoder Hardening — Real-Bitstream Decode

**Date:** 2026-06-27
**Status:** Approved
**Scope:** Harden the existing `Core/Decoders/VideoDecoder/` scaffold to decode real compressed bitstreams, fix design flaws, and add full test coverage.
**Supersedes:** None (extends `2026-06-25-video-decoder-design.md`)

## Overview

A complete decoder scaffold already exists under `Core/Decoders/VideoDecoder/` (protocols, `VideoToolboxDecoder`, `FFmpegSoftwareDecoder`, `AdaptiveDecoderManager`, `DecoderSelector`, `PerformanceMonitor`, `ZeroCopyBufferManager`). It compiles but cannot decode real bitstreams because codec parameter sets (SPS/PPS/VPS) are never threaded from demuxer to decoder, the demuxers are placeholders, and several internal flaws prevent correct operation. This spec hardens the existing scaffold — no protocol redesign — to achieve real H.264/HEVC hardware and software decode from `Tests/Fixtures/test.mp4`, with both AVFoundation and FFmpeg demuxer paths supplying real compressed packets and extradata.

## Requirements

### Functional

1. **Real Hardware Decode (VideoToolbox)**
   - H.264/HEVC decode from real bitstreams via `VTDecompressionSession`
   - Codec parameter sets (SPS/PPS/VPS) parsed from `extradata` and passed to `CMVideoFormatDescriptionCreateFromH264ParameterSets` / `CMVideoFormatDescriptionCreateFromHEVCParameterSets`
   - Annex-B → AVCC length-prefix conversion for NALUs submitted to VideoToolbox
   - IOSurface-backed, Metal-compatible output pixel buffers (zero-copy to renderer)
   - HDR: 10-bit `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` when `isHDR`

2. **Real Software Decode (FFmpeg)**
   - `extradata` copied into `AVCodecContext.extradata` + `extradata_size` before `avcodec_open2`
   - Thread count auto-detect (`thread_count = 0`, `thread_type = FF_THREAD_FRAME`)
   - HDR: `AV_PIX_FMT_P010LE` → `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` when `isHDR`
   - B-frame reordering via multi-frame drain queue (existing `decodedQueue`)

3. **Real Demuxing (both paths)**
   - **AVFoundation:** `AVAssetReader` extracts real compressed `CMSampleBuffer` data, real track metadata (codec, dimensions, framerate, HDR), and `extradata` from `AVAssetTrack.formatDescriptions`
   - **FFmpeg:** Real `Libavformat` demuxing — `avformat_open_input`, `avformat_find_stream_info`, `av_read_frame`, `avcodec_parameters_to_context`; `extradata` from `AVStream.codecpar.extradata`

4. **Adaptive Manager Correctness**
   - `DecoderSelector.checkForSwitch` returns a `DecoderSwitch` enum (`.toHardware` / `.toSoftware` / `.none`) instead of creating throwaway decoder instances
   - `AdaptiveDecoderManager` performs switches using its own owned decoder instances
   - Automatic fallback on `DecoderError.hardwareFailure` (transient) → software decoder

5. **Validation Criteria (from prompt)**
   - H.264/HEVC hardware decoding on all Macs
   - VP9 hardware decoding on Apple Silicon (M1+)
   - AV1 hardware decoding on M3+ chips
   - Software fallback for unsupported codecs (MPEG-2, VC-1)
   - Automatic fallback on hardware errors

### Non-Functional

1. **Latency target:** <16ms decode time for 60fps content (hardware path)
2. **Swift 6 readiness:** No NSLock-in-async warnings
3. **Test coverage:** Unit tests for all components; integration tests with real bitstreams from `test.mp4`

## Architecture

### Extradata Threading (Approach A — approved)

Add a single optional field to `VideoTrackInfo`:

```swift
struct VideoTrackInfo {
    let codec: String
    let width: Int
    let height: Int
    let frameRate: Double
    let isHDR: Bool
    let extradata: Data?      // SPS/PPS/VPS parameter sets (avcC/hvcC or Annex-B)
}
```

Both demuxers populate `extradata`; both decoders consume it. This is the minimal type change that unblocks real-bitstream decode.

### Component Changes

#### 1. `SharedTypes.swift` — `VideoTrackInfo.extradata`

Add `extradata: Data?` field. Update all call sites that construct `VideoTrackInfo` to pass `extradata` (demuxers pass real data; tests pass `nil` or fixture data).

#### 2. `ParameterSetParser` (new file: `Hardware/ParameterSetParser.swift`)

Converts `extradata: Data` into a `CMVideoFormatDescription`:

- **H.264 avcC:** Parse avcC box → SPS + PPS pointers → `CMVideoFormatDescriptionCreateFromH264ParameterSets`
- **HEVC hvcC:** Parse hvcC box → VPS + SPS + PPS pointers → `CMVideoFormatDescriptionCreateFromHEVCParameterSets`
- **Annex-B fallback:** Scan for `00 00 00 01` / `00 00 01` start codes, split NALUs, identify NALU types (SPS=7, PPS=8 for H.264; VPS=32, SPS=33, PPS=34 for HEVC), pass to the same VT constructors
- **VP9/AV1:** No parameter sets; `CMVideoFormatDescriptionCreate` with codec type only (existing path)

Returns `CMVideoFormatDescription?` on success, `nil` on unparseable input.

#### 3. `VideoToolboxDecoder` — Real Decode

- `configure(for:)`: Use `ParameterSetParser` to build `CMVideoFormatDescription` from `track.extradata` (replaces bare `CMVideoFormatDescriptionCreate` for H.264/HEVC)
- `decode(_:)`: Submit real compressed packets via `VTDecompressionSessionDecodeFrame` with `._EnableAsynchronousDecompression` + `._1xRealTimePlayback` flags; callback resumes `CheckedContinuation` with decoded `CMSampleBuffer` (already scaffolded)
- Output: `CMSampleBuffer` wrapping IOSurface-backed `CVImageBuffer` for zero-copy Metal rendering
- Error path: `status != noErr` in callback → throw `.hardwareFailure` → manager fallback

#### 4. `ZeroCopyBufferManager` — Annex-B → AVCC Conversion

Add `annexBToAVCC(_ data: Data) -> Data` method:
- Scan for `00 00 00 01` / `00 00 01` start codes
- Replace each start code with a 4-byte big-endian length prefix (NALU size)
- VideoToolbox requires length-prefixed NALUs; this transform is applied before `createSampleBuffer` when the source is Annex-B

#### 5. `FFmpegSoftwareDecoder` — Real Decode Fixes

- Set `ctx.pointee.extradata` + `extradata_size` from `track.extradata` (allocate via `av_mallocz`, copy bytes) before `avcodec_open2`
- Set `ctx.pointee.thread_count = 0` (auto-detect), `ctx.pointee.thread_type = FF_THREAD_FRAME`
- HDR path: `AV_PIX_FMT_P010LE` + `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` when `track.isHDR`; existing `NV12` + 8-bit otherwise
- Free `extradata` in `teardownCodecContext` (FFmpeg owns the allocation via `av_mallocz`)

#### 6. `FFmpegBridge` — Real `Libavformat` Bindings

Replace all placeholder methods with real FFmpeg calls:
- `avformat_open_input` / `avformat_alloc_context`
- `avformat_find_stream_info`
- `av_find_best_stream` (video/audio)
- `av_read_frame` → `MediaPacket` with real compressed `Data`
- `avcodec_parameters_alloc` / `avcodec_parameters_to_context` → extract `extradata`
- `av_seek_frame` / `avformat_seek_file`
- `avformat_close_input` on teardown
- Map `AVCodecID` → `VideoCodec` rawValue for `VideoTrackInfo`

#### 7. `FFmpegDemuxer` — Real Demuxing

- Populate `MediaInfo` with real track metadata from `AVStream.codecpar` (codec, width, height, framerate from `avg_frame_rate`, HDR from color primaries/transfer)
- Populate `VideoTrackInfo.extradata` from `AVStream.codecpar.extradata`
- Real `nextPacket()` returning compressed data from `av_read_frame`
- Real `seek()` via `av_seek_frame`

#### 8. `AVFoundationDemuxer` — Real Demuxing

- `open(url:)`: Read real track metadata via `AVAssetTrack` async APIs (`load(.codecType)`, `load(.naturalSize)`, `load(.nominalFrameRate)`, `load(.formatDescriptions)`)
- Extract `extradata` from `CMFormatDescription` extensions (avcC/hvcC atoms) or via `CMVideoFormatDescriptionGetH264ParameterSetAtIndex` / HEVC equivalent
- `nextPacket()`: Extract real compressed `Data` from `CMSampleBuffer` → `CMBlockBuffer` → `Data` (currently returns `Data()`)
- Real codec string mapping (`CMVideoCodecType` → `VideoCodec` rawValue)

#### 9. `Package.swift` — Add `Libavformat`

```swift
.product(name: "Libavformat", package: "FFmpegBuild"),
```

Add to TitanPlayer target dependencies. Required for real FFmpeg demuxing.

#### 10. `DecoderSelector` — Fix Throwaway Instances

- Remove `findHardwareDecoder()`, `findSoftwareDecoder()`, `findSoftwareDecoder(from:)` methods that create new instances
- `checkForSwitch` returns `DecoderSwitch` enum instead of `VideoDecoding?`:

```swift
enum DecoderSwitch: Sendable {
    case toHardware
    case toSoftware
    case none
}
```

- `AdaptiveDecoderManager` interprets the enum and switches using its own `hardwareDecoder` / `softwareDecoder` instances

#### 11. `AdaptiveDecoderManager` — Use Owned Instances

- `performSwitch(to:)` takes a `DecoderSwitch` enum, not a `VideoDecoding` instance
- Selects its own `hardwareDecoder` or `softwareDecoder`, configures against `currentTrack` if in `.idle` state
- `handleDecodeError` maps errors to `DecoderSwitch` decisions instead of calling `getFallbackDecoder`: transient error on hardware decoder → `.toSoftware`; transient error on software decoder → `.toHardware`
- Remove `getFallbackDecoder(for:)` — replaced by the `DecoderSwitch` enum

#### 12. NSLock → `OSAllocatedUnfairLock`

Replace `NSLock` in `VideoToolboxDecoder` and `FFmpegSoftwareDecoder` with `OSAllocatedUnfairLock` (available on macOS 14+, the project's deployment target):
- Works in both sync (C callback) and async contexts
- No Swift 6 warnings
- `withLock { }` scoped locking

#### 13. `PerformanceMonitor` — CPU Monitoring

- Implement `startResourceMonitoring()` with `host_processor_info` for CPU usage sampling (timer-based, every 2 seconds)
- GPU monitoring via Metal counters: stub with clear `// TODO: Metal counter API` marker (non-blocking for decode verification)
- Battery monitoring: already implemented via `ProcessInfo`

### Directory Structure (new/changed files)

```
Core/Decoders/
├── VideoDecoder/
│   ├── Protocols/
│   │   ├── VideoDecoding.swift              (unchanged)
│   │   └── DecoderCapabilities.swift        (unchanged)
│   ├── Hardware/
│   │   ├── VideoToolboxDecoder.swift        (modified: real decode, OSAllocatedUnfairLock)
│   │   ├── HardwareCapabilities.swift       (unchanged)
│   │   └── ParameterSetParser.swift         (NEW: avcC/hvcC/Annex-B parsing)
│   ├── Software/
│   │   ├── FFmpegSoftwareDecoder.swift      (modified: extradata, HDR, threading, lock)
│   │   └── SoftwareCapabilities.swift       (unchanged)
│   ├── Manager/
│   │   ├── AdaptiveDecoderManager.swift     (modified: DecoderSwitch enum, owned instances)
│   │   └── DecoderSelector.swift            (modified: no throwaway instances)
│   └── Utilities/
│       ├── ZeroCopyBuffer.swift             (modified: Annex-B → AVCC conversion)
│       └── PerformanceMonitor.swift         (modified: real CPU monitoring)
├── FFmpeg/
│   ├── FFmpegBridge.swift                   (modified: real Libavformat bindings)
│   ├── FFmpegDemuxer.swift                  (modified: real demuxing, extradata)
│   └── FFmpegDecoder.swift                  (unchanged — legacy, deprecated)
├── AVFoundation/
│   └── AVFoundationDemuxer.swift            (modified: real data, extradata, metadata)
└── Protocols/
    └── SharedTypes.swift                    (modified: VideoTrackInfo.extradata)

Tests/VideoDecoderTests/
├── Protocols/
│   └── VideoDecodingTests.swift             (existing, extend for extradata)
├── Hardware/
│   ├── HardwareCapabilitiesTests.swift      (NEW)
│   ├── VideoToolboxDecoderTests.swift       (NEW: unit tests)
│   ├── VideoToolboxDecoderIntegrationTests.swift  (NEW: real H.264 from test.mp4)
│   └── ParameterSetParserTests.swift        (NEW: avcC/hvcC/Annex-B parsing)
├── Software/
│   ├── SoftwareCapabilitiesTests.swift      (NEW)
│   ├── FFmpegSoftwareDecoderTests.swift     (NEW: unit tests)
│   └── FFmpegSoftwareDecoderIntegrationTests.swift  (NEW: real H.264 from test.mp4)
├── Manager/
│   ├── AdaptiveDecoderManagerTests.swift    (NEW: fallback, hot-swap)
│   └── DecoderSelectorTests.swift           (NEW: scoring, switch decisions)
└── Utilities/
    ├── ZeroCopyBufferTests.swift            (NEW: buffer creation, Annex-B → AVCC)
    └── PerformanceMonitorTests.swift        (NEW: metrics, degradation)

Tests/VideoDecoderTests/Integration/
├── FFmpegDemuxerIntegrationTests.swift      (NEW: real demuxing of test.mp4)
└── AVFoundationDemuxerIntegrationTests.swift (NEW: real demuxing of test.mp4)

Package.swift                                 (modified: add Libavformat dependency)
```

## Data Flow

```
File (test.mp4)
  │
  ├─ AVFoundationDemuxer.open(url)
  │    → AVAssetReader → AVAssetTrack
  │    → VideoTrackInfo { codec, width, height, framerate, isHDR, extradata }
  │    → nextPacket() → MediaPacket { real compressed Data }
  │
  ├─ FFmpegDemuxer.open(url)
  │    → avformat_open_input → avformat_find_stream_info
  │    → AVStream.codecpar → VideoTrackInfo { ..., extradata }
  │    → nextPacket() → av_read_frame → MediaPacket { real compressed Data }
  │
  ▼
AdaptiveDecoderManager.configure(for: track)
  → DecoderSelector.selectDecoder(for: track, available: [hw, sw], systemState)
  → HardwareDecoder.configure(for: track)
      → ParameterSetParser.parse(extradata) → CMVideoFormatDescription
      → VTDecompressionSessionCreate (hardware-accelerated)
  ▼
AdaptiveDecoderManager.decode(packet)
  → HardwareDecoder.decode(packet)
      → ZeroCopyBufferManager.annexBToAVCC(packet.data)
      → createSampleBuffer(from: packet, formatDescription)
      → VTDecompressionSessionDecodeFrame
      → callback: CVImageBuffer → CMSampleBufferCreateReadyWithImageBuffer
      → return .sampleBuffer(CMSampleBuffer)
  │
  ├─ on success → DecoderOutput.sampleBuffer → renderer (zero-copy Metal)
  │
  └─ on .hardwareFailure (transient)
      → performSwitch(.toSoftware)
      → SoftwareDecoder.configure(for: track)
          → AVCodecContext.extradata = track.extradata
          → avcodec_open2
      → SoftwareDecoder.decode(packet)
          → avcodec_send_packet → avcodec_receive_frame
          → sws_scale → CVPixelBuffer
          → return .pixelBuffer(CVPixelBuffer)
```

## Error Handling

Existing `DecoderError` severity model is retained:

| Error | Severity | Recovery |
|---|---|---|
| `.hardwareFailure` | transient | Auto-fallback to software decoder via `performSwitch(.toSoftware)` |
| `.sessionNotConfigured` | transient | Reconfigure active decoder |
| `.bufferCreationFailed` | transient | Retry or fallback |
| `.unsupportedCodec` | persistent | Report to UI |
| `.noFramesDecoded` | persistent | Report to UI (corrupt stream or decoder exhausted) |
| `.softwareFailure` | persistent | Report to UI |

## Testing Strategy

### Unit Tests (pure logic, no real bitstreams)

- **`VideoDecodingTests`** (existing, extend): `VideoTrackInfo.extradata` field, default `nil`
- **`HardwareCapabilitiesTests`**: codec support per chip generation, max resolution, `isAppleSilicon` / `isM3OrLater` consistency
- **`SoftwareCapabilitiesTests`**: all codecs supported, no hardware accel, max resolution ≥ 4K
- **`ParameterSetParserTests`**: avcC parsing, hvcC parsing, Annex-B fallback, invalid data → nil, VP9/AV1 passthrough
- **`ZeroCopyBufferTests`**: sample buffer creation, pixel buffer pool, Annex-B → AVCC conversion correctness
- **`DecoderSelectorTests`**: scoring (codec/hardware/performance/thermal/resolution), switch decisions return `DecoderSwitch` enum (not throwaway instances)
- **`PerformanceMonitorTests`**: thermal state mapping, metrics calculation, degradation threshold (<16ms / >2% drops)

### Integration Tests (real bitstreams from `Tests/Fixtures/test.mp4`)

- **`VideoToolboxDecoderIntegrationTests`**: Open test.mp4 via `AVAssetReader`, extract real H.264 packets + extradata, configure `VideoToolboxDecoder`, decode first N frames, assert non-nil `CVImageBuffer`, correct dimensions, state transitions (idle → configured → decoding), latency < 16ms
- **`FFmpegSoftwareDecoderIntegrationTests`**: Same source, configure `FFmpegSoftwareDecoder` with extradata, decode frames, assert non-nil `CVPixelBuffer`
- **`AdaptiveDecoderManagerIntegrationTests`**: Configure with real track, decode real packet, inject `.hardwareFailure` → verify fallback to software, verify output continues
- **`FFmpegDemuxerIntegrationTests`**: Open test.mp4, verify real `MediaInfo` (codec = "avc1", dimensions > 0, extradata non-nil), read packets with non-empty `Data`
- **`AVFoundationDemuxerIntegrationTests`**: Open test.mp4, verify real track metadata, verify `nextPacket()` returns non-empty `Data`

### Validation Criteria Mapping

| Criterion | Verified By |
|---|---|
| H.264/HEVC hardware decoding on all Macs | `VideoToolboxDecoderIntegrationTests` |
| VP9 hardware decoding on Apple Silicon (M1+) | `HardwareCapabilitiesTests` (codec support check) + VT session creation |
| AV1 hardware decoding on M3+ chips | `HardwareCapabilitiesTests` (M3 detection) + VT session creation |
| Software fallback for unsupported codecs | `FFmpegSoftwareDecoderTests` (MPEG-2, VC-1 configure + decode) |
| Automatic fallback on hardware errors | `AdaptiveDecoderManagerIntegrationTests` |

## Implementation Phases

### Phase 1: Type & Infrastructure Changes
1. Add `extradata: Data?` to `VideoTrackInfo`, update call sites
2. Add `Libavformat` to `Package.swift`
3. Implement `ParameterSetParser`
4. Add Annex-B → AVCC conversion to `ZeroCopyBufferManager`

### Phase 2: Decoder Hardening
5. Fix `VideoToolboxDecoder` to use `ParameterSetParser` for format description
6. Fix `FFmpegSoftwareDecoder` extradata wiring, HDR, threading
7. Replace NSLock with `OSAllocatedUnfairLock` in both decoders

### Phase 3: Demuxer Hardening
8. Replace `FFmpegBridge` placeholders with real `Libavformat` calls
9. Fix `FFmpegDemuxer` for real demuxing + extradata extraction
10. Fix `AVFoundationDemuxer` for real data extraction + metadata + extradata

### Phase 4: Manager & Selector Fixes
11. Fix `DecoderSelector` to return `DecoderSwitch` enum (no throwaway instances)
12. Fix `AdaptiveDecoderManager` to use owned instances for switches
13. Implement real CPU monitoring in `PerformanceMonitor`

### Phase 5: Testing
14. Write unit tests (capabilities, parser, buffer, selector, monitor)
15. Write integration tests (hardware decode, software decode, manager fallback, demuxers)
16. Run full test suite, verify latency target, fix failures

## Dependencies

- **VideoToolbox** (system) — hardware decoding
- **FFmpegBuild** package — `Libavcodec`, `Libavutil`, `Libswscale`, `Libavformat` (new)
- **CoreMedia, CoreVideo** (system) — buffer types
- **Metal** (system) — pixel buffer compatibility
- **`Tests/Fixtures/test.mp4`** — real H.264 bitstream for integration tests (existing)

## Future Considerations

1. **Real GPU monitoring** via Metal counter API (stubbed in this spec)
2. **HDR metadata extraction** — pass HDR10/DolbyVision metadata through decode pipeline (existing `HDRTypes` / `HDRMetadataProcessor`)
3. **MediaPipeline integration** — wire `AdaptiveDecoderManager` into `MediaPipeline` (replacing legacy `FFmpegDecoder` / `AVFoundationDecoder`)
4. **Multi-stream decoding** — concurrent decoder sessions
5. **Network streaming** — adaptive bitrate via FFmpeg protocol layer
