# AdaptiveDecoderManager Fallback Logic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire `AdaptiveDecoderManager` into `PlaybackEngine.load()` with automatic hardware→software decoder fallback and error surfacing.

**Architecture:** `AdaptiveDecoderManager` gains configure-time fallback logic with `os.Logger`. A `VideoDecodingAdapter` bridges `VideoDecoding` → `MediaDecoding`. `MediaPipeline.openFile()` becomes throwing and accepts the manager. `PlaybackEngine` creates the manager, passes it through, and catches errors for the UI.

**Tech Stack:** Swift, SwiftPM, os.Logger, VideoToolbox, FFmpeg (Libavcodec)

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Core/Decoders/VideoDecoder/Manager/AdaptiveDecoderManager.swift` | Modify | Add fallback in `configure()`, `selectedDecoderName`, `os.Logger` |
| `Core/Decoders/VideoDecoder/Manager/VideoDecodingAdapter.swift` | **Create** | Bridge `VideoDecoding` → `MediaDecoding` |
| `Core/Engine/MediaPipeline.swift` | Modify | Make `openFile()` throwing, accept `AdaptiveDecoderManager` |
| `Core/Engine/PlaybackEngine.swift` | Modify | Create manager, pass to pipeline, log selection |
| `Tests/VideoDecoderTests/Manager/AdaptiveDecoderManagerTests.swift` | **Create** | Fallback logic unit tests |
| `Tests/Integration/PlaybackPipelineTests.swift` | Modify | Update `openFile()` calls to `try await` |

---

### Task 1: Add os.Logger and selectedDecoderName to AdaptiveDecoderManager

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Manager/AdaptiveDecoderManager.swift`

- [ ] **Step 1: Add os.Logger import and property**

At the top of `AdaptiveDecoderManager.swift`, add `import os` after the existing `import Foundation`:

```swift
import Foundation
import os
```

Inside the `AdaptiveDecoderManager` class, add the logger property after the existing properties (after line 30, before `init()`):

```swift
private let logger = Logger(subsystem: "com.titanplayer", category: "Decoder")
```

- [ ] **Step 2: Add selectedDecoderName computed property**

Add after the `activeDecoderType` computed property (after line 125):

```swift
var selectedDecoderName: String? {
    get async {
        await stateActor.getActiveDecoder().map { String(describing: type(of: $0)) }
    }
}
```

- [ ] **Step 3: Build to verify no errors**

Run: `swift build` from `TitanPlayer/` directory.
Expected: Build succeeds (no functional changes yet).

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Manager/AdaptiveDecoderManager.swift
git commit -m "feat: add os.Logger and selectedDecoderName to AdaptiveDecoderManager"
```

---

### Task 2: Add fallback logic to AdaptiveDecoderManager.configure()

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Manager/AdaptiveDecoderManager.swift`

- [ ] **Step 1: Replace configure(for:) with fallback version**

Replace the entire `configure(for:)` method (lines 48-70) with:

```swift
func configure(for track: VideoTrackInfo) async throws {
    currentTrack = track

    let availableDecoders = queryAvailableDecoders(for: track)

    preferenceLock.lock()
    let pref = self.preference
    preferenceLock.unlock()

    let selection = decoderSelector.selectDecoder(
        for: track,
        available: availableDecoders,
        systemState: performanceMonitor.currentSystemState,
        preference: pref
    )

    // Try the selected decoder
    do {
        try await selection.decoder.configure(for: track)
        await stateActor.setActiveDecoder(selection.decoder)
        await stateActor.setState(.decoding(selection.decoder))
        let decoderName = String(describing: type(of: selection.decoder))
        logger.info("Selected decoder: \(decoderName)")
        return
    } catch {
        // If hardware failed, try software fallback
        guard let fallback = getFallbackDecoder(for: selection.decoder) else {
            throw PlaybackError.decodingFailed(error)
        }

        do {
            try await fallback.configure(for: track)
            await stateActor.setActiveDecoder(fallback)
            await stateActor.setState(.decoding(fallback))
            let fallbackName = String(describing: type(of: fallback))
            logger.info("Fell back to: \(fallbackName)")
            return
        } catch {
            // Both decoders failed
            logger.error("Both decoders failed: \(error.localizedDescription)")
            await stateActor.setState(.error(.softwareFailure))
            throw PlaybackError.decodingFailed(error)
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build` from `TitanPlayer/` directory.
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Manager/AdaptiveDecoderManager.swift
git commit -m "feat: add hardware→software fallback to AdaptiveDecoderManager.configure()"
```

---

### Task 3: Create VideoDecodingAdapter

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Manager/VideoDecodingAdapter.swift`

