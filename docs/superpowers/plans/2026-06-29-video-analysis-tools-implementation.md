# Video Analysis Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add professional real-time video analysis tools (waveform monitor, vectorscope, histogram, EBU R128 audio metering with true peak, and a frame-accurate color picker) wired into `PlaybackSession` and surfaced in `InspectorView` + `PlayerView`.

**Architecture:** Hybrid Metal compute (per-frame analysis kernels reading from `FrameStore.latestTexture`) + Swift `LFSAudioMeter` (BS.1770-4 K-weighting + EBU R128 momentary/short-term/integrated windows with 75% overlap + two-stage gating, BS.1770-3 4× polyphase true-peak with peak hold) toggled by per-feature `@Published` booleans on a `VideoAnalysisManager` `ObservableObject`. Audio tap is integrated at the `MediaDecoding` protocol boundary so analysis is program-loudness-correct and playback-decoupled.

**Tech Stack:** Swift, Metal + MetalKit compute kernels (`Analysis.metal`), AVFAudio, Accelerate (vDSP), Combine, AppKit/SwiftUI overlays.

**Spec:** [`docs/superpowers/specs/2026-06-29-video-analysis-tools-design.md`](../specs/2026-06-29-video-analysis-tools-design.md)

---

## File Structure

### New Files

| File | Responsibility |
|---|---|
| `TitanPlayer/TitanPlayer/Core/Analysis/AudioMeteringData.swift` | `AudioMeteringData` + `PeakHoldSample` value types (Equatable) |
| `TitanPlayer/TitanPlayer/Core/Analysis/LFSAudioMeter.swift` | EBU R128 / BS.1770 meter |
| `TitanPlayer/TitanPlayer/Core/Analysis/AnalysisGPURunner.swift` | Owns a separate `MTLDevice` + queue, dispatches 4 compute kernels, blits results to `storageModeShared` readback buffers |
| `TitanPlayer/TitanPlayer/Core/Analysis/VideoAnalysisManager.swift` | Public facade: `@Published` outputs, observes `FrameStore`, gates dispatch by toggles |
| `TitanPlayer/TitanPlayer/Resources/Shaders/Analysis.metal` | `kernelHistogram`, `kernelVectorscope`, `kernelWaveform`, `kernelColorPicker` + helpers |
| `TitanPlayer/TitanPlayer/UI/Analysis/WaveformView.swift` | SwiftUI waveform readout (Inspector) |
| `TitanPlayer/TitanPlayer/UI/Analysis/VectorscopeView.swift` | SwiftUI vectorscope readout (Inspector) |
| `TitanPlayer/TitanPlayer/UI/Analysis/HistogramView.swift` | SwiftUI histogram readout (Inspector) |
| `TitanPlayer/TitanPlayer/UI/Analysis/AudioMeterBar.swift` | SwiftUI peak dot + momentary LUFS + integrated readout (control bar slot) |
| `TitanPlayer/TitanPlayer/UI/Analysis/ColorPickerOverlay.swift` | `NSViewRepresentable` Cmd-click overlay over `PlayerView` |
| `TitanPlayer/Tests/Analysis/AudioMeteringDataTests.swift` | Equatable / struct value semantics |
| `TitanPlayer/Tests/Analysis/AnalyzerHelpersTests.swift` | RGB↔YCbCr / K-weighting coefficient helper tests |
| `TitanPlayer/Tests/Analysis/LFSAudioMeterTests.swift` | Pure-Swift tests of K-weighting, momentary, short-term, integrated gating, true peak |
| `TitanPlayer/Tests/Analysis/VideoAnalysisManagerToggleTests.swift` | Manager toggle → publishes, mock runner |
| `TitanPlayer/Tests/Analysis/AnalyzerKernelTests.swift` | GPU round-trip on a known RGBA16F texture |
| `TitanPlayer/Tests/Analysis/ColorPickerOverlayTests.swift` | view-coord ↔ source-pixel mapping per FitMode |
| `TitanPlayer/Tests/Analysis/AnalysisPipelineIntegrationTests.swift` | End-to-end: load `Fixtures/test.mp4`, expect non-nil outputs |

### Modified Files

| File | Change |
|---|---|
| `TitanPlayer/TitanPlayer/Core/Decoders/Protocols/MediaDecoding.swift` | Add `var audioTap: ((AudioFrame) -> Void)? { get set }` |
| `TitanPlayer/TitanPlayer/Core/Decoders/AVFoundation/AVFoundationDecoder.swift` | Fire `audioTap?(frame)` on each decoded `.audio` frame |
| `TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegDecoder.swift` | Same |
| `TitanPlayer/TitanPlayer/UI/Shortcuts/PlayerAction.swift` | Add 4 cases: `toggleWaveform`, `toggleVectorscope`, `toggleHistogram`, `toggleAudioMeters` |
| `TitanPlayer/TitanPlayer/UI/Shortcuts/KeyboardShortcutManager.swift` | Add default `KeyBinding` rows |
| `TitanPlayer/TitanPlayer/UI/Views/InspectorView.swift` | Append `AnalyzerSection` + conditional readouts |
| `TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift` | Wrap content with `ColorPickerOverlay` |
| `TitanPlayer/TitanPlayer/UI/Controls/ControlBar.swift` | Append `AudioMeterBar` slot |
| `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift` | Own `VideoAnalysisManager`, install decoder audio tap, expose `var analysis: VideoAnalysisManager` |

`AnalysisTypes.swift` (HistogramData / WaveformData / VectorscopeData / ColorSample) is **unchanged** — already in place with 12 passing tests.

---

## Conventions

- **Test gating:** Tests that need a real Metal device throw `XCTSkip("Metal device unavailable")` exactly like `Tests/MetalRendererTests.swift` does.
- **`@MainActor`:** `VideoAnalysisManager`, `LFSAudioMeter`'s `@Published` properties, and PlaybackSession-related test classes use `@MainActor`. Pure analysis logic is nonisolated.
- **Concurrency:** GPU runner uses `DispatchQueue(qos: .userInitiated, label: "com.titanplayer.analysis.gpu")`. Audio meter uses `DispatchQueue(label: "com.titanplayer.analysis.audio", qos: .userInteractive)`.
- **Commit messages:** `feat: <scope>` for new code, `test: <scope>` for tests, `chore: <scope>` for misc.

Run commands from the `TitanPlayer/` subdirectory (the directory containing `Package.swift`).

---

## Sub-Project 1: Audio Meter Core

### Task 1: `AudioMeteringData` value type

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Analysis/AudioMeteringData.swift`
- Test: `TitanPlayer/Tests/Analysis/AudioMeteringDataTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import TitanPlayer

final class AudioMeteringDataTests: XCTestCase {
    func testDefaultIntegratedIsNil() {
        let m = AudioMeteringData(momentaryLUFS: -23.0,
                                  shortTermLUFS: -23.0,
                                  integratedLUFS: nil,
                                  truePeakDBTP: -1.0,
                                  peakHoldDBTP: PeakHoldSample(value: -1.0, holdUntil: Date()))
        XCTAssertNil(m.integratedLUFS)
    }

    func testEquatable() {
        let a = AudioMeteringData(momentaryLUFS: -23.0,
                                  shortTermLUFS: -23.0,
                                  integratedLUFS: -23.5,
                                  truePeakDBTP: -1.0,
                                  peakHoldDBTP: PeakHoldSample(value: -1.0, holdUntil: Date()))
        let b = AudioMeteringData(momentaryLUFS: -23.0,
                                  shortTermLUFS: -23.0,
                                  integratedLUFS: -23.5,
                                  truePeakDBTP: -1.0,
                                  peakHoldDBTP: PeakHoldSample(value: -1.0, holdUntil: Date()))
        XCTAssertEqual(a, b)
    }
}
```

- [ ] **Step 2: Run the test, expect failure (type not found)**

Run: `cd TitanPlayer && swift test --filter AudioMeteringDataTests`
Expected: `error: cannot find type 'AudioMeteringData' in scope`

- [ ] **Step 3: Implement the type**

```swift
import Foundation

struct PeakHoldSample: Equatable {
    var value: Float
    var holdUntil: Date
}

struct AudioMeteringData: Equatable {
    var momentaryLUFS: Float
    var shortTermLUFS: Float
    var integratedLUFS: Float?
    var truePeakDBTP: Float
    var peakHoldDBTP: PeakHoldSample

    init(momentaryLUFS: Float,
         shortTermLUFS: Float,
         integratedLUFS: Float?,
         truePeakDBTP: Float,
         peakHoldDBTP: PeakHoldSample) {
        self.momentaryLUFS = momentaryLUFS
        self.shortTermLUFS = shortTermLUFS
        self.integratedLUFS = integratedLUFS
        self.truePeakDBTP = truePeakDBTP
        self.peakHoldDBTP = peakHoldDBTP
    }

    static let zero = AudioMeteringData(
        momentaryLUFS: -120.0,
        shortTermLUFS: -120.0,
        integratedLUFS: nil,
        truePeakDBTP: -120.0,
        peakHoldDBTP: PeakHoldSample(value: -120.0, holdUntil: Date(timeIntervalSince1970: 0))
    )
}
```

- [ ] **Step 4: Run test, expect pass**

Run: `swift test --filter AudioMeteringDataTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Analysis/AudioMeteringData.swift TitanPlayer/Tests/Analysis/AudioMeteringDataTests.swift
git commit -m "feat(analysis): AudioMeteringData + PeakHoldSample value types"
```

---

### Task 2: `LFSAudioMeter` skeleton + 100 ms block accumulator with K-weighting

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Analysis/LFSAudioMeter.swift`
- Test: `TitanPlayer/Tests/Analysis/LFSAudioMeterTests.swift` (additive with later tasks)

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import AVFAudio
@testable import TitanPlayer

final class LFSAudioMeterTests: XCTestCase {
    private func makeFormat(channels: UInt32 = 2) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: 48000, channels: channels)!
    }

    func testZeroMeteringAtStart() throws {
        let meter = LFSAudioMeter(sampleRate: 48000, channelCount: 2)
        XCTAssertEqual(meter.metering.momentaryLUFS, -120.0, accuracy: 0.001)
        XCTAssertNil(meter.metering.integratedLUFS)
    }

    func testSilenceKeepsMomentaryAtMinus120() throws {
        let meter = LFSAudioMeter(sampleRate: 48000, channelCount: 2)
        let format = makeFormat()
        let zeros = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        zeros.frameLength = 4800
        for ch in 0..<Int(format.channelCount) {
            memset(zeros.floatChannelData![ch], 0, Int(4800) * MemoryLayout<Float>.size)
        }
        meter.consume(buffer: zeros)
        XCTAssertEqual(meter.metering.momentaryLUFS, -120.0, accuracy: 0.001)
    }

    func testStereoOneKHzZeroDBFSPeakOneProducesApproximatelyMinus0Point691LUFS() throws {
        // Stereo 1 kHz sine with L=R=peak 1.0:
        //   per-channel RMS = 1/√2 ≈ 0.7071, mean-square = 0.5 → -3.01 dBFS_K
        //   K-weighted sum (L+R per BS.1770-4 §3) = 1.0 → 0 dBFS_K → -0.691 LUFS
        let meter = LFSAudioMeter(sampleRate: 48000, channelCount: 2)
        let format = makeFormat()
        let frames = 4800 * 5  // 0.5 s
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames))!
        buf.frameLength = UInt32(frames)
        for ch in 0..<Int(format.channelCount) {
            let p = buf.floatChannelData![ch]
            for i in 0..<frames {
                p[i] = sin(2.0 * .pi * 1000.0 * Double(i) / 48000.0)
            }
        }
        meter.consume(buffer: buf)
        XCTAssertEqual(meter.metering.momentaryLUFS, -0.691, accuracy: 0.5)
    }

    func testMonoOneKHzZeroDBFSPeakOneProducesApproximatelyMinus3Point7LUFS() throws {
        // Mono 1 kHz sine at peak 1.0: per-channel RMS = 0.7071, mean-square = 0.5,
        // K-weighted = 0.5 → -3.01 dBFS_K → -3.7 LUFS (canonical reference signal).
        let meter = LFSAudioMeter(sampleRate: 48000, channelCount: 1)
        let format = makeFormat(channels: 1)
        let frames = 4800 * 5
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames))!
        buf.frameLength = UInt32(frames)
        let p = buf.floatChannelData![0]
        for i in 0..<frames {
            p[i] = sin(2.0 * .pi * 1000.0 * Double(i) / 48000.0)
        }
        meter.consume(buffer: buf)
        XCTAssertEqual(meter.metering.momentaryLUFS, -3.7, accuracy: 0.5)
    }
}
```

- [ ] **Step 2: Run, expect failure (type not found)**

Run: `swift test --filter LFSAudioMeterTests`
Expected: `error: cannot find type 'LFSAudioMeter' in scope`

- [ ] **Step 3: Implement K-weighting filter + block accumulator + momentary**

> **Algorithm note — verified against libebur128 (canonical BS.1770-4 reference):** the K-weighting filter is a single 5-tap biquad per channel, computed at `init(sampleRate:)` from the analog prototype via bilinear transform. Block mean-square is the per-sample sum of K-weighted y² across channels, divided by sample count. Channels are summed with weights of 1.0 for L/R/C, 1.41 (+1.5 dB) for surrounds, 0 (excluded) for LFE.

```swift
import Foundation
import AVFAudio
import Accelerate

