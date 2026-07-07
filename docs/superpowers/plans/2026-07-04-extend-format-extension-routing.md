# Extend Format Extension Routing in MediaPipeline — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `shouldUseAVFoundationDirectly`/`shouldTryFFmpegFirst` with a `MediaBackend` enum and `backend(for:)` method, expand FFmpeg-preferred formats, and add unit tests.

**Architecture:** A three-case enum (`avFoundationDirect`, `ffmpegPreferred`, `avFoundationFallback`) consolidates routing logic. `openFile` switches on it. Old boolean methods are removed.

**Tech Stack:** Swift, XCTest

---

## File Map

| File | Action | Purpose |
|------|--------|---------|
| `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift` | Modify | Add `MediaBackend` enum, update extension sets, add `backend(for:)`, refactor `openFile`, remove old methods |
| `TitanPlayer/Tests/Unit/MediaPipelineBackendRoutingTests.swift` | Create | Unit tests for all three backend assignments |

---

### Task 1: Add `MediaBackend` enum and updated extension sets

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift:299-310`

- [ ] **Step 1: Add the `MediaBackend` enum and update the extension sets**

Replace the block at lines 299–310 with:

```swift
    enum MediaBackend {
        case avFoundationDirect
        case ffmpegPreferred
        case avFoundationFallback
    }

    private static let avFoundationDirectExtensions: Set<String> = ["mp4", "mov", "m4v"]
    private static let ffmpegPreferredExtensions: Set<String> = [
        "flv", "mkv", "webm", "ts", "ogv", "wmv", "avi", "3gp", "rm"
    ]

    /// Returns the preferred backend for a given file extension.
    static func backend(for ext: String) -> MediaBackend {
        if avFoundationDirectExtensions.contains(ext) { return .avFoundationDirect }
        if ffmpegPreferredExtensions.contains(ext) { return .ffmpegPreferred }
        return .avFoundationFallback
    }
```

- [ ] **Step 2: Remove the old `shouldUseAVFoundationDirectly` and `shouldTryFFmpegFirst` methods**

Delete the following methods (originally at lines 302–310):

```swift
    /// Standard container formats that AVFoundation handles reliably — bypass FFmpeg entirely.
    static func shouldUseAVFoundationDirectly(for ext: String) -> Bool {
        avFoundationDirectExtensions.contains(ext)
    }

    /// Containers where FFmpeg has better demuxing support — try FFmpeg first, fall back to AVFoundation.
    static func shouldTryFFmpegFirst(for ext: String) -> Bool {
        ffmpegPreferredExtensions.contains(ext)
    }
