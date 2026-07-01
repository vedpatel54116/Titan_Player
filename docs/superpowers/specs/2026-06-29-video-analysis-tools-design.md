# Video Analysis Tools Design

**Date:** 2026-06-29
**Status:** Approved
**Branch:** `feat/video-analysis-tools`
**Target:** macOS 14+

## Overview

Add professional, real-time video analysis tools to TitanPlayer:

1. **Waveform monitor** — luminance (Y) distribution per source column over the source height, with 8 vertical bucket levels
2. **Vectorscope** — chrominance scatter plot in the Cb/Cr plane, color-coded by saturation
3. **Histogram** — R/G/B/Luma tonal-range distribution (256 bins per channel)
4. **Audio metering** — full **EBU R128** loudness measurement (K-weighted momentary, short-term, integrated) plus 4×-oversampled **true peak** (dBTP) with peak hold
5. **Frame-accurate color picker** — single-pixel `ColorSample` from the displayed frame

The existing `Core/Analysis/AnalysisTypes.swift` data shapes (`HistogramData`, `WaveformData`, `VectorscopeData`, `ColorSample`) and their tests (`AnalysisTypesTests.swift`, 12 cases) are kept verbatim. This spec adds the active compute pipeline, audio meter, integration wiring, and UI surface.

## Goals & Non-Goals

**Goals**

- 30 fps analyzer update rate on 4K SDR content without dropping the playback render loop
- Audio metering matches **EBU R128** (BS.1770-4) loudness model and **BS.1770-3** true-peak measurement
- All five modes independently toggleable from the inspector and (for the binary toggles) via keyboard shortcuts
- All five analyzers unit-testable in isolation; integration with `PlaybackSession` testable end-to-end on `Fixtures/test.mp4`

**Non-Goals (YAGNI)**

- HDR-aware beyond existing tone-mapping path (analyzers operate on the post-tone-map sRGB-equivalent texture; we do not analyze raw PQ/HLG pixel values)
- Recording/exporting analyzer data (snapshot-only)
- Web-based or external-scripting hooks
- 3D/big-picture analysis overlays
- True-peak over-sampling rates other than 4×

## Architecture & Data Flow

```
┌──────────────────────────── VideoAnalysisManager ────────────────────────────┐
│ @Published var waveformEnabled / vectorscopeEnabled /                       │
│              histogramEnabled / audioMeteringEnabled                        │
│ @Published private(set) var histogram: HistogramData?                       │
│ @Published private(set) var waveform: WaveformData?                         │
│ @Published private(set) var vectorscope: VectorscopeData?                   │
│ @Published private(set) var colorPicker: ColorSample?                       │
│ @Published private(set) var audioMeter: AudioMeteringData?                  │
└──┬───────────────────────────────────────────┬────────────────────────────────┘
   │ observes (Combine)                         │ owns
   ▼                                           ▼
┌──────────────────────────┐         ┌─────────────────────────────┐
│ FrameStore               │         │ LFSAudioMeter               │
│  - latestTexture         │         │  - K-weighting biquad       │
│  - frameID (DidChange)   │         │  - 4× true-peak oversampler │
└─────────────┬────────────┘         │  - momentary / short-term / │
              │ texture               │    integrated LUFS + gating │
              ▼                       └─────────────────────────────┘
┌──────────────────────────┐
│ AnalysisGPURunner         │
│ (Metal only)              │
│  - waveformKernel         │     Per frame (when any video analyzer
│  - vectorscopeKernel      │     flag is on): dispatchOnce(texture)
│  - histogramKernel        │     → blit to CPU → publish on main actor.
│  - colorPickerKernel      │
└──────────────────────────┘
```