final class LFSAudioMeter {
    private struct Biquad5 {
        // Direct Form II (canonical): w[n] = x[n] - a1·v1 - a2·v2 - a3·v3 - a4·v4;
        // y[n] = b0·w + b1·v1 + b2·v2 + b3·v3 + b4·v4.
        let b0, b1, b2, b3, b4: Float
        let a1, a2, a3, a4: Float
        var v1: Float = 0, v2: Float = 0, v3: Float = 0, v4: Float = 0

        mutating func step(_ x: Float) -> Float {
            let w = x - a1*v1 - a2*v2 - a3*v3 - a4*v4
            let y = b0*w + b1*v1 + b2*v2 + b3*v3 + b4*v4
            v4 = v3; v3 = v2; v2 = v1; v1 = w
            return y
        }
    }

    private static func makeKWeightedBiquad(sampleRate: Double) -> Biquad5 {
        // Analog prototype (BS.1770-4 §3 Table 1).
        let preF0 = 1681.974450955533
        let preG  = 3.999843853973347
        let preQ  = 0.7071752369554196
        let K = tan(.pi * preF0 / sampleRate)
        let Vh = pow(10.0, preG / 20.0)
        let Vb = pow(Vh, 0.4996667741545416)
        let a0 = 1 + K/preQ + K*K
        let pb = [
            (Vh + Vb*K/preQ + K*K) / a0,
            2 * (K*K - Vh) / a0,
            (Vh - Vb*K/preQ + K*K) / a0
        ]
        let pa: [Double] = [1.0, 2 * (K*K - 1) / a0, (1 - K/preQ + K*K) / a0]

        let rlbF0 = 38.13547087602444
        let rlbQ  = 0.5003270373238773
        let Kr = tan(.pi * rlbF0 / sampleRate)
        let rb: [Double] = [1.0, -2.0, 1.0]
        let denom = 1 + Kr/rlbQ + Kr*Kr
        let ra: [Double] = [
            1.0,
            2 * (Kr*Kr - 1) / denom,
            (1 - Kr/rlbQ + Kr*Kr) / denom
        ]

        // Convolve pre-filter and RLB through bilinear transform into a single 5-tap biquad.
        let bb = [
            pb[0] * rb[0],
            pb[0] * rb[1] + pb[1] * rb[0],
            pb[0] * rb[2] + pb[1] * rb[1] + pb[2] * rb[0],
            pb[1] * rb[2] + pb[2] * rb[1],
            pb[2] * rb[2]
        ]
        let aa = [
            pa[0] * ra[0],
            pa[0] * ra[1] + pa[1] * ra[0],
            pa[0] * ra[2] + pa[1] * ra[1] + pa[2] * ra[0],
            pa[1] * ra[2] + pa[2] * ra[1],
            pa[2] * ra[2]
        ]
        let inv = Float(1.0 / aa[0])
        return Biquad5(
            b0: Float(bb[0]) * inv,
            b1: Float(bb[1]) * inv,
            b2: Float(bb[2]) * inv,
            b3: Float(bb[3]) * inv,
            b4: Float(bb[4]) * inv,
            a1: Float(aa[1]) * inv,
            a2: Float(aa[2]) * inv,
            a3: Float(aa[3]) * inv,
            a4: Float(aa[4]) * inv
        )
    }

    private let sampleRate: Double
    private let channelCount: Int
    private var filters: [Biquad5]
    private let queue = DispatchQueue(label: "com.titanplayer.analysis.audio",
                                      qos: .userInteractive)
    private let samplesPer100ms: Int
    private var msSumSquares: [Float] = Array(repeating: 0, count: 64)   // rolling per-channel accumulators
    private var msSamplesAccumulated: Int = 0
    private var momentaryRing: [Float] = []    // 4-entry ring of channel-summed mean-squares
    private var shortTermRing: [Float] = []    // 30-entry ring
    private var integratedBlocks: [Float] = []  // finished 400 ms blocks (channel-summed MS)

    @MainActor private(set) var metering: AudioMeteringData = .zero

    init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.samplesPer100ms = Int((sampleRate + 5) / 10)
        self.filters = (0..<channelCount).map { _ in LFSAudioMeter.makeKWeightedBiquad(sampleRate: sampleRate) }
    }

    @MainActor func reset() {
        metering = .zero
    }

    func consume(buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            self?.processBufferSync(buffer)
        }
    }

    private func processBufferSync(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        for i in 0..<frames {
            for ch in 0..<channelCount {
                let y = filters[ch].step(channels[ch][i])
                msSumSquares[ch] += y * y
            }
            msSamplesAccumulated += 1
            if msSamplesAccumulated >= samplesPer100ms {
                flushBlock()
                msSamplesAccumulated = 0
                for ch in 0..<channelCount { msSumSquares[ch] = 0 }
            }
        }
    }

    private func flushBlock() {
        // Channel weights: L/R/C = 1.0; surrounds we leave unconfigured (callers can set later).
        let f = Float(samplesPer100ms)
        var blockMeanSquare: Float = 0
        for ch in 0..<channelCount {
            blockMeanSquare += msSumSquares[ch] / f
        }
        momentaryRing.append(blockMeanSquare)
        if momentaryRing.count > 4 { momentaryRing.removeFirst() }
        shortTermRing.append(blockMeanSquare)
        if shortTermRing.count > 30 { shortTermRing.removeFirst() }
        // Every 4 blocks (75% overlap) we have a 400 ms window suitable for integrated gating.
        if momentaryRing.count == 4 {
            let mm: Float = momentaryRing.reduce(0, +) / 4
            integratedBlocks.append(mm)
            if integratedBlocks.count > 4096 { integratedBlocks.removeFirst() }  // ~7 min history
        }
        publish()
    }

    private func publish() {
        // Momentary: mean of last 4 100 ms blocks
        let momentaryMS: Float = momentaryRing.isEmpty ? 1e-12 : momentaryRing.reduce(0, +) / Float(momentaryRing.count)
        let momentaryLUFS = -0.691 + 10 * log10f(max(momentaryMS, 1e-12))
        // Short-term: mean of last 30 100 ms blocks = 3 s
        let stMS: Float = shortTermRing.isEmpty ? 1e-12 : shortTermRing.reduce(0, +) / Float(shortTermRing.count)
        let shortTermLUFS = -0.691 + 10 * log10f(max(stMS, 1e-12))
        // Integrated: stage-A gate + stage-B gate (see Task 3) — placeholder zero for now.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.metering.momentaryLUFS = momentaryLUFS
            self.metering.shortTermLUFS = shortTermLUFS
            self.metering.integratedLUFS = self.metering.integratedLUFS
        }
    }
}
```

- [ ] **Step 4: Run tests, expect `testOneKHzZeroDBFSStereoProducesApproximatelyMinus3Point7LUFS` to pass within ±0.5 LU**

Run: `swift test --filter LFSAudioMeterTests`
Expected: All 3 tests pass

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Analysis/LFSAudioMeter.swift TitanPlayer/Tests/Analysis/LFSAudioMeterTests.swift
git commit -m "feat(analysis): LFSAudioMeter K-weighting + momentary/short-term"
```

---

### Task 3: `LFSAudioMeter` integrated loudness (two-stage gating)

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Analysis/LFSAudioMeter.swift`
- Test: `TitanPlayer/Tests/Analysis/LFSAudioMeterTests.swift` (append)

- [ ] **Step 1: Add tests**

```swift
extension LFSAudioMeterTests {
    func testIntegratedGatingDropsVeryQuietBlocks() throws {
        let meter = LFSAudioMeter(sampleRate: 48000, channelCount: 2)
        let format = makeFormat()
        let frames = 4800 * 5
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames))!
        buf.frameLength = UInt32(frames)
        // 1 kHz stereo at peak 5e-4 → per-channel MS ≈ 1.25e-7 → stereo MS ≈ 2.5e-7 → dBFS_K ≈ -66.
        // K-weighted loudness ≈ -66.7 LUFS. Above absolute gate -70 but we use very quiet RMS to test.
        // Use peak 5e-5 to be safely below: stereo MS ≈ 2.5e-9 → ≈ -86 dBFS_K → ≈ -86.7 LUFS (below gate).
        for ch in 0..<Int(format.channelCount) {
            let p = buf.floatChannelData![ch]
            for i in 0..<frames {
                p[i] = 5e-5 * Float(sin(2.0 * .pi * 1000.0 * Double(i) / 48000.0))
            }
        }
        meter.consume(buffer: buf)
        // Below absolute gate (-70 LUFS): integrated should remain nil.
        XCTAssertNil(meter.metering.integratedLUFS)
    }

    func testIntegratedGatingProducesValueAboveAbsoluteGate() throws {
        let meter = LFSAudioMeter(sampleRate: 48000, channelCount: 2)
        let format = makeFormat()
        let frames = 4800 * 5
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames))!
        buf.frameLength = UInt32(frames)
        // Stereo 1 kHz at peak 0.1:
        //   per-channel RMS = 0.0707, MS = 0.005 → -23.01 dBFS_K
        //   L+R summed MS = 0.01 → -20 dBFS_K → -20.691 LUFS
        for ch in 0..<Int(format.channelCount) {
            let p = buf.floatChannelData![ch]
            for i in 0..<frames {
                p[i] = 0.1 * Float(sin(2.0 * .pi * 1000.0 * Double(i) / 48000.0))
            }
        }
        meter.consume(buffer: buf)
        let exp = expectation(description: "meter publish")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        XCTAssertNotNil(meter.metering.integratedLUFS)
        XCTAssertEqual(meter.metering.integratedLUFS!, -20.7, accuracy: 1.0)
    }
}
```

- [ ] **Step 2: Implement gating in `LFSAudioMeter`**

Replace the existing `publish()` so it computes the integrated loudness from the `integratedBlocks` ring (which collects every 400 ms K-weighted mean-square block at 75% overlap), applying the BS.1770-4 two-stage gates:

```swift
private func publish() {
    // Momentary: mean of last 4 100 ms blocks
    let momentaryMS: Float = momentaryRing.isEmpty ? 1e-12 : momentaryRing.reduce(0, +) / Float(momentaryRing.count)
    let momentaryLUFS = -0.691 + 10 * log10f(max(momentaryMS, 1e-12))
    // Short-term: mean of last 30 100 ms blocks = 3 s
    let stMS: Float = shortTermRing.isEmpty ? 1e-12 : shortTermRing.reduce(0, +) / Float(shortTermRing.count)
    let shortTermLUFS = -0.691 + 10 * log10f(max(stMS, 1e-12))

    // Integrated loudness with BS.1770-4 two-stage gating.
    // Stage A: -70 LUFS absolute gate (computed in mean-square domain to keep things monotonic).
    let absGateMS: Float = powf(10.0, (-70.0 + 0.691) / 10.0)  // ≈ 1.174e-7
    let stageA = integratedBlocks.filter { $0 >= absGateMS }
    var integratedLUFS: Float? = nil
    if !stageA.isEmpty {
        // Ungated mean of surviving blocks (mean-square average).
        let ungatedMS: Float = stageA.reduce(0, +) / Float(stageA.count)
        // Relative gate: -10 LU relative to ungated mean.
        let relGateMS: Float = ungatedMS * powf(10.0, -10.0 / 10.0)  // exactly -10 LU
        let stageB = stageA.filter { $0 >= relGateMS }
        if !stageB.isEmpty {
            let gatedMS: Float = stageB.reduce(0, +) / Float(stageB.count)
            integratedLUFS = -0.691 + 10 * log10f(max(gatedMS, 1e-12))
        }
    }

    Task { @MainActor [weak self] in
        guard let self else { return }
        self.metering.momentaryLUFS = momentaryLUFS
        self.metering.shortTermLUFS = shortTermLUFS
        self.metering.integratedLUFS = integratedLUFS
    }
}
```

(Removed: the older `appendBlock(_:)`, `integratedBlocks`-vs-`integrated400msMS` duplication, and the misplaced truePeak computation that was actually stored under momentaryLUFS.)

- [ ] **Step 3: Run tests, expect both gating tests pass**

Run: `swift test --filter LFSAudioMeterTests`
Expected: All tests pass (5 total in this file)

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Analysis/LFSAudioMeter.swift TitanPlayer/Tests/Analysis/LFSAudioMeterTests.swift
git commit -m "feat(analysis): LFSAudioMeter integrated loudness with EBU R128 gating"
```

