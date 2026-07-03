# MKV AVFoundation Bypass — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make MKV files play by bypassing FFmpeg and using AVFoundation directly, with real track metadata and proper error messages.

**Architecture:** Move MKV from FFmpeg-first routing to AVFoundation-direct routing in MediaPipeline. Fix AVFoundationDemuxer to read actual track info from AVAsset (codec, dimensions, frame rate) instead of hardcoding, create proper AVAssetReaderTrackOutput objects, and read real packet data.

**Tech Stack:** Swift, AVFoundation (AVURLAsset, AVAssetReader, AVAssetReaderTrackOutput), CoreMedia (CMFormatDescription, CMSampleBuffer)

---

## Files Modified

| File | Responsibility |
|---|---|
| `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift` | Route MKV to AVFoundation, add error wrapping |
| `TitanPlayer/TitanPlayer/Core/Decoders/AVFoundation/AVFoundationDemuxer.swift` | Read real tracks, create outputs, read packet data |

---

### Task 1: Route MKV to AVFoundation in MediaPipeline

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift:247-248`

- [ ] **Step 1: Move MKV from ffmpegPreferred to avFoundationDirect**

In `MediaPipeline.swift`, change the extension sets:

```swift
// Before (line 247-248)
private static let avFoundationDirectExtensions: Set<String> = ["mp4", "mov", "m4v"]
private static let ffmpegPreferredExtensions: Set<String> = ["mkv", "flv"]

// After
private static let avFoundationDirectExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv"]
private static let ffmpegPreferredExtensions: Set<String> = ["flv"]
```

- [ ] **Step 2: Build and verify no compile errors**

Run: `swift build` from `TitanPlayer/` directory
Expected: Build succeeds with no errors

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift
git commit -m "route MKV files to AVFoundation directly, bypass FFmpeg"
```

---

### Task 2: Fix AVFoundationDemuxer to read real track info

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/AVFoundation/AVFoundationDemuxer.swift`

- [ ] **Step 1: Replace hardcoded `open(url:)` with real AVAsset introspection**

Replace the entire `open(url:)` method in `AVFoundationDemuxer.swift`:

```swift
func open(url: URL) async throws -> MediaInfo {
    let asset = AVURLAsset(url: url)
    self.asset = asset

    guard let reader = try? AVAssetReader(asset: asset) else {
        throw MediaError(code: .decodingFailed, message: "Failed to create asset reader")
    }
    self.assetReader = reader

    let duration = try await asset.load(.duration)

    let avVideoTracks = try await asset.loadTracks(withMediaType: .video)
    var videoTracks: [VideoTrackInfo] = []
    var foundVideoOutput: AVAssetReaderTrackOutput?

    for track in avVideoTracks {
        let codecName = extractVideoCodecName(from: track)
        let isHDR = detectHDR(from: track)

        let trackInfo = VideoTrackInfo(
            codec: codecName,
            width: Int(track.naturalSize.x),
            height: Int(track.naturalSize.y),
            frameRate: try await track.load(.nominalFrameRate),
            isHDR: isHDR,
            extradata: nil
        )
        videoTracks.append(trackInfo)

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        if reader.canAdd(output) {
            reader.add(output)
            foundVideoOutput = output
        }
    }

    let avAudioTracks = try await asset.loadTracks(withMediaType: .audio)
    var audioTracks: [AudioTrackInfo] = []
    var foundAudioOutput: AVAssetReaderTrackOutput?

    for track in avAudioTracks {
        let codecName = extractAudioCodecName(from: track)
        let trackInfo = AudioTrackInfo(
            codec: codecName,
            sampleRate: Int(try await track.load(.sampleRate)),
            channels: Int(try await track.load(.channelCount)),
            language: try await track.load(.languageCode)
        )
        audioTracks.append(trackInfo)

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        if reader.canAdd(output) {
            reader.add(output)
            foundAudioOutput = output
        }
    }

    guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
        throw MediaError(
            code: .unsupportedFormat,
            message: "No playable tracks found — unsupported codec inside \(url.pathExtension.uppercased()) file"
        )
    }

    self.videoOutput = foundVideoOutput
    self.audioOutput = foundAudioOutput
    reader.startReading()

    return MediaInfo(
        duration: duration,
        videoTracks: videoTracks,
        audioTracks: audioTracks,
        subtitleTracks: [],
        format: url.pathExtension.uppercased()
    )
}
```

- [ ] **Step 2: Add codec extraction helper methods**

Add these private methods to `AVFoundationDemuxer` (after `close()`):

```swift
private func extractVideoCodecName(from track: AVAssetTrack) -> String {
    guard let desc = try? track.load(.formatDescriptions).first else { return "unknown" }
    let codec = CMFormatDescriptionGetCodecType(desc)
    return fourCharCodeToString(codec)
}

private func extractAudioCodecName(from track: AVAssetTrack) -> String {
    guard let desc = try? track.load(.formatDescriptions).first else { return "unknown" }
    let codec = CMFormatDescriptionGetCodecType(desc)
    return fourCharCodeToString(codec)
}

private func detectHDR(from track: AVAssetTrack) -> Bool {
    guard let desc = try? track.load(.formatDescriptions).first else { return false }
    guard let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any] else { return false }
    return extensions["ContainsHDRMetadata"] as? Bool ?? false
}

private func fourCharCodeToString(_ code: OSType) -> String {
    let bytes = [
        UInt8(truncatingIfNeeded: code >> 24),
        UInt8(truncatingIfNeeded: code >> 16),
        UInt8(truncatingIfNeeded: code >> 8),
        UInt8(truncatingIfNeeded: code)
    ]
    return String(bytes: bytes, encoding: .ascii) ?? "unknown"
}
```

- [ ] **Step 3: Build and verify no compile errors**

Run: `swift build` from `TitanPlayer/` directory
Expected: Build succeeds with no errors

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/AVFoundation/AVFoundationDemuxer.swift
git commit -m "fix AVFoundationDemuxer to read real track metadata from AVAsset"
```

---

### Task 3: Fix AVFoundationDemuxer nextPacket to read real data

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/AVFoundation/AVFoundationDemuxer.swift`

- [ ] **Step 1: Replace `nextPacket()` with real data reading**

Replace the entire `nextPacket()` method:

```swift
func nextPacket() async throws -> MediaPacket {
    guard let reader = assetReader, reader.status == .reading else {
        throw MediaError(code: .decodingFailed, message: "Reader not ready")
    }

    if let output = videoOutput, let sampleBuffer = output.copyNextSampleBuffer() {
        return try buildPacket(from: sampleBuffer, streamIndex: 0)
    }

    if let output = audioOutput, let sampleBuffer = output.copyNextSampleBuffer() {
        return try buildPacket(from: sampleBuffer, streamIndex: 1)
    }

    throw MediaError(code: .decodingFailed, message: "No more packets")
}

private func buildPacket(from sampleBuffer: CMSampleBuffer, streamIndex: Int) throws -> MediaPacket {
    let timestamp = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
    let duration = CMSampleBufferGetOutputDuration(sampleBuffer)

    guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        throw MediaError(code: .decodingFailed, message: "No data buffer")
    }

    var length: Int = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    let status = CMBlockBufferGetDataPointer(
        dataBuffer,
        atOffset: 0,
        lengthAtOffsetOut: &length,
        totalLengthOut: nil,
        dataPointerOut: &dataPointer
    )

    guard status == noErr, let pointer = dataPointer else {
        throw MediaError(code: .decodingFailed, message: "Failed to get data pointer")
    }

    let data = Data(bytes: pointer, count: length)

    return MediaPacket(
        streamIndex: streamIndex,
        data: data,
        timestamp: timestamp,
        duration: duration,
        isKeyFrame: true
    )
}
```

- [ ] **Step 2: Build and verify no compile errors**

Run: `swift build` from `TitanPlayer/` directory
Expected: Build succeeds with no errors

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/AVFoundation/AVFoundationDemuxer.swift
git commit -m "fix AVFoundationDemuxer to read real packet data from track outputs"
```

---

### Task 4: Add error wrapping in MediaPipeline for unsupported codecs

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift:38-55`

- [ ] **Step 1: Wrap AVFoundation direct path with specific error handling**

In `MediaPipeline.swift`, replace the AVFoundation direct block (lines 38-55) with:

```swift
if Self.shouldUseAVFoundationDirectly(for: ext) {
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
        playState = .paused
        logger.info("AVFoundation (direct) demuxing completed, state set to paused")
        return
    } catch let error as MediaError {
        let detailed = "\(error.message) — \(ext.uppercased()) file: \(url.lastPathComponent)"
        logger.error("AVFoundation demuxing failed: \(detailed, privacy: .public)")
        throw MediaError(code: error.code, message: detailed)
    }
}
```

- [ ] **Step 2: Also wrap the AVFoundation fallback block (lines 92-107)**

Replace the fallback block:

```swift
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
    playState = .paused
    logger.info("AVFoundation (fallback) demuxing completed, state set to paused")
    return
} catch let error as MediaError {
    let detailed = "\(error.message) — \(ext.uppercased()) file: \(url.lastPathComponent)"
    logger.error("AVFoundation (fallback) demuxing failed: \(detailed, privacy: .public)")
    throw MediaError(code: error.code, message: detailed)
}
```

- [ ] **Step 3: Build and verify no compile errors**

Run: `swift build` from `TitanPlayer/` directory
Expected: Build succeeds with no errors

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift
git commit -m "add codec-specific error messages for unsupported MKV files"
```

---

### Task 5: Verify build and run existing tests

**Files:** None (verification only)

- [ ] **Step 1: Full build verification**

Run: `swift build` from `TitanPlayer/` directory
Expected: Build succeeds with no errors

- [ ] **Step 2: Run tests (if available)**

Run: `swift test` from `TitanPlayer/` directory
Expected: All existing tests pass. If `swift test` fails with `no such module 'XCTest'`, run:
```bash
swift build --build-tests 2>&1 | grep "error:" | grep -v "no such module 'XCTest'"
```
Expected: Empty result (no test compilation errors other than environmental XCTest issue)

- [ ] **Step 3: Final commit with all changes (if not already committed)**

```bash
git add -A
git status
```