```

- [ ] **Step 3: Refactor `openFile` to switch on `backend(for:)`**

Replace the two sequential `if` blocks (lines 57–118) with a single `switch`:

```swift
        switch Self.backend(for: ext) {
        case .avFoundationDirect:
            // Standard container formats — skip FFmpeg probing entirely
            logger.info("Backend: AVFoundation (direct) for \(ext, privacy: .public)")
            let avDemuxer = AVFoundationDemuxer()
            do {
                logger.info("Starting AVFoundation demuxing for: \(url.path, privacy: .public)")
                let info = try await avDemuxer.open(url: url)
                self.mediaInfo = info
                timeObserver.duration = info.duration.seconds
                demuxer = avDemuxer
                decoder = AVFoundationDecoder()
                if let videoTrack = info.videoTracks.first {
                    try decoder?.configure(for: videoTrack)
                    logger.info("Decoder configured for video track: \(videoTrack.codec, privacy: .public)")
                }
                phase = .paused
                logger.info("AVFoundation (direct) demuxing completed, state set to paused")
                return
            } catch let error as MediaError {
                let detailed = "\(error.message) — \(ext.uppercased()) file: \(url.lastPathComponent)"
                logger.error("AVFoundation demuxing failed: \(detailed, privacy: .public)")
                throw MediaError(code: error.code, message: detailed)
            }

        case .ffmpegPreferred:
            // Containers where FFmpeg may have better demuxing — try FFmpeg, fall back to AVFoundation
            logger.info("Backend: attempting FFmpeg for \(ext, privacy: .public)")
            let probeDemuxer = FFmpegDemuxer()
            do {
                logger.info("Starting FFmpeg demuxing for: \(url.path, privacy: .public)")
                let info = try await probeDemuxer.open(url: url)
                self.mediaInfo = info
                timeObserver.duration = info.duration.seconds
                logger.info("FFmpeg demuxing successful, \(info.videoTracks.count, privacy: .public) video track(s), \(info.audioTracks.count, privacy: .public) audio track(s)")

                if let videoTrack = info.videoTracks.first, let manager = adaptiveManager {
                    try await manager.configure(for: videoTrack)
                    guard let activeDecoder = manager.activeDecoder else {
                        throw MediaError(code: .decodingFailed, message: "AdaptiveDecoderManager has no active decoder after configure()")
                    }
                    demuxer = probeDemuxer
                    decoder = VideoDecodingAdapter(decoder: activeDecoder)
                    logger.info("Adaptive decoder configured for video track")
                } else {
                    demuxer = probeDemuxer
                    decoder = FFmpegDecoder()
                    logger.info("FFmpeg decoder configured")
                }

                if let videoTrack = info.videoTracks.first {
                    try decoder?.configure(for: videoTrack)
                    logger.info("Decoder configured for video track: \(videoTrack.codec, privacy: .public)")
                }
                logger.info("Backend: FFmpeg succeeded for \(ext, privacy: .public)")
                phase = .paused
                return
            } catch {
                logger.warning("Backend: FFmpeg failed for \(ext, privacy: .public), falling back to AVFoundation — \(error.localizedDescription, privacy: .public)")
                probeDemuxer.close()
            }

        case .avFoundationFallback:
            // Fallback: use AVFoundation
            logger.info("Backend: AVFoundation (fallback) for \(ext, privacy: .public)")
            let avDemuxer = AVFoundationDemuxer()
            do {
                logger.info("Starting AVFoundation (fallback) demuxing for: \(url.path, privacy: .public)")
                let info = try await avDemuxer.open(url: url)
                self.mediaInfo = info
                timeObserver.duration = info.duration.seconds
                demuxer = avDemuxer
                decoder = AVFoundationDecoder()
                if let videoTrack = info.videoTracks.first {
                    try decoder?.configure(for: videoTrack)
                    logger.info("Decoder configured for video track: \(videoTrack.codec, privacy: .public)")
                }
                phase = .paused
                logger.info("AVFoundation (fallback) demuxing completed, state set to paused")
                return
            } catch let error as MediaError {
                let detailed = "\(error.message) — \(ext.uppercased()) file: \(url.lastPathComponent)"
                logger.error("AVFoundation (fallback) demuxing failed: \(detailed, privacy: .public)")
                throw MediaError(code: error.code, message: detailed)
            }
```

- [ ] **Step 4: Build to verify compilation**

Run: `swift build`
Expected: BUILD SUCCEEDED (no errors)

---

### Task 2: Write unit tests for `backend(for:)`

**Files:**
- Create: `TitanPlayer/Tests/Unit/MediaPipelineBackendRoutingTests.swift`

- [ ] **Step 1: Create the test file**

```swift
import XCTest
@testable import TitanPlayer

@MainActor
final class MediaPipelineBackendRoutingTests: XCTestCase {

    func testBackendDirectForStandardContainers() {
        for ext in ["mp4", "mov", "m4v"] {
            XCTAssertEqual(
                MediaPipeline.backend(for: ext),
                .avFoundationDirect,
                "Expected .avFoundationDirect for \(ext)"
            )
        }
    }

    func testBackendFFmpegPreferredForContainersNeedingDemuxing() {
        for ext in ["flv", "mkv", "webm", "ts", "ogv", "wmv", "avi", "3gp", "rm"] {
            XCTAssertEqual(
                MediaPipeline.backend(for: ext),
                .ffmpegPreferred,
                "Expected .ffmpegPreferred for \(ext)"
            )
        }
    }

    func testBackendFallbackForUnrecognizedExtensions() {
        for ext in ["xyz", "abc", "dat", "bin"] {
            XCTAssertEqual(
                MediaPipeline.backend(for: ext),
                .avFoundationFallback,
                "Expected .avFoundationFallback for \(ext)"
            )
        }
    }
}
```

- [ ] **Step 2: Build tests to verify compilation**

Run: `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: Empty output (no errors other than the environmental XCTest one)

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift TitanPlayer/Tests/Unit/MediaPipelineBackendRoutingTests.swift
git commit -m "feat: extend format routing with MediaBackend enum and expanded FFmpeg-preferred extensions

- Add MediaBackend enum (avFoundationDirect, ffmpegPreferred, avFoundationFallback)
- Add backend(for:) static method replacing shouldUseAVFoundationDirectly/shouldTryFFmpegFirst
- Expand ffmpegPreferredExtensions to include webm, ts, ogv, wmv, avi, 3gp, rm
- Refactor openFile to switch on backend(for:)
- Add unit tests covering all three backend assignments"
```
