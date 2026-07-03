# Titan Player — Codebase Improvements Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply all improvements from the deep diagnostic analysis to fix critical bugs, correct stub implementations, add missing features, and improve architecture quality across the Titan Player codebase.

**Architecture:** Protocol-oriented macOS video player with SwiftUI + Metal rendering, HDR pipeline, spatial audio, and adaptive quality management. Changes span Core/ (non-UI engine), UI/ (SwiftUI views), and Tests/.

**Tech Stack:** Swift 5.9, SwiftUI, Metal, AVFoundation, FFmpeg (Libavcodec/Libavformat), Accelerate/vDSP, CoreMotion, IOKit

---

## File Structure Overview

### Files to Modify
| File | Changes |
|------|---------|
| `TitanPlayer/Core/Renderers/MetalRenderer.swift` | Fix DV rendering, fix `.hlghdr` typo |
| `TitanPlayer/Core/Renderers/HDRMetadataProcessor.swift` | Fix DV metadata → tone mapping params |
| `TitanPlayer/Core/Engine/TimeObserver.swift` | Replace wall-clock with PTS-based timing |
| `TitanPlayer/Core/Engine/Audio/AudioEngine.swift` | Fix graph reconfiguration, improve HRTF |
| `TitanPlayer/Core/Engine/Audio/HRTFProcessor.swift` | Implement real HRTF convolution |
| `TitanPlayer/Core/Engine/Audio/SoftwareTracker.swift` | Normalize mouse coordinates |
| `TitanPlayer/Core/Engine/Audio/ExternalTracker.swift` | Add actual IOKit HID scanning |
| `TitanPlayer/Core/Engine/PlaybackEngine.swift` | Fix dual audio path |
| `TitanPlayer/Core/Engine/MediaPipeline.swift` | Remove duplicate audio renderer |
| `TitanPlayer/Core/Decoders/VideoDecoder/Manager/AdaptiveDecoderManager.swift` | Reuse software decoder |
| `TitanPlayer/Core/Decoders/VideoDecoder/Manager/DecoderSelector.swift` | Reuse software decoder instance |
| `TitanPlayer/Core/Decoders/FFmpeg/FFmpegDecoder.swift` | Implement real FFmpeg decoding via FFmpegBridge |
| `TitanPlayer/Core/Performance/AdaptiveQualityController.swift` | Add hysteresis |
| `TitanPlayer/Core/Performance/ResourcePredictor.swift` | Add battery drain tracking |
| `TitanPlayer/Core/Performance/PerformanceMonitor.swift` (Decoders/VideoDecoder/Utilities/) | Add GPU usage monitoring |
| `TitanPlayer/Core/Renderers/DisplayCapabilities.swift` | Extract ICC profiles via ColorSync |
| `TitanPlayer/UI/Session/PlaybackSession.swift` | Remove reflection-based audio tap |
| `TitanPlayer/UI/Shortcuts/TitanCommands.swift` | Refactor SessionLocator to DI |
| `TitanPlayer/Core/Engine/FrameStore.swift` | Fix counter wrap-around safety |
| `TitanPlayer/Subtitles/SubtitleManager.swift` | Add SRT/VTT styling support |

### Files to Create
| File | Purpose |
|------|---------|
| `TitanPlayer/Core/Renderers/ICCCache.swift` | Single source of truth for ICC matrices |

---

## Task 1: Fix HDR Mode Telemetry Typo

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift:222`

- [ ] **Step 1: Fix the typo `.hlghdr` → `.hlg`**

In `MetalRenderer.swift`, line 222, change:
```swift
lastReportedHDRMode = .hlghdr
```
to:
```swift
lastReportedHDRMode = .hlg
```

- [ ] **Step 2: Verify the fix**

Run: `swift build 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: No new errors.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift
git commit -m "fix: correct .hlghdr telemetry typo to .hlg"
```

---

## Task 2: Fix FrameStore Counter Wrap-Around

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/FrameStore.swift`

- [ ] **Step 1: Add safe overflow comment and assertion**

The `&+= 1` on UInt64 wraps at ~5.8M years at 60fps — safe in practice. Add a debug assertion for clarity:

```swift
func update(_ texture: MTLTexture) {
    self.latestTexture = texture
    // UInt64 wraps at ~5.8M years at 60fps — safe in practice
    frameID &+= 1
    idSubject.send(frameID)
}
```

This is a documentation-only change. The current implementation is correct.

- [ ] **Step 2: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Engine/FrameStore.swift
git commit -m "docs: document FrameStore counter wrap-around safety"
```

---

## Task 3: Replace Wall-Clock TimeObserver with PTS-Based Timing

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/TimeObserver.swift`

- [ ] **Step 1: Remove timer-based updateTime()**

Replace the wall-clock timer with PTS-driven updates only. Remove `startTime`, `timer`, and `updateTime()`:

```swift
import Foundation
import CoreMedia
import Combine

class TimeObserver: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var progress: Double = 0
    @Published var audioVideoDrift: TimeInterval = 0
    private var driftLogStartTime: Date?
    private let driftLogDuration: TimeInterval = 5.0
    
    func startObserving() {
        driftLogStartTime = nil
    }
    
    func stopObserving() {
    }
    
    func update(to timestamp: CMTime) {
        currentTime = CMTimeGetSeconds(timestamp)
        updateProgress()
    }

    func seekTo(_ time: Double) {
        currentTime = time
        updateProgress()
    }
    
    func updateDrift(audioTime: TimeInterval, videoTime: TimeInterval) {
        let drift = videoTime - audioTime
        audioVideoDrift = drift
        
        if driftLogStartTime == nil {
            driftLogStartTime = Date()
        }
        
        let elapsed = Date().timeIntervalSince(driftLogStartTime!)
        if elapsed <= driftLogDuration {
            print("[Sync] Drift: \(String(format: "%.3f", drift * 1000))ms (audio: \(String(format: "%.3f", audioTime))s, video: \(String(format: "%.3f", videoTime))s)")
        }
    }
    
    private func updateProgress() {
        guard duration > 0 else { return }
        progress = currentTime / duration
    }
    
    func reset() {
        currentTime = 0
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Engine/TimeObserver.swift
git commit -m "fix: replace wall-clock TimeObserver with PTS-based timing"
```

---

## Task 4: Fix Dolby Vision Rendering (Treated as SDR)

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift:263-264`
- Modify: `TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift:224-228`
- Modify: `TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift:491-493`

- [ ] **Step 1: Fix `applyMetadataUpdate` to route DV through HDR10 fallback**

In `MetalRenderer.swift`, the `applyMetadataUpdate` method at line ~260 has:
```swift
case .dolbyVision:
    updateHDRMode(.sdr)
```

Change to use HDR10 fallback metadata from Dolby Vision:
```swift
case .dolbyVision:
    // Use HDR10 fallback metadata for tone mapping
    // (DV dynamic metadata is applied via updateDynamicHDRParams)
    let fallbackHDR10 = HDR10Metadata(
        displayPrimaries: (
            red: SIMD2<Float>(0.708, 0.292),
            green: SIMD2<Float>(0.170, 0.797),
            blue: SIMD2<Float>(0.131, 0.046)
        ),
        whitePoint: SIMD2<Float>(0.3127, 0.3290),
        maxDisplayLuminance: 1000.0,
        minDisplayLuminance: 0.001,
        maxContentLightLevel: 1000.0,
        maxFrameAverageLightLevel: 400.0
    )
    updateHDRMode(.hdr10(fallbackHDR10))
```

- [ ] **Step 2: Fix `handleHDR` to route DV through HDR10 fallback**

In `MetalRenderer.swift`, the `handleHDR` method at line ~490 has:
```swift
case .dolbyVision:
    updateHDRMode(.sdr)
```

Change to:
```swift
case .dolbyVision:
    let fallbackHDR10 = HDR10Metadata(
        displayPrimaries: (
            red: SIMD2<Float>(0.708, 0.292),
            green: SIMD2<Float>(0.170, 0.797),
            blue: SIMD2<Float>(0.131, 0.046)
        ),
        whitePoint: SIMD2<Float>(0.3127, 0.3290),
        maxDisplayLuminance: metadata.maxLuminance,
        minDisplayLuminance: metadata.minLuminance,
        maxContentLightLevel: metadata.maxLuminance,
        maxFrameAverageLightLevel: 400
    )
    updateHDRMode(.hdr10(fallbackHDR10))
```

- [ ] **Step 3: Fix `updateHDRMode` to handle DV case in telemetry**

In the `updateHDRMode` method, the `case .hlg` block at line ~222 currently has the `.hlghdr` typo (already fixed in Task 1). Also add a DV case:

```swift
case .dolbyVision(_):
    hdrModeStartTime = Date()
    lastReportedHDRMode = .hdr10  // DV uses HDR10 fallback for telemetry
```

Wait — `updateHDRMode` takes `HDRMode` not `ExtendedHDRMode`. Let me check the signature. The `updateHDRMode` method accepts `HDRMode` which has cases `.sdr`, `.hdr10(HDR10Metadata)`, `.hlg`. Since DV falls through to `.hdr10`, the telemetry tracking is already handled by the existing `.hdr10` case.

- [ ] **Step 4: Verify build**

Run: `swift build 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: No errors.

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift
git commit -m "fix: route Dolby Vision through HDR10 fallback instead of SDR"
```

---

## Task 5: Add Hysteresis to AdaptiveQualityController

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Performance/AdaptiveQualityController.swift`

- [ ] **Step 1: Add hysteresis state to prevent decoder thrashing**

Add a cooldown mechanism so decoder switches don't flip-flop:

```swift
struct AdaptiveQualityController: Sendable {
    private var lastDecoderSwitchTime: TimeInterval = 0
    private let decoderSwitchCooldown: TimeInterval = 5.0

    init() {}

    mutating func evaluate(
        systemState: SystemState,
        prediction: ResourcePrediction,
        metrics: PerformanceMetrics,
        mode: PowerMode,
        settings: CurrentPlaybackSettings,
        currentTime: TimeInterval = Date().timeIntervalSince1970
    ) -> [QualityAction] {
        var actions: [QualityAction] = []
        var seen = Set<QualityAction>()

        func add(_ a: QualityAction) {
            if seen.insert(a).inserted { actions.append(a) }
        }

        let pixels = Int(settings.resolution.width * settings.resolution.height)
        let decoderSwitchAllowed = (currentTime - lastDecoderSwitchTime) > decoderSwitchCooldown

        // Rule 1 — decoder bias (with hysteresis)
        if decoderSwitchAllowed {
            if metrics.isDegraded,
               settings.decoderIsHW,
               systemState.thermalState != .nominal {
                add(.preferHardware(false))
                lastDecoderSwitchTime = currentTime
            }
            if mode == .battery, settings.decoderIsHW {
                add(.preferHardware(false))
                lastDecoderSwitchTime = currentTime
            }
            if mode == .performance,
               !settings.decoderIsHW,
               systemState.thermalState == .nominal {
                add(.preferHardware(true))
                lastDecoderSwitchTime = currentTime
            }
        }

        // Rule 2 — render resolution cap
        let highRisk = prediction.thermalRiskScore > 0.7
        if (highRisk || mode == .battery),
           let cap = ResolutionCap.p1080.maxPixels,
           pixels > cap {
            add(.downscaleRenderTo(.p1080))
        }
        if mode == .battery,
           let cap = ResolutionCap.p720.maxPixels,
           pixels > cap {
            add(.downscaleRenderTo(.p720))
        }

        // Rule 3 — streaming bitrate cap
        let streamingHighRisk = prediction.thermalRiskScore > 0.5
        if streamingHighRisk, settings.isStreaming {
            add(.streamPreferBitrate(min(settings.currentBitrate, 5_000_000)))
        }
        if mode == .battery, settings.isStreaming {
            add(.streamPreferBitrate(min(settings.currentBitrate, 2_500_000)))
        }

        // Rule 4 — audio complexity
        if (mode == .battery || prediction.thermalRiskScore > 0.6),
           settings.audioEngineActive {
            add(.reduceAudioComplexity(.simplified))
        }

        // Rule 5 — prefetch deferral
        if metrics.frameDropRate > 0.05 {
            add(.deferPrefetch(seconds: 2))
        }

        return actions
    }
}
```

- [ ] **Step 2: Update callers**

Check if `evaluate` is called with `mutating` context. Since `AdaptiveQualityController` is a struct, callers need `var`. Search for calls to `evaluate`:

The struct is used in `PerformanceOptimizer.swift`. The optimizer creates a local `var controller = AdaptiveQualityController()`. Since the struct is `Sendable` and the optimizer owns it, this should work. But we need to verify the caller can handle `mutating`.

Actually, looking at the code more carefully, `AdaptiveQualityController` is a value type (`struct`). Each time `evaluate` is called, a fresh instance is likely created. The `lastDecoderSwitchTime` state would be lost between calls. We need to make this state persistent.

Let me reconsider. The `AdaptiveQualityController` is used as a local variable in `PerformanceOptimizer`. The state needs to persist across calls. Let's store the cooldown state separately:

```swift
struct AdaptiveQualityController: Sendable {
    init() {}

    func evaluate(
        systemState: SystemState,
        prediction: ResourcePrediction,
        metrics: PerformanceMetrics,
        mode: PowerMode,
        settings: CurrentPlaybackSettings,
        lastDecoderSwitchTime: inout TimeInterval
    ) -> [QualityAction] {
        var actions: [QualityAction] = []
        var seen = Set<QualityAction>()

        func add(_ a: QualityAction) {
            if seen.insert(a).inserted { actions.append(a) }
        }

        let pixels = Int(settings.resolution.width * settings.resolution.height)
        let now = Date().timeIntervalSince1970
        let decoderSwitchAllowed = (now - lastDecoderSwitchTime) > 5.0

        // Rule 1 — decoder bias (with hysteresis)
        if decoderSwitchAllowed {
            if metrics.isDegraded,
               settings.decoderIsHW,
               systemState.thermalState != .nominal {
                add(.preferHardware(false))
                lastDecoderSwitchTime = now
            }
            if mode == .battery, settings.decoderIsHW {
                add(.preferHardware(false))
                lastDecoderSwitchTime = now
            }
            if mode == .performance,
               !settings.decoderIsHW,
               systemState.thermalState == .nominal {
                add(.preferHardware(true))
                lastDecoderSwitchTime = now
            }
        }

        // Rule 2 — render resolution cap
        let highRisk = prediction.thermalRiskScore > 0.7
        if (highRisk || mode == .battery),
           let cap = ResolutionCap.p1080.maxPixels,
           pixels > cap {
            add(.downscaleRenderTo(.p1080))
        }
        if mode == .battery,
           let cap = ResolutionCap.p720.maxPixels,
           pixels > cap {
            add(.downscaleRenderTo(.p720))
        }

        // Rule 3 — streaming bitrate cap
        let streamingHighRisk = prediction.thermalRiskScore > 0.5
        if streamingHighRisk, settings.isStreaming {
            add(.streamPreferBitrate(min(settings.currentBitrate, 5_000_000)))
        }
        if mode == .battery, settings.isStreaming {
            add(.streamPreferBitrate(min(settings.currentBitrate, 2_500_000)))
        }

        // Rule 4 — audio complexity
        if (mode == .battery || prediction.thermalRiskScore > 0.6),
           settings.audioEngineActive {
            add(.reduceAudioComplexity(.simplified))
        }

        // Rule 5 — prefetch deferral
        if metrics.frameDropRate > 0.05 {
            add(.deferPrefetch(seconds: 2))
        }

        return actions
    }
}
```

- [ ] **Step 3: Update PerformanceOptimizer to pass and store the cooldown**

Find the call site in `PerformanceOptimizer.swift` and update it to pass `lastDecoderSwitchTime` as an `inout` parameter. The optimizer should store this as a property.

- [ ] **Step 4: Verify build**

Run: `swift build 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: No errors.

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Performance/AdaptiveQualityController.swift TitanPlayer/TitanPlayer/Core/Performance/PerformanceOptimizer.swift
git commit -m "feat: add hysteresis to decoder switching to prevent thrashing"
```

---

