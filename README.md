# Titan Player

**A native macOS video player built for people who care about picture quality.**

Titan Player renders HDR content the way it was meant to look — with real-time Metal GPU tone mapping, Dolby Vision RPU parsing, and spatial audio. It's a Swift/SwiftUI application that treats video playback as a rendering problem, not just a decoding one.

---

## What makes it different

Most video players decode frames and hand them to a compositor. Titan Player takes the raw HDR signal and processes it through a full GPU pipeline — PQ/HLG to linear conversion, ACES or dynamic bezier tone mapping, and ICC-aware color transforms — before it ever reaches the screen. The result is accurate, display-aware HDR on any connected monitor, including EDR-capable Apple displays.

It also decodes video itself (via VideoToolbox or FFmpeg) rather than relying entirely on AVFoundation, which means it can inspect Dolby Vision RPU metadata, HDR10+ dynamic tone curves, and per-frame HDR parameters that AVFoundation discards.

---

## Features

### HDR & Color

- HDR10, HDR10+, Dolby Vision (Profiles 4, 5, 7, 8), and HLG playback
- Real-time Metal compute tone mapping with per-frame transition smoothing
- Dolby Vision RPU and HDR10+ SEI metadata parsing from CMSampleBuffer attachments
- ICC profile color matrix transforms for sRGB, Display P3, and BT.2020
- Extended Dynamic Range (EDR) output for Apple XDR displays

### Audio

- Spatial audio engine built on AVAudioEngine with HRTF processing
- Room simulation with configurable size and reverb
- AirPods head tracking and external tracker support
- CoreAudio bridge for low-level device management
- BS.1770-4 / EBU R128 loudness metering

### Rendering

- Metal compute shader YCbCr-to-RGB conversion
- Full-screen quad rendering via MTKView at 60fps
- Triple-buffered in-flight semaphore
- Subtitle overlay rendered as a separate Metal pass (SRT, ASS, WebVTT via libass)
- Fallback to AVPlayerLayer when Metal is unavailable

### Decoding

- Adaptive decoder manager: VideoToolbox (hardware) or FFmpeg (software)
- Hardware codec profiles for Intel, M1, M2, M3, and M4 Macs
- Runtime switching based on codec capabilities and system resources

### Analysis Tools

- GPU-accelerated histogram, vectorscope, and waveform display
- Color picker with HSV/YCbCr conversion
- Analysis panels only consume GPU when enabled

### Network & Streaming

- HLS playback with variant bitrate observation and adaptive quality switching
- Streaming cache for offline playback via AVAssetDownloadURLSession
- DASH support (in progress)
- Network reachability and thermal state monitoring

### Interface

- Customizable keyboard shortcuts (30+ actions, conflict detection)
- Mini player and full player modes
- Library window for browsing media folders
- Inspector view for media info
- Touch Bar support
- Multi-display detection with per-display HDR tone mapping
- AirPlay integration

---

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15+ with Command Line Tools (for building)
- [FFmpeg](https://ffmpeg.org/) libraries (built via the included script)
- libass system library (for ASS/SSA subtitle rendering)

---

## Building

### Quick build (SwiftPM)

```bash
cd TitanPlayer
swift build
```

### Full build with Xcode

```bash
cd TitanPlayer
make build
```

### Build FFmpeg dependencies

```bash
cd TitanPlayer
make ffmpeg
# or run the script directly:
./scripts/build-ffmpeg.sh
```

### Run tests

Requires a full Xcode installation (not just Command Line Tools):

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
swift test
```

---

## Project structure

```
TitanPlayer/
├── Core/                    # Business logic (non-UI)
│   ├── Engine/              # Playback engine, MediaPipeline, audio
│   ├── Renderers/           # Metal rendering pipeline
│   ├── Decoders/            # AVFoundation + FFmpeg decoders
│   ├── Streaming/           # HLS/DASH, caching, network
│   ├── Performance/         # Adaptive quality & resource prediction
│   ├── Analysis/            # GPU video analysis tools
│   └── Hardware/            # Mac hardware detection
├── UI/                      # SwiftUI views & controllers
│   ├── Views/               # PlayerView, MiniPlayer, Sidebar, Library
│   ├── Controls/            # ControlBar, SeekSlider
│   ├── Session/             # Central PlaybackSession coordinator
│   ├── Shortcuts/           # Keyboard shortcuts
│   └── Analysis/            # Analysis panel views
├── Subtitles/               # Parser, renderer, libass integration
├── Telemetry/               # Opt-in Sentry crash reporting
└── Resources/Shaders/       # Metal shaders (.metal)
```

---

## Architecture

Titan Player uses a **modular monolith** pattern: a single macOS app with strongly separated internal modules communicating through protocols.

**Central state coordinator:** `PlaybackSession` is an `ObservableObject` that owns all subsystems (engine, renderer, display manager, streaming, analysis, performance) and distributes state to SwiftUI views via `.environmentObject()`.

**Dual-path rendering:** `PlaybackEngine` runs an `AVPlayer` for audio output alongside a custom `MediaPipeline` that feeds decoded frames to the Metal renderer. This lets Titan Player inspect HDR metadata at the decode stage while still using AVFoundation for audio mixing and AirPlay.

**State machine:** `PlaybackState` enforces valid transitions with `canTransition(to:)`, preventing impossible state changes.

**Protocol-oriented:** Core abstractions (`MediaDecoding`, `MediaDemuxing`, `VideoDecoding`, `FrameRendering`) are protocols, enabling hardware/software decoder swapping and testability.

**Runtime shader compilation:** When a pre-compiled `default.metallib` isn't available (common with SwiftPM), `MetalShaders.loadLibrary()` concatenates all `.metal` files and compiles them at runtime.

---

## Dependencies

| Dependency | Purpose |
|---|---|
| [FFmpegBuild](https://github.com/nicklama/FFmpegBuild) | Software video decoding (libavcodec, libavformat, libavutil, libswscale) |
| [Sentry](https://github.com/getsentry/sentry-cocoa) | Opt-in crash reporting (anonymous, no PII) |
| libass | ASS/SSA subtitle rendering (system library) |

---

## Documentation

Detailed design specs and implementation plans live in [`docs/superpowers/specs/`](docs/superpowers/specs/) and [`docs/superpowers/plans/`](docs/superpowers/plans/).

---

## License

MIT License. See [LICENSE](LICENSE) for details.

---

## Privacy

Titan Player's telemetry is completely opt-in, anonymous, and collects no personal information. See [PRIVACY.md](PRIVACY.md) for the full policy.
