# Design: Data-Driven SW Decoder Switching with Hysteresis

**Date:** 2026-07-03
**Status:** Approved
**Replaces:** Unconditional HW→SW flip in AdaptiveQualityController Rule 1

## Problem

AdaptiveQualityController Rule 1 (lines ~35-42) unconditionally forces a software decoder when:
- `cpuUsage > 0.70 && thermalState != .nominal && decoderIsHW`, OR
- `isDegraded && decoderIsHW`

This can degrade performance if the SW decoder is slower than HW under the same load (CODEBASE_CONTEXT §11).

## Solution

Replace the unconditional flip with a data-driven estimator that compares predicted SW decode time against observed HW decode time. Add hysteresis to prevent rapid HW↔SW oscillation.

## Components

### 1. SWDecodeEstimator

**File:** `TitanPlayer/TitanPlayer/Core/Performance/SWDecodeEstimator.swift`

A stateless struct providing codec-aware SW decode time estimation.

**Lookup table** (1080p baseline, seconds):

| Codec  | Base Time |
|--------|-----------|
| h264   | 0.008     |
| hevc   | 0.012     |
| vp9    | 0.015     |
| av1    | 0.020     |
| unknown| 0.012     |

**Resolution scaling:** `estimatedSWTime = baseTime × (pixels / 1080pPixels)`
- 1080p (2,073,600 px): 1.0×
- 4K (8,294,400 px): 4.0×

**Decision logic:**
```swift
func shouldPreferSW(codec: String, resolution: CGSize, hwDecodeTime: TimeInterval) -> Bool
```
Returns `true` only when `hwDecodeTime × 1.5 < estimatedSWTime`. The 1.5× margin accounts for measurement noise and prevents thrashing when HW and SW performance are close.

**Rationale:** SW decode time scales roughly linearly with pixel count. A flat per-codec constant would be wrong for 4K vs 720p content. The 1.5× margin ensures we only switch to SW when it's *clearly* faster.

### 2. Modified Rule 1 in AdaptiveQualityController

**File:** `TitanPlayer/TitanPlayer/Core/Performance/AdaptiveQualityController.swift`

The `cpuHigh && thermalHot && decoderIsHW` branch changes from:

```swift
// Before: unconditional
add(.preferHardware(false), cooldown: decoderSwitchCooldown)
```

To:

```swift
// After: data-driven
if swDecodeEstimator.shouldPreferSW(
    codec: "unknown",
    resolution: settings.resolution,
    hwDecodeTime: metrics.averageDecodeTime
) {
    add(.preferHardware(false), cooldown: decoderSwitchCooldown)
} else {
    add(.downscaleRenderTo(.p1080), cooldown: cooldown)
}
```

When SW would be slower, we downscale render instead — reducing GPU/CPU load without the decoder switch penalty.

**Unchanged paths:**
- `isDegraded && decoderIsHW` branch: still emits `.preferHardware(false)` unconditionally (degraded metrics indicate the current path is already failing)
- `mode == .battery && decoderIsHW` branch: still emits `.preferHardware(false)` unconditionally (battery saving takes priority)

### 3. Hysteresis

**New state in AdaptiveQualityController:**
```swift
private var lastSWSwitchTime: Date?
```

**Modified performance-mode upswitch path:**

Current code:
```swift
if mode == .performance,
   !settings.decoderIsHW,
   systemState.thermalState == .nominal,
   !cpuHigh,
   !isOnCooldown(.preferHardware(true)) {
    add(.preferHardware(true), cooldown: decoderSwitchCooldown)
}
```

New code adds two additional guards:
```swift
if mode == .performance,
   !settings.decoderIsHW,
   systemState.thermalState == .nominal,
   !cpuHigh,
   systemState.cpuUsage < 0.50,
   let lastSW = lastSWSwitchTime,
   Date().timeIntervalSince(lastSW) >= decoderSwitchCooldown,
   !isOnCooldown(.preferHardware(true)) {
    add(.preferHardware(true), cooldown: decoderSwitchCooldown)
}
```

**Conditions for switching back to HW:**
1. `thermalState == .nominal` (already existed)
2. `cpuUsage < 0.50` (new — ensures system has headroom)
3. At least `decoderSwitchCooldown` (10s) elapsed since last SW switch (new — prevents oscillation)
4. Standard cooldown on `.preferHardware(true)` (already existed)

**Tracking:** `lastSWSwitchTime` is set whenever `.preferHardware(false)` is emitted.

### 4. Tests

**File:** `TitanPlayer/Tests/Unit/AdaptiveQualityControllerTests.swift`

Four new tests:

#### `test_hotCPU_thermal_HW_swFasterSwitchesToSW`
- Setup: CPU 0.80, thermal .fair, HW decoder, metrics.averageDecodeTime = 0.020s
- H.264 at 1080p: estimated SW = 0.008s
- 0.020 × 1.5 = 0.030 > 0.008 → SW is faster → expect `.preferHardware(false)`

#### `test_hotCPU_thermal_HW_swSlower_staysHW_downscalesInstead`
- Setup: CPU 0.80, thermal .fair, HW decoder, metrics.averageDecodeTime = 0.003s
- H.264 at 1080p: estimated SW = 0.008s
- 0.003 × 1.5 = 0.0045 < 0.008 → HW is faster → expect `.downscaleRenderTo(.p1080)`, no `.preferHardware(false)`

#### `test_battery_mode_prefersSW`
- Setup: battery mode, HW decoder
- Expect `.preferHardware(false)` regardless of estimate (battery path unchanged)

#### `test_performance_mode_upswitchRequiresCooldown`
- Step 1: Emit `.preferHardware(false)` via degraded metrics + HW decoder
- Step 2: Immediately call evaluate with performance mode, nominal thermal, low CPU
- Expect: no `.preferHardware(true)` (cooldown not elapsed)
- Step 3: Advance time past `decoderSwitchCooldown`, call again
- Expect: `.preferHardware(true)` emitted

## Files Changed

| File | Action |
|------|--------|
| `TitanPlayer/TitanPlayer/Core/Performance/SWDecodeEstimator.swift` | **New** — estimator struct |
| `TitanPlayer/TitanPlayer/Core/Performance/AdaptiveQualityController.swift` | **Modified** — inject estimator, modify Rule 1, add hysteresis state |
| `TitanPlayer/Tests/Unit/AdaptiveQualityControllerTests.swift` | **New** — 4 unit tests |

## Files NOT Changed

- `QualityAction.swift` — enum unchanged per constraint
- `PerformanceOptimizer.swift` — no changes needed (controller is self-contained)
- `PerformanceMonitor.swift` — no changes needed (metrics already exposed)

## Acceptance Criteria

1. All 4 new tests pass
2. All existing `AdaptiveQualityControllerTests` still pass
3. All existing `PerformanceOptimizerTests` still pass
4. `swift build` succeeds
5. Branch: `refactor/adaptive-quality-data-driven`
6. PR created against `main`