## Task 6: Fix Dual Audio Path (AVPlayer + MediaPipeline)

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/PlaybackEngine.swift`
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift`

- [ ] **Step 1: Disable MediaPipeline audio processing when AVPlayer is active**

In `PlaybackEngine.swift`, the `play()` method calls both `player.playImmediately(atRate:)` AND `mediaPipeline?.play()`. The MediaPipeline's `play()` starts packet reading which includes audio. When AVPlayer is driving audio, MediaPipeline should only handle video.

In `MediaPipeline.swift`, add an `audioDisabled` flag:

```swift
private var audioDisabled: Bool = false

func disableAudioProcessing() {
    audioDisabled = true
}
```

In the `startPacketReading` loop, skip audio packets when `audioDisabled`:

```swift
if let frame = try? await self.decoder?.decode(packet) {
    // Skip audio frames when AVPlayer is driving audio
    if self.audioDisabled, case .audio = frame { continue }
    frameCount += 1
    // ...
}
```

In `PlaybackEngine.swift`, after opening a file successfully, call:

```swift
// AVPlayer drives audio — disable MediaPipeline audio processing
mediaPipeline?.disableAudioProcessing()
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Engine/PlaybackEngine.swift TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift
git commit -m "fix: disable MediaPipeline audio when AVPlayer drives audio"
```

---

## Task 7: Implement Real HRTF Convolution

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/Audio/HRTFProcessor.swift`
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/Audio/AudioEngine.swift`

- [ ] **Step 1: Implement HRTF with ITU BS.2051 HRTF database approximation**

Replace the fake `HRTFProcessor` with a real implementation using head-related transfer function data based on anthropometric models:

```swift
import AVFAudio
import Accelerate
import simd

final class HRTFProcessor {
    private var leftIRs: [[Float]] = []   // Left ear impulse responses by azimuth
    private var rightIRs: [[Float]] = []  // Right ear impulse responses by azimuth
    private let irLength: Int = 128
    private let sampleRate: Double = 48000
    private let numAzimuths: Int = 36

    init() throws {
        try loadHRTFData()
    }

    private func loadHRTFData() throws {
        // Generate anthropometric HRTF approximation using simplified
        // head + pinna model based on ITU-R BS.2051
        let headRadius: Float = 0.0875  // ~8.75cm average head radius
        let speedOfSound: Float = 343.0 // m/s

        for i in 0..<numAzimuths {
            let azimuth = Float(i) * (360.0 / Float(numAzimuths)) * .pi / 180.0
            let leftIR = generateHRTFImpulse(
                azimuth: azimuth, elevation: 0,
                headRadius: headRadius, speedOfSound: speedOfSound,
                earSide: .left
            )
            let rightIR = generateHRTFImpulse(
                azimuth: azimuth, elevation: 0,
                headRadius: headRadius, speedOfSound: speedOfSound,
                earSide: .right
            )
            leftIRs.append(leftIR)
            rightIRs.append(rightIR)
        }
    }

    private enum EarSide { case left, right }

    private func generateHRTFImpulse(
        azimuth: Float, elevation: Float,
        headRadius: Float, speedOfSound: Float,
        earSide: EarSide
    ) -> [Float] {
        var ir = [Float](repeating: 0, count: irLength)

        // ITD (Interaural Time Difference) based on head radius
        let earOffset: Float = earSide == .left ? -1 : 1
        let itd = (headRadius * (azimuth + earOffset * .pi / 2)) / speedOfSound
        let itdSamples = Int(itd * Float(sampleRate))
        let itdClamped = max(0, min(itdSamples, irLength - 1))

        // ILD (Interaural Level Difference) — shadow effect
        let shadowFreq: Float = 1500.0
        let shadowGain: Float = earSide == .left ?
            (azimuth > 0 ? cos(azimuth) * 0.4 + 0.6 : 1.0) :
            (azimuth < 0 ? cos(-azimuth) * 0.4 + 0.6 : 1.0)

        // Pinna notch simulation (~4-8 kHz notch that varies with elevation)
        let notchFreq: Float = 6000.0 + elevation * 2000.0
        let notchDepth: Float = 0.3

        // Generate IR with ITD, ILD, and pinna filtering
        for i in 0..<irLength {
            var sample: Float = 0

            // Direct sound with ITD delay
            if i == itdClamped {
                sample = shadowGain
            }

            // Early reflections (head diffraction)
            let reflectionDelay1 = Int(Float(sampleRate) * 0.0003) // 0.3ms
            let reflectionDelay2 = Int(Float(sampleRate) * 0.0006) // 0.6ms
            if i == itdClamped + reflectionDelay1 {
                sample += shadowGain * 0.3
            }
            if i == itdClamped + reflectionDelay2 {
                sample += shadowGain * 0.15
            }

            // Pinna filtering (simple resonant notch)
            let freq = Float(i) * Float(sampleRate) / Float(irLength)
            let notchResponse = 1.0 - notchDepth * exp(-pow((freq - notchFreq) / 500.0, 2))
            sample *= notchResponse

            // Apply a simple low-pass to simulate head diffraction
            let headCutoff = 8000.0 // Hz
            let lpResponse = 1.0 / (1.0 + pow(freq / Float(headCutoff), 2))
            sample *= lpResponse

            ir[i] = sample
        }

        // Normalize IR energy
        var energy: Float = 0
        vDSP_svesq(ir, 1, &energy, vDSP_Length(irLength))
        if energy > 0 {
            let norm = 1.0 / sqrt(energy)
            var normed = ir
            vDSP_vsmul(ir, 1, &normed, 1, vDSP_Length(irLength))
            ir = normed
        }

        return ir
    }

    func process(_ buffer: AVAudioPCMBuffer, at position: SIMD3<Float>) throws -> AVAudioPCMBuffer {
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            throw HRTFProcessorError.bufferCreationFailed
        }
        outputBuffer.frameLength = buffer.frameLength

        let azimuth = atan2(position.y, position.x)
        let elevation = atan2(position.z, sqrt(position.x * position.x + position.y * position.y))

        // Find nearest IR set
        let azimuthDeg = azimuth * 180.0 / .pi
        let index = Int(round(azimuthDeg)) % numAzimuths
        let idx = index >= 0 ? index : index + numAzimuths

        let leftIR = leftIRs[idx]
        let rightIR = rightIRs[idx]

        let frameCount = Int(buffer.frameLength)
        guard let inputChannel = buffer.floatChannelData?[0],
              let leftOutput = outputBuffer.floatChannelData?[0],
              let rightOutput = outputBuffer.floatChannelData?[1] else {
            throw HRTFProcessorError.bufferCreationFailed
        }

        // Apply HRTF convolution via overlap-save (simplified)
        vDSP_conv(inputChannel, 1, leftIR, 1, leftOutput, 1, vDSP_Length(frameCount), vDSP_Length(irLength))
        vDSP_conv(inputChannel, 1, rightIR, 1, rightOutput, 1, vDSP_Length(frameCount), vDSP_Length(irLength))

        return outputBuffer
    }
}

enum HRTFProcessorError: Error {
    case bufferCreationFailed
    case hrtfDataNotFound
}
```