`VideoAnalysisManager` is the public facade. It owns one `AnalysisGPURunner` (own Metal device — does **not** share `MetalRenderer`'s semaphore) and one `LFSAudioMeter`. It observes `FrameStore.frameID` via a `frameIDPublisher`, dispatches when the frame changes and at least one video analyzer is enabled, and publishes the resulting data on the main actor.

`LFSAudioMeter` is wired through a new `MediaDecoding.audioTap: ((AudioFrame) -> Void)?` property. The decoder implementations (`AVFoundationDecoder`, `FFmpegDecoder`) fire this tap on every successfully decoded `.audio(AudioFrame)` packet. `PlaybackSession` sets the tap on engine construction. **Why decoder-level and not playback-level:** this codebase's `MediaPipeline.processFrame(_:)` only routes `MediaFrame.video` to a renderer (the playback path for `MediaFrame.audio` is not yet wired). Tapping at the decoder gives us the same audio stream that EBU R128 standards target — decoded, pre-rendering, program loudness — without depending on the (unbuilt) playback wiring. As a bonus, audio metering works even when playback is muted.

`LFSAudioMeter.consume(_ frame: AudioFrame)` converts the interleaved `[Float]` samples in the `AudioFrame` into a single `AVAudioPCMBuffer` and feeds it through the standard K-weighting + block → momentary/short-term/integrated pipeline.

`AnalysisGPURunner` keeps its own `MTLDevice` (== `MTLCreateSystemDefaultDevice()`) and command queue, separate from `MetalRenderer`'s in-flight semaphore. This avoids head-of-line-blocking the playback render loop.

## Components

| Component | File | Public API summary |
|---|---|---|
| `VideoAnalysisManager` | `Core/Analysis/VideoAnalysisManager.swift` | `init(metalDevice:)`, `attach(frameStore:)`, toggle-flags `@Published`, `sampleColor(at:in:) async`, `@Published` outputs |
| `AnalysisGPURunner` | `Core/Analysis/AnalysisGPURunner.swift` | `init(device:)`, `dispatchOnce(for: MTLTexture) async -> AnalysisResults`, `samplePixel(in:at:) async -> float4` |
| `LFSAudioMeter` | `Core/Analysis/LFSAudioMeter.swift` | `init(sampleRate:)`, `consume(_: AVAudioPCMBuffer)`, `@Published var metering: AudioMeteringData`, `reset()` |
| `AudioMeteringData` | `Core/Analysis/AudioMeteringData.swift` | `struct { momentaryLUFS, shortTermLUFS, integratedLUFS: Float?, truePeakDBTP, peakHoldDBTP: (value: Float, holdUntil: Date) }` |
| `Analysis.metal` | `Resources/Shaders/Analysis.metal` | 4 kernels + helpers (`rgbToYCbCr`, K-weighted luminance, atomics helpers) |
| `WaveformView` / `VectorscopeView` / `HistogramView` | `UI/Analysis/*.swift` | SwiftUI readouts inside `InspectorView` |
| `ColorPickerOverlay` | `UI/Analysis/ColorPickerOverlay.swift` | NSViewRepresentable wrapping `MTKView`'s event tap when `colorPickerEnabled` |
| `AudioMeterBar` | `UI/Analysis/AudioMeterBar.swift` | SwiftUI peak/momentary/integrated row inserted into `ControlBar` |

`AnalysisTypes.swift` (`HistogramData`, `WaveformData`, `VectorscopeData`, `ColorSample`) is unchanged.

## Metal Kernel Contract (`Analysis.metal`)

All kernels read the post-tone-mapped `rgba16Float` texture exposed by `FrameStore.latestTexture`. Helper functions are declared in `Analysis.metal` itself (we do not extend `Common.metal` to keep kernel dependencies explicit).

```metal
// shared constants
constant uint kHistogramBins        = 256;
constant uint kVectorscopeGrid      = 256;
constant uint kWaveformColumns      = 1024;
constant uint kWaveformBuckets      = 8;   // vertical Y bucketing
```

### `kernelHistogram`

- One thread per pixel. Reads `inputTexture.read(uint2(gid))`, derives `{R, G, B, Y}` in `[0,1]`, casts to `UInt32` bin indices `0..255`, then `atomic_add` into four separate `device atomic_uint*` arrays in the output buffer
- Output layout (size in bytes): `4 * 256 * sizeof(uint)` = 4 KiB

### `kernelVectorscope`

- One thread per pixel. Converts `rgb → Cb/Cr` (BT.601 coefficient, matching `ColorSample.cb/cr`); computes `gridX = quantize(Cb)`, `gridY = quantize(Cr)`; `atomic_add` into `device atomic_uint*` grid
- Saturation-weighted: bin atomic count is multiplied by `uint(saturation * 255 + 0.5)` so high-chroma pixels dominate (color-coded behavior)
- Output layout: `256*256 * sizeof(uint)` = 256 KiB

### `kernelWaveform`

- One threadgroup per source *column*, threads cooperate to reduce height dimension. Each thread samples its row, computes `{Y, R, G, B}`, then accumulates up to 8 bucket counts (card-coded levels) for the column into `device atomic_uint*` arrays. Per-column stride is `kWaveformColumns * kWaveformBuckets * 4` channels × `sizeof(uint)` = 32 KiB
- Reads texture width from `get_width()`; if `width < kWaveformColumns` we downsample by averaging column ranges; if `width > kWaveformColumns` we sample evenly spaced columns

### `kernelColorPicker`

- One threadgroup (1×1). Reads `inputTexture.read(uint2(coord))`, writes a single `float4` into output buffer
- Output layout: `sizeof(float4)` = 16 bytes

### Shader → CPU readback

After the `MTLCommandBuffer` completes, `AnalysisGPURunner` does a `MTLBlitCommandEncoder.copy(from: sourceBuffer, sourceOffset: 0, to: destBuffer, ...)` into a `storageModeShared` mirror. No CPU `memcpy` needed; Swift sees data on next `@Published` access. Atomic increments from the GPU remain coherent across the copy because the source buffer is `storageModeShared` for the duration of the dispatch.

## Audio Meter (`LFSAudioMeter`) — EBU R128 / BS.1770

### Block sizes and windows

| Concept | Duration | Block size | Overlap |
|---|---|---|---|
| True-peak detection | 100 ms | `0.1 * sampleRate` samples | none |
| Momentary loudness | 400 ms | 4 × 100 ms blocks | none |
| Short-term loudness | 3 s | 30 × 100 ms blocks | none |
| Integrated loudness | whole stream | 400 ms blocks | 75% |

### K-weighting filter (per BS.1770-4 §3)

Implemented as a biquad pair (pre-filter + RLB high-pass) per sample, on its own serial queue `com.titanplayer.analysis.audio` (`qos: .userInteractive`):

- 48 kHz coefficients from BS.1770-4 Table 1 (pre-filter) and standard RLB
- For non-48 kHz sample rates, we bilinearly interpolate coefficients against 44.1/48/96 kHz anchor tables (kept in `LFSAudioMeter.swift`)
- Channels are summed per BS.1770-4 (mono; L/R weighted equally; surround channels `-10 dB`; LFE excluded)

### True-peak (per BS.1770-3 / Annex)

- 4× polyphase FIR lowpass interpolation; 48-tap prototype at 4× rate
- Per 100 ms upsampled block, find max |sample| → convert to dBTP (`20 * log10(abs(sample))`)
- Per 100 ms peak hold: 1500 ms decay hold, then release at -0.5 dB/s

### Momentary loudness

- 4 consecutive K-weighted 100 ms blocks → mean square → `dBFS` → `LUFS = -0.691 + dBFS_K`
- Sliding window; republished on every block boundary

### Short-term loudness

- 30 consecutive K-weighted 100 ms blocks → same conversion as momentary, 3 s sliding window

### Integrated loudness (with gating)

- Maintains a ring buffer of 400 ms blocks across the stream's lifetime
- Stage A (absolute gate): drop blocks with loudness `-70 LUFS`
- Stage B (relative gate): compute mean of surviving blocks (ungated mean `L`), then drop blocks `< L - 10 LU` (relative-gated mean `Lr`); this is the integrated loudness
- `integratedLUFS` stays `nil` until at least one block survives both gates (typically a few seconds in)

### Public `AudioMeteringData`

```swift
struct AudioMeteringData: Equatable {
    var momentaryLUFS: Float
    var shortTermLUFS: Float
    var integratedLUFS: Float?
    var truePeakDBTP: Float
    var peakHoldDBTP: PeakHoldSample    // { value: Float, holdUntil: Date }
}

struct PeakHoldSample: Equatable {
    var value: Float
    var holdUntil: Date
}
```

## Color Picker (Frame-Accurate)

- `ColorPickerOverlay` wraps `PlayerView`'s content with an `NSViewRepresentable` that becomes first responder when `colorPickerEnabled == true`
- Captures `mouseDown(with:)` only when modifier flags contain `.command`
- On capture:
  - Maps view-space (x,y) → source-pixel (col,row) via the existing `FitMode` math (`PlayerView` already exposes the same mapping for its hit-test for zoom; we resolve to the same exact pixel as the one displayed)
  - Calls `manager.sampleColor(at: coord, in: texture)` which dispatches `kernelColorPicker`
  - Awaits the readback and assigns `manager.colorPicker = ColorSample(...)`
- `InspectorView` exposes a persistent "Last Picked" section: hex + 0-255 RGB + HSV + YCbCr

## Threading & Update Pacing

| Path | Thread / Queue | Frame cap |
|---|---|---|
| `VideoAnalysisManager.observe(frameStore)` callback | main actor (Combine sink) | throttled to ~30 Hz (decimate frame-id changes within 33 ms windows) |
| `AnalysisGPURunner.dispatchOnce` | `DispatchQueue(qos: .userInitiated, label: "com.titanplayer.analysis.gpu")` | one in-flight dispatch via a `DispatchSemaphore(value: 1)` guarding the shared command queue |
| `LFSAudioMeter.consume` | `DispatchQueue(label: "com.titanplayer.analysis.audio", qos: .userInteractive)` | every consumed buffer (typically ~10 ms at 48 kHz stereo) |
| `ColorPickerOverlay.sampleColor` | main actor → GPU queue → main actor | on demand only |

The dispatch-once-throttle pattern guarantees that a 60 fps source does not produce 60 analyzes per second when waveform+vectorscope+histogram are all enabled.

## Integration with Existing System

### `PlaybackSession`

```swift
let analysis: VideoAnalysisManager    // new

init(...) {
    ...
    self.analysis = VideoAnalysisManager()
    analysis.attach(frameStore: frameStore)
    // Decoder audio tap fires for every decoded audio frame
    if let decoder = engine.mediaPipeline?.decoder as? MediaDecoding {
        decoder.audioTap = { [weak analysis] frame in
            Task { @MainActor in analysis?.audioMeter.consume(frame) }
        }
    }
}
```

(Exact form of `engine.mediaPipeline` access depends on `MediaPipeline`'s public surface; the wiring point may move to `PlaybackEngine` if `MediaPipeline` keeps its decoder private. The spec requires that *some* seam on the audio-decoding path calls `LFSAudioMeter.consume(_:)`.)

### `MediaDecoding` protocol (additive property)

```swift
protocol MediaDecoding: AnyObject {
    var audioTap: ((AudioFrame) -> Void)? { get set }
    // existing methods...
}
```

`AVFoundationDecoder` and `FFmpegDecoder` both set their audio tap result to `audioTap?(frame)` immediately after a successful decode that produces `MediaFrame.audio(_)` (or for FFmpeg, when a synthesized `AudioFrame` is produced during demuxer loop). The tap is fire-and-forget; it dispatches onto its own queue internally.

### `LFSAudioMeter.consume(_ frame: AudioFrame)`

`LFSAudioMeter`'s public entry is `consume(_ frame: AudioFrame)`. It:
1. Converts `frame.buffer: [Float]` (interleaved, `frame.format.channels`) into a single `AVAudioPCMBuffer` at `frame.format.sampleRate`
2. Hands it to the internal block-accumulation pipeline (K-weighting biquad pair per sample; 100 ms block mean square; momentary/short-term/integrated)
3. Publishes the updated `AudioMeteringData` on the main actor

### `PlayerAction` (5 new actions)

| Action | Default shortcut |
|---|---|
| `toggleWaveform` | ⌘1 |
| `toggleVectorscope` | ⌘2 |
| `toggleHistogram` | ⌘3 |
| `toggleAudioMeters` | ⌘4 |
| `activateColorPicker` | ⌘Click (handled in overlay) |

### `KeyboardShortcutManager` defaults

The default `KeyboardShortcutManager` adds bindings for the 4 toggle actions (the color-picker is gesture-only). User can rebind via the existing shortcut UI.

### UI changes

- `InspectorView`: append an `AnalyzerSection` with the four `Toggle`s and a "Last Picked" detail card (when `colorPicker != nil`)
- Below the analyzer toggles, three SwiftUI readouts: `WaveformView`, `VectorscopeView`, `HistogramView` (each only rendered when its toggle is on)
- `ControlBar`: append `AudioMeterBar` slot (peak dot + LUFS readout); only rendered when `audioMeteringEnabled`
- `PlayerView`: wrap content with `ColorPickerOverlay`

## Validation Criteria Mapping

| Source criterion | Design element |
|---|---|
| Waveform updates at 30 fps without lag | §"Threading & Update Pacing" throttle + GPU-only compute + storageModeShared readback + `kWaveformColumns` bucket count |
| Vectorscope accurately displays color distribution | `kernelVectorscope` with BT.601 Cb/Cr + saturation weighting → `VectorscopeData.grid` |
| Histogram shows correct tonal range | `kernelHistogram` 4-channel atomic_add into `HistogramData.{r,g,b,luma}Bins[256]` |
| Audio metering conforms to EBU R128 | §"Audio Meter" — full BS.1770-4 K-weighting + momentary/short-term/integrated with 75%-overlap gating + BS.1770-3 4× true-peak |
| Color picker samples accurate values | `kernelColorPicker` 1×1 readback + `ColorSample` conversions (all math already validated in `AnalysisTypesTests`) |

## Testing Strategy

### Unit tests (pure Swift, no GPU)

| Test file | Cases |
|---|---|
| `Analysis/AnalyzerHelpersTests.swift` | RGB→YCbCr matches `ColorSample` (Red: `Y=0.2126, Cb=Cr=0.5`); K-weighting coefficients at 44.1/48/96 kHz |
| `Analysis/LFSAudioMeterTests.swift` | 1 kHz sine at 0 dBFS K-weighted ≈ -3.7 LUFS (within ±0.5 LU); 1 kHz sine at -20 dBFS K-weighted → momentary equal to ungated mean; integrated stage-A gate drops a -80 dBFS block; integrated stage-B gate drops block ≥ 10 LU below ungated mean; true-peak on a clipped sample > sample-peak by > 0.5 dBTP |
| `Analysis/VideoAnalysisManagerToggleTests.swift` | Flipping `waveformEnabled`/`vectorscopeEnabled`/`histogramEnabled` while no frames arrive leaves outputs nil; flips during frame-arrival dispatch the correct kernel (mocked `AnalysisGPURunner`) |
| `Analysis/ColorPickerOverlayTests.swift` | view-coord ↔ source-pixel mapping under each `FitMode` |

### GPU round-trip tests (real `MTLDevice`)

| Test file | Cases |
|---|---|
| `Analysis/AnalyzerKernelTests.swift` | Render a known `256×256` `rgba16Float` texture (gradient + known histogram distribution); assert `HistogramData` bin counts match expected within 0.5%; assert `VectorscopeData.grid` non-zero only where expected; assert `WaveformData` column counts monotonically track a horizontal gradient |
| `Analysis/AnalysisPipelineIntegrationTests.swift` | Load `Fixtures/test.mp4`; advance 30 frames; assert `histogram`, `waveform`, `vectorscope` all settle to stable non-nil data within 1 s; `audioMeter.momentaryLUFS` settles within ±1 LU once steady-state playback is reached |

### Test gating

Tests requiring `MTLCreateSystemDefaultDevice()` are marked with a custom trait `requiresGPU()`. Where Xcode/command-line tools are unavailable, tests are skipped but logged. Same gating already used by `MetalRendererTests.swift` (existing convention).

## File Plan

### Add

```
TitanPlayer/TitanPlayer/Core/Analysis/VideoAnalysisManager.swift
TitanPlayer/TitanPlayer/Core/Analysis/AnalysisGPURunner.swift
TitanPlayer/TitanPlayer/Core/Analysis/LFSAudioMeter.swift
TitanPlayer/TitanPlayer/Core/Analysis/AudioMeteringData.swift
TitanPlayer/TitanPlayer/UI/Analysis/WaveformView.swift
TitanPlayer/TitanPlayer/UI/Analysis/VectorscopeView.swift
TitanPlayer/TitanPlayer/UI/Analysis/HistogramView.swift
TitanPlayer/TitanPlayer/UI/Analysis/ColorPickerOverlay.swift
TitanPlayer/TitanPlayer/UI/Analysis/AudioMeterBar.swift
TitanPlayer/TitanPlayer/Resources/Shaders/Analysis.metal
TitanPlayer/Tests/Analysis/AnalyzerHelpersTests.swift
TitanPlayer/Tests/Analysis/LFSAudioMeterTests.swift
TitanPlayer/Tests/Analysis/VideoAnalysisManagerToggleTests.swift
TitanPlayer/Tests/Analysis/ColorPickerOverlayTests.swift
TitanPlayer/Tests/Analysis/AnalyzerKernelTests.swift
TitanPlayer/Tests/Analysis/AnalysisPipelineIntegrationTests.swift
```

No new SwiftPM dependencies. `Metal.framework`, `Accelerate.framework`, `AVFoundation.framework` already linked for the existing renderer/audio engine.

### Modify

```
TitanPlayer/TitanPlayer/Core/Decoders/Protocols/MediaDecoding.swift               # + audioTap property
TitanPlayer/TitanPlayer/Core/Decoders/AVFoundation/AVFoundationDecoder.swift      # call audioTap on each decoded AudioFrame
TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegDecoder.swift                  # call audioTap on each decoded AudioFrame
TitanPlayer/TitanPlayer/Core/Engine/PlaybackEngine.swift                           # expose decoder hookup (or PlaybackSession wires directly)
TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift                          # own + expose analysis + install audio tap on decoder
TitanPlayer/TitanPlayer/UI/Views/InspectorView.swift                              # AnalyzerSection
TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift                                 # wrap with ColorPickerOverlay
TitanPlayer/TitanPlayer/UI/Controls/ControlBar.swift                              # AudioMeterBar slot
TitanPlayer/TitanPlayer/UI/Shortcuts/PlayerAction.swift                           # 4 new toggle actions
TitanPlayer/TitanPlayer/UI/Shortcuts/KeyboardShortcutManager.swift                 # default bindings for new actions
```

No public API deletions; existing concrete audio/video renderers continue to compile.

## Out of Scope

- HDR-aware pre-tone-map analysis (separate later spec)
- Per-tool color spaces / calibration targets
- Two-sample variance / programmatic conformance-test harness against reference BS.1770 vectors
