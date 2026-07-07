<div align="right"><sub>

<!-- signal bars: a quiet nod to scope monitors and HDR mastering racks -->
<svg width="240" height="14" viewBox="0 0 240 14" fill="none" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
  <rect x="0"   y="4" width="46" height="6" fill="#d8a44a"/>
  <rect x="52"  y="4" width="32" height="6" fill="#3aa57a"/>
  <rect x="90"  y="4" width="18" height="6" fill="#7a7a82"/>
  <rect x="114" y="4" width="10" height="6" fill="#5a5a62"/>
  <rect x="130" y="4" width="4"  height="6" fill="#2e2e34"/>
  <rect x="140" y="2" width="2"  height="10" fill="#d8a44a"/>
  <rect x="148" y="2" width="2"  height="10" fill="#d8a44a"/>
  <rect x="156" y="2" width="2"  height="10" fill="#d8a44a"/>
  <rect x="164" y="2" width="2"  height="10" fill="#3aa57a"/>
  <rect x="172" y="2" width="2"  height="10" fill="#3aa57a"/>
  <rect x="180" y="2" width="2"  height="10" fill="#7a7a82"/>
  <rect x="188" y="2" width="2"  height="10" fill="#7a7a82"/>
  <rect x="196" y="2" width="2"  height="10" fill="#5a5a62"/>
  <rect x="204" y="2" width="2"  height="10" fill="#5a5a62"/>
  <rect x="212" y="2" width="2"  height="10" fill="#2e2e34"/>
  <text x="232" y="11" text-anchor="end" font-family="ui-monospace, SFMono-Regular, Menlo, monospace" font-size="9" fill="#7a7a82">REC.2100</text>
</svg>

</sub></div>

<div align="center">

# **Titan Player.**

### A native macOS video renderer. Built for people who care about how a frame looks.

<sub><i>Pixels in. PQ → linear. Tone curve. Color matrix. Pixels out.</i></sub>

</div>

---

> Most video players decode, then hand frames to a compositor.
> **Titan Player treats video as a rendering problem.**
>
> It reads the raw HDR signal from the bitstream, parses per-frame Dolby Vision
> RPU and HDR10+ SEI metadata that AVFoundation throws away, and pushes the
> result through a custom Metal compute pipeline:
> **PQ/HLG → linear → dynamic bezier or ACES tone map → ICC color matrix → display.**
> Accurate HDR on any monitor, including EDR-capable Apple displays.

<div align="right">

<sub>

`swift` `metal` `swiftui` `macos 14+` `appkit` `h.264/5` `av1` `vp9` `hdr10` `hdr10+` `dolby vision` `hlg` `edr`

</sub>

</div>

---

## What it does, briefly

| | |
|---|---|
| **HDR** | HDR10, HDR10+ (dynamic bezier curves), Dolby Vision Profiles 4/5/7/8, HLG. Per-frame metadata parsing with bezier-based transition smoothing (~83 ms). |
| **Tone map** | Metal compute shader: PQ/HLG → linear, ACES reference curve or dynamic per-frame bezier, GPU-side saturation/brightness. |
| **Color** | ICC-aware matrix transforms for sRGB, Display P3, BT.2020, BT.709. Stable across connected and external displays. |
| **Audio** | Spatial audio on AVAudioEngine with HRTF, configurable room simulation, AirPods head tracking, CoreAudio bridge, **BS.1770-4 / EBU R128** loudness metering. |
| **Decoding** | Adaptive decoder: VideoToolbox (hardware) on Intel / M1 → M4, FFmpeg (software) when needed. Runtime switching via performance signals. |
| **Analysis** | GPU-accelerated **histogram**, **vectorscope**, **waveform**, **color picker**. Idle when off — no GPU cost. |
| **Streaming** | HLS with variant bitrate observation, AVAssetDownloadURLSession cache for offline. DASH in progress. |
| **UI** | Customizable keyboard shortcuts (30+), mini player, library, inspector, Touch Bar, multi-display, AirPlay. |

---

## Architecture, at a glance

Titan is a **modular monolith**: one macOS binary, strongly separated internal modules behind protocols.

```
                            ┌──────────────────────┐
                            │   SwiftUI view layer │  PlayerView · Library · Inspector
                            └──────────┬───────────┘
                                       │ @EnvironmentObject
                            ┌──────────▼───────────┐
                            │   PlaybackSession    │  ObservableObject façade. Owns everything.
                            └──┬────┬─────┬─────┬───┘
                               │    │     │     │
        ┌──────────────────────┘    │     │     └─────────────────────┐
        │                           │     │                           │
┌───────▼────────┐  ┌──────────▼──┐ │ ┌───▼─────────┐  ┌──────────────▼──────┐
│ PlaybackEngine │  │MediaPipeline│ │ │ HDRMetadata │  │  StreamingManager   │
│  (AVPlayer)    │  │ FFmpeg/AV → │ │ │  Processor  │  │     (HLS, cache)    │
└───────┬────────┘  │ decoded     │ │ └──────┬──────┘  └─────────┬────────────┘
        │           │ frames      │ │        │                 │
        │           └──────┬──────┘ │ ┌──────▼─────────┐  ┌─────▼─────────┐
        │                  ▼        │ │ MetalRenderer  │  │ VideoAnalysis │
        │         ┌──────────────┐ │ │ MTKView · HDR   │  │ Histogram ·   │
        │         │MetalRenderer │ │ │ compute · ICC  │  │ Vectorscope · │
        │         │  (per-frame) │ │ └──────┬─────────┘  │ Waveform      │
        │         └──────┬───────┘ │        │            └────────┬───────┘
        │                ▼         │        ▼                     │
┌───────▼──────────────────────────▼───────▼───────────────────────▼─────────┐
│  AudioEngine (spatial, HRTF, room sim, BS.1770) · DisplayManager · AirPlay │
└────────────────────────────────────────────────────────────────────────────┘
```