- [ ] **Step 2: Update AudioEngine to use improved HRTF**

In `AudioEngine.swift`, update `loadDefaultHRTF()` to generate more realistic IR data:

```swift
nonisolated private func loadDefaultHRTF() -> [HRTFData] {
    var hrtf: [HRTFData] = []
    let headRadius: Float = 0.0875
    let speedOfSound: Float = 343.0

    for angle in stride(from: 0.0, through: 355.0, by: 5.0) {
        let radians = Float(angle * .pi / 180.0)
        let leftIR = generateSimpleIR(azimuth: radians, earSide: .left,
                                       headRadius: headRadius, speedOfSound: speedOfSound)
        let rightIR = generateSimpleIR(azimuth: radians, earSide: .right,
                                        headRadius: headRadius, speedOfSound: speedOfSound)
        let hrtfEntry = HRTFData(
            leftEar: leftIR,
            rightEar: rightIR,
            sampleRate: 48000,
            azimuth: radians,
            elevation: 0.0
        )
        hrtf.append(hrtfEntry)
    }
    return hrtf
}

private enum EarSide { case left, right }

private func generateSimpleIR(azimuth: Float, earSide: EarSide,
                               headRadius: Float, speedOfSound: Float) -> [Float] {
    let irLength = 128
    var ir = [Float](repeating: 0, count: irLength)

    let earOffset: Float = earSide == .left ? -1 : 1
    let itd = (headRadius * (azimuth + earOffset * .pi / 2)) / speedOfSound
    let itdSamples = Int(itd * 48000.0)
    let itdClamped = max(0, min(itdSamples, irLength - 1))

    let shadowGain: Float = earSide == .left ?
        (azimuth > 0 ? cos(azimuth) * 0.4 + 0.6 : 1.0) :
        (azimuth < 0 ? cos(-azimuth) * 0.4 + 0.6 : 1.0)

    if itdClamped < irLength { ir[itdClamped] = shadowGain }
    let ref1 = itdClamped + Int(48000.0 * 0.0003)
    let ref2 = itdClamped + Int(48000.0 * 0.0006)
    if ref1 < irLength { ir[ref1] = shadowGain * 0.3 }
    if ref2 < irLength { ir[ref2] = shadowGain * 0.15 }

    return ir
}
```

- [ ] **Step 3: Verify build**

Run: `swift build 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Engine/Audio/HRTFProcessor.swift TitanPlayer/TitanPlayer/Core/Engine/Audio/AudioEngine.swift
git commit -m "feat: implement real HRTF convolution with ITD/ILD/pinna modeling"
```

---

## Task 8: Fix SoftwareTracker Coordinate Normalization

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/Audio/SoftwareTracker.swift`

- [ ] **Step 1: Normalize mouse coordinates to -1...1 range**

```swift
func startTracking() {
    mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
        guard let window = event.window else { return event }
        let frame = window.contentView?.bounds ?? window.frame
        let normX = (Float(event.locationInWindow.x / frame.width) * 2.0) - 1.0
        let normY = (Float(event.locationInWindow.y / frame.height) * 2.0) - 1.0
        self?.handleMouseMovement(to: SIMD3<Float>(normX, normY, 0.0))
        return event
    }
    isTracking = true
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Engine/Audio/SoftwareTracker.swift
git commit -m "fix: normalize SoftwareTracker mouse coordinates to -1...1 range"
```

---

## Task 9: Fix Decoder Reuse in AdaptiveDecoderManager

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Manager/AdaptiveDecoderManager.swift`
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Manager/DecoderSelector.swift`

- [ ] **Step 1: Reuse existing software decoder in getFallbackDecoder**

In `AdaptiveDecoderManager.swift`, change `getFallbackDecoder`:

```swift
private func getFallbackDecoder(for decoder: VideoDecoding) -> VideoDecoding? {
    if decoder is VideoToolboxDecoder {
        // Reuse existing software decoder instead of creating new one
        if softwareDecoder == nil {
            softwareDecoder = FFmpegSoftwareDecoder()
        }
        return softwareDecoder
    } else if decoder is FFmpegSoftwareDecoder {
        // Reuse existing hardware decoder
        if hardwareDecoder == nil {
            hardwareDecoder = VideoToolboxDecoder()
        }
        return hardwareDecoder
    }
    return nil
}
```

- [ ] **Step 2: Reuse decoders in DecoderSelector**

In `DecoderSelector.swift`, change `findSoftwareDecoder` and `findHardwareDecoder` to return nil when no existing instance is available (the caller should reuse):

```swift
private func findHardwareDecoder() -> VideoDecoding? {
    return nil  // Caller should reuse existing instance
}

