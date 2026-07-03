# AudioTap Typed Accessor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the indirect AudioTappable/AudioTapProvider protocol forwarding in `installAudioTap()` with a typed `audioTapSource: MediaDecoding?` accessor, add nil-guard logging, and add a test verifying decoder reachability after file load.

**Architecture:** Add a two-hop accessor chain: `PlaybackEngine.audioTapSource → MediaPipeline.activeDecoder → decoder`. Rewrite `installAudioTap()` to use this accessor directly. The AudioTappable/AudioTapProvider conformance on PlaybackEngine/MediaPipeline stays (used by other code) but `installAudioTap` no longer relies on it.

**Tech Stack:** Swift, SwiftPM, XCTest

---

## File Map

| Action | File |
|--------|------|
| Modify | `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift:13` — add `internal var activeDecoder` |
| Modify | `TitanPlayer/TitanPlayer/Core/Engine/PlaybackEngine.swift:40` — add `var audioTapSource` |
| Modify | `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift:309-321` — rewrite `installAudioTap()` |
| Create | `TitanPlayer/Tests/Unit/AudioTapTests.swift` — test decoder reachability |

---

### Task 1: Add `activeDecoder` accessor on MediaPipeline

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift:13`

- [ ] **Step 1: Add internal accessor**

After line 13 (`private var decoder: MediaDecoding?`), add:

```swift
    /// Expose the active decoder for typed audio-tap wiring without Mirror reflection.
    internal var activeDecoder: MediaDecoding? { decoder }
```

- [ ] **Step 2: Verify build**

Run: `swift build` from `TitanPlayer/` directory
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift
git commit -m "feat: expose MediaPipeline.activeDecoder for typed audio-tap access"
```

---

### Task 2: Add `audioTapSource` accessor on PlaybackEngine

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/PlaybackEngine.swift:40`

- [ ] **Step 1: Add accessor after `private var mediaPipeline` (line 40)**

After line 40 (`private var mediaPipeline: MediaPipeline?`), add:

```swift
    /// Typed accessor to the active decoder for audio-tap wiring.
    var audioTapSource: MediaDecoding? { mediaPipeline?.activeDecoder }
```

- [ ] **Step 2: Verify build**

Run: `swift build` from `TitanPlayer/` directory
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Engine/PlaybackEngine.swift
git commit -m "feat: expose PlaybackEngine.audioTapSource typed decoder accessor"
```

---

### Task 3: Rewrite `installAudioTap()` and add nil-guard logging

**Files:**
- Modify: `TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift:309-321`

- [ ] **Step 1: Replace `installAudioTap()` body**

Replace lines 305-321 (the doc comment and method body) with:

```swift
    /// Wire the audio tap via a typed `audioTapSource` accessor on the
    /// engine. No Mirror reflection. The closure feeds decoded PCM frames
    /// to both the loudness meter and the spatial audio engine.
    private func installAudioTap() {
        guard let meter = analysis?.audioMeter else { return }
        guard let decoder = engine.audioTapSource else {
            logger.warning("installAudioTap: no decoder available (audioTapSource is nil)")
            return
        }
        decoder.audioTap = { [weak self] frame in
            Task { @MainActor in
                meter.consume(frame: frame)
                if let spatialEngine = self?.engine.activeSpatialAudioEngine,
                   spatialEngine.isRunning {
                    let buf = Self.makePCMBuffer(from: frame)
                    spatialEngine.processAudioBuffer(buf)
                }
            }
        }
    }
```

- [ ] **Step 2: Verify build**

Run: `swift build` from `TitanPlayer/` directory
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Verify no Mirror usage**

Run: `grep -rn "Mirror(" TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift`
Expected: (empty — no matches)

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/UI/Session/PlaybackSession.swift
git commit -m "refactor: replace AudioTap Mirror reflection with typed accessor"
```

---

### Task 4: Add AudioTapTests

**Files:**
- Create: `TitanPlayer/Tests/Unit/AudioTapTests.swift`

- [ ] **Step 1: Write the test file**

```swift
import XCTest
import AVFAudio
@testable import TitanPlayer

@MainActor
final class AudioTapTests: XCTestCase {

    private func makeEngine() -> PlaybackEngine {
        PlaybackEngine(videoRenderer: MockFrameRenderer())
    }

    private func testFileURL() throws -> URL {
        guard let url = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4") else {
            throw XCTSkip("Fixtures/test.mp4 missing from test bundle")
        }
        return url
    }

    func testAudioTapSourceIsNilBeforeLoad() {
        let engine = makeEngine()
        XCTAssertNil(engine.audioTapSource)
    }

    func testAudioTapSourceReturnsDecoderAfterLoad() async throws {
        let engine = makeEngine()
        let url = try testFileURL()
        try await engine.load(url: url)
        let decoder = engine.audioTapSource
        XCTAssertNotNil decoder, "audioTapSource should return a decoder after load(url:)")
        XCTAssertTrue(decoder is MediaDecoding, "audioTapSource should conform to MediaDecoding")
    }

    func testAudioTapSourceIsNilAfterStop() async throws {
        let engine = makeEngine()
        let url = try testFileURL()
        try await engine.load(url: url)
        XCTAssertNotNil(engine.audioTapSource)
        engine.stop()
        // After stop the pipeline is cleared; decoder should be nil.
        XCTAssertNil(engine.audioTapSource)
    }
}
```

- [ ] **Step 2: Verify test compiles and passes**

Run: `swift test --filter AudioTap` from `TitanPlayer/` directory
Expected: All 3 tests PASS

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/Tests/Unit/AudioTapTests.swift
git commit -m "test: add AudioTapTests verifying decoder reachability after load"
```

---

### Task 5: Branch, push, and create PR

- [ ] **Step 1: Create branch and push**

```bash
git checkout -b refactor/audiotap-typed-accessor
git push -u origin refactor/audiotap-typed-accessor
```

- [ ] **Step 2: Create PR**

```bash
gh pr create \
  --title "refactor: typed AudioTap accessor" \
  --body "Replaces Mirror-based reflection in installAudioTap with a typed engine.audioTapSource accessor. Adds a test verifying the decoder is reachable after load." \
  --base main
```
