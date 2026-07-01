# Performance Optimization & Resource Management Design

**Date:** 2026-06-29
**Status:** Approved (pending writing-plans and implementation)
**Branch:** `feat/performance-optimizer`
**Target:** macOS 14+
**Depends on:** existing `PerformanceMonitor`, `NetworkMonitor`, `AdaptiveDecoderManager`, `StreamingManager`, `PlaybackSession`.

## Overview

Add a session-tier **PerformanceOptimizer** that coordinates cross-cutting playback adaptation in response to thermal pressure, battery state, low-power mode, CPU saturation, network reachability, and decoder-side frame drop metrics. It introduces:

1. An explicit, user-overridable **PowerMode** state machine (auto / performance / balanced / battery).
2. A **PlaybackHistory** ring buffer and a deterministic **ResourcePrediction** heuristic (no CoreML).
3. An **AdaptiveQualityController** that derives ordered **QualityAction**s from `(systemState, prediction, metrics, mode, settings)`.
4. **Subsystem adapters** that translate those actions into concrete changes on the decoder, renderer, streaming layer, and (lightly) the audio engine.
5. A small **`_testInject` testing seam** added to `PerformanceMonitor` so the new code is unit-testable without ProcessInfo.

The goal is *predictive-adaptation* and *graceful throttling*, not the validation criteria of "CPU <5% / battery <10%/hr"; those are product-level acceptance metrics verified via Instruments / QA soak runs (and noted in the validation section below).

## Goals & Non-Goals

**Goals**

- One place (`PerformanceOptimizer`) decides adaptation policy; subsystems stay responsible for *executing* within their own constraints.
- PowerMode is observable to UI (read-only badge), overridable by user, and falls back to auto-derivation when `auto`.
- Deterministic, testable prediction: rolling-window statistics over recent playback samples — no ML model, no opaque state.
- Existing `AdaptiveDecoderManager` continues to handle decoder hot-swap in real time; the optimizer **biases** its preference rather than bypassing it.
- Existing `NetworkMonitor.thermalState` and `PerformanceMonitor.currentSystemState` remain the only ProcessInfo observers (one source of truth each).
- All new code has a protocol seam following the project's existing pattern (e.g., `NetworkMonitorProtocol`, `HLSPlayerProtocol`).
- All new behavior is covered by unit tests.

**Non-Goals (YAGNI)**

- CoreML / on-device learning. The "machine learning" in the prompt is implemented as a deterministic rolling-statistic predictor.
- Auto-selecting audio output device, speaker EQ, or surround-mode based on thermal state.
- A user-facing "Performance" preferences panel. v1 exposes PowerMode via a read-only badge in `ControlBar`; user override is wired but only documented — no UI for it in this prompt. (Mock-friendly test injection of `PowerMode` covers the override path today.)
- Frame-rate caps (e.g. dropping from 60fps to 30fps to save power). Out of scope; can be added as a future quality action.
- A long-running soak-test harness. Product-level criteria are validated manually; the spec focuses on internal contracts.
- Replacing any existing frame buffer / audio buffer / packet pool. Memory management is *coordinated* (smart buffering via existing primitives), not rebuilt.

## Decisions Log