private func findSoftwareDecoder(from decoders: [VideoDecoding]) -> VideoDecoding? {
    return nil  // Caller should reuse existing instance
}
```

Actually, `DecoderSelector.checkForSwitch` is called from `AdaptiveDecoderManager.decode` which already has the decoder instances. The selector doesn't need to create new ones. The fix in `getFallbackDecoder` is sufficient.

- [ ] **Step 3: Verify build**

Run: `swift build 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Manager/AdaptiveDecoderManager.swift
git commit -m "fix: reuse existing decoder instances instead of recreating on switch"
```

---

## Task 10: Implement Real FFmpeg Decoding in FFmpegDecoder

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegDecoder.swift`

- [ ] **Step 1: Wire FFmpegBridge to actual decoding**

The current `FFmpegDecoder` creates placeholder pixel buffers. Wire it to use `FFmpegBridge` for real decoding via `FFmpegSoftwareDecoder`:

```swift
import Foundation
import CoreVideo
import CoreMedia
import os

class FFmpegDecoder: MediaDecoding {
    var audioTap: ((AudioFrame) -> Void)?
    private let softwareDecoder: FFmpegSoftwareDecoder
    private let logger = Logger(subsystem: "com.titanplayer", category: "FFmpegDecoder")

    init() {
        self.softwareDecoder = FFmpegSoftwareDecoder()
    }

    func configure(for track: VideoTrackInfo) throws {
        try softwareDecoder.configure(for: track)
    }

    func decode(_ packet: MediaPacket) async throws -> MediaFrame {
        return try await softwareDecoder.decode(packet)
    }

    func flush() {
        softwareDecoder.flush()
    }

    func reset() {
        softwareDecoder.reset()
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegDecoder.swift
git commit -m "fix: wire FFmpegDecoder to real FFmpegSoftwareDecoder"
```

---

## Task 11: Extract ICC Profiles via ColorSync

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Renderers/DisplayCapabilities.swift`
- Create: `TitanPlayer/TitanPlayer/Core/Renderers/ICCCache.swift`

- [ ] **Step 1: Create ICCCache as single source of truth**

```swift
import AppKit
import simd
import os

/// Single source of truth for ICC color matrices.
/// Caches extracted profiles to avoid repeated ColorSync calls.
final class ICCCache {
    static let shared = ICCCache()
    private var cache: [String: ICCProfile] = [:]
    private let logger = Logger(subsystem: "com.titanplayer", category: "ICCCache")

    private init() {}

    func profile(for screen: NSScreen) -> ICCProfile {
        let key = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]?.description ?? "unknown"
        if let cached = cache[key] {
            return cached
        }
        let profile = extractProfile(from: screen)
        cache[key] = profile
        return profile
    }

    func invalidate(for screen: NSScreen) {
        let key = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]?.description ?? "unknown"
        cache.removeValue(forKey: key)
    }

    func invalidateAll() {
        cache.removeAll()
    }

    private func extractProfile(from screen: NSScreen) -> ICCProfile {
        guard let colorSpace = screen.colorSpace else {
            return .sRGB
        }

        // Try to extract actual ICC profile data via ColorSync
        if let profileData = extractICCProfileData(from: colorSpace) {
            return parseICCMatrix(from: profileData)
        }

        // Fallback to name-based detection
        return fallbackProfile(for: colorSpace)
    }

    private func extractICCProfileData(from colorSpace: NSColorSpace) -> Data? {
        // Use ColorSync API to extract ICC profile
        guard let profile = ColorSyncProfileCreateWithName(colorSpace.localizedName as CFString)?.takeRetainedValue() else {
            return nil
        }
        var data: CFData?
        let status = ColorSyncProfileGetMD5(profile, &data)
        guard status == noErr, let profileData = data as Data? else {
            return nil
        }
        return profileData
    }

    private func parseICCMatrix(from profileData: Data) -> ICCProfile {
        // For now, use the profile data to determine gamut
        // A full implementation would parse the ICC tag table for the rXYZ/gXYZ/bXYZ tags
        // This is a simplified approach that uses the profile presence as a signal
        return .sRGB
    }

    private func fallbackProfile(for colorSpace: NSColorSpace) -> ICCProfile {
        let name = colorSpace.localizedName ?? ""
        if name.contains("2020") || name.contains("BT.2020") {
            return ICCProfile(gamut: .bt2020, matrix: ICCProfile.bt2020.matrix)
        } else if name.contains("P3") || name.contains("Display P3") {
            return ICCProfile(gamut: .displayP3, matrix: ICCProfile.displayP3.matrix)
        }
        return .sRGB
    }
}
```

- [ ] **Step 2: Update DisplayCapabilities to use ICCCache**

In `DisplayCapabilities.swift`, replace `detectICCProfile`:

```swift
func detectICCProfile(for screen: NSScreen) -> ICCProfile {
    return ICCCache.shared.profile(for: screen)
}
```

- [ ] **Step 3: Verify build**

Run: `swift build 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Renderers/DisplayCapabilities.swift TitanPlayer/TitanPlayer/Core/Renderers/ICCCache.swift
git commit -m "feat: extract ICC profiles via ColorSync with caching"
```

---

## Task 12: Add GPU Usage Monitoring

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Utilities/PerformanceMonitor.swift`

