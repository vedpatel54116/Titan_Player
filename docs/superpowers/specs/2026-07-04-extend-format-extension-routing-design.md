# Extend Format Extension Routing in MediaPipeline

**Date:** 2026-07-04
**Status:** Approved
**Author:** Agent

## Problem

`shouldUseAVFoundationDirectly` only covers mp4/mov/m4v; `shouldTryFFmpegFirst` only covers flv/mkv. Containers like webm, ts, ogv, wmv, avi, 3gp, and rm fall through to the generic AVFoundation fallback, which often fails for these formats.

## Solution

Introduce a `MediaBackend` enum and a single `backend(for:)` method that replaces both `shouldUseAVFoundationDirectly` and `shouldTryFFmpegFirst`. Expand the FFmpeg-preferred set to cover all containers where FFmpeg demuxes better than AVFoundation.

## Changes

### 1. `MediaBackend` enum (nested in `MediaPipeline`)

```swift
enum MediaBackend {
    case avFoundationDirect
    case ffmpegPreferred
    case avFoundationFallback
}
```

### 2. Updated extension sets

```swift
private static let avFoundationDirectExtensions: Set<String> = ["mp4", "mov", "m4v"]
private static let ffmpegPreferredExtensions: Set<String> = [
    "flv", "mkv", "webm", "ts", "ogv", "wmv", "avi", "3gp", "rm"
]
```

### 3. `backend(for:)` static method

```swift
static func backend(for ext: String) -> MediaBackend {
    if avFoundationDirectExtensions.contains(ext) { return .avFoundationDirect }
    if ffmpegPreferredExtensions.contains(ext) { return .ffmpegPreferred }
    return .avFoundationFallback
}
```

### 4. `openFile` routing refactor

Replace the two sequential `if` blocks with a single `switch` on `backend(for:)`. The three branches preserve existing behavior exactly. The AVFoundation fallback remains the last resort.

### 5. Remove old methods

Delete `shouldUseAVFoundationDirectly(for:)` and `shouldTryFFmpegFirst(for:)`.

### 6. Unit tests

New file: `Tests/Unit/MediaPipelineBackendRoutingTests.swift`

Three test methods:
- `testBackendDirectForMP4` — `.avFoundationDirect` for mp4, mov, m4v
- `testBackendFFmpegPreferredForWebM` — `.ffmpegPreferred` for webm, ts, ogv, wmv, avi, 3gp, rm, flv, mkv
- `testBackendFallbackForUnknown` — `.avFoundationFallback` for unrecognized extensions

## Constraints

- The AVFoundation fallback branch is preserved as the last resort.
- The FFmpeg-fail → AVFoundation-fallback chain is preserved.
- No behavior change for mp4/mov/m4v/flv/mkv.
- Logging already covers the three paths; no new log statements needed.

## Definition of Done

- Opening a .webm or .avi file routes through FFmpeg first.
- Logs confirm `Backend: attempting FFmpeg for webm`.
- Tests cover all three `MediaBackend` assignments.
