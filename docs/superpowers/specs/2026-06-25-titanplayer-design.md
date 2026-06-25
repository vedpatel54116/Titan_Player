# TitanPlayer Design Specification

## Overview

TitanPlayer is a macOS video player for personal media playback with a modular, protocol-based architecture supporting both AVFoundation and FFmpeg backends for maximum codec compatibility.

**Target:** macOS 13+ (Ventura)
**UI Style:** Hybrid (native sidebar + custom player controls)
**Architecture:** Protocol-based abstracted pipeline (Approach 3)

---

## Architecture Overview

### Layered Architecture

```
┌─────────────────────────────────────────────┐
│                 UI Layer                    │
│  SwiftUI Views ← ViewModels ← Coordinator  │
├─────────────────────────────────────────────┤
│             Playback Control                │
│  PlayState, TimeObserver, PlaylistManager   │
├─────────────────────────────────────────────┤
│              Core Engine                    │
│  MediaPipeline ← Protocol Orchestration     │
├──────────────┬──────────────────────────────┤
│  AVFoundation│        FFmpeg                │
│   Backend    │        Backend               │
│  (Protocol)  │       (Protocol)             │
├──────────────┴──────────────────────────────┤
│           Rendering Pipeline                │
│  Metal Renderer ← Shader Pipeline           │
├─────────────────────────────────────────────┤
│            Subtitle System                  │
│  ASS/SSA Parser ← Subtitle Renderer        │
└─────────────────────────────────────────────┘
```

### Key Protocols

```swift
protocol MediaDemuxing {
    func open(url: URL) async throws -> MediaInfo
    func nextPacket() async throws -> MediaPacket
    func seek(to time: CMTime) async throws
}

protocol MediaDecoding {
    func decode(_ packet: MediaPacket) async throws -> MediaFrame
    func flush()
}

protocol FrameRendering {
    func render(_ frame: VideoFrame)
    func handleHDR(_ metadata: HDRMetadata)
}

protocol AudioOutput {
    func play(_ frames: [AudioFrame])
    func setVolume(_ volume: Float)
}
```

### Backend Selection Logic

1. Probe file with `avformat` (FFmpeg) for codec info
2. Check if AVFoundation supports the codec natively
3. Route to AVFoundation backend if supported, FFmpeg otherwise

---

## Project Structure

```
TitanPlayer/
├── Core/
│   ├── Engine/          # Playback engine, MediaPipeline
│   ├── Decoders/        # AVFoundation + FFmpeg backends
│   ├── Renderers/       # Metal renderers, shaders
│   └── Utilities/       # Helper functions, extensions
├── UI/
│   ├── Views/           # SwiftUI views
│   ├── ViewModels/      # MVVM view models
│   └── Controls/        # Custom player controls
├── Resources/
│   ├── Assets.xcassets  # App icons & images
│   └── Shaders/         # Metal shader files
└── Tests/
    ├── Unit/            # Unit tests
    └── Integration/     # Integration tests
```

---

## Core Engine & Protocols

### Protocol Definitions

```swift
protocol MediaDemuxing {
    func open(url: URL) async throws -> MediaInfo
    func nextPacket() async throws -> MediaPacket
    func seek(to time: CMTime) async throws
}

protocol MediaDecoding {
    func decode(_ packet: MediaPacket) async throws -> MediaFrame
    func flush()
}

protocol FrameRendering {
    func render(_ frame: VideoFrame)
    func handleHDR(_ metadata: HDRMetadata)
}

protocol AudioOutput {
    func play(_ frames: [AudioFrame])
    func setVolume(_ volume: Float)
}
```

### MediaPipeline Orchestrator

- Selects backend based on file extension and codec detection
- Manages packet flow: Demuxer → Decoder → Renderer
- Handles A/V sync via timestamp coordination
- Thread-safe with GCD concurrent queues

---

## Decoder Backends

### AVFoundation Backend

```swift
class AVFoundationDemuxer: MediaDemuxing {
    private let asset: AVURLAsset
    private let assetReader: AVAssetReader
}

class AVFoundationDecoder: MediaDecoding {
    private let videoOutput: AVAssetReaderVideoCompositionOutput
    private let audioOutput: AVAssetReaderAudioMixOutput
}
```

- Hardware-accelerated via VideoToolbox automatically
- Native HDR passthrough for ProRes, HEVC
- Best for: MP4, MOV, M4V, ProRes files

### FFmpeg Backend

```swift
class FFmpegDemuxer: MediaDemuxing {
    private let formatContext: UnsafeMutablePointer<AVFormatContext>
}

class FFmpegDecoder: MediaDecoding {
    private let codecContext: UnsafeMutablePointer<AVCodecContext>
}
```

- Extensive codec support via libavcodec
- Software decoding with optional hardware acceleration
- Best for: MKV, AVI, WMV, FLAC, exotic formats

### Shared Types

- `MediaPacket` - Raw compressed data with timestamps
- `VideoFrame` - Decoded pixel buffer (CVPixelPool)
- `AudioFrame` - PCM buffer with format info

---

## Metal Rendering Pipeline

### Shader Pipeline

```
Input (CVPixelBuffer/MTLTexture)
    ↓
Color Space Conversion (BT.709/BT.2020)
    ↓
HDR Tone Mapping (PQ/HLG → SDR display)
    ↓
Custom Effects (brightness, contrast, saturation)
    ↓
Output (CAMetalLayer)
```

### Key Components

```swift
class MetalRenderer: FrameRendering {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
}
```

### Shader Files

- `Video.metal` - Vertex/fragment for quad rendering
- `HDR.metal` - PQ/HLG tone mapping
- `Effects.metal` - Color adjustments

### HDR Handling