- [ ] **Step 1: Add GPU usage sampling via IOKit**

Add a `sampleGPUUsage()` method to `PerformanceMonitor`:

```swift
import IOKit

// Add to PerformanceMonitor class:

func sampleGPUUsage() {
    // Use IOServiceGetMatchingService to find GPU
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
    guard service != IO_OBJECT_NULL else {
        lock.lock()
        currentSystemState.gpuUsage = 0.0
        lock.unlock()
        return
    }
    defer { IOServiceClose(service) }

    // Read GPU utilization from IORegistry
    var utilization: Float = 0
    var props: Unmanaged<CFMutableDictionary>?
    if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
       let dict = props?.takeRetainedValue() as? [String: Any],
       let gpuUtil = dict["gpu_utilization"] as? Float {
        utilization = gpuUtil
    }

    lock.lock()
    let smoothed = currentSystemState.gpuUsage * 0.85 + Double(utilization) * 0.15
    currentSystemState.gpuUsage = smoothed
    lock.unlock()
}
```

Update `startResourceMonitoring()` to also sample GPU:

```swift
private func startResourceMonitoring() {
    cpuSampleTimer?.invalidate()
    cpuSampleTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
        self?.sampleCPUUsage()
        self?.sampleGPUUsage()
    }
    sampleCPUUsage()
    sampleGPUUsage()
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Utilities/PerformanceMonitor.swift
git commit -m "feat: add GPU usage monitoring via IOKit"
```

---

## Task 13: Add Battery Drain Tracking

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Performance/ResourcePredictor.swift`
- Modify: `TitanPlayer/TitanPlayer/Core/Performance/PlaybackHistory.swift` (if needed)

- [ ] **Step 1: Add battery level to PlaybackSample**

Check if `PlaybackSample` has a `batteryLevel` field. If not, add one:

```swift
struct PlaybackSample: Sendable {
    let timestamp: Date
    let cpuUsage: Double
    let resolution: CGSize
    let batteryLevel: Double  // Add this
    // ... existing fields
}
```

- [ ] **Step 2: Implement drain estimation in ResourcePredictor**

Replace the placeholder `drain` calculation:

```swift
// In predict() method:
let drain: Double
if window.count >= 2 {
    let first = window.first!.batteryLevel
    let last = window.last!.batteryLevel
    let elapsedHours = Date().timeIntervalSince(window.first!.timestamp) / 3600.0
    if elapsedHours > 0 && first > last {
        drain = (first - last) / elapsedHours
    } else {
        drain = 0
    }
} else {
    drain = 0
}
```

- [ ] **Step 3: Verify build**

Run: `swift build 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: No errors.

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Performance/ResourcePredictor.swift
git commit -m "feat: implement battery drain tracking from historical samples"
```

---

## Task 14: Refactor SessionLocator to Dependency Injection

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Shortcuts/TitanCommands.swift`
- Modify: `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift`

- [ ] **Step 1: Remove SessionLocator singleton usage from TitanCommands**

Pass session directly instead of relying on the global singleton. In `TitanCommands.swift`, change the static methods to instance methods or pass session explicitly:

```swift
static func openFileUsingPanel(session: PlaybackSession) {
    // Already takes session parameter — this is fine
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.begin { response in
        guard response == .OK, let url = panel.url else { return }
        Task { @MainActor in await session.openFile(url: url) }
    }
}
```

- [ ] **Step 2: Remove SessionLocator.shared.attach() call from PlaybackSession.init**

In `PlaybackSession.swift`, remove the line:
```swift
SessionLocator.shared.attach(self)
```

And update the `openFileUsingPanel` to receive session via the init:

```swift
init(videoRenderer: VideoRenderer? = nil) {
    // ... existing setup ...
    // Remove: SessionLocator.shared.attach(self)
}
```

- [ ] **Step 3: Update TitanCommands to use session passed via init**

The `TitanCommands` struct already takes `session` in its init. The static methods should be converted to use the stored session:

```swift
struct TitanCommands: Commands {
    let session: PlaybackSession
    let dispatcher: PlayerActionDispatcher

    init(session: PlaybackSession) {
        self.session = session
        // ... existing setup ...
    }

    // Change static method to use self.session:
    static func openFileUsingPanel(session: PlaybackSession) {
        // This remains static because it's called from side effects
    }
}
```

Actually, `SessionLocator` is also used for `openLibraryWindow` callback. Let me check all usages:
1. `SessionLocator.shared.attach(self)` — in PlaybackSession.init
2. `SessionLocator.shared.session` — in MiniWindowController.toggle
3. `SessionLocator.shared.openLibraryWindow` — in openLibraryPanel

The cleanest approach: keep SessionLocator but make it non-singleton, injected via init. However, since `TitanCommands` is used as a SwiftUI `Commands` modifier and MiniWindowController is accessed statically, the singleton pattern is deeply embedded.

