# MKV: Bypass FFmpeg, Force AVFoundation Demuxing

## Problem

MKV files currently route through FFmpegDemuxer first, which fails because:
- FFmpegDemuxer returns empty track arrays and zero duration (never parses stream info)
- The fallback to AVFoundationDemuxer also fails because it hardcodes H.264/AAC metadata and never creates track outputs

Result: all MKV files fail with generic "Cannot Open" errors.

## Solution

Route MKV files directly to AVFoundation and fix AVFoundationDemuxer to read real track data.

## Changes

### 1. MediaPipeline — Route MKV to AVFoundation

**File:** `TitanPlayer/Core/Engine/MediaPipeline.swift`

- Move `"mkv"` from `ffmpegPreferredExtensions` to `avFoundationDirectExtensions`
- FLV remains in `ffmpegPreferredExtensions` (FFmpeg preferred for FLV)

```swift
// Before
private static let avFoundationDirectExtensions: Set<String> = ["mp4", "mov", "m4v"]
private static let ffmpegPreferredExtensions: Set<String> = ["mkv", "flv"]

// After
private static let avFoundationDirectExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv"]
private static let ffmpegPreferredExtensions: Set<String> = ["flv"]
```

No other changes needed in MediaPipeline — the existing AVFoundation direct path already creates `AVFoundationDemuxer` + `AVFoundationDecoder`.

### 2. AVFoundationDemuxer — Fix `open(url:)` to read real track info

**File:** `TitanPlayer/Core/Decoders/AVFoundation/AVFoundationDemuxer.swift`

Replace hardcoded metadata with actual AVAsset introspection:

```swift
func open(url: URL) async throws -> MediaInfo {
    let asset = AVURLAsset(url: url)
    self.asset = asset

    guard let reader = try? AVAssetReader(asset: asset) else {
        throw MediaError(code: .decodingFailed, message: "Failed to create asset reader")
    }
    self.assetReader = reader

    let duration = try await asset.load(.duration)

    // Load actual video tracks
    let avVideoTracks = try await asset.loadTracks(withMediaType: .video)
    var videoTracks: [VideoTrackInfo] = []
    var videoOutput: AVAssetReaderTrackOutput?

    for track in avVideoTracks {
        let codec = try await track.load(.codecDescription)
        // Extract codec name from format description
        let codecName = extractCodecName(from: track)
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
            videoOutput = output
        }
    }

    // Load actual audio tracks
    let avAudioTracks = try await asset.loadTracks(withMediaType: .audio)
    var audioTracks: [AudioTrackInfo] = []
    var audioOutput: AVAssetReaderTrackOutput?

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
            audioOutput = output
        }
    }

    guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
        throw MediaError(code: .unsupportedFormat, message: "No playable tracks found — unsupported codec inside \(url.pathExtension.uppercased()) file")
    }

    self.videoOutput = videoOutput
    self.audioOutput = audioOutput
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

Helper methods to extract codec names from `AVAssetTrack` format descriptions:

```swift
private func extractCodecName(from track: AVAssetTrack) -> String {
    guard let desc = try? track.load(.formatDescriptions).first else { return "unknown" }
    let mediaType = CMFormatDescriptionGetMediaType(desc)
    switch mediaType {
    case kCMMediaType_Video:
        let codec = CMFormatDescriptionGetCodecType(desc)
        return FourCharCode(codec).toString()
    default:
        return "unknown"
    }
}

private func extractAudioCodecName(from track: AVAssetTrack) -> String {
    guard let desc = try? track.load(.formatDescriptions).first else { return "unknown" }
    let codec = CMFormatDescriptionGetCodecType(desc)
    return FourCharCode(codec).toString()
}

private func detectHDR(from track: AVAssetTrack) -> Bool {
    guard let desc = try? track.load(.formatDescriptions).first else { return false }
    let extensions = CMFormatDescriptionGetExtensions(desc) as? [String: Any]
    return extensions?["ContainsHDRMetadata"] as? Bool ?? false
}
```

FourCharCode helper:

```swift
extension FourCharCode {
    func toString() -> String {
        let bytes = [
            UInt8(truncatingIfNeeded: self >> 24),
            UInt8(truncatingIfNeeded: self >> 16),
            UInt8(truncatingIfNeeded: self >> 8),
            UInt8(truncatingIfNeeded: self)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "unknown"
    }
}
```

### 3. AVFoundationDemuxer — Fix `nextPacket()` to read from outputs

```swift
func nextPacket() async throws -> MediaPacket {
    guard let reader = assetReader, reader.status == .reading else {
        throw MediaError(code: .decodingFailed, message: "Reader not ready")
    }

    // Try video first, then audio
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
    let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &dataPointer)

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

### 4. MediaPipeline — Add specific error for unsupported MKV codecs

In the `openFile` AVFoundation path, wrap the `avDemuxer.open()` call to add context:

```swift
if Self.shouldUseAVFoundationDirectly(for: ext) {
    logger.info("Backend: AVFoundation (direct) for \(ext, privacy: .public)")
    let avDemuxer = AVFoundationDemuxer()
    do {
        let info = try await avDemuxer.open(url: url)
        // ... existing setup code ...
    } catch let error as MediaError {
        throw MediaError(code: error.code, message: "\(error.message) — \(ext.uppercased()) file: \(url.lastPathComponent)")
    }
}
```

## Acceptance Criteria

| Criterion | Implementation |
|---|---|
| MKV with H.264 plays via AVFoundation | MKV routes to AVFoundationDemuxer; demuxer reads real tracks from AVAsset |
| App doesn't call FFmpeg for MKV | `"mkv"` removed from `ffmpegPreferredExtensions` |
| Unsupported codec error is specific | Demuxer reads codec name from format description; error includes codec name and file name |

## Files Modified

| File | Change |
|---|---|
| `TitanPlayer/Core/Engine/MediaPipeline.swift` | Move MKV to `avFoundationDirectExtensions`, add error wrapping |
| `TitanPlayer/Core/Decoders/AVFoundation/AVFoundationDemuxer.swift` | Rewrite `open()` to read real tracks, fix `nextPacket()` to read data, add helpers |

## Out of Scope

- FLV demuxing changes (remains on FFmpeg-first path)
- Changes to PlaybackEngine (AVPlayer already handles MKV natively)
- Changes to FFmpegBridge or FFmpegDemuxer
- Subtitle track extraction from MKV