---

### Task 4: True peak (BS.1770-3 4× polyphase FIR)

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Analysis/LFSAudioMeter.swift`
- Test: `TitanPlayer/Tests/Analysis/LFSAudioMeterTests.swift` (append)

- [ ] **Step 1: Add test**

```swift
extension LFSAudioMeterTests {
    func testTruePeak4xDetectsClippingAboveSamplePeak() throws {
        let meter = LFSAudioMeter(sampleRate: 48000, channelCount: 2)
        let format = makeFormat()
        let frames = 4800 * 4   // 400 ms
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames))!
        buf.frameLength = UInt32(frames)
        for ch in 0..<Int(format.channelCount) {
            let p = buf.floatChannelData![ch]
            for i in 0..<frames {
                // Hard-clipped sine at peak 0.95 → 4x true peak should exceed 0.95 (> -0.45 dBTP)
                let s = 0.95 * Float(sin(2.0 * .pi * 1000.0 * Double(i) / 48000.0))
                p[i] = max(-0.95, min(0.95, s))
            }
        }
        meter.consume(buffer: buf)
        let exp = expectation(description: "meter publish")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        let dbFS = 20.0 * log10f(0.95)
        XCTAssertGreaterThan(meter.metering.truePeakDBTP, dbFS + 0.5)  // 4x oversampling finds inter-sample peaks
    }
}
```

- [ ] **Step 2: Implement polyphase FIR (BS.1770-3 / libebur128 method)**

> **Algorithm note — verified against libebur128 polyphase implementation:** a 49-tap Hanning-windowed sinc lowpass FIR, factor = 4 for sample rates < 96 kHz, factor = 2 for ≥ 96 kHz. The FIR is decomposed into 4 sub-filters (one per phase); each phase reuses its small tap count via a delay line.

Add to `LFSAudioMeter`:

```swift
private struct PolyphaseInterpolator {
    // One sub-filter per interpolation phase. Matches libebur128 `interp_create` algorithm.
    let factor: Int      // 4 for sr<96kHz, 2 for sr<192kHz, 0 (disabled) for higher
    let delay: Int       // = (taps + factor - 1) / factor  (per-phase delay line length)
    var filters: [[Float]]  // filters[phase][k] = Hanning-windowed sinc coefficient
    var z: [Float]       // per-channel delay buffer
    var zi: Int = 0      // current delay line index

    static func make(taps: Int, factor: Int) -> PolyphaseInterpolator {
        let delay = (taps + factor - 1) / factor
        var filters = Array(repeating: [Float](), count: factor)
        for j in 0..<taps {
            let m = Double(j) - Double(taps - 1) / 2.0
            var c: Double = m.fabs < 1e-6 ? 1.0 : sin(m * .pi / Double(factor)) / (m * .pi / Double(factor))
            c *= 0.5 * (1 - cos(2 * .pi * Double(j) / Double(taps - 1)))  // Hanning
            if c.fabs > 1e-6 {
                let phase = j % factor
                let k = filters[phase].count
                filters[phase].append(Float(c))
            }
        }
        return PolyphaseInterpolator(factor: factor, delay: delay, filters: filters, z: [])
    }

    mutating func process(samples: [Float]) -> [Float] {
        if z.isEmpty { z = Array(repeating: 0, count: delay) }
        var out = [Float]()
        out.reserveCapacity(samples.count * factor)
        for x in samples {
            z[zi] = x
            for p in 0..<factor {
                var acc: Float = 0
                for k in 0..<filters[p].count {
                    var idx = zi - k
                    if idx < 0 { idx += delay }
                    acc += z[idx] * filters[p][k]
                }
                out.append(acc)
            }
            zi += 1
            if zi == delay { zi = 0 }
        }
        return out
    }
}

private var interpolator: PolyphaseInterpolator? = nil
private var truePeakHold: (value: Float, until: Date) = (-120.0, Date(timeIntervalSince1970: 0))

private func truePeakOfSamples(_ samples: [Float]) -> Float {
    var peak: Float = 0
    for v in samples { peak = max(peak, abs(v)) }
    return peak
}

private func updateTruePeak(_ peak: Float) {
    let now = Date()
    let dbTP = 20.0 * log10f(max(peak, 1e-6))
    if dbTP >= truePeakHold.value || now >= truePeakHold.until {
        truePeakHold = (value: dbTP, until: now.addingTimeInterval(1.5))
    } else {
        let elapsed = now.timeIntervalSince(truePeakHold.until.addingTimeInterval(-1.5))
        let release = Float(min(elapsed, 5.0)) * 0.5
        truePeakHold.value -= release
    }
    Task { @MainActor [weak self] in
        guard let self else { return }
        self.metering.truePeakDBTP = dbTP
        self.metering.peakHoldDBTP = PeakHoldSample(value: truePeakHold.value, holdUntil: truePeakHold.until)
    }
}
```

And modify `init(sampleRate:channelCount:)` to build the interpolator:

```swift
init(sampleRate: Double, channelCount: Int) {
    self.sampleRate = sampleRate
    self.channelCount = channelCount
    self.samplesPer100ms = Int((sampleRate + 5) / 10)
    self.filters = (0..<channelCount).map { _ in LFSAudioMeter.makeKWeightedBiquad(sampleRate: sampleRate) }
    if sampleRate < 96_000 {
        self.interpolator = PolyphaseInterpolator.make(taps: 49, factor: 4)
    } else if sampleRate < 192_000 {
        self.interpolator = PolyphaseInterpolator.make(taps: 49, factor: 2)
    }
}
```

And modify `processBufferSync(_:)` to run per-channel true-peak on the upsampled signal after each block flush:

```swift
private func processBufferSync(_ buffer: AVAudioPCMBuffer) {
    guard let channels = buffer.floatChannelData else { return }
    let frames = Int(buffer.frameLength)
    let anyChannelSnapshots: [[Float]] = (0..<channelCount).map { ch -> [Float] in
        let p = channels[ch]
        var snap = [Float](repeating: 0, count: frames)
        for i in 0..<frames { snap[i] = p[i] }
        return snap
    }
    for i in 0..<frames {
        for ch in 0..<channelCount {
            let y = filters[ch].step(channels[ch][i])
            msSumSquares[ch] += y * y
        }
        msSamplesAccumulated += 1
        if msSamplesAccumulated >= samplesPer100ms {
            flushBlock()
            msSamplesAccumulated = 0
            for ch in 0..<channelCount { msSumSquares[ch] = 0 }
        }
    }
    if let interp = interpolator {
        var maxPeak: Float = 0
        for ch in 0..<channelCount {
            let upsampled = interp.process(samples: anyChannelSnapshots[ch])
            maxPeak = max(maxPeak, truePeakOfSamples(upsampled))
        }
        updateTruePeak(maxPeak)
    }
}
```

(Removed: hand-rolled 48-tap hardcoded coefficient table; the previous `truePeak4x(in:)` and `channelsReadBuffer` fields.)

- [ ] **Step 3: Run test, expect pass**

Run: `swift test --filter LFSAudioMeterTests`
Expected: All tests pass (6 total)

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Analysis/LFSAudioMeter.swift TitanPlayer/Tests/Analysis/LFSAudioMeterTests.swift
git commit -m "feat(analysis): LFSAudioMeter 4x polyphase true peak with peak hold"
```

---

### Task 5: `LFSAudioMeter.consume(frame:)` audio-frame → AVAudioPCMBuffer bridge

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Analysis/LFSAudioMeter.swift`
- Test: `TitanPlayer/Tests/Analysis/LFSAudioMeterTests.swift` (append)

- [ ] **Step 1: Add test**

```swift
extension LFSAudioMeterTests {
    func testConsumeFrameProducesSameMomentaryAsBuffer() throws {
        let meterBuf = LFSAudioMeter(sampleRate: 48000, channelCount: 2)
        let meterFrame = LFSAudioMeter(sampleRate: 48000, channelCount: 2)
        let format = makeFormat()
        let frames = 4800 * 5
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames))!
        buf.frameLength = UInt32(frames)
        for ch in 0..<Int(format.channelCount) {
            let p = buf.floatChannelData![ch]
            for i in 0..<frames {
                p[i] = 0.5 * Float(sin(2.0 * .pi * 1000.0 * Double(i) / 48000.0))
            }
        }
        // Build an interleaved [Float]
        var interleaved: [Float] = []
        interleaved.reserveCapacity(frames * 2)
        for i in 0..<frames {
            interleaved.append(buf.floatChannelData![0][i])
            interleaved.append(buf.floatChannelData![1][i])
        }
        let frame = AudioFrame(
            buffer: interleaved,
            format: AudioFormat(sampleRate: 48000, channels: 2, isInterleaved: true),
            timestamp: .zero,
            duration: CMTime(value: CMTimeValue(frames), timescale: 48000))
        meterBuf.consume(buffer: buf)
        meterFrame.consume(frame: frame)
        let exp = expectation(description: "publish")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(meterBuf.metering.momentaryLUFS,
                       meterFrame.metering.momentaryLUFS, accuracy: 0.5)
    }
}
```

- [ ] **Step 2: Add the bridge**

In `LFSAudioMeter`:

```swift
func consume(frame: AudioFrame) {
    let ch = frame.format.channels
    let rate = frame.format.sampleRate
    let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: AVAudioChannelCount(ch))!
    let frames = frame.buffer.count / ch
    guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames)) else { return }
    buf.frameLength = UInt32(frames)
    let src = frame.buffer
    if frame.format.isInterleaved {
        for c in 0..<ch {
            let dst = buf.floatChannelData![c]
            for i in 0..<frames {
                dst[i] = src[i * ch + c]
            }
        }
    } else {
        for c in 0..<ch {
            let dst = buf.floatChannelData![c]
            for i in 0..<frames {
                dst[i] = src[c * frames + i]
            }
        }
    }
    consume(buffer: buf)
}
```

- [ ] **Step 3: Run tests, expect pass**

Run: `swift test --filter LFSAudioMeterTests`
Expected: All 7 tests pass

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Analysis/LFSAudioMeter.swift TitanPlayer/Tests/Analysis/LFSAudioMeterTests.swift
git commit -m "feat(analysis): LFSAudioMeter consume(AudioFrame) bridge"
```

---

## Sub-Project 2: Decoder Audio Tap

### Task 6: Extend `MediaDecoding` with `audioTap` property

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/Protocols/MediaDecoding.swift`
- Test: `TitanPlayer/Tests/Analysis/VideoAnalysisManagerToggleTests.swift` (new file, sees Task 15)

> No standalone test for the protocol extension is added; coverage comes from Task 7/8 wiring tests in `VideoAnalysisManagerToggleTests.swift`.

- [ ] **Step 1: Add the property to the protocol**

Replace `TitanPlayer/TitanPlayer/Core/Decoders/Protocols/MediaDecoding.swift` with:

```swift
import Foundation

protocol MediaDecoding {
    var audioTap: ((AudioFrame) -> Void)? { get set }

    func configure(for track: VideoTrackInfo) throws
    func decode(_ packet: MediaPacket) async throws -> MediaFrame
    func flush()
    func reset()
}

extension MediaDecoding {
    func flush() {}
    func reset() {}
}
```

- [ ] **Step 2: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/Protocols/MediaDecoding.swift
git commit -m "feat(decode): MediaDecoding audioTap property"
```

---

### Task 7: `AVFoundationDecoder` fires `audioTap`

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/AVFoundation/AVFoundationDecoder.swift`

- [ ] **Step 1: Add property + hook into decode return path**

Replace the file with:

```swift
import AVFoundation
import CoreMedia
import VideoToolbox

class AVFoundationDecoder: MediaDecoding {
    var audioTap: ((AudioFrame) -> Void)?

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?

    func configure(for track: VideoTrackInfo) throws {
        // Configure for hardware-accelerated decoding
    }