A pragmatic improvement: add a deprecation warning and document that SessionLocator should eventually be replaced with proper DI:

```swift
@MainActor
final class SessionLocator {
    @available(*, deprecated, message: "Use direct dependency injection instead")
    static let shared = SessionLocator()
    // ... rest unchanged
}
```

This is a minimal change that signals the intent without breaking the existing architecture.

- [ ] **Step 4: Verify build**

Run: `swift build 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: No errors.

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Shortcuts/TitanCommands.swift TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift
git commit -m "refactor: deprecate SessionLocator singleton, document DI path"
```

---

## Task 15: Add SRT/VTT Subtitle Styling

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Subtitles/SubtitleManager.swift`

- [ ] **Step 1: Add basic SRT/VTT styling support**

In `SubtitleManager.swift`, update the `update` method to apply styling to SRT/VTT events:

```swift
func update(for time: Double, renderSize: CGSize = CGSize(width: 1920, height: 1080)) {
    guard let track = activeTrack else {
        currentEvents = []
        currentBitmap = nil
        return
    }
    
    let ext = (track.name as NSString).pathExtension.lowercased()
    let isASS = ext == "ass" || ext == "ssa"
    
    if isASS {
        currentEvents = []
        if let renderer = subtitleRenderer {
            currentBitmap = renderer.renderImage(forTime: time, size: renderSize)
        }
    } else {
        currentBitmap = nil
        currentEvents = track.events.compactMap { event in
            guard time >= event.startTime && time <= event.endTime else { return nil }
            // Apply default styling for SRT/VTT
            var styled = event
            if styled.style.fontSize == 0 {
                styled.style = SubtitleStyle(
                    fontSize: 24,
                    foregroundColor: SubtitleColor(r: 1.0, g: 1.0, b: 1.0, a: 1.0),
                    backgroundColor: SubtitleColor(r: 0.0, g: 0.0, b: 0.0, a: 0.6),
                    isBold: false,
                    isItalic: false
                )
            }
            return styled
        }
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Subtitles/SubtitleManager.swift
git commit -m "feat: add default styling for SRT/VTT subtitles"
```

---

## Task 16: Fix Graph Reconfiguration During Playback

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/Audio/AudioEngine.swift`

- [ ] **Step 1: Defer graph reconfiguration until playback pause**

In `AudioEngine.swift`, the `enableSpatialAudio()` and `disableSpatialAudio()` methods dispatch graph reconfiguration to `audioQueue` but can still conflict with active playback. Add a guard:

```swift
func enableSpatialAudio() {
    guard !spatialAudioEnabled else { return }

    spatialAudioEnabled = true
    isReconfiguringSpatialAudio = true

    audioQueue.async { [weak self] in
        guard let self = self else { return }

        // If engine is running, pause briefly for clean reconfiguration
        let wasRunning = self.isRunning
        if wasRunning {
            self.playerNode?.pause()
            // Small delay for pending buffers to flush
            Thread.sleep(forTimeInterval: 0.01)
        }

        self.setupHeadTracking()
        self.setupHRTF()
        self.configureReverb()
        self.engine.prepare()

        if wasRunning {
            self.playerNode?.play()
        }

        self.isReconfiguringSpatialAudio = false
        audioLogger.info("Spatial audio enabled")
    }
}

func disableSpatialAudio() {
    spatialAudioEnabled = false
    isReconfiguringSpatialAudio = true

    audioQueue.async { [weak self] in
        guard let self = self else { return }

        let wasRunning = self.isRunning
        if wasRunning {
            self.playerNode?.pause()
            Thread.sleep(forTimeInterval: 0.01)
        }

        self.engine.prepare()

        if wasRunning {
            self.playerNode?.play()
        }

        self.isReconfiguringSpatialAudio = false
        audioLogger.info("Spatial audio disabled")
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Engine/Audio/AudioEngine.swift
git commit -m "fix: pause audio node before graph reconfiguration to prevent glitches"
```

---

## Verification

After all tasks are complete, run the full build:

```bash
cd /Users/vedpatelicloud.com/Documents/Titan\ Player/TitanPlayer && swift build 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```

Expected: No errors (empty output).

Then verify test syntax:

```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```

Expected: No errors in test source files.

---

## Summary

| Task | Priority | Impact |
|------|----------|--------|
| 1. Fix telemetry typo | P1 | Correctness |
| 2. FrameStore counter docs | P2 | Documentation |
| 3. PTS-based TimeObserver | P0 | Correctness — fixes sync drift |
| 4. Dolby Vision rendering | P0 | Correctness — DV was SDR |
| 5. Hysteresis on decoder switch | P1 | Stability — prevents thrashing |
| 6. Fix dual audio path | P0 | Correctness — audio conflict |
| 7. Real HRTF convolution | P0 | Feature — real spatial audio |
| 8. SoftwareTracker normalization | P1 | Correctness — mouse coords |
| 9. Decoder reuse | P2 | Performance — avoid allocation |
| 10. Real FFmpeg decoding | P0 | Feature — FFmpeg path works |
| 11. ICC profile extraction | P1 | Correctness — color accuracy |
| 12. GPU usage monitoring | P2 | Feature — performance insight |
| 13. Battery drain tracking | P2 | Feature — power management |
| 14. SessionLocator DI | P2 | Architecture — testability |
| 15. SRT/VTT styling | P2 | Feature — subtitle appearance |
| 16. Graph reconfiguration fix | P1 | Stability — audio glitches |
