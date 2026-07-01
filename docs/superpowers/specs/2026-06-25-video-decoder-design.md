# Video Decoder System with Hardware Acceleration

**Date:** 2026-06-25
**Status:** Approved
**Scope:** TitanPlayer video decoding subsystem

## Overview

Replace the current decoder implementation with a modular video decoder system featuring intelligent hardware acceleration, zero-copy rendering, and adaptive decoder selection.

## Requirements

### Functional Requirements

1. **Codec Support (Progressive Implementation)**
   - Phase 1: H.264, HEVC (hardware guaranteed)
   - Phase 2: VP9, AV1 (Apple Silicon M1+/M3+)
   - Phase 3: MPEG-2, VC-1 (software only)

2. **Hardware Acceleration**
   - VideoToolbox via `VTDecompressionSession` for hardware decoding
   - Automatic detection of hardware capabilities per codec

3. **Software Fallback**
   - FFmpeg-based software decoding for unsupported codecs
   - Seamless fallback on hardware errors

4. **Zero-Copy Rendering**
   - Output `CMSampleBuffer` for direct pass-through to renderers
   - Output `CVImageBuffer` for flexible rendering paths
   - Protocol supports both output formats

5. **Adaptive Decoder Selection**
   - Capability-based: codec support, resolution limits
   - Performance-based: decode timing history, frame drop rate
   - Content-based: stream complexity analysis
   - System-based: thermal state, CPU/GPU load, battery level

6. **Hot-Swap Support**
   - Switch decoders during playback with brief rebuffer
   - Flush → Configure → Switch → Re-decode sequence

7. **Error Handling**
   - Transient errors (timeout, buffer overflow): automatic fallback
   - Persistent errors (unsupported format, corruption): report to UI

### Non-Functional Requirements

1. **Latency Target:** <16ms decode time for 60fps content
2. **Testing:** Unit tests, integration tests, performance benchmarks
3. **Architecture:** Protocol-based abstractions, parallel module (not replacing existing immediately)

## Architecture

### Directory Structure

```
Core/Decoders/
├── VideoDecoder/          # New system
│   ├── Protocols/
│   │   ├── VideoDecoding.swift
│   │   └── DecoderCapabilities.swift
│   ├── Hardware/
│   │   ├── VideoToolboxDecoder.swift
│   │   └── HardwareCapabilities.swift
│   ├── Software/
│   │   ├── FFmpegSoftwareDecoder.swift
│   │   └── SoftwareCapabilities.swift
│   ├── Manager/
│   │   ├── AdaptiveDecoderManager.swift
│   │   └── DecoderSelector.swift
│   └── Utilities/
│       ├── ZeroCopyBuffer.swift
│       └── PerformanceMonitor.swift
├── Protocols/             # Existing (kept for reference)
├── AVFoundation/          # Existing (deprecated after migration)
└── FFmpeg/                # Existing (deprecated after migration)
```

### Key Design Decisions

1. **Approach:** Custom decoder framework with protocol abstraction
2. **Integration:** Parallel system, migrate MediaPipeline in follow-up phase
3. **Performance Priority:** Latency-focused (<16ms target)

## Component Design

### Core Protocols

#### VideoDecoding Protocol

```swift
protocol VideoDecoding: AnyObject {
    var outputFormat: DecoderOutputFormat { get }
    var capabilities: DecoderCapabilities { get }
    var state: DecoderState { get }
    
    func configure(for track: VideoTrackInfo) async throws
    func decode(_ packet: MediaPacket) async throws -> DecoderOutput
    func flush() async
    func reset() async
    func invalidate() async
}
```

#### Output Format

```swift
enum DecoderOutputFormat {
    case sampleBuffer   // CMSampleBuffer for zero-copy
    case pixelBuffer    // CVImageBuffer for flexibility
    case both           // Support both output types
}

enum DecoderOutput {
    case sampleBuffer(CMSampleBuffer)
    case pixelBuffer(CVImageBuffer)
}
```

#### Decoder Capabilities

```swift
struct DecoderCapabilities {
    let supportedCodecs: Set<VideoCodec>
    let maxResolution: CGSize
    let supportsHDR: Bool
    let supportsHardwareAcceleration: Bool
    let maxConcurrentDecodes: Int
}

enum VideoCodec: String, CaseIterable {
    case h264 = "avc1"
    case hevc = "hvc1"
    case vp9 = "vp09"
    case av1 = "av01"
    case mpeg2 = "mp2v"
    case vc1 = "vc-1"
}
```

### Hardware Decoder

`VideoToolboxDecoder` implements `VideoDecoding` with:

- Output format: `CMSampleBuffer` (zero-copy)
- Uses `VTDecompressionSession` directly
- Pixel buffer attributes optimized for zero-copy
- Decode timing tracking for performance monitoring
- Codec support check via `VTIsHardwareDecodeSupported`

Key methods:
- `configure(for:)`: Creates format description and decompression session
- `decode(_:)`: Decodes packet via VideoToolbox, returns sample buffer
- `flush()`: Flushes pending frames
- `invalidate()`: Cleans up resources

### Software Decoder

`FFmpegSoftwareDecoder` implements `VideoDecoding` with:

- Output format: `CVImageBuffer` (flexible)
- Uses FFmpeg's `libavcodec` for decoding
- B-frame reordering support
- Pixel buffer pool for memory efficiency
- Supports all 6 codecs

