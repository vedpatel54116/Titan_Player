# Comprehensive Testing Strategy Design

**Date:** 2026-06-30
**Status:** Approved
**Branch:** `feat/testing-strategy`
**Target:** macOS 14+
**Depends on:** existing 103-test corpus, `PerformanceMonitor`, `PerformanceOptimizer`, `PlaybackSession`, `TitanPlayer` executable target.

## Overview

Close the testing gap on TitanPlayer by delivering four coordinated sub-projects:

- **A. Coverage tooling + unit-test gap closure** with an llvm-cov gate.
- **B. Performance benchmark harness** using `XCTMeasure` and per-metric JSON baselines.
- **C. UI interaction tests** in a parallel `TitanPlayer.xcodeproj` driving XCUITest.
- **D. Mac compatibility matrix** via `MacModelIdentifier` and capability-driven tests.

The goal is to make every behavioral claim in TitanPlayer verifiable by an automated, gated test, while honouring the existing architecture (no file moves, SwiftPM remains the canonical build system for the executable).

## Goals & Non-Goals

**Goals**

- Push Swift coverage in `TitanPlayer/TitanPlayer/Core/` to ≥90% via llvm-cov with a CI gate.
- Provide performance benchmarks that fail on regression against explicit per-metric baseline JSON files.
- Provide UI test flows (XCUITest) for play/pause, AirPlay menu, PiP, fullscreen, and HDR badge.
- Provide hardware compatibility detection (model + capabilities) with documented matrix.
- Establish a Makefile-driven workflow (`make test`, `make coverage`, `make benchmarks`, `make ui-tests`).
- Add small public accessors on `PlaybackEngine` (`cpuUsage`, `memoryUsage`) so benchmarks can read live metrics in one place.
- Ship a CI workflow (`.github/workflows/tests.yml`) covering the four lanes.

**Non-Goals (YAGNI)**

- Coverage inside UI/ (60% soft target; explicit untested list documented).
- C-language coverage of FFmpegBuild.
- Hosted Mac lab (MacStadium/BrowserStack) — incompatibilities surfaced via capability tests + manual `M_COMPAT_VALIDATION_LOG.md`.
- Migration of all existing audio test types to a normalized harness.
- Replacing `Tests/Fixtures/test.mp4` corpus.
- Replacing SwiftPM with Xcode-as-primary build system.

## Decisions Log

| Decision | Rationale |
|---|---|
| Four sub-projects sequenced A → B → C → D | A delivers the smallest pivot + biggest near-term coverage win and unblocks B (which reads `engine.cpuUsage` added in A). C and D run in parallel after the A API lands. |
| Parallel `.xcodeproj`, not replacement | UI tests require XCUITest, which SwiftPM does not host natively. Adding a `.xcodeproj` that consumes SwiftPM build artifacts avoids re-architecting the project. |
| Swift sources stay in `TitanPlayer/TitanPlayer/` | Both build systems reference the same files. No source moves; CI enforces parity via a small script. |
| llvm-cov via `swift test --enable-code-coverage` | Keeps SwiftPM as canonical test runner; runs without Xcode; gates on text-export thresholds. |
| `measure {}` + per-metric JSON baselines | Native XCTest ergonomics; baseline tweaks are a config change; nightly-only avoids PR noise. |
| Capability detection beats hardware matrix in CI | CI runners cannot enumerate M2/M3/M4. Tests assert capability flags rather than `MacModelIdentifier` raw values. |
| `PlaybackEngine.cpuUsage` / `.memoryUsage` are real public accessors | The prompt's example references them; without them the benchmarks don't compile. We proxy through `PerformanceMonitor` (`@_testInject`-stubbable). |
| Benchmarks nightly, not per-PR | GitHub Actions macOS runners have high CPU variance. PR-time "smoke" runs one-iteration regression check; full nightly runs detailed metrics. |
| UI tests nightly, not per-PR | XCUITest is slow and fragile in CI; nightly + manual review is the realistic cadence. |
| Tests pass `--enable-code-coverage`; benchmarks in their own target | Benchmark noise pollutes coverage profile; isolate them in `TitanPlayerBenchmarks` to keep coverage clean. |

## Architecture