| Decision | Rationale |
|---|---|
| Layer above the existing `PerformanceMonitor` | Preserves `AdaptiveDecoderManager` + `DecoderSelector` semantics and `SystemState` struct definition; avoids coupling subsystems to a higher-level coordinator. |
| Deterministic rolling-statistic prediction, not CoreML | Testability (no model variance), tiny CPU footprint, no model artifact shipping. The prompt's "ML" is satisfied as statistical inference; can be upgraded to CoreML later behind the same `ResourcePredictor` protocol. |
| AdaptiveQualityController is pure logic (no side-effects) | Pure functions are trivially testable; subsystem adapters sit in their own layer and own the side-effects. |
| Subsystem adapters are injected as `[any AdaptiveSubsystemAdapting]` | Follows the project's protocol-array pattern (compare `Tests/Helpers/Streaming/MockX.swift`). Easy to mock. |
| PowerMode override + auto-derivation coexist | Default `.auto` derives from system state each tick; user-set `.performance` / `.balanced` / `.battery` skips derivation. State is recoverable on app restart via UserDefaults (out of scope for v1; structure is in place). |
| Augment `PerformanceMonitor.startResourceMonitoring()` instead of writing a parallel CPU sampler | Avoids two ProcessInfo probes; consistent CPU state. The existing stub becomes a real sampler using `host_processor_info`. |
| GPU usage is sampled opportunistically | macOS doesn't expose GPU usage uniformly; we sample `MTLDevice.currentAllocatedSize` or skip when unavailable and document. The optimizer treats GPU-as-unknown gracefully (no false positives). |
| Thermal response uses the existing `SystemState.ThermalState` scale (nominal / fair / serious / critical) | Maps directly to `ProcessInfo.ThermalState`. No new scale. |
| Validation criteria that depend on real hardware (CPU<5%, battery<10%/hr) are NOT tested in unit tests | They are acceptance criteria for QA; unit tests cover the *contract* that triggers them. |
| QualityAction is an enum, not a struct of optionals | Easier to switch over, exhaustively test in `AdaptiveQualityController`, and forward-compatible (new cases don't ripple through optionals). |

## Architecture & Data Flow

```
                              PlaybackSession
                              ───────────────
                              │ owns PerformanceOptimizer
                              │ owns existing monitors/managers
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                   PerformanceOptimizer  (@MainActor, ObservableObject)  │
│                                                                         │
│   @Published powerMode: PowerMode                                       │
│   @Published thermalState: ProcessInfo.ThermalState                     │
│   @Published currentActions: [QualityAction]                            │
│   @Published prediction: ResourcePrediction                             │
│   @Published batteryState: BatteryState                                 │
│                                                                         │
│   private predictor: ResourcePredictor   (pure, deterministic)          │
│   private controller: AdaptiveQualityController  (pure, deterministic)  │
│   private history: PlaybackHistory        (rolling ring buffer)         │
│   private adapters: [any AdaptiveSubsystemAdapting]                     │
│   private monitor: any PerformanceMonitorProtocol                       │
│   private networkMonitor: any NetworkMonitorProtocol                    │
└──────┬───────────────┬───────────────────┬───────────────────┬──────────┘
       │ reads         │ reads             │ reads             │ applies
       ▼               ▼                   ▼                   ▼
 ┌───────────┐  ┌──────────────┐  ┌────────────────────┐  ┌────────────────┐
 │ Perform-  │  │  Network     │  │ PlaybackHistory    │  │ Subsystem      │
 │ anceMonitor│  │  Monitor     │  │ (in-memory)        │  │ Adapters      │
 │ (System-  │  │ (reach,      │  │                    │  │  - Decoder     │
 │  State,    │  │  thermal)    │  │                    │  │  - Renderer    │
 │  Metrics)  │  │              │  │                    │  │  - Streaming   │
 │            │  │              │  │                    │  │  - Audio       │
 │            │  │              │  │                    │  └────────────────┘
 └───────────┘  └──────────────┘  └────────────────────┘
       ▲
       │ adds _testInject seam + real CPU sampler
       │ (modification, not replacement)
```

**Data flow per tick (driven by ProcessInfo notifications + a 60s timer + PlaybackSession's `playState` transitions):**

1. Capture current `systemState`, `metrics`, `powerMode`, current `PlaybackSettings` (codec / resolution / fps / decoder / streaming ABR).
2. Append a sample to `PlaybackHistory`.
3. `predictor.predict(history:, currentSettings:) → ResourcePrediction`.
4. `controller.evaluate(systemState:, prediction:, metrics:, mode:, settings:) → [QualityAction]`.
5. `optimizeForCurrentState()` derives new `powerMode` if currently `.auto`.
6. For each `QualityAction` in the recommendation set, walk to the matching `AdaptiveSubsystemAdapting` adapter; adapter applies or no-ops.
7. Publish updated `powerMode`, `prediction`, `currentActions` to UI.

Tick sources:

- `PerformanceMonitor` notification observer (thermalState, low-power) — immediate.
- `NetworkMonitor.$thermalState` Combine stream — immediate (it now matches ProcessInfo too).
- `engine.$playbackRate`, `streaming.$currentQuality`, decoder switch events — immediate.
- Internal 60-second timer — for prediction refresh.

## Components

| Component | File | Public API summary |
|---|---|---|
| `PerformanceOptimizer` | `Core/Performance/PerformanceOptimizer.swift` | `@MainActor final class : ObservableObject`; `init(monitor:, networkMonitor:, history:, adapter:); observe(); optimizeForCurrentState(); forcePowerMode(_:)`; published `powerMode`, `thermalState`, `prediction`, `currentActions`. |
| `PowerMode` | `Core/Performance/PowerMode.swift` | `enum .auto, .performance, .balanced, .battery, .unknown`; `init(userChoice:systemState:lowPowerMode:)`. |
| `ResourcePrediction` | `Core/Performance/ResourcePrediction.swift` | `struct: cpuUsageEstimate, memoryMBEstimate, batteryDrainPctPerHour, thermalRiskScore, confidence`; static `.zero`. |
| `PlaybackHistory` | `Core/Performance/PlaybackHistory.swift` | Ring buffer of `PlaybackSample`; `append(_:)`, `recent(seconds:)`, `samplesPerSecond()`; bounded (5 min default). |
| `PlaybackSample` | same file | `struct`: timestamp, decoderName, resolution, fps, frameDropRate, thermalState, powerMode, codecName. |
| `ResourcePredictor` | `Core/Performance/ResourcePredictor.swift` | `predict(history:, currentSettings:) -> ResourcePrediction`. Pure. |
| `AdaptiveQualityController` | `Core/Performance/AdaptiveQualityController.swift` | `evaluate(...) -> [QualityAction]`. Pure. |
| `QualityAction` | `Core/Performance/QualityAction.swift` | `enum .preferHardware(Bool), .downscaleRenderTo(ResolutionCap), .streamPreferBitrate(Int), .reduceAudioComplexity(AudioMode), .deferPrefetch(seconds:Int)`. |
| `ResolutionCap` | same file | `enum .original, .p2160, .p1080, .p720` (resolution caps in pixels). |
| `AudioMode` | same file | `enum .full, .simplified` (HRTF on/off). |
| `AdaptiveSubsystemAdapting` | `Core/Performance/SubsystemAdapters.swift` | Protocol seam: `apply(_ actions:, context:)`. |
| `DecoderAdapter`, `RenderAdapter`, `StreamingAdapter`, `AudioAdapter` | same file | Production adapters wiring to existing types through new seams (`AdaptiveDecoderManager.forcePreference(_:)`, `MetalRenderer.setResolutionCap(_:)`, `StreamingManager.setPreferredPeakBitRate(_:)`, `AudioEngine.setComplexityMode(_:)`). |
| `PerformanceMonitorProtocol` | `Core/Performance/PerformanceMonitorProtocol.swift` | Read-only view of `PerformanceMonitor`: `currentSystemState`, `recentMetrics`. |
| `PerformanceContext` | `Core/Performance/PerformanceContext.swift` | Snapshot passed to adapters (systemState + metrics). |

**Modified existing files:**

| File | Change |
|---|---|
| `Core/Decoders/VideoDecoder/Utilities/PerformanceMonitor.swift` | (1) Add `_testInject(state: SystemState)` + `_testInject(metrics: PerformanceMetrics)` seams. (2) Implement `startResourceMonitoring()` to sample CPU via `MachHostCpuLoadInfo`-equivalent (or `host_processor_info` via `Darwin`) every 5s; only CPU is implemented; GPU stays at 0 with a documented comment. (3) Conform `PerformanceMonitor` to `PerformanceMonitorProtocol`. |
| `Core/Decoders/VideoDecoder/Manager/AdaptiveDecoderManager.swift` | Add public `forcePreference(_ preference: DecoderPreference?)` so `DecoderAdapter` can bias selection (preferred/hw/neutral). Selection still uses `DecoderSelector`; preference is a tie-breaker. |
| `Core/Streaming/StreamingManager.swift` | Add public `setPreferredPeakBitrate(_ bitrate: Int)` writing to `player.currentItem?.preferredPeakBitRate`. |
| `Core/Renderers/MetalRenderer.swift` | Add public `setResolutionCap(_ cap: ResolutionCap)` short-circuit: render to a scaled-down intermediate texture when cap < `.original`. (Implementation note: only honors `.p2160 / .p1080 / .p720`; `.original` is the no-op default.) |
| `Core/Engine/Audio/AudioEngine.swift` | Add public `setComplexityMode(_ mode: AudioMode)` that toggles HRTF on/off. |
| `UI/Session/PlaybackSession.swift` | Add `let performance: PerformanceOptimizer` initialized similarly to `streaming`, `displayManager`, `airPlayController`; call `performance.observe(playState:)` on state changes; bind published values if any UI badge is added (out of scope for v1). |

### PerformanceMonitorProtocol

```swift
public protocol PerformanceMonitorProtocol: AnyObject {
    var currentSystemState: SystemState { get }
    var recentMetrics: PerformanceMetrics { get }
}

extension PerformanceMonitor: PerformanceMonitorProtocol {}
```

### PowerMode

```swift
public enum PowerMode: String, Sendable, Equatable, Codable {
    case auto        // derive from system state every tick
    case performance // user override; ignore thermal unless .critical
    case balanced    // user override; normal rules
    case battery     // user override; aggressive throttling
    case unknown     // initial state pre-observation
}

public extension PowerMode {
    init(userChoice: PowerMode, systemState: SystemState, isExternalPower: Bool) {
        switch userChoice {
        case .auto, .unknown:
            self = PowerMode.derived(from: systemState, isExternalPower: isExternalPower)
        default:
            self = userChoice
        }
    }

    static func derived(from state: SystemState, isExternalPower: Bool) -> PowerMode {
        if state.isLowPowerMode { return .battery }
        if state.batteryState == .discharging && state.batteryLevel < 0.20 { return .battery }
        if state.thermalState == .critical { return .battery }
        if isExternalPower && state.thermalState != .critical { return .performance }
        switch state.thermalState {
        case .nominal: return .performance
        case .fair:    return .balanced
        case .serious: return .balanced
        case .critical:return .battery
        }
    }
}
```

### ResourcePrediction

```swift
public struct ResourcePrediction: Sendable, Equatable {
    public var cpuUsageEstimate: Double      // 0...1
    public var memoryMBEstimate: Int          // MB; 0 if unknown
    public var batteryDrainPctPerHour: Double // %/hr; 0 if invalid
    public var thermalRiskScore: Double       // 0...1
    public var confidence: Double             // 0...1; 0 if <5 samples

    public static let zero = ResourcePrediction(
        cpuUsageEstimate: 0, memoryMBEstimate: 0,
        batteryDrainPctPerHour: 0, thermalRiskScore: 0, confidence: 0
    )
}
```

### QualityAction

```swift
public enum QualityAction: Sendable, Equatable, Hashable {
    case preferHardware(Bool)
    case downscaleRenderTo(ResolutionCap)
    case streamPreferBitrate(Int)     // bits per second
    case reduceAudioComplexity(AudioMode)
    case deferPrefetch(seconds: Int)
}

public enum ResolutionCap: Sendable, Equatable, Hashable, Codable {
    case original
    case p2160
    case p1080
    case p720

    public var maxPixels: Int? {
        switch self {
        case .original: return nil
        case .p2160:    return 3840 * 2160
        case .p1080:    return 1920 * 1080
        case .p720:     return 1280 *  720
        }
    }
}

public enum AudioMode: Sendable, Equatable, Hashable, Codable {
    case full        // HRTF + spatial
    case simplified  // stereo downmix, HRTF off
}
```

### AdaptiveQualityController (rules — codified in implementation)

```
Inputs:  systemState, prediction, metrics, mode, settings
Output:  [QualityAction]   (deduplicated ordered list)

Rules (priority order; first match wins per slot):

(1) Decoder bias
    if metrics.isDegraded && settings.decoderIsHW && systemState.thermalState != .nominal
       emit .preferHardware(false)
    if mode == .battery && settings.decoderIsHW
       emit .preferHardware(false)
    if mode == .performance && !settings.decoderIsHW && systemState.thermalState == .nominal
       emit .preferHardware(true)

(2) Render resolution cap
    if prediction.thermalRiskScore > 0.7 || mode == .battery
       && settings.pixels > cap.maxPixels
       emit .downscaleRenderTo(.p1080)
    if mode == .battery && settings.pixels > .p720.maxPixels
       emit .downscaleRenderTo(.p720)
    (never downscale when mode == .performance)

(3) Streaming bitrate cap
    if prediction.thermalRiskScore > 0.5 && settings.isStreaming
       emit .streamPreferBitrate(min(currentBitrate, 5_000_000))   // ~5 Mb/s in v1
    if mode == .battery && settings.isStreaming
       emit .streamPreferBitrate(min(currentBitrate, 2_500_000))   // ~2.5 Mb/s in v1

(4) Audio complexity
    if (mode == .battery || prediction.thermalRiskScore > 0.6)
       && settings.audioEngineActive
       emit .reduceAudioComplexity(.simplified)

(5) Prefetch deferral
    if metrics.frameDropRate > 0.05
       emit .deferPrefetch(seconds: 2)
```

The controller is a pure function — no Combine, no callbacks, no side-effects.

### ResourcePredictor (rules)

`predict(history:, currentSettings:) → ResourcePrediction` rolling-window stats:

- Sample window: last 60 seconds OR last 60 samples (whichever is shorter).
- `cpuUsageEstimate` = mean+1.5*stdev of `systemState.cpuUsage` over window; clamp [0,1].
- `memoryMBEstimate` = median of `(resolution.width * resolution.height * bytes-per-pixel-for-decoder-type)` heuristic; v1 uses `resolution.pixelCount / 1024 / 1024 / 6` as a coarse proxy so the value tracks the actual workload; if insufficient samples, return 0.
- `batteryDrainPctPerHour` = linear-regression slope of `(batteryLevel, time)` over window, only valid when `batteryState == .discharging` and at least 10 samples; otherwise 0.
- `thermalRiskScore` = base from `systemState.thermalState` (`nominal=0, fair=0.3, serious=0.7, critical=1.0`) + 0.2 if `cpuUsageEstimate > 0.7`; clamp [0,1].
- `confidence` = `min(1, samples / 60)`.

All inputs are pure values; all outputs are pure values.

### SubsystemAdapters

```swift
public protocol AdaptiveSubsystemAdapting: AnyObject {
    func apply(_ actions: [QualityAction], context: PerformanceContext)
}
```

Productions:

- `DecoderAdapter` — holds weak `AdaptiveDecoderManager`; on `.preferHardware(Bool)` calls `forcePreference(_:)`. Idempotent — if already in requested state, no-op.
- `RenderAdapter` — holds weak renderer (any `MetalRendererProtocol`-seamed target cap setter; v1 uses `MetalRenderer` directly via a small protocol extension `MetalRendererCapApplying`). On `.downscaleRenderTo(_)` calls `setResolutionCap(_:)`.
- `StreamingAdapter` — holds weak `StreamingManager`; on `.streamPreferBitrate(_)` calls `setPreferredPeakBitrate(_:)`.
- `AudioAdapter` — holds weak `AudioEngine`; on `.reduceAudioComplexity(_)` calls `setComplexityMode(_:)`.

Adapters receive *all* actions and decide which they care about. Actions they don't handle are ignored — no error, no warning log spam.

`PerformanceOptimizer.apply(actions:)` walks adapters in registration order; each adapter's idempotence means re-applying is cheap.

## Behavior Specification

### `PerformanceOptimizer.optimizeForCurrentState()`

1. Read `monitor.currentSystemState`, `networkMonitor.thermalState` (prefer network's since it polls ProcessInfo), `monitor.recentMetrics`.
2. Read current PlaybackSettings (captured via `observe(engineState:)` or queried from collaborators — see Integration).
3. Append a `PlaybackSample` to `history`.
4. Call `predictor.predict(...)` → `prediction`.
5. Compute new `powerMode` via `PowerMode(userChoice: self.userChoice, systemState:, isExternalPower:)`.
6. Call `controller.evaluate(...)` → `[QualityAction]`.
7. Apply actions via `adapters`.
8. Publish `powerMode`, `prediction`, `currentActions`, `thermalState`, `batteryState` (assigning into `@MainActor` self).

### `PerformanceOptimizer.forcePowerMode(_ mode:)`

User override setter. When set to anything other than `.auto`, derivation is skipped. To return to auto, call with `.auto`. Persisted across ticks; **not** persisted across launches in v1 (a future prompt persists via UserDefaults).

### `PerformanceMonitor.startResourceMonitoring()` (modified)

- Add `host_processor_info` polling via Mach (Darwin). Sample at 5s same cadence as thermal timer.
- Update `currentSystemState.cpuUsage`. (GPU stays a documented `0`.)
- Subject to the existing `NSLock` on `currentSystemState`.

### `AdaptiveDecoderManager.forcePreference(_:)`

- Stored on the manager; `DecoderSelector.calculateScore` reads it for tie-break (+5 if matches preference direction).
- `nil` is neutral (current behavior).
- Matches today's `_decodeStateActor` threading (preference is read during score call; safe).

### `StreamingManager.setPreferredPeakBitrate(_:)`

- Sets `player.currentItem?.preferredPeakBitRate` (Double). Idempotent.
- No-op when `player` is nil; no-op when value already set.

### `MetalRenderer.setResolutionCap(_:)`

- Forces an intermediate texture of at most `cap.maxPixels` pixels (rounded to nearest power-of-two dimension square, capped by an aspect-preserving scale).
- Implements only the codec/decoder output view; per-frame scale uniforms route through the same shader pipeline.
- `.original` releases the intermediate (back to native).
- Out of scope: per-source-frame scaling evaluation; v1 switches at the next frame after the call.

### `AudioEngine.setComplexityMode(_:)`

- `.full` → enables HRTF + spatial mix.
- `.simplified` → bypasses HRTF, downmixes to stereo (4-channel + height maintained for compatibility, but no spatialization).

## Integration Touchpoints

| Existing | Where | Change |
|---|---|---|
| `PerformanceMonitor` | `Core/Decoders/VideoDecoder/Utilities/PerformanceMonitor.swift` | Add `_testInject`, conform to protocol, implement CPU sampler. |
| `AdaptiveDecoderManager` | `Core/Decoders/VideoDecoder/Manager/AdaptiveDecoderManager.swift` | Add `forcePreference(_:)`. |
| `StreamingManager` | `Core/Streaming/StreamingManager.swift` | Add `setPreferredPeakBitrate(_:)`. |
| `MetalRenderer` | `Core/Renderers/MetalRenderer.swift` | Add `setResolutionCap(_:)`. |
| `AudioEngine` | `Core/Engine/Audio/AudioEngine.swift` | Add `setComplexityMode(_:)`. |
| `PlaybackSession` | `UI/Session/PlaybackSession.swift:46` | Add `let performance: PerformanceOptimizer`, init from `PerformanceOptimizer.makeDefault()`, call `observe(playState:)` from `openFile`, `play`, `pause`, `stop`, `seek` paths. |

`PerformanceOptimizer.makeDefault()` constructs the production Pipeline:

```swift
public static func makeDefault() -> PerformanceOptimizer {
    PerformanceOptimizer(
        monitor: PerformanceMonitor(),
        networkMonitor: NetworkMonitor(),
        adapters: [
            DecoderAdapter(),
            RenderAdapter(),
            StreamingAdapter(),
            AudioAdapter()
        ]
    )
}
```

### Why `observe(playState:)` rather than a continuous timer?

`observe(playState:)` captures settings (codec, resolution, fps, decoder, streaming ABR) at the moment they change. The optimizer's `optimizeForCurrentState()` already runs on a 60s timer + immediate ProcessInfo notifications — no new ticks are needed for playback state changes; `observe(playState:)` simply pushes a fresh `currentSettings` snapshot to the optimizer so the *next* optimize-for-state uses the right decoder/resolution.

## Testing Strategy

Following the project's `Tests/Streaming/` pattern: mocks in `Tests/Helpers/Performance/`, one test file per component. Every behavior **must** map to a named test below; all tests are unit tests and use protocol seams only.

### Tests

| File | Test method | Behavior |
|---|---|---|
| `PowerModeTests.swift` | `test_derive_auto_returns_performance_for_nominal_plugged_in` | Auto derivation: nominal + plugged → performance. |
| | `test_derive_auto_returns_battery_when_low_power_mode_enabled` | `isLowPowerMode == true` → battery. |
| | `test_derive_auto_returns_battery_when_battery_low_unplugged` | discharging < 20% → battery. |
| | `test_derive_auto_returns_battery_when_thermal_critical` | thermal critical → battery. |
| | `test_derive_auto_returns_balanced_for_fair_thermal` | fair + discharging → balanced. |
| | `test_user_choice_performance_overrides_thermal_fair` | User-set `.performance` ignores fair thermal. |
| | `test_user_choice_battery_overrides_plugged_in` | User-set `.battery` ignored power source. |
| | `test_user_choice_none_falls_back_to_auto` | `userChoice == .unknown` → auto. |
| `ResourcePredictionTests.swift` | `test_predict_returns_zero_for_empty_history` | No samples → zero prediction, zero confidence. |
| | `test_predict_cpu_estimate_uses_mean_plus_stdev` | CPU stat formula. |
| | `test_predict_battery_drain_only_when_discharging` | Charging → 0 drain. |
| | `test_predict_thermal_risk_clamped_at_one` | Clamp upper bound. |
| | `test_predict_confidence_scales_with_samples` | 30 samples → 0.5 confidence. |
| `PlaybackHistoryTests.swift` | `test_history_appends_and_trims_max_samples` | Ring-buffer trim. |
| | `test_history_recent_filters_within_window` | Window filter. |
| | `test_history_thread_safe_concurrent_appends` | Append from multiple threads (using `XCTestExpectation`). |
| `AdaptiveQualityControllerTests.swift` | `test_emits_prefer_hardware_false_when_metrics_degraded_and_thermal_fair` | Rule 1a. |
| | `test_emits_prefer_hardware_false_for_battery_mode` | Rule 1b. |
| | `test_emits_prefer_hardware_true_for_performance_mode_nominal` | Rule 1c. |
| | `test_emits_downscale_to_1080_for_high_thermal_risk_with_existing_4k` | Rule 2a. |
| | `test_emits_downscale_to_720_for_battery_mode` | Rule 2b. |
| | `test_does_not_downscale_for_performance_mode` | Rule 2 negative. |
| | `test_emits_stream_prefer_bitrate_for_high_thermal_risk_streaming` | Rule 3a. |
| | `test_emits_stream_prefer_bitrate_for_battery_streaming` | Rule 3b. |
| | `test_emits_reduce_audio_complexity_for_battery_mode` | Rule 4. |
| | `test_emits_defer_prefetch_for_high_frame_drop_rate` | Rule 5. |
| | `test_returns_no_actions_when_balanced_and_nominal` | All clean: zero actions. |
| | `test_returns_deduplicated_action_list` | Same action twice → one in output. |
| | `test_returns_actions_in_priority_order` | Multi-rule evaluation: order matches spec. |
| `PerformanceOptimizerTests.swift` | `test_init_does_not_crash_with_default_adapters` | Init happy path. |
| | `test_optimize_for_current_state_publishes_power_mode` | tick → `powerMode` published. |
| | `test_optimize_appies_actions_through_adapters_in_order` | Order respected; mock adapter records calls. |
| | `test_optimize_for_critical_thermal_applies_downscale_then_bitrate` | Sequence under critical state. |
| | `test_force_power_mode_overrides_auto_derivation_on_next_tick` | User override path. |
| | `test_optimize_returns_idempotent_when_state_unchanged` | Same inputs → no adapter calls. (Adapters are idempotent; verify by mock call-count.) |
| | `test_history_appends_a_sample_per_optimize_call` | History grows. |
| `PerformanceMonitorSeamTests.swift` | (in `PerformanceMonitorTests.swift`) `test_inject_state_overrides_current` | New test seam works. |
| | `test_inject_metrics_overrides_recent` | Same. |
| | `test_cpu_sampler_updates_system_state_cpu_usage` | Sampler path: spin a run-loop tick, observe CPU update. |
| `DecoderAdapterTests.swift` | `test_apply_prefer_hardware_false_calls_force_preference` | Adapter forwards correctly. |
| | `test_apply_ignores_unhandled_actions` | Streaming actions ignored by decoder adapter. |
| `RenderAdapterTests.swift` | `test_apply_downscale_calls_set_resolution_cap_with_same_value` | Renderer cap forwarded. |
| `StreamingAdapterTests.swift` | `test_apply_stream_prefer_bitrate_calls_set_preferred_peak_bitrate` | bitrate forwarded. |
| `AudioAdapterTests.swift` | `test_apply_reduce_audio_complexity_calls_set_complexity_mode` | audio mode forwarded. |
| `PerformanceIntegrationTests.swift` | `test_optimize_chain_reaches_decoder_for_critical_thermal` | End-to-end through mocks: `PerformanceOptimizer → DecoderAdapter → AdaptiveDecoderManager` mock. |
| | `test_optimize_chain_reaches_renderer_for_battery_mode_4k` | Same chain for renderer. |

Mocks:

- `MockPerformanceMonitor: PerformanceMonitorProtocol`
- `MockNetworkMonitor: NetworkMonitorProtocol`
- `MockDecoderAdapter`, `MockRenderAdapter`, `MockStreamingAdapter`, `MockAudioAdapter`
- `MockAdaptiveDecoderManager` for adapter integration

## Data Model Summary

Final state surfaces (Swift declarations in the components table above):

- `PowerMode` — 5 cases, user/derived.
- `PlaybackSample` — single timestamped sample; 11 fields.
- `ResourcePrediction` — 5 fields, deterministic.
- `QualityAction` — 5 cases.
- `ResolutionCap` — 4 cases with `maxPixels` map.
- `AudioMode` — 2 cases.

## Validation Criteria

### Internal contract (unit-tested)

- [ ] PowerMode derivation follows the rules in §PowerMode.
- [ ] ResourcePrediction is deterministic for given inputs.
- [ ] AdaptiveQualityController emits the action set in §QualityAction rules and in priority order.
- [ ] Subsystem adapters correctly forward and ignore non-matching actions.
- [ ] `PerformanceOptimizer.optimizeForCurrentState()` is idempotent when nothing has changed.
- [ ] User override (`.forcePowerMode`) takes precedence over auto-derivation.
- [ ] `PerformanceMonitor._testInject` makes state and metrics observable from tests.
- [ ] `PerformanceMonitor.startCPUUsageMonitoring` actually populates `cpuUsage` over time.

### Product-level acceptance (NOT unit-tested, verified in QA)

- CPU usage <5% during 4K playback on battery — measured via Instruments CPU profiler; not asserted in unit tests.
- Memory usage stable over 2-hour playback — soak run; not asserted in unit tests.
- Battery drain <10%/hour for 4K content — physical measurement; not asserted in unit tests.
- Thermal throttling handled gracefully — observation: when ProcessInfo reports `.critical` or `.serious`, optimizer downgrades, no frame drops >2% of `metrics.frameDropRate` baseline.
- Quality adaptation prevents frame drops — observation: under thermal stress, frame drop rate stays <2% (current `PerformanceMetrics.isDegraded` threshold) because the controller downscales.

These belong in a QA / soak-test plan, not in unit tests. The contract is: *when those environmental signals change, the optimizer responds*. The hardware-level counts are outside the unit-test surface.

### Code-level success

- `swift build` succeeds with the new files.
- `swift build --build-tests` succeeds modulo the documented XCTest framework unavailability on Command-Line-Tools (per AGENTS.md).
- New files compile cleanly with no warnings (matching the existing repo's strictness).
- No existing test is broken — `PerformanceMonitor`, `AdaptiveDecoderManager`, `StreamingManager`, `MetalRenderer`, `AudioEngine` continue to compile and pass their existing tests.

## Risks

- **Risk:** Augmenting `PerformanceMonitor` with a CPU sampler could theoretically race with the existing thermal observers.
  **Mitigation:** Same `NSLock` already protects `currentSystemState`; sampler takes the lock for its update.
- **Risk:** Subsystem adapters hold weak references to targets that may be deallocated mid-playback.
  **Mitigation:** Adapters no-op when weak ref is `nil`; same pattern used by other adapter classes in the project.
- **Risk:** The `MetalRenderer.setResolutionCap` change is a real rendering pipeline mutation; could affect visual output for unrelated tests.
  **Mitigation:** Cap is opt-in (`.original` by default); existing renderer tests unaffected when no call is made.
- **Risk:** `preferredPeakBitRate` may interact with the access log stats publisher.
  **Mitigation:** Stats publisher reads `observedBitrate` after the fact, not before the cap is set; no conflict.

## Open Questions

None for v1. Items deliberately deferred (potential future prompts):

- Persist `userChoice` across launches via UserDefaults.
- Add a read-only "Power" UI badge in `ControlBar`.
- Replace `ResourcePredictor` with a CoreML-backed predictor behind the same protocol.
- Add frame-rate caps as a new `QualityAction` case.