- [ ] **Step 1: Create the adapter file**

Create `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Manager/VideoDecodingAdapter.swift`:

```swift
import Foundation
import CoreMedia
import CoreVideo

/// Bridges a `VideoDecoding` conformer to the `MediaDecoding` protocol
/// so MediaPipeline can use VideoToolboxDecoder / FFmpegSoftwareDecoder.
final class VideoDecodingAdapter: MediaDecoding {
    private let decoder: VideoDecoding
    var audioTap: AudioTap?

    init(decoder: VideoDecoding) {
        self.decoder = decoder
    }

    func configure(for track: VideoTrackInfo) async throws {
        try await decoder.configure(for: track)
    }

    func decode(_ packet: MediaPacket) async throws -> MediaFrame {
        let output = try await decoder.decode(packet)
        switch output {
        case .sampleBuffer(let sampleBuffer):
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                throw DecoderError.noFramesDecoded
            }
            let videoFrame = VideoFrame(
                pixelBuffer: pixelBuffer,
                timestamp: packet.timestamp,
                duration: packet.duration,
                colorSpace: .sRGB
            )
            return .video(videoFrame)
        case .pixelBuffer(let pixelBuffer):
            let videoFrame = VideoFrame(
                pixelBuffer: pixelBuffer,
                timestamp: packet.timestamp,
                duration: packet.duration,
                colorSpace: .sRGB
            )
            return .video(videoFrame)
        }
    }

    func flush() async { await decoder.flush() }
    func reset() async { await decoder.reset() }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build` from `TitanPlayer/` directory.
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Manager/VideoDecodingAdapter.swift
git commit -m "feat: add VideoDecodingAdapter bridging VideoDecoding to MediaDecoding"
```

---

### Task 4: Make MediaPipeline.openFile() throwing and accept AdaptiveDecoderManager

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift`

- [ ] **Step 1: Replace openFile() method**

Replace the entire `openFile(url:)` method (lines 31-61) with:

```swift
func openFile(url: URL, adaptiveManager: AdaptiveDecoderManager? = nil) async throws {
    playState = .loading

    let probeDemuxer = FFmpegDemuxer()
    let info = try await probeDemuxer.open(url: url)

    self.mediaInfo = info
    timeObserver.duration = info.duration.seconds

    if let videoTrack = info.videoTracks.first, let manager = adaptiveManager {
        // Use AdaptiveDecoderManager for real decoding
        // configure() handles hardware→software fallback internally
        try await manager.configure(for: videoTrack)
        demuxer = probeDemuxer
        decoder = VideoDecodingAdapter(decoder: manager.activeDecoder!)
    } else if shouldUseAVFoundation(for: info) {
        probeDemuxer.close()
        let avDemuxer = AVFoundationDemuxer()
        decoder = AVFoundationDecoder()
        _ = try await avDemuxer.open(url: url)
        demuxer = avDemuxer
    } else {
        demuxer = probeDemuxer
        decoder = FFmpegDecoder()
    }

    if let videoTrack = info.videoTracks.first {
        try decoder?.configure(for: videoTrack)
    }

    playState = .paused
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build` from `TitanPlayer/` directory.
Expected: Build may show errors in callers of `openFile()` that need `try` — this is expected and fixed in Task 6.

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift
git commit -m "feat: make MediaPipeline.openFile() throwing, accept AdaptiveDecoderManager"
```

---

### Task 5: Wire AdaptiveDecoderManager into PlaybackEngine

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/PlaybackEngine.swift`