```
                ┌────────────────────────────────────────────────────────────┐
                │                Tests (103 existing files)                  │
                │  Unit/  Integration/  AudioTests/  Performance/             │
                │  Streaming/  Analysis/  Display/  VideoDecoder/  Helpers/   │
                └────────────────────────────────────────────────────────────┘
                                            │   augmented, never moved
                                            ▼
   ┌──────────────────────────┐    ┌──────────────────────────────────┐
   │  SwiftPM (canonical)     │    │  Parallel .xcodeproj (UI-only)   │
   │                          │    │                                  │
   │  executable TitanPlayer  │ ◀──│  XCUITest target                 │
   │  testTarget TitanPlayerTests │  │ drives SwiftPM-built .app       │
   │  testTarget TitanPlayerBenchmarks│  │ via Run Script build phase   │
   │                          │    │                                  │
   └──────────────────────────┘    └──────────────────────────────────┘
                  ▲                                ▲
                  │  reads                         │  drives
                  │                                │
        ┌─────────┴─────────┐      ┌───────────────┴─────────────┐
        │  llvm-cov gate    │      │  XCUITest flows             │
        │  >=90% Core/      │      │  (open,play,AirPlay,PiP,…)   │
        └───────────────────┘      └─────────────────────────────┘
                  ▲                                ▲
                  └──────────────┬─────────────────┘
                                 │
                       ┌─────────┴──────────┐
                       │ GitHub Actions     │
                       │ tests.yml          │
                       └────────────────────┘
```

## Sub-project A: Coverage & gap closure

- New `Macros/coverage.swift` script + `Makefile` target `coverage`.
- New `TitanPlayer/TitanPlayer/Core/Performance/EnginePerformanceProbe.swift` providing `cpuUsage` / `memoryUsage` for `PlaybackEngine`.
- New `Tests/Performance/EnginePerformanceProbeTests.swift`.
- Gap closure: a sub-agent reads `llvm-cov report` text export and ranks uncovered `public` types in `Core/`; for each, a test file is added under `Tests/Unit/` (or the appropriate subfolder). The plan ships the harness; gap closure is incremental and tracked in PRs.
- New `coverage.threshold.json`: `{ total_pct: 90.0, per_file_min_pct: 70.0 }`.

## Sub-project B: Benchmark harness

- New SwiftPM `executableTarget` `TitanPlayerBenchmarks` at `Benchmarks/Sources/Benchmarks/` (NOT linked into the main executable).
- New `Benchmarks/Sources/Benchmarks/Playback/H264_4K_CPUAndMemory.swift`.
- New `Benchmarks/Sources/Benchmarks/Baselines/playback_4k_h264.json`: `{ cpuCeilingPct: 0.05, memoryCeilingBytes: 500_000_000, iterations: 5 }`.
- New `Benchmarks/Sources/Benchmarks/Helpers/BenchmarkConfig.swift`.
- New `Tests/Performance/Benchmarks/` thin wrappers calling into the benchmark target; `swift test --filter TitanPlayerBenchmarks` runs them.

## Sub-project C: UI test target

- New `TitanPlayer.xcodeproj/` parallel to `TitanPlayer/`.
- XCUITest target `TitanPlayerUITests`.
- Scenarios: `testOpenLocalFileAndPlayPause`, `testAirPlayMenuOpens`, `testPictureInPictureToggles`, `testFullscreenTransitionToggles`, `testHdrBadgeAppears`.
- Accessibility IDs added on `ControlBar`, `PlayerView`, and `AirPlayController` (small coordinated source change).

## Sub-project D: Compatibility matrix

- New `TitanPlayer/TitanPlayer/Core/Hardware/MacModelIdentifier.swift`.
- New `TitanPlayer/TitanPlayer/Core/Hardware/DecoderCapabilities.swift`.
- New `Tests/Hardware/MacModelIdentifierTests.swift` + `Tests/Hardware/DecoderCapabilitiesTests.swift`.
- New `docs/superpowers/specs/M_COMPAT_MATRIX.md` matrix and `docs/M_COMPAT_VALIDATION_LOG.md` checklist.

## CI

- New `.github/workflows/tests.yml` with six jobs: `unit-and-integration`, `coverage-gate`, `benchmarks-smoke`, `benchmarks-full`, `ui-tests`, `compat-smoke`.
- New `Makefile` with `test`, `coverage`, `benchmarks`, `ui-tests`, `compat-smoke`-like targets.

## Validation criteria → tests mapping

The prompt's bullets map as follows (and each is automated in CI + the local Makefile):

| Bullet | Automated gate |
|---|---|
| All unit tests pass consistently | `make test`; CI job green; coverage gate green |
| Performance benchmarks meet targets | `make benchmarks`; CI bot posts regression JSON |
| UI tests cover all user interactions | `make ui-tests`; nightly CI; new AX IDs reviewed in PRs |
| Compatibility tests pass on supported Macs | `make compat-smoke`; manual sign-off via `M_COMPAT_VALIDATION_LOG.md` |
| No memory leaks detected | ASAN env var in `make test`; full ASAN run on release branches |