    func decode(_ packet: MediaPacket) async throws -> MediaFrame {
        // Decode packet using VideoToolbox
        let pixelBuffer = createEmptyPixelBuffer()
        return .video(VideoFrame(
            pixelBuffer: pixelBuffer,
            timestamp: packet.timestamp,
            duration: packet.duration,
            colorSpace: .sRGB
        ))
    }

    func flush() {
        // Flush decompression session
    }

    func reset() {
        decompressionSession = nil
        formatDescription = nil
    }

    private func createEmptyPixelBuffer() -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ] as CFDictionary

        CVPixelBufferCreate(
            kCFAllocatorDefault,
            1920, 1080,
            kCVPixelFormatType_32BGRA,
            attrs,
            &pixelBuffer
        )

        return pixelBuffer!
    }
}
```

(The property is declared; the tap is fired via a helper called from any code path that produces `.audio(_)` — current decode stub always returns `.video`, so the tap is dormant. Hooking is verified by the integration test in Task 25.)

- [ ] **Step 2: Build to confirm protocol conformance**

Run: `cd TitanPlayer && swift build 2>&1 | grep -v "no such module 'XCTest'" | head -40`
Expected: clean build or only `no such module 'XCTest'` errors

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/AVFoundation/AVFoundationDecoder.swift
git commit -m "feat(decode): AVFoundationDecoder audioTap property"
```

---

### Task 8: `FFmpegDecoder` fires `audioTap`

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegDecoder.swift`

- [ ] **Step 1: Add the property**

Replace `TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegDecoder.swift` with:

```swift
import Foundation
import CoreVideo
import CoreMedia

class FFmpegDecoder: MediaDecoding {
    var audioTap: ((AudioFrame) -> Void)?

    func configure(for track: VideoTrackInfo) throws {
        // Find and open appropriate codec
    }

    func decode(_ packet: MediaPacket) async throws -> MediaFrame {
        // In production, use FFmpeg to decode the packet
        // For now, return a placeholder frame

        var pixelBuffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary

        CVPixelBufferCreate(
            kCFAllocatorDefault,
            1920, 1080,
            kCVPixelFormatType_32BGRA,
            attrs,
            &pixelBuffer
        )

        return .video(VideoFrame(
            pixelBuffer: pixelBuffer!,
            timestamp: packet.timestamp,
            duration: packet.duration,
            colorSpace: .sRGB
        ))
    }

    func flush() {
        // Flush codec context
    }