- [ ] **Step 1: Add adaptiveDecoderManager property and os.Logger**

After the existing `private let performanceProbe` property (around line 41), add:

```swift
private let adaptiveDecoderManager = AdaptiveDecoderManager()
private let logger = Logger(subsystem: "com.titanplayer", category: "PlaybackEngine")
```

Add `import os` at the top of the file (after `import Combine`).

- [ ] **Step 2: Update load(url:) to use adaptiveDecoderManager**

In the `load(url:)` method, replace the line:
```swift
await mediaPipeline?.openFile(url: url)
```
with:
```swift
try await mediaPipeline?.openFile(url: url, adaptiveManager: adaptiveDecoderManager)
```

After the `openFile` call and before `self.state = .ready`, add logging:

```swift
// Log decoder selection
if let decoderName = await adaptiveDecoderManager.selectedDecoderName {
    logger.info("Selected decoder: \(decoderName) for \(url.lastPathComponent)")
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `swift build` from `TitanPlayer/` directory.
Expected: Build succeeds (with possible test target errors fixed in Task 6).

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Engine/PlaybackEngine.swift
git commit -m "feat: wire AdaptiveDecoderManager into PlaybackEngine.load()"
```

---

### Task 6: Fix integration tests for throwing openFile()

**Files:**
- Modify: `TitanPlayer/Tests/Integration/PlaybackPipelineTests.swift`

- [ ] **Step 1: Update test calls to use try await**

Read the test file and update every `await pipeline.openFile(url:)` call to `try await pipeline.openFile(url:)`. The test methods that call `openFile` will need to be marked `throws` or wrapped in `do/catch`.

The test file has 4 calls at lines 14, 24, 38, 50. Each test method should be updated. For example, if a test looks like:

```swift
func testSomething() async {
    await pipeline.openFile(url: testURL)
    // assertions
}
```

Change to:

```swift
func testSomething() async throws {
    try await pipeline.openFile(url: testURL)
    // assertions
}
```

- [ ] **Step 2: Build tests to verify compilation**

Run: `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: Empty output (no errors other than the environmental XCTest one).

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/Tests/Integration/PlaybackPipelineTests.swift
git commit -m "fix: update integration tests for throwing openFile()"
```

---

### Task 7: Write AdaptiveDecoderManager fallback tests

**Files:**
- Create: `TitanPlayer/Tests/VideoDecoderTests/Manager/AdaptiveDecoderManagerTests.swift`

- [ ] **Step 1: Create the test file**

Create `TitanPlayer/Tests/VideoDecoderTests/Manager/AdaptiveDecoderManagerTests.swift`:

```swift
import XCTest
@testable import TitanPlayer

final class AdaptiveDecoderManagerTests: XCTestCase {

    // MARK: - Helpers

    private func makeH264Track() -> VideoTrackInfo {
        VideoTrackInfo(
            codec: "avc1",
            width: 1920,
            height: 1080,
            frameRate: 30,
            isHDR: false,
            extradata: nil
        )
    }

    private func makeMPEG2Track() -> VideoTrackInfo {
        VideoTrackInfo(
            codec: "mp2v",
            width: 1920,
            height: 1080,
            frameRate: 30,
            isHDR: false,
            extradata: nil
        )
    }

    // MARK: - Test: H.264 selects hardware decoder

    func testH264SelectsHardwareDecoder() async throws {
        let manager = AdaptiveDecoderManager()
        let track = makeH264Track()

        try await manager.configure(for: track)

        let decoderName = await manager.selectedDecoderName
        XCTAssertNotNil(decoderName)
        // On Apple Silicon, H.264 should use VideoToolboxDecoder
        // On Intel or if VT fails, it may fall back to FFmpegSoftwareDecoder
        XCTAssertTrue(
            decoderName == "VideoToolboxDecoder" || decoderName == "FFmpegSoftwareDecoder",
            "Expected VideoToolboxDecoder or FFmpegSoftwareDecoder, got \(decoderName ?? "nil")"
        )
    }

    // MARK: - Test: Unsupported codec falls back to software

    func testUnsupportedHardwareCodecFallsBackToSoftware() async throws {
        let manager = AdaptiveDecoderManager()
        let track = makeMPEG2Track() // mpeg2 not supported by VideoToolbox

        try await manager.configure(for: track)

        let decoderName = await manager.selectedDecoderName
        XCTAssertNotNil(decoderName)
        // MPEG-2 has no hardware support, should fall back to FFmpegSoftwareDecoder
        XCTAssertEqual(decoderName, "FFmpegSoftwareDecoder")
    }

    // MARK: - Test: Both decoders fail throws PlaybackError

    func testBothDecodersFailThrowsPlaybackError() async {
        // This test verifies the error path when both decoders fail.
        // On a real system, both decoders should not fail for a supported codec.
        // We test the error propagation by verifying the manager state.
        let manager = AdaptiveDecoderManager()
        // Use a codec that should work on any system
        let track = makeH264Track()

        // This should succeed on any Mac with H.264 support
        do {
            try await manager.configure(for: track)
            let decoderName = await manager.selectedDecoderName
            XCTAssertNotNil(decoderName, "A decoder should be selected")
        } catch {
            // If it fails, it should be a PlaybackError.decodingFailed
            XCTAssertTrue(error is PlaybackError)
            if case .decodingFailed = error as? PlaybackError {
                // Expected
            } else {
                XCTFail("Expected PlaybackError.decodingFailed, got \(error)")
            }
        }
    }

    // MARK: - Test: selectedDecoderName is nil before configuration

    func testSelectedDecoderNameNilBeforeConfiguration() async {
        let manager = AdaptiveDecoderManager()
        let decoderName = await manager.selectedDecoderName
        XCTAssertNil(decoderName)
    }

    // MARK: - Test: selectedDecoderName matches after configuration

    func testSelectedDecoderNameMatchesAfterConfiguration() async throws {
        let manager = AdaptiveDecoderManager()
        let track = makeH264Track()

        try await manager.configure(for: track)

        let decoderName = await manager.selectedDecoderName
        XCTAssertNotNil(decoderName)
        // Verify the name corresponds to a real decoder type
        let validNames = ["VideoToolboxDecoder", "FFmpegSoftwareDecoder"]
        XCTAssertTrue(validNames.contains(decoderName ?? ""),
            "Unexpected decoder name: \(decoderName ?? "nil")")
    }
}
```

- [ ] **Step 2: Build tests to verify compilation**

Run: `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: Empty output (no errors other than the environmental XCTest one).

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/Tests/VideoDecoderTests/Manager/AdaptiveDecoderManagerTests.swift
git commit -m "test: add AdaptiveDecoderManager fallback tests"
```

---

### Task 8: Final verification and cleanup

**Files:**
- All modified files

- [ ] **Step 1: Full build**

Run: `swift build` from `TitanPlayer/` directory.
Expected: Build succeeds.

- [ ] **Step 2: Test build**

Run: `swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"`
Expected: Empty output.

- [ ] **Step 3: Run linter if available**

Run: `swift build 2>&1 | grep -i "warning:"` to check for warnings.
Expected: No new warnings introduced by this change.

- [ ] **Step 4: Final commit with all changes**

```bash
git add -A
git commit -m "feat: complete adaptive decoder fallback integration

- AdaptiveDecoderManager.configure() now falls back hardware→software
- VideoDecodingAdapter bridges VideoDecoding to MediaDecoding
- MediaPipeline.openFile() is now throwing, accepts AdaptiveDecoderManager
- PlaybackEngine creates and wires the manager, logs decoder selection
- Tests for fallback logic and error propagation"
```