- Detect HDR10, Dolby Vision, HLG via codec metadata
- PQ/HLG EOTF conversion in fragment shader
- Fallback to SDR with tone mapping for non-HDR displays
- Preserve color gamut when display supports it

### Frame Delivery

- `CAMetalLayer` for low-latency rendering
- Triple buffering to avoid stalls
- Display link synchronization (60Hz/120Hz)

---

## UI Layer (SwiftUI + MVVM)

### Window Structure

```
┌─────────────────────────────────────────────┐
│  Toolbar (window controls, menu)            │
├────────────┬────────────────────────────────┤
│            │                                │
│  Sidebar   │      Player View               │
│  (Native)  │   ┌──────────────────────┐     │
│            │   │                      │     │
│  Library   │   │   Video Content      │     │
│  Playlists │   │   (Metal Layer)      │     │
│  History   │   │                      │     │
│            │   └──────────────────────┘     │
│            │   [Controls: play/seek/volume] │
├────────────┴────────────────────────────────┤
│  Inspector (metadata, subtitles, chapters)  │
└─────────────────────────────────────────────┘
```

### ViewModels

```swift
@MainActor class PlayerViewModel: ObservableObject {
    @Published var playState: PlayState
    @Published var currentTime: Double
    @Published var duration: Double
    @Published var volume: Float
}

@MainActor class LibraryViewModel: ObservableObject {
    @Published var mediaFiles: [MediaItem]
    @Published var playlists: [Playlist]
}
```

### Key Views

- `PlayerView` - Video content + controls overlay
- `SidebarView` - Library browser, playlists
- `InspectorView` - Metadata, subtitle tracks, chapters
- `ControlBar` - Play/pause, seek, volume, fullscreen

### Interaction

- Keyboard shortcuts (space, arrow keys, cmd+F)
- Gesture support (pinch zoom, swipe seeking)
- Menu bar integration

---

## Threading Model & Data Flow

### GCD Queue Architecture

```
Main Queue          - UI updates, user input
├─ User Initiated   - File loading, seeking
Media Pipeline Queue - Packet reading, decoding (concurrent)
├─ Video Decode     - High priority
├─ Audio Decode     - High priority
Render Queue        - Metal rendering, display
└─ Audio Output     - Real-time audio unit callbacks
```

### Data Flow

```
File on Disk
    ↓ (User Initiated Queue)
MediaDemuxer → MediaPacket (compressed)
    ↓ (Media Pipeline Queue)
MediaDecoding → VideoFrame / AudioFrame
    ↓ (Render Queue)
FrameRendering → CAMetalLayer (video)
AudioOutput → AudioUnit (audio)
    ↓ (Main Queue)
ViewModel updates → SwiftUI views
```

### Synchronization

- A/V sync via timestamp comparison
- Audio master clock (audio drives video timing)
- Frame drop strategy: skip late video frames
- Seek: flush all queues, reload from keyframe

### Memory Management

- Frame buffer pool (CVPixelBufferPool)
- Packet ring buffer (bounded, drops old packets)
- Auto-release on pipeline teardown

---

## Subtitle System

### Supported Formats

- SRT (SubRip) - Most common, simple parsing
- ASS/SSA (Advanced SubStation Alpha) - Rich styling, positioning
- VobSub (PGS) - Bitmap-based, Blu-ray subtitles
- WebVTT - Web standard, chapter support

### Subtitle Pipeline

```
Subtitle File / Embedded Track
    ↓
SubtitleParser (format-specific)
    ↓
[SubtitleEvent] (timestamp + styled text)
    ↓
SubtitleRenderer (Metal overlay on video)
```

### Key Types

```swift
struct SubtitleEvent {
    let startTime: Double
    let endTime: Double
    let text: AttributedString  // Styled text
    let position: SubtitlePosition  // .bottom, .top, .custom
}

class SubtitleManager {
    @Published var activeTrack: SubtitleTrack?
    @Published var availableTracks: [SubtitleTrack]
    func render(for time: Double) -> [SubtitleEvent]
}
```

### Rendering

- Metal overlay composited on video frames
- ASS/SSA: full style support (fonts, colors, positioning)
- Fallback to system font for missing ASS fonts
- User preferences: size, color, background, position

---

## Testing Strategy

### Unit Tests

- Protocol implementations (mock backends)
- Parser correctness (SRT, ASS, WebVTT format tests)
- Time calculation and A/V sync logic
- ViewModel state management

### Integration Tests

- End-to-end playback (open file → render frames)
- Seek accuracy across formats
- Subtitle rendering with various tracks
- Error handling (corrupted files, missing codecs)

### Performance Tests

- Memory usage (<50MB at startup)
- Frame drop rate under load
- Codec decode speed benchmarks

### Test Structure

```
Tests/
├── Unit/
│   ├── DemuxerTests.swift
│   ├── DecoderTests.swift
│   ├── ParserTests.swift
│   └── ViewModelTests.swift
├── Integration/
│   ├── PlaybackPipelineTests.swift
│   └── SubtitleIntegrationTests.swift
└── Fixtures/
    └── (test media files)
```

---

## Validation Criteria

- [ ] Project compiles without errors on Xcode 15+
- [ ] Basic window appears with empty media state
- [ ] Modular architecture allows component swapping
- [ ] Memory usage <50MB on startup

---

## Success Criteria

1. Open and play common video formats (MP4, MKV, MOV)
2. Hardware-accelerated decoding via VideoToolbox
3. FFmpeg fallback for unsupported formats
4. HDR tone mapping for HDR content
5. Subtitle rendering with ASS/SSA styling
6. Responsive UI with <100ms seek latency
7. Memory-efficient pipeline with bounded buffers