<details>
<summary><b>Key design choices</b></summary>

- **`PlaybackSession`** — single `ObservableObject` owning every subsystem. The whole UI binds to it. State changes distribute through environment, nothing else.
- **Dual-path rendering** — `PlaybackEngine` runs an `AVPlayer` for audio output while a custom `MediaPipeline` feeds decoded frames to the GPU renderer. You get AVFoundation's audio mixing and AirPlay *plus* per-frame HDR metadata inspection.
- **`PlaybackState` state machine** — `canTransition(to:)` guards every change. Impossible states are unrepresentable.
- **Protocol-oriented core** — `MediaDecoding`, `MediaDemuxing`, `VideoDecoding`, `FrameRendering` are all protocols. Hardware and software decoders are interchangeable; tests inject fakes the same way.
- **Runtime shader compilation** — when SwiftPM doesn't ship a `default.metallib`, `MetalShaders.loadLibrary()` concatenates and compiles the `.metal` files at runtime. No `xcodebuild` step required.

</details>

---

## Pipeline walkthrough — opening a Dolby Vision file

```
file:///Users/me/movies/dune.mkv
        │
        │   ContentView.handleDrop / AppDelegate.application(_:open:)
        ▼
PlaybackSession.openFile(_:)              ← security-scoped resource, AVURLAsset probe
        │
        ▼
PlaybackEngine.load(_)                    ← AVPlayerItem, time observation, audio clock
        │
        ▼
MediaPipeline.openFile(_)                 ← FFmpegDemuxer probe, backend selection
        │                                   (AVFoundation if HW codec available,
        │                                    FFmpeg otherwise)
        ▼
decode(packet) → processFrame(frame)       ← CMSampleBuffer carries HDR10+/DV attachments
        │
        ▼
HDRMetadataProcessor.processMetadata(_)    ← parses RPU, SEI, derives per-frame params
        │
        ▼
MetalRenderer.render(_)                   ← compute shader: PQ→linear→tone map→ICC matrix
        │
        ▼
MTKView · draw(in:)                       ← screen @ 60 fps, triple-buffered
```

The HDR path runs **per frame**. Dynamic metadata (Dolby Vision RPU, HDR10+ SEI) flows through with a bezier transition smoother so scenes don't snap when curves change.

---

## Building

> Requires macOS 14 (Sonoma) or later. Xcode 15+ recommended for full development.

### Quickest path — SwiftPM build

```bash
cd TitanPlayer
swift build
```

### Full Xcode build

```bash
cd TitanPlayer
make build
```

### FFmpeg dependencies (software decoder)

```bash
cd TitanPlayer
make ffmpeg        # or: ./scripts/build-ffmpeg.sh
```

### Running the test suite

Tests need a full Xcode install (Command Line Tools do not ship XCTest):

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
swift test
```

---

## Repo layout

```
TitanPlayer/
├── Core/                     # business logic (no UI)
│   ├── Engine/               # PlaybackEngine, MediaPipeline, audio
│   ├── Renderers/            # MetalRenderer, HDR pipeline, displays
│   ├── Decoders/             # VideoToolbox + FFmpeg, codec negotiation
│   ├── Streaming/            # HLS, cache, network monitor
│   ├── Performance/          # PerformanceOptimizer, AdaptiveQualityController
│   ├── Analysis/             # GPU scopes, audio metering
│   └── Hardware/             # Mac hardware detection
├── UI/                       # SwiftUI views & coordinators
│   ├── Views/                # PlayerView, MiniPlayer, Library, Sidebar
│   ├── Controls/             # ControlBar, SeekSlider
│   ├── Session/              # PlaybackSession, DisplayManager, AirPlay
│   └── Shortcuts/            # Bindings & conflict detection
├── Subtitles/                # SRT / ASS (libass) / WebVTT
├── Telemetry/                # Opt-in anonymous Sentry crash reporting
└── Resources/Shaders/        # Metal Shading Language (.metal)
```

Specs and implementation plans: [`docs/superpowers/specs/`](docs/superpowers/specs/) · [`docs/superpowers/plans/`](docs/superpowers/plans/)

---

## Dependencies

| | |
|---|---|
| **[FFmpegBuild](https://github.com/nicklama/FFmpegBuild)** | `libavcodec` · `libavformat` · `libavutil` · `libswscale` — software decoding when VideoToolbox can't. |
| **[Sentry](https://github.com/getsentry/sentry-cocoa)** | *Opt-in* crash reporting. No PII. Off by default. |
| **libass** | ASS/SSA subtitle rendering (system library via Homebrew). |

Private. No data exfiltration beyond optional, anonymous crash reports.

---

## Privacy & telemetry

Titan Player's telemetry is **opt-in, anonymous, and collects no personal information**. Nothing leaves your machine unless you turn it on.

Full policy: [**PRIVACY.md**](PRIVACY.md).

---

## License

[**MIT**](LICENSE) · © 2026 TitanPlayer contributors.
