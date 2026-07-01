# FFmpegBridge Real Integration Design

## Context

`FFmpegBridge.swift` is currently a stub with commented-out FFmpeg calls. The actual FFmpeg integration already works through `FFmpegSoftwareDecoder.swift` (which imports `Libavcodec`, `Libavutil`, `Libswscale` directly), but `FFmpegBridge` serves as the demuxer layer used by `FFmpegDemuxer.swift` for format-level operations (opening files, reading packets, seeking).

The `FFmpegBuild` external package is fully functional with pre-built xcframeworks — no module map creation or Package.swift changes are needed.

## Changes

### 1. Rewrite `FFmpegBridge.swift`

**File:** `TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegBridge.swift`

Replace the stub with real FFmpeg C function calls:

- Import `Libavformat`, `Libavcodec`, `Libavutil`
- `initialize()` → no-op (FFmpeg 4.x+ auto-registers; `avformat_network_init()` if needed)
- `openFormatContext(url:)` → call `avformat_open_input`, return Bool
- `findStreamInfo()` → call `avformat_find_stream_info`, return Int32
- `findBestStream(type:)` → call `av_find_best_stream`, return Int32
- `readFrame()` → call `av_read_frame`, return optional tuple `(data: Data, timestamp: Int64, duration: Int64, isKeyFrame: Bool)`
- `seekFrame(timestamp:flags:)` → call `av_seek_frame`, return Int32

Memory management: store `AVFormatContext` as an instance property, close with `avformat_close_input` in a cleanup method.

### 2. Create `scripts/build-ffmpeg.sh`

**File:** `scripts/build-ffmpeg.sh`

Convenience wrapper that:
1. Verifies git, make, and clang are available
2. Checks if `.build/checkouts/FFmpegBuild` exists; if not, runs `swift package resolve` to fetch it
3. Executes `.build/checkouts/FFmpegBuild/build.sh` (the real build script)
4. Reports success/failure with xcframework paths

### 3. No Package.swift changes

Already correctly links `Libavcodec`, `Libavformat`, `Libavutil`, `Libswscale` from the `FFmpegBuild` package.

### 4. No module map changes

The xcframeworks ship with pre-generated `module.modulemap` files. No local module maps needed.

## Acceptance Criteria

- `swift build` succeeds without FFmpeg-related "missing library" or "header not found" errors
- `scripts/build-ffmpeg.sh` runs and triggers the FFmpeg build
- `FFmpegBridge.swift` imports `Libavformat` and calls `avformat_open_input` successfully