Key methods:
- `configure(for:)`: Finds codec, allocates context, opens codec
- `decode(_:)`: Sends packet, receives frames, converts to pixel buffer
- `flush()`: Flushes FFmpeg decoder, clears frame buffer
- `invalidate()`: Frees codec context

### Adaptive Decoder Manager

`AdaptiveDecoderManager` coordinates decoder selection and switching:

- Maintains hardware and software decoder instances
- Queries `DecoderSelector` for optimal decoder
- Monitors `PerformanceMonitor` for system state
- Performs hot-swap with flush → configure → switch sequence
- Handles error recovery with fallback logic

Key methods:
- `configure(for:)`: Selects and configures optimal decoder
- `decode(_:)`: Decodes with active decoder, checks for switch
- `flush()`: Flushes active decoder
- `invalidate()`: Cleans up all decoders

### Decoder Selector

`DecoderSelector` implements intelligent decoder selection:

- Multi-factor scoring system (codec, hardware, performance, thermal, resolution)
- Real-time switching decisions based on system state
- Battery-aware and thermal-aware selection
- Performance history influences future decisions

Scoring factors:
- Codec support (0-30 points)
- Hardware acceleration bonus (0-20 points)
- Performance history (0-25 points)
- Thermal efficiency (0-15 points)
- Resolution support (0-10 points)

### Performance Monitor

`PerformanceMonitor` tracks system state and decoder performance:

- Real-time thermal, CPU, GPU, and battery monitoring
- Decode timing tracking per codec
- Frame drop rate calculation
- Degradation detection triggers adaptive switching

System state tracked:
- Thermal state (nominal, fair, serious, critical)
- CPU/GPU usage percentages
- Battery level and charging state
- Low power mode status

### Zero-Copy Buffer Utilities

`ZeroCopyBufferManager` handles efficient buffer management:

- Sample buffer creation from packet data
- Pixel buffer pool for memory reuse
- Buffer queue for recycling
- Format conversion between sample and pixel buffers

`FormatConverter` provides:
- Sample buffer ↔ pixel buffer conversion
- Color space conversion utilities

## Error Handling

### Error Types

```swift
enum DecoderError: Error {
    case unsupportedCodec(String)
    case sessionNotConfigured
    case bufferCreationFailed(OSStatus)
    case noFramesDecoded
    case hardwareFailure
    case softwareFailure
}
```

### Error Severity

```swift
extension DecoderError {
    enum ErrorSeverity {
        case transient  // Auto-recoverable
        case persistent  // Requires UI intervention
    }
    
    var severity: ErrorSeverity {
        switch self {
        case .sessionNotConfigured, .bufferCreationFailed:
            return .transient
        case .unsupportedCodec, .noFramesDecoded:
            return .persistent
        }
    }
}
```

### Recovery Strategy

1. **Transient errors:** Automatic fallback to alternative decoder
2. **Persistent errors:** Report to UI, allow user to retry or change settings
3. **Hardware failures:** Immediate switch to software decoder
4. **Thermal throttling:** Proactive switch to software decoder

## Testing Strategy

### Unit Tests

- `DecoderSelectorTests`: Selection logic, scoring, switching decisions
- `AdaptiveDecoderManagerTests`: Configuration, hot-swap, error handling
- `VideoToolboxDecoderTests`: Hardware decoding, latency targets
- `FFmpegSoftwareDecoderTests`: Software decoding, codec support
- `PerformanceMonitorTests`: System state tracking, metrics calculation

### Integration Tests

- Full decode pipeline with real codec packets
- Hot-swap during playback scenario
- Error recovery scenarios
- Multi-codec stream handling

### Performance Benchmarks

- Per-codec decode timing (H.264, HEVC, VP9, AV1)
- 4K 60fps stress test
- Memory usage profiling
- Latency measurement validation (<16ms target)

### Validation Criteria

- [ ] H.264/HEVC hardware decoding on all Macs
- [ ] VP9 hardware decoding on Apple Silicon (M1+)
- [ ] AV1 hardware decoding on M3+ chips
- [ ] Software fallback for unsupported codecs
- [ ] Automatic fallback on hardware errors
- [ ] <16ms decode time target for 60fps

## Implementation Phases

### Phase 1: Core Framework

1. Define protocols (`VideoDecoding`, `DecoderCapabilities`)
2. Implement `VideoToolboxDecoder` for H.264/HEVC
3. Implement `FFmpegSoftwareDecoder` with full codec support
4. Create `ZeroCopyBufferManager`

### Phase 2: Intelligence Layer

1. Implement `DecoderSelector` with scoring system
2. Implement `PerformanceMonitor` for system state
3. Implement `AdaptiveDecoderManager` for coordination
4. Add hot-swap support

### Phase 3: Testing & Validation

1. Write unit tests for all components
2. Create integration tests with real content
3. Implement performance benchmarks
4. Validate latency targets

### Phase 4: Migration

1. Integrate with `MediaPipeline`
2. Deprecate old decoder implementations
3. Update UI for decoder switching feedback

## Future Considerations

1. **HDR Support:** Extend `VideoFrame` with HDR metadata
2. **Multi-Stream:** Support multiple concurrent video streams
3. **Network Streams:** Adaptive bitrate streaming integration
4. **GPU Acceleration:** Metal-based post-processing pipeline
5. **Machine Learning:** Content-aware decoder selection optimization

## Dependencies

- VideoToolbox framework (system)
- FFmpegBuild package (existing dependency)
- CoreMedia, CoreVideo frameworks (system)
- Metal framework (existing renderer)
