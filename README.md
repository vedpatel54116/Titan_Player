# Titan Player

A native macOS video player with HDR rendering, spatial audio, and real-time video analysis.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange.svg)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue.svg)](https://developer.apple.com/macos/)
[![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen.svg)](Package.swift)

## Features

- **Dual decoder backend** — AVFoundation primary with FFmpeg fallback (hardware VideoToolbox + software decoding)
- **HDR rendering** — HDR10, HDR10+, Dolby Vision, and HLG with per-frame dynamic tone mapping via Metal compute shaders
- **Spatial audio** — head tracking, HRTF processing, and room simulation built on AVAudioEngine
- **HLS streaming** — adaptive bitrate, network-aware quality switching, and download-to-cache for offline playback
- **Subtitles** — SRT, ASS, and WebVTT parsing with styled overlay rendering
- **Real-time video analysis** — GPU-accelerated histogram, vectorscope, waveform, and color picker; BS.1770-4 loudness metering
- **Adaptive performance** — monitors CPU, thermal, battery, and network to dynamically adjust decoder, resolution, and bitrate

## Screenshots

<!-- ![Screenshot](docs/screenshot.png) -->

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+ or Command Line Tools (`xcode-select --install`)
- [libass](https://github.com/libass/libass): `brew install libass`
- FFmpeg is pulled in automatically via the [FFmpegBuild](https://github.com/superuser404notfound/FFmpegBuild) SwiftPM dependency

## Build & Run

### SwiftPM

```bash
cd TitanPlayer
swift build
./build/debug/TitanPlayer
```

### Xcode (via XcodeGen)

```bash
xcodegen generate
open TitanPlayer.xcodeproj
```

### Tests

Tests require a full Xcode install (not Command Line Tools):

```bash
cd TitanPlayer
swift test
```

If you only have Command Line Tools, you can verify the test sources compile without XCTest errors:

```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```

## Architecture

TitanPlayer is a modular monolith — a single macOS application with strongly separated internal modules behind protocol boundaries. The SwiftUI view layer holds a `PlaybackSession` observable object that acts as a facade over all subsystems.

When a file is opened, `PlaybackEngine` creates an AVPlayer item and simultaneously probes the file with `MediaPipeline` (which selects AVFoundation or FFmpeg demuxing). Decoded video frames flow through `MetalRenderer` for GPU rendering with HDR tone mapping, while `AudioEngine` handles spatial audio output. `PerformanceOptimizer` continuously monitors system state and applies adaptive quality rules to keep playback smooth.

**Core modules:**

| Module | Responsibility |
|--------|---------------|
| PlaybackSession | Central state coordinator; owns all subsystems |
| PlaybackEngine | AVPlayer-based playback with time observation and seeking |
| MediaPipeline | FFmpeg/AVFoundation demuxing and decoding |
| MetalRenderer | GPU rendering with HDR tone mapping and ICC color transform |
| AudioEngine | Spatial audio with head tracking, HRTF, room simulation |
| HDR pipeline | HDR10/HDR10+/Dolby Vision/HLG detection and per-frame tone mapping |
| Performance system | Adaptive quality — CPU/thermal/battery-aware decoder and renderer tuning |
| Streaming | HLS playback, adaptive bitrate, caching, network monitoring |
| Subtitles | SRT/ASS/WebVTT parsing and overlay |
| Analysis | GPU histogram, vectorscope, waveform, color picker, loudness metering |
| Display management | HDR/EDR display detection, AirPlay, persisted display configs |

See [CODEBASE_CONTEXT.md](CODEBASE_CONTEXT.md) for the full architecture map and data flow diagrams.

## Configuration

**Entitlements:** Two entitlements profiles are available — `TitanPlayer.entitlements` (App Sandbox) and `TitanPlayer.Direct.entitlements` (direct filesystem access for development builds).

**Telemetry:** Sentry is integrated for crash reporting. Set your DSN in `Info.plist` under the `SentryDSN` key. No telemetry is sent without a valid DSN. See [PRIVACY.md](PRIVACY.md) for details.

## Contributing

See [AGENTS.md](AGENTS.md) for build instructions, architecture notes, and contributor guidelines.

## License

[MIT](LICENSE)