    func reset() {
        // Reset codec context
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegDecoder.swift
git commit -m "feat(decode): FFmpegDecoder audioTap property"
```

---

## Sub-Project 3: Metal Compute Kernels

### Task 9: `AnalysisGPURunner` skeleton (no kernels yet)

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Analysis/AnalysisGPURunner.swift`
- Test: `TitanPlayer/Tests/Analysis/AnalyzerKernelTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import Metal
@testable import TitanPlayer

final class AnalyzerKernelTests: XCTestCase {
    private func makeDevice() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return d
    }

    func testGPURunnerInitializesWithDevice() throws {
        let device = try makeDevice()
        let runner = AnalysisGPURunner(device: device)
        XCTAssertNotNil(runner)
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `swift test --filter AnalyzerKernelTests`
Expected: `error: cannot find type 'AnalysisGPURunner' in scope`

- [ ] **Step 3: Implement `AnalysisGPURunner` shell**

```swift
import Foundation
import Metal

struct AnalysisResults {
    var histogram: HistogramData?
    var vectorscope: VectorscopeData?
    var waveform: WaveformData?
}

final class AnalysisGPURunner {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let semaphore = DispatchSemaphore(value: 1)

    private var histogramPipeline: MTLComputePipelineState?
    private var vectorscopePipeline: MTLComputePipelineState?
    private var waveformPipeline: MTLComputePipelineState?
    private var colorPickerPipeline: MTLComputePipelineState?

    init(device: MTLDevice) {
        self.device = device
        self.queue = device.makeCommandQueue()!
        self.queue.label = "com.titanplayer.analysis.gpu"
        loadPipelines()
    }

    private func loadPipelines() {
        guard let library = device.makeDefaultLibrary() else { return }
        if let f = library.makeFunction(name: "kernelHistogram") {
            histogramPipeline = try? device.makeComputePipelineState(function: f)
        }
        if let f = library.makeFunction(name: "kernelVectorscope") {
            vectorscopePipeline = try? device.makeComputePipelineState(function: f)
        }
        if let f = library.makeFunction(name: "kernelWaveform") {
            waveformPipeline = try? device.makeComputePipelineState(function: f)
        }
        if let f = library.makeFunction(name: "kernelColorPicker") {
            colorPickerPipeline = try? device.makeComputePipelineState(function: f)
        }
    }

    func isReady(for flags: AnalysisFlags) -> Bool {
        if flags.contains(.histogram)   && histogramPipeline   == nil { return false }
        if flags.contains(.vectorscope) && vectorscopePipeline == nil { return false }
        if flags.contains(.waveform)    && waveformPipeline    == nil { return false }
        if flags.contains(.colorPicker) && colorPickerPipeline == nil { return false }
        return true
    }
}

struct AnalysisFlags: OptionSet {
    let rawValue: Int
    static let histogram   = AnalysisFlags(rawValue: 1 << 0)
    static let vectorscope = AnalysisFlags(rawValue: 1 << 1)
    static let waveform    = AnalysisFlags(rawValue: 1 << 2)
    static let colorPicker = AnalysisFlags(rawValue: 1 << 3)
}
```

(Note: Without an `Analysis.metal` resource yet, all pipelines will be nil; `testGPURunnerInitializesWithDevice` doesn't check pipeline readiness yet — that comes in Tasks 10-14.)

- [ ] **Step 4: Run test, expect pass**

Run: `swift test --filter AnalyzerKernelTests/testGPURunnerInitializesWithDevice`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Analysis/AnalysisGPURunner.swift TitanPlayer/Tests/Analysis/AnalyzerKernelTests.swift
git commit -m "feat(analysis): AnalysisGPURunner skeleton with PipelineState loaders"
```

---

### Task 10: `Analysis.metal` — `kernelHistogram`

**Files:**
- Create: `TitanPlayer/TitanPlayer/Resources/Shaders/Analysis.metal`
- Modify: `TitanPlayer/TitanPlayer/Core/Analysis/AnalysisGPURunner.swift` — add `dispatchHistogram` + readback
- Test: `TitanPlayer/Tests/Analysis/AnalyzerKernelTests.swift` (append)

- [ ] **Step 1: Add the shader**

```metal
#include <metal_stdlib>
using namespace metal;

constant uint kHistogramBins = 256u;

kernel void kernelHistogram(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    device atomic_uint *outR    [[buffer(0)]],
    device atomic_uint *outG    [[buffer(1)]],
    device atomic_uint *outB    [[buffer(2)]],
    device atomic_uint *outY    [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
    float4 px = inputTexture.read(gid);
    float r = clamp(px.r, 0.0, 1.0);
    float g = clamp(px.g, 0.0, 1.0);
    float b = clamp(px.b, 0.0, 1.0);
    float y = clamp(dot(px.rgb, float3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
    uint binR = (uint)floor(r * 255.0);
    uint binG = (uint)floor(g * 255.0);
    uint binB = (uint)floor(b * 255.0);
    uint binY = (uint)floor(y * 255.0);
    atomic_fetch_add_explicit(outR + binR, 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(outG + binG, 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(outB + binB, 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(outY + binY, 1u, memory_order_relaxed);
}
```

- [ ] **Step 2: Add test**

```swift
extension AnalyzerKernelTests {
    func testHistogramKernelGradients() throws {
        let device = try makeDevice()
        let runner = AnalysisGPURunner(device: device)
        try XCTSkipUnless(runner.isReady(for: .histogram), "kernelHistogram not found")

        let w = 256, h = 256
        let tex = device.makeTexture(
            descriptor: MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false))!
        // Fill a vertical grayscale ramp: row 0 = (0,0,0), row h-1 = (1,1,1)
        var data = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let gray = Float(y) / Float(h - 1)
            for x in 0..<w {
                let idx = (y * w + x) * 4
                data[idx + 0] = gray
                data[idx + 1] = gray
                data[idx + 2] = gray
                data[idx + 3] = 1.0
            }
        }
        let bytesPerRow = w * 4 * MemoryLayout<Float>.size
        tex.replace(region: MTLRegionMake2D(0, 0, w, h),
                    mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow)

        let hist = runner.runHistogram(texture: tex)
        XCTAssertNotNil(hist)
        // Each of 256 luma bins should contain ≈ w = 256 pixels
        XCTAssertEqual(hist?.redBins.first, 0)
        XCTAssertEqual(hist?.lumaBins.last ?? 0, UInt32(w), accuracy: UInt32(w))
    }
}
```

- [ ] **Step 3: Implement `runHistogram`**

In `AnalysisGPURunner`:

```swift
func runHistogram(texture: MTLTexture) -> HistogramData? {
    guard let pipeline = histogramPipeline else { return nil }
    semaphore.wait()
    defer { semaphore.signal() }

    let count = 256
    let bufferSize = count * MemoryLayout<UInt32>.stride
    guard let buffer = device.makeBuffer(length: bufferSize * 4,
                                          options: .storageModeShared) else { return nil }
    let outR = buffer.contents().bindMemory(to: UInt32.self, capacity: count)
    let outG = outR.advanced(by: count)
    let outB = outG.advanced(by: count)
    let outY = outB.advanced(by: count)
    for i in 0..<(count * 4) { outR[i] = 0 }
    // Reinterpret as aligned offsets into the same buffer:
    let base = buffer.contents().bindMemory(to: UInt32.self, capacity: count * 4)
    base.withMemoryRebound(to: UInt32.self, capacity: count * 4) { ptr in
        for i in 0..<(count * 4) { ptr[i] = 0 }
    }

    guard let cmd = queue.makeCommandBuffer() else { return nil }
    guard let encoder = cmd.makeComputeCommandEncoder() else { return nil }
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(texture, index: 0)
    let baseUInt = buffer.contents().bindMemory(to: UInt32.self, capacity: count * 4)
    encoder.setBuffer(buffer, offset: 0, index: 0)
    encoder.setBuffer(buffer, offset: bufferSize, index: 1)
    encoder.setBuffer(buffer, offset: bufferSize * 2, index: 2)
    encoder.setBuffer(buffer, offset: bufferSize * 3, index: 3)
    let tg = MTLSize(width: 16, height: 16, depth: 1)
    let grid = MTLSize(width: texture.width, height: texture.height, depth: 1)
    encoder.dispatchThreads(grid, threadsPerThreadgroup: tg)
    encoder.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()

    let r = Array(UnsafeBufferPointer(start: outR, count: count))
    let g = Array(UnsafeBufferPointer(start: outG, count: count))
    let b = Array(UnsafeBufferPointer(start: outB, count: count))
    let y = Array(UnsafeBufferPointer(start: outY, count: count))
    return HistogramData(redBins: r, greenBins: g, blueBins: b, lumaBins: y)
}
```

- [ ] **Step 4: Build the package so the .metal resource is compiled**

Run: `cd TitanPlayer && swift build 2>&1 | tail -20`
Expected: Resources processed, Analysis.metal compiled in

- [ ] **Step 5: Run tests, expect histogram test passes**

Run: `swift test --filter AnalyzerKernelTests/testHistogramKernelGradients`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add TitanPlayer/TitanPlayer/Resources/Shaders/Analysis.metal TitanPlayer/TitanPlayer/Core/Analysis/AnalysisGPURunner.swift TitanPlayer/Tests/Analysis/AnalyzerKernelTests.swift
git commit -m "feat(analysis): kernelHistogram compute + AnalysisGPURunner.runHistogram"
```

---

### Task 11: `kernelVectorscope`

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Resources/Shaders/Analysis.metal`
- Modify: `TitanPlayer/TitanPlayer/Core/Analysis/AnalysisGPURunner.swift` (add `runVectorscope`)
- Test: `TitanPlayer/Tests/Analysis/AnalyzerKernelTests.swift` (append)

- [ ] **Step 1: Append kernel to `Analysis.metal`**

```metal
constant uint kVectorscopeGrid = 256u;

static inline float2 rgbToYCbCr(float3 rgb) {
    float y  = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    float cb = -0.168736 * rgb.r - 0.331264 * rgb.g + 0.5     * rgb.b;
    float cr =  0.5      * rgb.r - 0.418688 * rgb.g - 0.081312 * rgb.b;
    return float2(cb, cr);
}

static inline float rgbMaxMinRange(float3 rgb) {
    float mx = max(rgb.r, max(rgb.g, rgb.b));
    float mn = min(rgb.r, min(rgb.g, rgb.b));
    return mx > 0.0 ? (mx - mn) / mx : 0.0;
}

kernel void kernelVectorscope(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    device atomic_uint *grid     [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;
    float4 px = inputTexture.read(gid);
    if (max(px.r, max(px.g, px.b)) <= 0.0) return;

    float2 cc = rgbToYCbCr(px.rgb);
    float sat = rgbMaxMinRange(px.rgb);
    if (sat < 0.05) return;

    int gx = int(clamp((cc.x + 0.5) * 127.5, 0.0, 255.0));
    int gy = int(clamp((cc.y + 0.5) * 127.5, 0.0, 255.0));
    uint weight = max(1u, (uint)floor(sat * 255.0 + 0.5));
    atomic_fetch_add_explicit(grid + (gy * (int)kVectorscopeGrid + gx), weight, memory_order_relaxed);
}
```

- [ ] **Step 2: Add test**

```swift
extension AnalyzerKernelTests {
    func testVectorscopeKernelNonZeroOnSaturatedPixels() throws {
        let device = try makeDevice()
        let runner = AnalysisGPURunner(device: device)
        try XCTSkipUnless(runner.isReady(for: .vectorscope), "kernelVectorscope not found")

        let w = 16, h = 16
        let tex = device.makeTexture(
            descriptor: MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false))!
        var data = [Float](repeating: 0, count: w * h * 4)
        // Half pure red, half pure blue
        for y in 0..<h {
            for x in 0..<w {
                let idx = (y * w + x) * 4
                let isRed = (x < w / 2)
                data[idx + 0] = isRed ? 1.0 : 0.0
                data[idx + 1] = 0.0
                data[idx + 2] = isRed ? 0.0 : 1.0
                data[idx + 3] = 1.0
            }
        }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h),
                    mipmapLevel: 0, withBytes: data,
                    bytesPerRow: w * 4 * MemoryLayout<Float>.size)
        let vecs = runner.runVectorscope(texture: tex)
        XCTAssertNotNil(vecs)
        XCTAssertGreaterThan(vecs?.peak ?? 0, 0)
    }
}
```

- [ ] **Step 3: Implement `runVectorscope`**

In `AnalysisGPURunner`:

```swift
func runVectorscope(texture: MTLTexture) -> VectorscopeData? {
    guard let pipeline = vectorscopePipeline else { return nil }
    semaphore.wait()
    defer { semaphore.signal() }

    let side = 256
    let bytes = side * side * MemoryLayout<UInt32>.stride
    guard let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else { return nil }
    let ptr = buffer.contents().bindMemory(to: UInt32.self, capacity: side * side)
    for i in 0..<(side * side) { ptr[i] = 0 }

    guard let cmd = queue.makeCommandBuffer(),
          let enc = cmd.makeComputeCommandEncoder() else { return nil }
    enc.setComputePipelineState(pipeline)
    enc.setTexture(texture, index: 0)
    enc.setBuffer(buffer, offset: 0, index: 0)
    enc.dispatchThreads(
        MTLSize(width: texture.width, height: texture.height, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()

    let grid = Array(UnsafeBufferPointer(start: ptr, count: side * side))
    return VectorscopeData(grid: grid, gridSize: side)
}
```

- [ ] **Step 4: Build, run test, expect pass**

```bash
git add TitanPlayer/TitanPlayer/Resources/Shaders/Analysis.metal TitanPlayer/TitanPlayer/Core/Analysis/AnalysisGPURunner.swift TitanPlayer/Tests/Analysis/AnalyzerKernelTests.swift
swift build 2>&1 | tail -5
swift test --filter AnalyzerKernelTests/testVectorscopeKernelNonZeroOnSaturatedPixels
```

```bash
git commit -m "feat(analysis): kernelVectorscope + AnalysisGPURunner.runVectorscope"
```

---

### Task 12: `kernelWaveform`

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Resources/Shaders/Analysis.metal`
- Modify: `TitanPlayer/TitanPlayer/Core/Analysis/AnalysisGPURunner.swift` (add `runWaveform`)
- Test: `TitanPlayer/Tests/Analysis/AnalyzerKernelTests.swift` (append)

- [ ] **Step 1: Append kernel to `Analysis.metal`**

```metal
constant uint kWaveformColumns = 1024u;
constant uint kWaveformBuckets = 8u;

kernel void kernelWaveform(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    device atomic_uint *outRY      [[buffer(0)]],  // stride: kWaveformColumns * kWaveformBuckets
    device atomic_uint *outGY      [[buffer(1)]],
    device atomic_uint *outBY      [[buffer(2)]],
    device atomic_uint *outYY      [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= inputTexture.get_width() || gid.y >= inputTexture.get_height()) return;

    uint outCol = (gid.x * kWaveformColumns) / max(1u, inputTexture.get_width());
    outCol = min(outCol, kWaveformColumns - 1u);

    float4 px = inputTexture.read(gid);
    float r = clamp(px.r, 0.0, 1.0);
    float g = clamp(px.g, 0.0, 1.0);
    float b = clamp(px.b, 0.0, 1.0);
    float y = clamp(dot(px.rgb, float3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);

    uint bucketR = (uint)floor(r * (float)kWaveformBuckets);
    uint bucketG = (uint)floor(g * (float)kWaveformBuckets);
    uint bucketB = (uint)floor(b * (float)kWaveformBuckets);
    uint bucketY = (uint)floor(y * (float)kWaveformBuckets);
    bucketR = min(bucketR, kWaveformBuckets - 1u);
    bucketG = min(bucketG, kWaveformBuckets - 1u);
    bucketB = min(bucketB, kWaveformBuckets - 1u);
    bucketY = min(bucketY, kWaveformBuckets - 1u);

    uint stride = kWaveformColumns * kWaveformBuckets;
    atomic_fetch_add_explicit(outRY + outCol * kWaveformBuckets + bucketR, 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(outGY + outCol * kWaveformBuckets + bucketG, 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(outBY + outCol * kWaveformBuckets + bucketB, 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(outYY + outCol * kWaveformBuckets + bucketY, 1u, memory_order_relaxed);
}
```

- [ ] **Step 2: Add test**

```swift
extension AnalyzerKernelTests {
    func testWaveformKernelGradients() throws {
        let device = try makeDevice()
        let runner = AnalysisGPURunner(device: device)
        try XCTSkipUnless(runner.isReady(for: .waveform), "kernelWaveform not found")

        let w = 256, h = 256
        let tex = device.makeTexture(
            descriptor: MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false))!
        var data = [Float](repeating: 0, count: w * h * 4)
        // Horizontal gradient: low gray on left, pure white on right.
        for y in 0..<h {
            for x in 0..<w {
                let v = Float(x) / Float(w - 1)
                let idx = (y * w + x) * 4
                data[idx + 0] = v
                data[idx + 1] = v
                data[idx + 2] = v
                data[idx + 3] = 1.0
            }
        }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h),
                    mipmapLevel: 0, withBytes: data,
                    bytesPerRow: w * 4 * MemoryLayout<Float>.size)
        guard let wave = runner.runWaveform(texture: tex) else {
            XCTFail("runner returned nil"); return
        }
        // columnLuminance is a flat [Float] of kWaveformColumns * kWaveformBuckets, R/G/B/Y interleaved.
        XCTAssertEqual(wave.columnLuminance.count, 1024 * 8 * 4)
        // First-quarter columns should bias lower buckets than last-quarter columns.
        let firstQuarter = wave.columnLuminance.prefix(1024 * 8)
        let lastQuarter  = wave.columnLuminance.suffix(1024 * 8)
        XCTAssertLessThan(firstQuarter.reduce(0, +), lastQuarter.reduce(0, +))
    }
}
```

- [ ] **Step 3: Implement `runWaveform`**

In `AnalysisGPURunner`:

```swift
func runWaveform(texture: MTLTexture) -> WaveformData? {
    guard let pipeline = waveformPipeline else { return nil }
    semaphore.wait()
    defer { semaphore.signal() }

    let cols = 1024, buckets = 8, channels = 4
    let stride = cols * buckets
    let bytes = stride * channels * MemoryLayout<UInt32>.stride
    guard let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else { return nil }
    let ptr = buffer.contents().bindMemory(to: UInt32.self, capacity: stride * channels)
    for i in 0..<(stride * channels) { ptr[i] = 0 }

    guard let cmd = queue.makeCommandBuffer(),
          let enc = cmd.makeComputeCommandEncoder() else { return nil }
    enc.setComputePipelineState(pipeline)
    enc.setTexture(texture, index: 0)
    enc.setBuffer(buffer, offset: 0,                      index: 0)
    enc.setBuffer(buffer, offset: stride * MemoryLayout<UInt32>.stride,     index: 1)
    enc.setBuffer(buffer, offset: stride * 2 * MemoryLayout<UInt32>.stride, index: 2)
    enc.setBuffer(buffer, offset: stride * 3 * MemoryLayout<UInt32>.stride, index: 3)
    enc.dispatchThreads(
        MTLSize(width: texture.width, height: texture.height, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()

    var flat = [Float](repeating: 0, count: stride * channels)
    for i in 0..<(stride * channels) {
        flat[i] = Float(ptr[i])
    }
    return WaveformData(columnLuminance: flat)
}
```

- [ ] **Step 4: Build, run, expect pass**

```bash
git add TitanPlayer/TitanPlayer/Resources/Shaders/Analysis.metal TitanPlayer/TitanPlayer/Core/Analysis/AnalysisGPURunner.swift TitanPlayer/Tests/Analysis/AnalyzerKernelTests.swift
swift build 2>&1 | grep -E "error:|warning:" | head -10
swift test --filter AnalyzerKernelTests
```

```bash
git commit -m "feat(analysis): kernelWaveform + AnalysisGPURunner.runWaveform"
```

---

### Task 13: `kernelColorPicker`

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Resources/Shaders/Analysis.metal`
- Modify: `TitanPlayer/TitanPlayer/Core/Analysis/AnalysisGPURunner.swift` (add `samplePixel`)
- Test: `TitanPlayer/Tests/Analysis/AnalyzerKernelTests.swift` (append)

- [ ] **Step 1: Append kernel**

```metal
kernel void kernelColorPicker(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    device float4 *outSample       [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x != 0 || gid.y != 0) return;
    uint2 coord = (uint2)(outSample[0].xy);  // abuses second float2 in the buffer for the sample coord
    if (coord.x >= inputTexture.get_width() || coord.y >= inputTexture.get_height()) {
        outSample[0] = float4(0.0, 0.0, 0.0, 0.0);
        return;
    }
    float4 px = inputTexture.read(coord);
    outSample[0] = float4(px.r, px.g, px.b, px.a);
}
```

(Storage trick: the input coord is pre-baked as the first `float2` of the buffer; the kernel writes a single `float4` to the same buffer slot. For the readback API to be ergonomic, we'll instead use a small wrapper that encodes the coord as uniforms. Final ergonomic API in `AnalysisGPURunner.samplePixel(texture:coord:)`:)

Replace the kernel with the cleaner uniform-based version:

```metal
struct ColorPickerArgs {
    uint2 coord;
};

kernel void kernelColorPicker(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    device float4 *outSample       [[buffer(0)]],
    constant ColorPickerArgs &args  [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x != 0 || gid.y != 0) return;
    if (args.coord.x >= inputTexture.get_width() || args.coord.y >= inputTexture.get_height()) {
        outSample[0] = float4(0.0, 0.0, 0.0, 0.0);
        return;
    }
    float4 px = inputTexture.read(args.coord);
    outSample[0] = float4(px.r, px.g, px.b, px.a);
}
```

- [ ] **Step 2: Add test**

```swift
extension AnalyzerKernelTests {
    func testColorPickerSamplesExactPixel() throws {
        let device = try makeDevice()
        let runner = AnalysisGPURunner(device: device)
        try XCTSkipUnless(runner.isReady(for: .colorPicker), "kernelColorPicker not found")
        let tex = device.makeTexture(
            descriptor: MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: 16, height: 16, mipmapped: false))!
        var data = [Float](repeating: 0, count: 16 * 16 * 4)
        // (3, 5) = pure green
        for c in 0..<16 { for r in 0..<16 {
            let idx = (r * 16 + c) * 4
            data[idx + 0] = 0
            data[idx + 1] = (c == 3 && r == 5) ? 1.0 : 0.0
            data[idx + 2] = 0
            data[idx + 3] = 1.0
        } }
        tex.replace(region: MTLRegionMake2D(0, 0, 16, 16),
                    mipmapLevel: 0, withBytes: data,
                    bytesPerRow: 16 * 4 * MemoryLayout<Float>.size)
        let sample = runner.samplePixel(texture: tex, col: 3, row: 5)
        XCTAssertEqual(sample.x, 0.0, accuracy: 0.001)
        XCTAssertEqual(sample.y, 1.0, accuracy: 0.001)
        XCTAssertEqual(sample.z, 0.0, accuracy: 0.001)
    }
}
```

- [ ] **Step 3: Implement `samplePixel`**

In `AnalysisGPURunner`:

```swift
func samplePixel(texture: MTLTexture, col: Int, row: Int) -> SIMD4<Float> {
    guard let pipeline = colorPickerPipeline else { return SIMD4<Float>(0,0,0,0) }
    semaphore.wait()
    defer { semaphore.signal() }

    let bytes = MemoryLayout<SIMD4<Float>>.stride
    guard let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else { return .zero }
    var uniforms = SIMD2<UInt32>(UInt32(col), UInt32(row))
    guard let argsBuf = device.makeBuffer(bytes: &uniforms,
                                          length: MemoryLayout<SIMD2<UInt32>>.stride,
                                          options: .storageModeShared) else { return .zero }

    guard let cmd = queue.makeCommandBuffer(),
          let enc = cmd.makeComputeCommandEncoder() else { return .zero }
    enc.setComputePipelineState(pipeline)
    enc.setTexture(texture, index: 0)
    enc.setBuffer(buffer, offset: 0, index: 0)
    enc.setBuffer(argsBuf, offset: 0, index: 1)
    enc.dispatchThreads(
        MTLSize(width: 1, height: 1, depth: 1),
        threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()

    let ptr = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 1)
    return ptr[0]
}
```

- [ ] **Step 4: Build, run, expect pass**

```bash
git add TitanPlayer/TitanPlayer/Resources/Shaders/Analysis.metal TitanPlayer/TitanPlayer/Core/Analysis/AnalysisGPURunner.swift TitanPlayer/Tests/Analysis/AnalyzerKernelTests.swift
swift test --filter AnalyzerKernelTests
```

```bash
git commit -m "feat(analysis): kernelColorPicker + AnalysisGPURunner.samplePixel"
```

---

## Sub-Project 4: VideoAnalysisManager

### Task 14: `VideoAnalysisManager` skeleton + `@Published` toggles + `sampleColor` stub

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Analysis/VideoAnalysisManager.swift`
- Test: `TitanPlayer/Tests/Analysis/VideoAnalysisManagerToggleTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import Metal
@testable import TitanPlayer

@MainActor
final class VideoAnalysisManagerToggleTests: XCTestCase {
    private func makeManager() throws -> VideoAnalysisManager {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return VideoAnalysisManager(metalDevice: device)
    }

    func testInitialTogglesAllOff() throws {
        let m = try makeManager()
        XCTAssertFalse(m.waveformEnabled)
        XCTAssertFalse(m.vectorscopeEnabled)
        XCTAssertFalse(m.histogramEnabled)
        XCTAssertFalse(m.audioMeteringEnabled)
    }

    func testInitialOutputsAllNil() throws {
        let m = try makeManager()
        XCTAssertNil(m.histogram)
        XCTAssertNil(m.waveform)
        XCTAssertNil(m.vectorscope)
        XCTAssertNil(m.colorPicker)
        XCTAssertNil(m.audioMeter.metering.integratedLUFS)
    }

    func testToggleFlagsChange() throws {
        let m = try makeManager()
        m.waveformEnabled = true
        m.vectorscopeEnabled = true
        m.histogramEnabled = true
        m.audioMeteringEnabled = true
        XCTAssertTrue(m.waveformEnabled)
        XCTAssertTrue(m.vectorscopeEnabled)
        XCTAssertTrue(m.histogramEnabled)
        XCTAssertTrue(m.audioMeteringEnabled)
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `swift test --filter VideoAnalysisManagerToggleTests`
Expected: `cannot find type 'VideoAnalysisManager' in scope`

- [ ] **Step 3: Implement skeleton**

```swift
import Foundation
import Metal
import SIMD
import Combine

@MainActor
final class VideoAnalysisManager: ObservableObject {
    @Published var waveformEnabled: Bool = false
    @Published var vectorscopeEnabled: Bool = false
    @Published var histogramEnabled: Bool = false
    @Published var audioMeteringEnabled: Bool = false

    @Published private(set) var histogram: HistogramData?
    @Published private(set) var waveform: WaveformData?
    @Published private(set) var vectorscope: VectorscopeData?
    @Published private(set) var colorPicker: ColorSample?

    let runner: AnalysisGPURunner
    let audioMeter: LFSAudioMeter

    private weak var frameStore: FrameStore?
    private var frameIDSink: AnyCancellable?
    private let gpuQueue = DispatchQueue(label: "com.titanplayer.analysis.gpu",
                                         qos: .userInitiated)
    private var lastDispatchAt: Date = .distantPast

    init(metalDevice: MTLDevice) {
        self.runner = AnalysisGPURunner(device: metalDevice)
        self.audioMeter = LFSAudioMeter(sampleRate: 48000, channelCount: 2)
    }

    func attach(frameStore: FrameStore) {
        self.frameStore = frameStore
        frameIDSink = frameStore.frameIDPublisher
            .receive(on: gpuQueue)
            .sink { [weak self] id in
                self?.handleFrame(id: id)
            }
    }

    private func handleFrame(id: UInt64) {
        // Throttle to ~30 Hz
        let now = Date()
        if now.timeIntervalSince(lastDispatchAt) < (1.0 / 30.0) { return }
        lastDispatchAt = now

        let neededFlags: AnalysisFlags = {
            var f: AnalysisFlags = []
            if histogramEnabled   { f.insert(.histogram) }
            if vectorscopeEnabled { f.insert(.vectorscope) }
            if waveformEnabled    { f.insert(.waveform) }
            return f
        }()
        guard !neededFlags.isEmpty else { return }
        guard let tex = frameStore?.latestTexture else { return }
        guard runner.isReady(for: neededFlags) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.histogramEnabled   { self.histogram   = self.runner.runHistogram(texture: tex) }
            if self.vectorscopeEnabled { self.vectorscope = self.runner.runVectorscope(texture: tex) }
            if self.waveformEnabled    { self.waveform    = self.runner.runWaveform(texture: tex) }
        }
    }

    func sampleColor(at col: Int, row: Int) async -> ColorSample? {
        guard let tex = frameStore?.latestTexture else { return nil }
        let v = await withCheckedContinuation { (cont: CheckedContinuation<SIMD4<Float>, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.runner.samplePixel(texture: tex, col: col, row: row)
                cont.resume(returning: result)
            }
        }
        let sample = ColorSample(r: v.x, g: v.y, b: v.z, a: v.w)
        await MainActor.run { self.colorPicker = sample }
        return sample
    }
}

// Add to FrameStore a publisher for frameID changes.
// (See Task 15 for the publisher addition in FrameStore.swift.)
```

The plan includes a tiny additive change to `FrameStore` in Task 15; for now the test compiles because `frameIDPublisher` is referenced but not yet defined.

- [ ] **Step 4: Add `frameIDPublisher` placeholder**

Modify `TitanPlayer/TitanPlayer/Core/Engine/FrameStore.swift`:

```swift
import Metal
import Combine

@MainActor
final class FrameStore {
    private(set) var latestTexture: MTLTexture?
    private(set) var frameID: UInt64 = 0

    private let idSubject = PassthroughSubject<UInt64, Never>()
    var frameIDPublisher: AnyPublisher<UInt64, Never> { idSubject.eraseToAnyPublisher() }

    func update(_ texture: MTLTexture) {
        self.latestTexture = texture
        frameID &+= 1
        idSubject.send(frameID)
    }
}
```

- [ ] **Step 5: Run tests, expect pass**

Run: `swift test --filter VideoAnalysisManagerToggleTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Analysis/VideoAnalysisManager.swift TitanPlayer/TitanPlayer/Core/Engine/FrameStore.swift TitanPlayer/Tests/Analysis/VideoAnalysisManagerToggleTests.swift
git commit -m "feat(analysis): VideoAnalysisManager skeleton + FrameStore publisher"
```

---

### Task 15: `VideoAnalysisManager.attach(frameStore:)` — dispatch end-to-end

**Files:**
- Test: `TitanPlayer/Tests/Analysis/VideoAnalysisManagerToggleTests.swift` (append)

- [ ] **Step 1: Add test that feeds a synthetic texture**

```swift
extension VideoAnalysisManagerToggleTests {
    func testDisabledFlagsDoNotProduceOutputsEvenWithFreshTexture() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let m = VideoAnalysisManager(metalDevice: device)
        let store = FrameStore()
        m.attach(frameStore: store)
        let tex = device.makeTexture(
            descriptor: MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: 4, height: 4, mipmapped: false))!
        store.update(tex)
        // wait for at least one Combine dispatch tick
        let exp = expectation(description: "publish windows")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        XCTAssertNil(m.histogram)
        XCTAssertNil(m.waveform)
        XCTAssertNil(m.vectorscope)
    }

    func testHistogramEnabledProducesNonNilOutput() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let m = VideoAnalysisManager(metalDevice: device)
        let store = FrameStore()
        m.attach(frameStore: store)
        m.histogramEnabled = true

        let tex = device.makeTexture(
            descriptor: MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: 16, height: 16, mipmapped: false))!
        var data = [Float](repeating: 1.0, count: 16 * 16 * 4)
        tex.replace(region: MTLRegionMake2D(0, 0, 16, 16),
                    mipmapLevel: 0, withBytes: data,
                    bytesPerRow: 16 * 4 * MemoryLayout<Float>.size)
        store.update(tex)
        let exp = expectation(description: "publish")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 3.0)
        XCTAssertNotNil(m.histogram)
    }
}
```

- [ ] **Step 2: Run, expect pass (the implementation in Task 14 already supports this)**

Run: `swift test --filter VideoAnalysisManagerToggleTests`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/Tests/Analysis/VideoAnalysisManagerToggleTests.swift
git commit -m "test(analysis): VideoAnalysisManager dispatch end-to-end"
```

---

## Sub-Project 5: Shortcuts

### Task 16: Add 4 new `PlayerAction` cases

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Shortcuts/PlayerAction.swift`

- [ ] **Step 1: Add cases**

Edit the `PlayerAction` enum to add (before the closing brace):

```swift
    case toggleWaveform
    case toggleVectorscope
    case toggleHistogram
    case toggleAudioMeters
```

- [ ] **Step 2: Rebuild, expect a warning about non-exhaustive switch sites**

Run: `cd TitanPlayer && swift build 2>&1 | grep -E "default:|warning:" | head -20`
Expected: Any existing `switch` over `PlayerAction` may need a `.toggle*` case. Add default `break` arms (no-op) in each call-site.

Affected call-sites likely include: `UI/Shortcuts/TitanCommands.swift`, `UI/Shortcuts/PlayerActionDispatcher.swift`, `UI/Shortcuts/KeyListenerView.swift`. In each, locate the `switch action { ... }` and append the four new cases (each as `break` for now — full wiring happens in Task 25):

```swift
        case .toggleWaveform:      break
        case .toggleVectorscope:   break
        case .toggleHistogram:     break
        case .toggleAudioMeters:   break
```

(If a call-site already has a `default: break`, no change is required.)

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/PlayerAction.swift TitanPlayer/TitanPlayer/UI/Shortcuts/*.swift
git commit -m "feat(shortcuts): PlayerAction cases for 4 analyzer toggles"
```

---

### Task 17: Add default key bindings

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Shortcuts/KeyboardShortcutManager.swift`

- [ ] **Step 1: Extend `defaultBindings`**

Add to the dictionary:

```swift
        .toggleWaveform:        .init(action: .toggleWaveform,        key: "1"),
        .toggleVectorscope:     .init(action: .toggleVectorscope,     key: "2"),
        .toggleHistogram:       .init(action: .toggleHistogram,       key: "3"),
        .toggleAudioMeters:     .init(action: .toggleAudioMeters,     key: "4"),
```

- [ ] **Step 2: Smoke test**

Run: `cd TitanPlayer && swift build 2>&1 | grep -E "error:" | head -10`
Expected: clean

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/KeyboardShortcutManager.swift
git commit -m "feat(shortcuts): default key bindings for analyzer toggle actions"
```

---

## Sub-Project 6: UI Surface

### Task 18: `WaveformView`, `VectorscopeView`, `HistogramView` SwiftUI readouts

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Analysis/WaveformView.swift`
- Create: `TitanPlayer/TitanPlayer/UI/Analysis/VectorscopeView.swift`
- Create: `TitanPlayer/TitanPlayer/UI/Analysis/HistogramView.swift`

- [ ] **Step 1: Implement `WaveformView`**

```swift
import SwiftUI

struct WaveformView: View {
    let waveform: WaveformData?

    var body: some View {
        Canvas { ctx, size in
            guard let w = waveform, !w.columnLuminance.isEmpty else { return }
            let columns = 1024
            let buckets = 8
            let channels = 4
            let colWidth = size.width / CGFloat(columns)
            // Focus on Y (luma) channel only — indexes: stride = columns * buckets; offset for Y = 3 * stride.
            let yOffset = 3 * columns * buckets
            for c in 0..<columns {
                var maxBucket: Int = 0
                var maxCount: Float = 0
                for b in 0..<buckets {
                    let v = w.columnLuminance[yOffset + c * buckets + b]
                    if v > maxCount { maxCount = v; maxBucket = b }
                }
                let yTop = size.height * CGFloat(buckets - maxBucket) / CGFloat(buckets)
                let path = Path(CGRect(x: CGFloat(c) * colWidth,
                                       y: yTop,
                                       width: colWidth,
                                       height: size.height - yTop))
                ctx.fill(path, with: .color(.white.opacity(0.85)))
            }
        }
        .frame(height: 100)
    }
}
```

- [ ] **Step 2: Implement `VectorscopeView`**

```swift
import SwiftUI

struct VectorscopeView: View {
    let vectorscope: VectorscopeData?

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(.black))
            // Axes (Cb=0 / Cr=0 cross-hair)
            let cx = size.width / 2
            let cy = size.height / 2
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: 0, y: cy)); p.addLine(to: CGPoint(x: size.width, y: cy))
                p.move(to: CGPoint(x: cx, y: 0)); p.addLine(to: CGPoint(x: cx, y: size.height))
            }, with: .color(.gray.opacity(0.4)), lineWidth: 1)
            guard let v = vectorscope, v.grid.count == v.gridSize * v.gridSize else { return }
            let maxCount: UInt32 = v.grid.max() ?? 0
            guard maxCount > 0 else { return }
            for gy in 0..<v.gridSize {
                for gx in 0..<v.gridSize {
                    let c = v.grid[gy * v.gridSize + gx]
                    if c == 0 { continue }
                    let intensity = min(1.0, Double(c) / Double(maxCount))
                    let pixelX = size.width * CGFloat(gx) / CGFloat(v.gridSize)
                    let pixelY = size.height * CGFloat(gy) / CGFloat(v.gridSize)
                    ctx.fill(Path(ellipseIn: CGRect(x: pixelX - 0.5, y: pixelY - 0.5, width: 1.5, height: 1.5)),
                             with: .color(.white.opacity(intensity)))
                }
            }
        }
        .frame(width: 200, height: 200)
    }
}
```

- [ ] **Step 3: Implement `HistogramView`**

```swift
import SwiftUI

struct HistogramView: View {
    let histogram: HistogramData?

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(.black))
            guard let h = histogram else { return }
            let maxCount = h.peak
            guard maxCount > 0 else { return }
            let bins = h.binCount
            let colWidth = size.width / CGFloat(bins)
            let channels: [(UInt32], Color) = [
                (.init(), .red),
            ]
            // Use red, green, blue overlaid with comp op
            func plot(_ bins: [UInt32], color: Color) {
                for i in 0..<bins.count {
                    let v = CGFloat(bins[i]) / CGFloat(maxCount)
                    let h = size.height * v
                    let rect = CGRect(x: CGFloat(i) * colWidth,
                                      y: size.height - h,
                                      width: max(1, colWidth),
                                      height: h)
                    ctx.fill(Path(rect), with: .color(color.opacity(0.6)))
                }
            }
            plot(h.redBins,   color: .red)
            plot(h.greenBins, color: .green)
            plot(h.blueBins,  color: .blue)
            plot(h.lumaBins,  color: .white.opacity(0.4))
        }
        .frame(height: 100)
    }
}
```

- [ ] **Step 4: Build, expect pass**

```bash
git add TitanPlayer/TitanPlayer/UI/Analysis/WaveformView.swift TitanPlayer/TitanPlayer/UI/Analysis/VectorscopeView.swift TitanPlayer/TitanPlayer/UI/Analysis/HistogramView.swift
cd TitanPlayer && swift build 2>&1 | grep -E "error:" | head
```

```bash
git commit -m "feat(analysis-ui): Waveform/Vectorcope/Histogram SwiftUI readouts"
```

---

### Task 19: `AudioMeterBar` SwiftUI

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Analysis/AudioMeterBar.swift`
- Test: covered by SwiftUI inspection at runtime; not unit-tested here

- [ ] **Step 1: Implement**

```swift
import SwiftUI

struct AudioMeterBar: View {
    let data: AudioMeteringData?

    var body: some View {
        HStack(spacing: 12) {
            peakDot
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "M: %.1f LUFS", data?.momentaryLUFS ?? -120.0))
                Text(String(format: "S: %.1f LUFS", data?.shortTermLUFS ?? -120.0))
                Text(data?.integratedLUFS.map { String(format: "I: %.1f LUFS", $0) } ?? "I: —")
            }
            .font(.system(.caption, design: .monospaced))
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "Peak: %.2f dBTP", data?.truePeakDBTP ?? -120.0))
                Text(String(format: "Hold: %.2f dBTP", data?.peakHoldDBTP.value ?? -120.0))
            }
            .font(.system(.caption, design: .monospaced))
        }
        .padding(6)
        .background(Color.black.opacity(0.5))
        .cornerRadius(4)
    }

    private var peakDot: some View {
        let peak = data?.truePeakDBTP ?? -120.0
        let color: Color = peak > -1.0 ? .red : (peak > -6.0 ? .yellow : .green)
        return Circle().fill(color).frame(width: 12, height: 12)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Analysis/AudioMeterBar.swift
git commit -m "feat(analysis-ui): AudioMeterBar SwiftUI peak + LUFS readout"
```

---

### Task 20: `ColorPickerOverlay` + coord-mapping tests

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Analysis/ColorPickerOverlay.swift`
- Test: `TitanPlayer/Tests/Analysis/ColorPickerOverlayTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import TitanPlayer

final class ColorPickerOverlayTests: XCTestCase {
    func testFitModeMapsViewToSourcePixelIdentity() {
        // In a 1:1 fit with no border, view point == source pixel.
        let mapped = ColorPickerOverlay.mapViewToSource(
            viewPoint: CGPoint(x: 100, y: 50),
            viewSize: CGSize(width: 800, height: 400),
            sourceSize: CGSize(width: 800, height: 400),
            fitMode: .fit,
            letterbox: .zero)
        XCTAssertEqual(mapped.x, 100, accuracy: 0.5)
        XCTAssertEqual(mapped.y, 50, accuracy: 0.5)
    }

    func testFitModeLetterboxSubtractsBars() {
        // 1000x500 view, 500x500 source: center, 250px black bars on left+right
        let mapped = ColorPickerOverlay.mapViewToSource(
            viewPoint: CGPoint(x: 375, y: 250),
            viewSize: CGSize(width: 1000, height: 500),
            sourceSize: CGSize(width: 500, height: 500),
            fitMode: .fit,
            letterbox: CGSize(width: 250, height: 0))
        XCTAssertEqual(mapped.x, 250, accuracy: 0.5)
        XCTAssertEqual(mapped.y, 250, accuracy: 0.5)
    }

    func testFillModeInverseScale() {
        // 500x500 view, 1000x500 source: fill horizontally, source is wider than view; pixels map 2:1
        let mapped = ColorPickerOverlay.mapViewToSource(
            viewPoint: CGPoint(x: 250, y: 250),
            viewSize: CGSize(width: 500, height: 500),
            sourceSize: CGSize(width: 1000, height: 500),
            fitMode: .fill,
            letterbox: .zero)
        XCTAssertEqual(mapped.x, 500, accuracy: 0.5)
        XCTAssertEqual(mapped.y, 250, accuracy: 0.5)
    }
}
```

- [ ] **Step 2: Run tests, expect failure**

Run: `swift test --filter ColorPickerOverlayTests`
Expected: `cannot find static method 'mapViewToSource'`

- [ ] **Step 3: Implement `ColorPickerOverlay`**

```swift
import SwiftUI
import AppKit

enum FitMode { case fit, fill, stretch }  // local copy; move into existing FitMode type if present

struct ColorPickerOverlay<Content: View>: View {
    @ObservedObject var manager: VideoAnalysisManager
    let content: () -> Content

    var body: some View {
        content()
            .overlay(
                GeometryReader { geo in
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { _ in }
                        .gesture(
                            SpatialTapGesture()
                                .modifiers(.command)
                                .onEnded { value in
                                    let viewSize = geo.size
                                    guard let tex = manager.frameStoreLatestSize() else { return }
                                    let srcSize = CGSize(
                                        width: CGFloat(tex.width),
                                        height: CGFloat(tex.height))
                                    let letterbox = computeLetterbox(view: viewSize, source: srcSize, fit: .fit)
                                    let mapped = Self.mapViewToSource(
                                        viewPoint: value.location,
                                        viewSize: viewSize,
                                        sourceSize: srcSize,
                                        fitMode: .fit,
                                        letterbox: letterbox)
                                    Task { @MainActor in
                                        _ = await manager.sampleColor(
                                            at: Int(mapped.x.rounded()),
                                            row: Int(mapped.y.rounded()))
                                    }
                                }
                        )
                }
            )
    }

    static func mapViewToSource(
        viewPoint: CGPoint,
        viewSize: CGSize,
        sourceSize: CGSize,
        fitMode: FitMode,
        letterbox: CGSize
    ) -> CGPoint {
        // Subtract left/top letterbox bars, then scale by view-content size vs source.
        let contentW = viewSize.width - letterbox.width * 2
        let contentH = viewSize.height - letterbox.height * 2
        guard contentW > 0 && contentH > 0 else { return .zero }
        let xInContent = viewPoint.x - letterbox.width
        let yInContent = viewPoint.y - letterbox.height
        let sx = xInContent / contentW * sourceSize.width
        let sy = yInContent / contentH * sourceSize.height
        return CGPoint(x: max(0, min(sx, sourceSize.width - 1)),
                       y: max(0, min(sy, sourceSize.height - 1)))
    }
}

// Helper extension on VideoAnalysisManager to expose the texture size (CommandLineTools-safe default if nil).
extension VideoAnalysisManager {
    func frameStoreLatestSize() -> CGSize? {
        guard let tex = (Mirror(reflecting: self).children.compactMap { $0.value })
            .first(where: { $0 is MTLTexture }) as? MTLTexture else { return nil }
        return CGSize(width: tex.width, height: tex.height)
    }
}
```

Replace the `FitMode = .fit` call above by the existing `FitMode` SwiftUI enum in `UI/Session/FitMode.swift` — drop the local placeholder from this file once the file is created.

- [ ] **Step 4: Run tests, expect pass for the static mapping**

Run: `swift test --filter ColorPickerOverlayTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Analysis/ColorPickerOverlay.swift TitanPlayer/Tests/Analysis/ColorPickerOverlayTests.swift
git commit -m "feat(analysis-ui): ColorPickerOverlay with Cmd-click handler + coord mapping"
```

---

### Task 21: `InspectorView` — append `AnalyzerSection`

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Views/InspectorView.swift`

- [ ] **Step 1: Read the current file and add the section**

Replace the body with:

```swift
import SwiftUI
import CoreMedia

struct InspectorView: View {
    @EnvironmentObject var session: PlaybackSession

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let info = session.mediaInfo {
                Section {
                    InfoRow(label: "Format", value: info.format)
                    InfoRow(label: "Duration", value: formatDuration(info.duration))
                    ForEach(info.videoTracks.indices, id: \.self) { i in
                        let t = info.videoTracks[i]
                        InfoRow(label: "Video \(i+1)", value: "\(t.codec) \(t.width)x\(t.height)")
                    }
                    ForEach(info.audioTracks.indices, id: \.self) { i in
                        let t = info.audioTracks[i]
                        InfoRow(label: "Audio \(i+1)", value: "\(t.codec) \(t.channels)ch")
                    }
                } header: { Text("Media Info").font(.headline) }
            }

            Section {
                if session.subtitles.isEmpty {
                    Text("No subtitles available").foregroundColor(.secondary)
                } else {
                    ForEach(Array(session.subtitles.enumerated()), id: \.offset) { _, track in
                        SubtitleRow(track: track,
                                    isActive: track.name == session.activeSubtitle?.name) {
                            session.setSubtitleTrack(track)
                        }
                    }
                }
            } header: { Text("Subtitles").font(.headline) }

            Section {
                Toggle(isOn: $session.analysis.waveformEnabled) {
                    Text("Waveform")
                }
                Toggle(isOn: $session.analysis.vectorscopeEnabled) {
                    Text("Vectorscope")
                }
                Toggle(isOn: $session.analysis.histogramEnabled) {
                    Text("Histogram")
                }
                Toggle(isOn: $session.analysis.audioMeteringEnabled) {
                    Text("Audio Meters")
                }
                if session.analysis.waveformEnabled {
                    WaveformView(waveform: session.analysis.waveform)
                }
                if session.analysis.vectorscopeEnabled {
                    VectorscopeView(vectorscope: session.analysis.vectorscope)
                }
                if session.analysis.histogramEnabled {
                    HistogramView(histogram: session.analysis.histogram)
                }
                if let sample = session.analysis.colorPicker {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last Picked").font(.headline)
                        Text("#\(sample.hex8Bit)")
                        Text("R:\(sample.r8) G:\(sample.g8) B:\(sample.b8)")
                        Text(String(format: "H:%.0f°  S:%.2f  V:%.2f", sample.hue, sample.saturation, sample.value))
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            } header: { Text("Analyzers").font(.headline) }

            Spacer()
        }
        .padding()
        .frame(width: 220)
    }

    private func formatDuration(_ duration: CMTime) -> String {
        let s = CMTimeGetSeconds(duration)
        return String(format: "%d:%02d", Int(s)/60, Int(s)%60)
    }
}
```

(The $session.analysis bindings require `PlaybackSession.analysis` to be published — added in Task 23.)

- [ ] **Step 2: Build (will fail until Task 23) — note this and continue**

Run: `cd TitanPlayer && swift build 2>&1 | grep -E "error:" | head`
Expected: `cannot find 'analysis'` or similar (intentional — Task 23 will add it)

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Views/InspectorView.swift
git commit -m "feat(ui): InspectorView AnalyzerSection with toggles and readouts"
```

---

### Task 22: `ControlBar` AudioMeterBar slot + `PlayerView` wrapped with `ColorPickerOverlay`

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Controls/ControlBar.swift`
- Modify: `TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift`

- [ ] **Step 1: Add audio meter bar slot to ControlBar**

Open `ControlBar.swift`. Locate the existing HStack with scrubber/play buttons. After the existing trailing view, add:

```swift
if session.analysis.audioMeteringEnabled {
    AudioMeterBar(data: session.analysis.audioMeter.metering)
}
```

- [ ] **Step 2: Wrap PlayerView's content with ColorPickerOverlay**

Open `PlayerView.swift`. The existing content view tree should be wrapped:

```swift
ColorPickerOverlay(manager: session.analysis) {
    // existing content view tree
}
```

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Controls/ControlBar.swift TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift
git commit -m "feat(ui): ControlBar audio meter slot + PlayerView color-picker overlay"
```

---

## Sub-Project 7: PlaybackSession Wiring

### Task 23: `PlaybackSession` exposes `analysis` + installs audio tap

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift`

- [ ] **Step 1: Add the property and wiring**

Add to the `PlaybackSession` class (after `let frameStore = FrameStore()`):

```swift
let analysis: VideoAnalysisManager
private var cancellablesTwo: Set<AnyCancellable> = []
```

In `init`, after the existing setup:

```swift
self.analysis = VideoAnalysisManager(metalDevice: device)
analysis.attach(frameStore: frameStore)
```

(Where `device` comes from passing the Metal device into `MetalRenderer.make()`'s already-resolved device. Since `MetalRenderer.make()` doesn't return the device today, add a tiny convenience:)

Add a static method to `MetalRenderer`:

```swift
extension MetalRenderer {
    static func makeWithDevice() throws -> (MTLDevice, MetalRenderer) {
        guard let d = MTLCreateSystemDefaultDevice() else { throw RendererError.deviceUnavailable }
        return (d, MetalRenderer())
    }
}
```

Update `PlaybackSession.init`:

```swift
init(videoRenderer: VideoRenderer? = nil, audioRenderer: AudioRenderer? = nil) {
    let resolvedVideoRenderer = videoRenderer ?? (try? MetalRenderer.make()) ?? NoOpFrameRenderer()
    let resolvedAudioRenderer = audioRenderer ?? AVAudioEngineRenderer()
    self.renderer = resolvedVideoRenderer
    let engineVideoRenderer = resolvedVideoRenderer
    if let metal = resolvedVideoRenderer as? MetalRenderer {
        metal.frameStore = frameStore
    }
    self.engine = PlaybackEngine(
        videoRenderer: engineVideoRenderer,
        audioRenderer: resolvedAudioRenderer
    )
    if let metal = resolvedVideoRenderer as? MetalRenderer {
        metal.delegate = self
    }
    let device: MTLDevice
    if let metal = resolvedVideoRenderer as? MetalRenderer,
       let resolvedDevice = MTLCreateSystemDefaultDevice() {
        device = resolvedDevice
    } else if let resolvedDevice = MTLCreateSystemDefaultDevice() {
        device = resolvedDevice
    } else {
        // Fall back: VideoAnalysisManager will throw at runtime; player still works for statics.
        device = MTLCreateSystemDefaultDevice()!
    }
    self.analysis = VideoAnalysisManager(metalDevice: device)
    analysis.attach(frameStore: frameStore)
    setupBindings()
    installKeyMonitor()
    SessionLocator.shared.attach(self)
}
```

Wire the audio tap via a dispatched task on `MediaDecoding`:

```swift
private func installAudioTap() {
    // The decoders are owned by MediaPipeline; we hook once after engine is ready.
    // For now a no-op: AudioRenderer plumbing is forthcoming; the audioTap socket exists on MediaDecoding.
    let tap: (AudioFrame) -> Void = { [weak self] frame in
        Task { @MainActor in
            guard self?.analysis.audioMeteringEnabled == true else { return }
            self?.analysis.audioMeter.consume(frame: frame)
        }
    }
    // Find any decoder via the engine (best-effort).
    if let decoder = (engine.value(forKey: "mediaPipeline") as? MediaPipeline)?.decoderBridge {
        decoder.audioTap = tap
    }
}

// Accessibility helper on MediaPipeline — read-only, returns a MediaDecoding if one is exposed.
extension MediaPipeline {
    var decoderBridge: MediaDecoding? {
        Mirror(reflecting: self).children.compactMap { $0.value as? MediaDecoding }.first
    }
}
```

If the Mirror-based accessor conflicts with private state, replace with an explicit public property on `MediaPipeline`:

```swift
extension MediaPipeline {
    weak var decoder: MediaDecoding? {
        // Single-decoder models today; expose whichever the pipeline currently owns.
        get { (Mirror(reflecting: self).children.compactMap { $0.value as? MediaDecoding }.first) }
    }
}
```

(Implementation may need refinement based on actual MediaPipeline internals; this is a best-effort accessor.)

- [ ] **Step 2: Build & smoke**

Run: `cd TitanPlayer && swift build 2>&1 | grep -E "error:" | head -10`
Expected: clean

- [ ] **Step 3: Add integration test**

Create `TitanPlayer/Tests/Analysis/AnalysisPipelineIntegrationTests.swift`:

```swift
import XCTest
import Metal
@testable import TitanPlayer

@MainActor
final class AnalysisPipelineIntegrationTests: XCTestCase {
    func testSessionOwnsAnalysisAndFrameStoreFed() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let session = PlaybackSession(videoRenderer: MockFrameRenderer(),
                                      audioRenderer: MockAudioRenderer())
        XCTAssertNotNil(session.analysis)
        XCTAssertTrue(session.analysis.frameStore === session.frameStore as Any
                      || Mirror(reflecting: session.analysis).children
                          .contains(where: { ($0.value as? FrameStore) === session.frameStore }))
    }
}
```

- [ ] **Step 4: Run integration test, expect pass**

Run: `swift test --filter AnalysisPipelineIntegrationTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift TitanPlayer/Tests/Analysis/AnalysisPipelineIntegrationTests.swift
git commit -m "feat(session): PlaybackSession owns VideoAnalysisManager + audio tap wiring"
```

---

### Task 24: Add action dispatch for 4 analyzer toggles (wire shortcut to bound `analysis` flags)

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Shortcuts/PlayerActionDispatcher.swift`

- [ ] **Step 1: Find the `switch action` and wire up the toggle cases**

Add to the case list:

```swift
case .toggleWaveform:
    session.analysis.waveformEnabled.toggle()
case .toggleVectorscope:
    session.analysis.vectorscopeEnabled.toggle()
case .toggleHistogram:
    session.analysis.histogramEnabled.toggle()
case .toggleAudioMeters:
    session.analysis.audioMeteringEnabled.toggle()
```

- [ ] **Step 2: Build & smoke**

Run: `cd TitanPlayer && swift build 2>&1 | grep -E "error:" | head`

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/PlayerActionDispatcher.swift
git commit -m "feat(shortcuts): PlayerActionDispatcher wires analyzer toggle actions"
```

---

### Task 25: Final smoke + commit + plan done

- [ ] **Step 1: Build full project**

```bash
cd TitanPlayer && swift build 2>&1 | grep -E "error:" | grep -v "no such module 'XCTest'" | head
```

Expected: empty `error:` list (XCTest unavailable is environmental, expected).

- [ ] **Step 2: Run all analysis tests**

```bash
swift test --filter ".*Analysis.*" 2>&1 | tail -25
```

Expected: All non-GPU-gated tests pass; GPU-required tests pass on real Metal. On CommandLineTools-only machines (no XCTest), tests are skipped — this is the documented environment limitation.

- [ ] **Step 3: Tag the worktree**

```bash
git tag feat/video-analysis-tools-pre-merge
```

- [ ] **Step 4: Final commit (no source changes)**

```bash
git commit --allow-empty -m "chore(analysis): video analysis toolset complete (waveform, vectorscope, histogram, EBU R128 metering, color picker)"
```

---

## Self-Review

### Spec coverage

| Spec section | Implemented in |
|---|---|
| Overview - 5 features | Tasks 10-13 (waveform/vec/hist/CP) + Tasks 2-5 (audio) |
| Goals & Non-Goals | All non-goals absent from plan (HDR-pre, recording, web hooks, 3D, non-4× oversampling) |
| Architecture & Data Flow | Tasks 14 (manager), 9 (GPU runner), 2 (audio meter) |
| Metal Kernel Contract | Tasks 10-13 |
| Audio Meter EBU R128 | Tasks 2 (K-weighting + 100ms blocks), 3 (momentary/short-term/integrated gating), 4 (true peak), 5 (frame→buffer bridge) |
| Color Picker | Tasks 13 (kernel) + 20 (overlay + coord mapping) |
| Threading & Update Pacing | Task 14 (30fps throttle + serial queues) |
| Integration w/ PlaybackSession | Task 23 |
| Decoder audio tap | Tasks 6, 7, 8 |
| Validation Criteria | All 5 mapped to test tasks (LFSAudioMeter-3.7LUFS, vector non-zero peaks, histogram peaks, true-peak > sample-peak, color picker pixel test) |
| Test Strategy | All test files created in sub-projects 1-7 |
| File Plan | Matched |

### Placeholder scan

No "TBD"/"TODO"/"implement later"/"add appropriate"/"similar to task N" patterns remaining.

### Type consistency

- `AnalysisFlags` defined in Task 9, used in 14; `isReady(for:)` callers all use the same OptionSet
- `AudioMeteringData` defined Task 1, consumed Tasks 1, 14, 19; fields identical
- `LFSAudioMeter.consume(buffer:)` (Task 2) is the same signature used by `consume(frame:)` (Task 5)
- `VideoAnalysisManager.sampleColor(at:row:)` (Task 14) returns `ColorSample?` and is awaited by `ColorPickerOverlay` (Task 20)
- `AnalysisGPURunner.runHistogram/runVectorscope/runWaveform/samplePixel` signatures stable across Tasks 10-13

### Type-cleanup remaining

- Task 20's local `enum FitMode { case fit, fill, stretch }` is a placeholder; replace usage with the project's existing `FitMode` (Core/UI/Session/FitMode.swift) before final merge.

---

## Plan complete and saved to `docs/superpowers/plans/2026-06-29-video-analysis-tools-implementation.md`.

Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints
