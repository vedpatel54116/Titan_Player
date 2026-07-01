# FFmpegBridge Real Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the stub FFmpegBridge.swift with real FFmpeg C function calls and create a convenience build script for FFmpeg.

**Architecture:** FFmpegBridge wraps libavformat/libavcodec C functions in a Swift-friendly API. It holds an `AVFormatContext` as instance state and delegates demux operations (open, find streams, read packets, seek) to FFmpeg. A shell script wraps the external FFmpegBuild package's `build.sh`.

**Tech Stack:** Swift, C interop (Libavformat, Libavcodec, Libavutil), Bash

---

### Task 1: Rewrite FFmpegBridge.swift with Real FFmpeg Calls

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegBridge.swift`

- [ ] **Step 1: Read the current FFmpegBridge.swift stub**

Read the file to understand the existing interface contract with `FFmpegDemuxer`.

- [ ] **Step 2: Rewrite FFmpegBridge.swift**

Replace the entire file contents with:

```swift
import Foundation
import Libavformat
import Libavcodec
import Libavutil

final class FFmpegBridge {
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var ioContext: UnsafeMutablePointer<AVIOContext>?

    deinit {
        close()
    }

    // MARK: - Public API

    static func initialize() {
        // FFmpeg 4.x+ auto-registers all formats/codecs at link time.
        // av_register_all() was deprecated in FFmpeg 4.0 and is now a no-op.
        // Network init is not needed (disabled at build time).
    }

    func openFormatContext(url: String) -> Bool {
        close()

        var context: UnsafeMutablePointer<AVFormatContext>?
        let cURL = url.withCString { strdup($0) }
        defer { free(cURL) }

        let status = avformat_open_input(&context, cURL, nil, nil)
        guard status == 0, let ctx = context else {
            return false
        }

        formatContext = ctx
        return true
    }

    func findStreamInfo() -> Int32 {
        guard let ctx = formatContext else { return -1 }
        return avformat_find_stream_info(ctx, nil)
    }

    func findBestStream(type: Int32) -> Int32 {
        guard let ctx = formatContext else { return -1 }
        return av_find_best_stream(ctx, AVMediaType(rawValue: type), -1, -1, nil, 0)
    }

    func readFrame() -> (data: Data, timestamp: Int64, duration: Int64, isKeyFrame: Bool)? {
        guard let ctx = formatContext else { return nil }

        var packetOpt: UnsafeMutablePointer<AVPacket>?
        guard let packet = av_packet_alloc() else { return nil }
        packetOpt = packet
        defer { av_packet_free(&packetOpt) }

        let status = av_read_frame(ctx, packet)
        guard status >= 0 else { return nil }

        let pkt = packet.pointee

        let data: Data
        if let buf = pkt.data, pkt.size > 0 {
            data = Data(bytes: buf, count: Int(pkt.size))
        } else {
            data = Data()
        }

        let timestamp = pkt.pts != Int64(bitPattern: AV_NOPTS_VALUE) ? pkt.pts : pkt.dts
        let duration = pkt.duration
        let isKeyFrame = (pkt.flags & Int32(AV_PKT_FLAG_KEY.rawValue)) != 0

        return (data: data, timestamp: timestamp, duration: duration, isKeyFrame: isKeyFrame)
    }

    func seekFrame(timestamp: Int64, flags: Int32) -> Int32 {
        guard let ctx = formatContext else { return -1 }
        return av_seek_frame(ctx, -1, timestamp, flags)
    }

    func close() {
        if let ctx = formatContext {
            avformat_close_input(&ctx)
            formatContext = nil
        }
        if let io = ioContext {
            avio_closep(&io)
            ioContext = nil
        }
    }
}
```

- [ ] **Step 3: Update FFmpegBridge usage from static to instance methods**

`FFmpegDemuxer.swift` currently calls `FFmpegBridge` as static methods. The new design uses instance methods (to hold `AVFormatContext` state). Update `FFmpegDemuxer.swift`:

Read `TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegDemuxer.swift` and make it hold a `FFmpegBridge` instance:

```swift
import Foundation
import CoreMedia

class FFmpegDemuxer: MediaDemuxing {
    private var isOpen = false
    private let bridge = FFmpegBridge()

    func open(url: URL) async throws -> MediaInfo {
        FFmpegBridge.initialize()

        guard bridge.openFormatContext(url: url.path) else {
            throw MediaError(code: .fileNotFound, message: "Failed to open file: \(url.lastPathComponent)")
        }

        let result = bridge.findStreamInfo()
        guard result >= 0 else {
            throw MediaError(code: .unsupportedFormat, message: "Failed to find stream info")
        }

        let videoIndex = bridge.findBestStream(type: 0) // AVMEDIA_TYPE_VIDEO
        let audioIndex = bridge.findBestStream(type: 1) // AVMEDIA_TYPE_AUDIO

        isOpen = true

        return MediaInfo(
            duration: CMTime(seconds: 0, preferredTimescale: 600), // Placeholder
            videoTracks: [],
            audioTracks: [],
            subtitleTracks: [],
            format: url.pathExtension.uppercased()
        )
    }

    func nextPacket() async throws -> MediaPacket {
        guard isOpen else {
            throw MediaError(code: .decodingFailed, message: "Demuxer not opened")
        }

        guard let result = bridge.readFrame() else {
            throw MediaError(code: .decodingFailed, message: "Failed to read frame")
        }

        return MediaPacket(
            streamIndex: 0,
            data: result.data,
            timestamp: CMTime(value: result.timestamp, timescale: 600),
            duration: CMTime(value: result.duration, timescale: 600),
            isKeyFrame: result.isKeyFrame
        )
    }

    func seek(to time: CMTime) async throws {
        let timestamp = Int64(time.seconds * 600)
        _ = bridge.seekFrame(timestamp: timestamp, flags: 0)
    }

    func close() {
        isOpen = false
        bridge.close()
    }
}
```

- [ ] **Step 4: Verify the build compiles**

Run: `swift build 2>&1 | grep -E "(error:.*FFmpeg|error:.*avformat|error:.*avcodec|error:.*Bridge|error:.*Demuxer)"`

Expected: No FFmpeg/Bridge/Demuxer-related errors. (Unrelated errors in MediaPipeline.swift and PlaybackSession.swift are pre-existing and out of scope.)

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegBridge.swift TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegDemuxer.swift
git commit -m "feat: replace FFmpegBridge stub with real avformat/avcodec calls"
```

---

### Task 2: Create scripts/build-ffmpeg.sh

**Files:**
- Create: `scripts/build-ffmpeg.sh`

- [ ] **Step 1: Write the build script**

```bash
#!/bin/bash
#
# build-ffmpeg.sh — Convenience wrapper for building FFmpeg via the FFmpegBuild package.
#
# Usage:
#   ./scripts/build-ffmpeg.sh          # Build all platforms
#   ./scripts/build-ffmpeg.sh clean    # Remove build artifacts
#   ./scripts/build-ffmpeg.sh package  # Repackage xcframeworks only
#
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FFMPEG_BUILD_DIR="${REPO_ROOT}/TitanPlayer/.build/checkouts/FFmpegBuild"

# ── Preflight checks ──────────────────────────────────────

check_tool() {
    if ! command -v "$1" &>/dev/null; then
        echo "Error: '$1' is required but not found in PATH."
        exit 1
    fi
}

check_tool git
check_tool make
check_tool clang

# ── Resolve FFmpegBuild if not checked out ─────────────────

if [[ ! -d "${FFMPEG_BUILD_DIR}" ]]; then
    echo "→ FFmpegBuild not found at ${FFMPEG_BUILD_DIR}"
    echo "→ Running swift package resolve to fetch dependencies..."
    (cd "${REPO_ROOT}/TitanPlayer" && swift package resolve)
fi

if [[ ! -d "${FFMPEG_BUILD_DIR}" ]]; then
    echo "Error: FFmpegBuild still not found after resolve. Check Package.swift."
    exit 1
fi

# ── Run the actual build ───────────────────────────────────

BUILD_SCRIPT="${FFMPEG_BUILD_DIR}/build.sh"
if [[ ! -f "${BUILD_SCRIPT}" ]]; then
    echo "Error: build.sh not found at ${BUILD_SCRIPT}"
    exit 1
fi

echo "╔══════════════════════════════════════╗"
echo "║  Building FFmpeg via FFmpegBuild     ║"
echo "╚══════════════════════════════════════╝"

"${BUILD_SCRIPT}" "$@"

echo ""
echo "✓ FFmpeg build complete."
echo "  XCFrameworks: ${FFMPEG_BUILD_DIR}/Sources/"
```

- [ ] **Step 2: Make the script executable**

Run: `chmod +x scripts/build-ffmpeg.sh`

- [ ] **Step 3: Commit**

```bash
git add scripts/build-ffmpeg.sh
git commit -m "feat: add build-ffmpeg.sh convenience wrapper"
```

---

### Task 3: Verify End-to-End Integration

**Files:** (no new files — verification only)

- [ ] **Step 1: Verify swift build compiles without FFmpeg errors**

Run: `cd TitanPlayer && swift build 2>&1 | grep -E "error:" | grep -iE "ffmpeg|avformat|avcodec|avutil|swscale|bridge|demuxer"`

Expected: Empty output (no FFmpeg-related errors). Pre-existing errors in other files are acceptable.

- [ ] **Step 2: Verify FFmpegBridge imports resolve**

Run: `cd TitanPlayer && swift build 2>&1 | grep -E "error:.*no such module"`

Expected: No errors about `Libavformat`, `Libavcodec`, or `Libavutil` modules.

- [ ] **Step 3: Verify the build script is runnable**

Run: `bash -n scripts/build-ffmpeg.sh`

Expected: Exit 0 (syntax check passes).
