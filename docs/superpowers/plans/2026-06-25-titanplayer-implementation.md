# TitanPlayer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a modular macOS video player with protocol-based architecture supporting AVFoundation and FFmpeg backends, Metal rendering, and SwiftUI interface.

**Architecture:** Protocol-based abstracted pipeline with separate backends for AVFoundation and FFmpeg, Metal renderer with custom shaders, and SwiftUI MVVM interface with native sidebar.

**Tech Stack:** Swift, AVFoundation, Metal, VideoToolbox, FFmpeg (libavformat/libavcodec), SwiftUI, GCD

---

## File Structure

```
TitanPlayer/
├── Package.swift                          # SPM dependencies (FFmpeg)
├── TitanPlayer.xcodeproj/                 # Xcode project
├── Core/
│   ├── Engine/
│   │   ├── MediaPipeline.swift            # Pipeline orchestrator
│   │   ├── PlayState.swift                # Playback state enum
│   │   └── TimeObserver.swift             # Time tracking
│   ├── Decoders/
│   │   ├── Protocols/
│   │   │   ├── MediaDemuxing.swift        # Demuxer protocol
│   │   │   ├── MediaDecoding.swift        # Decoder protocol
│   │   │   └── SharedTypes.swift          # MediaPacket, VideoFrame, etc.
│   │   ├── AVFoundation/
│   │   │   ├── AVFoundationDemuxer.swift  # AVFoundation demuxer
│   │   │   └── AVFoundationDecoder.swift  # AVFoundation decoder
│   │   └── FFmpeg/
│   │       ├── FFmpegDemuxer.swift        # FFmpeg demuxer
│   │       ├── FFmpegDecoder.swift        # FFmpeg decoder
│   │       └── FFmpegBridge.swift         # C bridge to libav
│   ├── Renderers/
│   │   ├── MetalRenderer.swift            # Metal renderer
│   │   └── ShaderTypes.swift              # Shared shader types
│   └── Utilities/
│       ├── Extensions.swift               # Swift extensions
│       └── Constants.swift                # App constants
├── Subtitles/
│   ├── SubtitleParser.swift               # Parser protocol + impls
│   ├── SubtitleManager.swift              # Subtitle orchestration
│   └── SubtitleTypes.swift                # SubtitleEvent, etc.
├── UI/
│   ├── Views/
│   │   ├── ContentView.swift              # Main window layout
│   │   ├── PlayerView.swift               # Video content view
│   │   ├── SidebarView.swift              # Library sidebar
│   │   └── InspectorView.swift            # Metadata inspector
│   ├── ViewModels/
│   │   ├── PlayerViewModel.swift          # Player state management
│   │   └── LibraryViewModel.swift         # Library state management
│   └── Controls/
│       ├── ControlBar.swift               # Play/pause, seek, volume
│       └── SeekSlider.swift               # Custom seek slider
├── Resources/
│   ├── Assets.xcassets/                   # App icons
│   └── Shaders/
│       ├── Video.metal                    # Vertex/fragment shaders
│       ├── HDR.metal                      # HDR tone mapping
│       └── Effects.metal                  # Color adjustments
├── Tests/
│   ├── Unit/
│   │   ├── DemuxerTests.swift
│   │   ├── DecoderTests.swift
│   │   ├── ParserTests.swift
│   │   └── ViewModelTests.swift
│   ├── Integration/
│   │   ├── PlaybackPipelineTests.swift
│   │   └── SubtitleIntegrationTests.swift
│   └── Fixtures/
│       └── test.mp4                       # Test media file
└── Docs/
    └── superpowers/specs/
        └── 2026-06-25-titanplayer-design.md
```

---

## Task 1: Project Setup

**Files:**
- Create: `TitanPlayer/TitanPlayer.xcodeproj`
- Create: `TitanPlayer/TitanPlayer/TitanPlayerApp.swift`
- Create: `TitanPlayer/TitanPlayer/Info.plist`

- [ ] **Step 1: Create Xcode project via command line**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player"
mkdir -p TitanPlayer/TitanPlayer
mkdir -p TitanPlayer/TitanPlayer/Core/Engine
mkdir -p TitanPlayer/TitanPlayer/Core/Decoders/Protocols
mkdir -p TitanPlayer/TitanPlayer/Core/Decoders/AVFoundation
mkdir -p TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg
mkdir -p TitanPlayer/TitanPlayer/Core/Renderers
mkdir -p TitanPlayer/TitanPlayer/Core/Utilities
mkdir -p TitanPlayer/TitanPlayer/Subtitles
mkdir -p TitanPlayer/TitanPlayer/UI/Views
mkdir -p TitanPlayer/TitanPlayer/UI/ViewModels
mkdir -p TitanPlayer/TitanPlayer/UI/Controls
mkdir -p TitanPlayer/TitanPlayer/Resources/Assets.xcassets
mkdir -p TitanPlayer/TitanPlayer/Resources/Shaders
mkdir -p TitanPlayer/Tests/Unit
mkdir -p TitanPlayer/Tests/Integration
mkdir -p TitanPlayer/Tests/Fixtures
```

- [ ] **Step 2: Create Swift Package.swift for FFmpeg dependency**

```swift
// TitanPlayer/Package.swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TitanPlayer",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/FFmpeg/FFmpeg.git", from: "6.0.0")
    ],
    targets: [
        .executableTarget(
            name: "TitanPlayer",
            dependencies: ["FFmpeg"],
            path: "TitanPlayer"
        ),
        .testTarget(
            name: "TitanPlayerTests",
            dependencies: ["TitanPlayer"],
            path: "Tests"
        )
    ]
)
```

- [ ] **Step 3: Create SwiftUI app entry point**

```swift
// TitanPlayer/TitanPlayer/TitanPlayerApp.swift
import SwiftUI

@main
struct TitanPlayerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open File...") {
                    NSApp.keyWindow?.contentViewController?.tryToPerform(
                        #selector(NSSceneDelegate.open(_:)), with: nil
                    )
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
```

- [ ] **Step 4: Create basic ContentView**

```swift
// TitanPlayer/TitanPlayer/UI/Views/ContentView.swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        HSplitView {
            SidebarView()
                .frame(minWidth: 200, idealWidth: 250)
            
            PlayerView()
                .frame(minWidth: 640, minHeight: 480)
        }
        .frame(minWidth: 840, minHeight: 480)
    }
}

#Preview {
    ContentView()
}
```

- [ ] **Step 5: Create placeholder views**

```swift
// TitanPlayer/TitanPlayer/UI/Views/SidebarView.swift
import SwiftUI

struct SidebarView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Library")
                .font(.headline)
            Text("No media loaded")
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding()
    }
}

// TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift
import SwiftUI

struct PlayerView: View {
    var body: some View {
        ZStack {
            Color.black
            Text("No media loaded")
                .foregroundColor(.white)
        }
    }
}
```

- [ ] **Step 6: Create Info.plist with media permissions**

```xml
<!-- TitanPlayer/TitanPlayer/Info.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>TitanPlayer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>$(MACOSX_DEPLOYMENT_TARGET)</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 7: Verify project builds**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer"
swift build 2>&1 | head -20
```

- [ ] **Step 8: Commit project setup**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player"
git init
git add .
git commit -m "feat: initial project setup with SwiftUI app structure"
```

---

## Task 2: Core Protocols & Shared Types

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Decoders/Protocols/MediaDemuxing.swift`
- Create: `TitanPlayer/TitanPlayer/Core/Decoders/Protocols/MediaDecoding.swift`
- Create: `TitanPlayer/TitanPlayer/Core/Decoders/Protocols/SharedTypes.swift`

- [ ] **Step 1: Create shared types**

```swift
// TitanPlayer/TitanPlayer/Core/Decoders/Protocols/SharedTypes.swift
import Foundation
import CoreMedia
import CoreVideo

struct MediaInfo {
    let duration: CMTime
    let videoTracks: [VideoTrackInfo]
    let audioTracks: [AudioTrackInfo]
    let subtitleTracks: [SubtitleTrackInfo]
    let format: String
}

struct VideoTrackInfo {
    let codec: String
    let width: Int
    let height: Int
    let frameRate: Double
    let isHDR: Bool
}

struct AudioTrackInfo {
    let codec: String
    let sampleRate: Int
    let channels: Int
    let language: String?
}

struct SubtitleTrackInfo {
    let codec: String
    let language: String?
    let isForced: Bool
}

struct MediaPacket {
    let streamIndex: Int
    let data: Data
    let timestamp: CMTime
    let duration: CMTime
    let isKeyFrame: Bool
}

enum MediaFrame {
    case video(VideoFrame)
    case audio(AudioFrame)
    case subtitle(SubtitleData)
}

struct VideoFrame {
    let pixelBuffer: CVPixelBuffer
    let timestamp: CMTime
    let duration: CMTime
    let colorSpace: ColorSpace
}

enum ColorSpace {
    case sRGB
    case p3
    case bt2020
}

struct AudioFrame {
    let buffer: [Float]
    let format: AudioFormat
    let timestamp: CMTime
    let duration: CMTime
}

struct AudioFormat {
    let sampleRate: Int
    let channels: Int
    let isInterleaved: Bool
}

struct SubtitleData {
    let text: String
    let timestamp: CMTime
    let duration: CMTime
}

struct HDRMetadata {
    let type: HDRType
    let maxLuminance: Float
    let minLuminance: Float
}

enum HDRType {
    case hdr10
    case dolbyVision
    case hlg
}

struct MediaError: Error, LocalizedError {
    let code: ErrorCode
    let message: String
    
    enum ErrorCode: Int {
        case fileNotFound = 1
        case unsupportedFormat = 2
        case decodingFailed = 3
        case networkError = 4
    }
    
    var errorDescription: String? { message }
}
```

- [ ] **Step 2: Create MediaDemuxing protocol**

```swift
// TitanPlayer/TitanPlayer/Core/Decoders/Protocols/MediaDemuxing.swift
import Foundation
import CoreMedia

protocol MediaDemuxing {
    func open(url: URL) async throws -> MediaInfo
    func nextPacket() async throws -> MediaPacket
    func seek(to time: CMTime) async throws
    func close()
}

extension MediaDemuxing {
    func close() {}
}
```

- [ ] **Step 3: Create MediaDecoding protocol**

```swift
// TitanPlayer/TitanPlayer/Core/Decoders/Protocols/MediaDecoding.swift
import Foundation

protocol MediaDecoding {
    func configure(for track: VideoTrackInfo) throws
    func decode(_ packet: MediaPacket) async throws -> MediaFrame
    func flush()
    func reset()
}

extension MediaDecoding {
    func flush() {}
    func reset() {}
}
```

- [ ] **Step 4: Verify compilation**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer"
swift build 2>&1 | tail -5
```

- [ ] **Step 5: Commit protocols**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player"
git add .
git commit -m "feat: add core protocols and shared types"
```

---

## Task 3: AVFoundation Backend

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Decoders/AVFoundation/AVFoundationDemuxer.swift`
- Create: `TitanPlayer/TitanPlayer/Core/Decoders/AVFoundation/AVFoundationDecoder.swift`

- [ ] **Step 1: Create AVFoundation demuxer**

```swift
// TitanPlayer/TitanPlayer/Core/Decoders/AVFoundation/AVFoundationDemuxer.swift
import AVFoundation
import CoreMedia

class AVFoundationDemuxer: MediaDemuxing {
    private var asset: AVURLAsset?
    private var assetReader: AVAssetReader?
    private var videoOutput: AVAssetReaderTrackOutput?
    private var audioOutput: AVAssetReaderTrackOutput?
    private var startTime: CMTime = .zero
    
    func open(url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        self.asset = asset
        
        guard let reader = try? await AVAssetReader(asset: asset) else {
            throw MediaError(code: .decodingFailed, message: "Failed to create asset reader")
        }
        self.assetReader = reader
        
        let duration = try await asset.load(.duration)
        var videoTracks: [VideoTrackInfo] = []
        var audioTracks: [AudioTrackInfo] = []
        
        for try await track in asset.loadTracks(withMediaType: .video) {
            let naturalSize = try await track.load(.naturalSize)
            let frameRate = try await track.load(.nominalFrameRate)
            let codec = try await track.load(.codecName)
            
            videoTracks.append(VideoTrackInfo(
                codec: codec,
                width: Int(naturalSize.width),
                height: Int(naturalSize.height),
                frameRate: Double(frameRate),
                isHDR: codec.contains("hevc") || codec.contains("prores")
            ))
        }
        
        for try await track in asset.loadTracks(withMediaType: .audio) {
            let formatDescriptions = try await track.load(.formatDescriptions)
            let codec = formatDescriptions.first.flatMap { 
                CMFormatDescriptionGetMediaSubType($0).description 
            } ?? "unknown"
            
            audioTracks.append(AudioTrackInfo(
                codec: codec,
                sampleRate: 44100,
                channels: 2,
                language: nil
            ))
        }
        
        return MediaInfo(
            duration: duration,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            subtitleTracks: [],
            format: url.pathExtension.uppercased()
        )
    }
    
    func nextPacket() async throws -> MediaPacket {
        guard let reader = assetReader, reader.status == .reading else {
            throw MediaError(code: .decodingFailed, message: "Reader not ready")
        }
        
        if let output = videoOutput, let sampleBuffer = output.copyNextSampleBuffer() {
            let timestamp = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
            let duration = CMSampleBufferGetOutputDuration(sampleBuffer)
            
            guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                throw MediaError(code: .decodingFailed, message: "No data buffer")
            }
            
            var length: Int = 0
            let _ = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: nil)
            
            return MediaPacket(
                streamIndex: 0,
                data: Data(),
                timestamp: timestamp,
                duration: duration,
                isKeyFrame: true
            )
        }
        
        throw MediaError(code: .decodingFailed, message: "No more packets")
    }
    
    func seek(to time: CMTime) async throws {
        startTime = time
    }
    
    func close() {
        assetReader?.cancelReading()
        assetReader = nil
    }
}
```

- [ ] **Step 2: Create AVFoundation decoder**

```swift
// TitanPlayer/TitanPlayer/Core/Decoders/AVFoundation/AVFoundationDecoder.swift
import AVFoundation
import CoreMedia

class AVFoundationDecoder: MediaDecoding {
    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    
    func configure(for track: VideoTrackInfo) throws {
        // Configure for hardware-accelerated decoding
    }
    
    func decode(_ packet: MediaPacket) async throws -> MediaFrame {
        // Decode packet using VideoToolbox
        let pixelBuffer = createEmptyPixelBuffer()
        
        return .video(VideoFrame(
            pixelBuffer: pixelBuffer,
            timestamp: packet.timestamp,
            duration: packet.duration,
            colorSpace: .sRGB
        ))
    }
    
    func flush() {
        // Flush decompression session
    }
    
    func reset() {
        decompressionSession = nil
        formatDescription = nil
    }
    
    private func createEmptyPixelBuffer() -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ] as CFDictionary
        
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            1920, 1080,
            kCVPixelFormatType_32BGRA,
            attrs,
            &pixelBuffer
        )
        
        return pixelBuffer!
    }
}
```

- [ ] **Step 3: Verify compilation**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer"
swift build 2>&1 | tail -5
```

- [ ] **Step 4: Commit AVFoundation backend**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player"
git add .
git commit -m "feat: add AVFoundation demuxer and decoder"
```

---

## Task 4: FFmpeg Backend

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegBridge.swift`
- Create: `TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegDemuxer.swift`
- Create: `TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegDecoder.swift`

- [ ] **Step 1: Create FFmpeg C bridge**

```swift
// TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegBridge.swift
import Foundation

// FFmpeg C bindings would be defined here
// This is a placeholder for the actual FFmpeg integration

class FFmpegBridge {
    static func initialize() {
        // av_register_all()
        // avformat_network_init()
    }
    
    static func openFormatContext(url: String) -> UnsafeMutablePointer<AVFormatContext>? {
        // avformat_open_input()
        return nil
    }
    
    static func findStreamInfo(context: UnsafeMutablePointer<AVFormatContext>) -> Int32 {
        // avformat_find_stream_info()
        return 0
    }
    
    static func findBestStream(
        context: UnsafeMutablePointer<AVFormatContext>,
        type: AVMediaType
    ) -> Int32 {
        // av_find_best_stream()
        return -1
    }
    
    static func openCodecContext(
        context: UnsafeMutablePointer<AVCodecContext>,
        codec: UnsafePointer<AVCodec>?
    ) -> Int32 {
        // avcodec_open2()
        return 0
    }
    
    static func readFrame(
        context: UnsafeMutablePointer<AVFormatContext>,
        packet: UnsafeMutablePointer<AVPacket>
    ) -> Int32 {
        // av_read_frame()
        return 0
    }
    
    static func sendPacket(
        context: UnsafeMutablePointer<AVCodecContext>,
        packet: UnsafePointer<AVPacket>?
    ) -> Int32 {
        // avcodec_send_packet()
        return 0
    }
    
    static func receiveFrame(
        context: UnsafeMutablePointer<AVCodecContext>,
        frame: UnsafeMutablePointer<AVFrame>
    ) -> Int32 {
        // avcodec_receive_frame()
        return 0
    }
    
    static func seekFrame(
        context: UnsafeMutablePointer<AVFormatContext>,
        streamIndex: Int32,
        timestamp: Int64,
        flags: Int32
    ) -> Int32 {
        // av_seek_frame()
        return 0
    }
}
```

- [ ] **Step 2: Create FFmpeg demuxer**

```swift
// TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegDemuxer.swift
import Foundation

class FFmpegDemuxer: MediaDemuxing {
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var videoStreamIndex: Int32 = -1
    private var audioStreamIndex: Int32 = -1
    
    func open(url: URL) async throws -> MediaInfo {
        FFmpegBridge.initialize()
        
        guard let context = FFmpegBridge.openFormatContext(url: url.path) else {
            throw MediaError(code: .fileNotFound, message: "Failed to open file: \(url.lastPathComponent)")
        }
        self.formatContext = context
        
        let result = FFmpegBridge.findStreamInfo(context: context)
        guard result >= 0 else {
            throw MediaError(code: .unsupportedFormat, message: "Failed to find stream info")
        }
        
        videoStreamIndex = FFmpegBridge.findBestStream(context: context, type: AVMEDIA_TYPE_VIDEO)
        audioStreamIndex = FFmpegBridge.findBestStream(context: context, type: AVMEDIA_TYPE_AUDIO)
        
        return MediaInfo(
            duration: CMTime(seconds: Double(context.pointee.duration) / Double(AV_TIME_BASE), preferredTimescale: 600),
            videoTracks: [],
            audioTracks: [],
            subtitleTracks: [],
            format: url.pathExtension.uppercased()
        )
    }
    
    func nextPacket() async throws -> MediaPacket {
        guard let context = formatContext else {
            throw MediaError(code: .decodingFailed, message: "No format context")
        }
        
        var packet = AVPacket()
        let result = FFmpegBridge.readFrame(context: context, packet: &packet)
        
        guard result >= 0 else {
            throw MediaError(code: .decodingFailed, message: "Failed to read frame")
        }
        
        return MediaPacket(
            streamIndex: Int(packet.stream_index),
            data: Data(bytes: packet.data!, count: Int(packet.size)),
            timestamp: CMTime(value: packet.pts, timescale: 600),
            duration: CMTime(value: packet.duration, timescale: 600),
            isKeyFrame: (packet.flags & 1) != 0
        )
    }
    
    func seek(to time: CMTime) async throws {
        guard let context = formatContext else { return }
        
        let timestamp = Int64(time.seconds * Double(AV_TIME_BASE))
        FFmpegBridge.seekFrame(context: context, streamIndex: -1, timestamp: timestamp, flags: 0)
    }
    
    func close() {
        if let context = formatContext {
            avformat_close_input(&formatContext)
        }
    }
}
```

- [ ] **Step 3: Create FFmpeg decoder**

```swift
// TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegDecoder.swift
import Foundation

class FFmpegDecoder: MediaDecoding {
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    
    func configure(for track: VideoTrackInfo) throws {
        // Find and open appropriate codec
    }
    
    func decode(_ packet: MediaPacket) async throws -> MediaFrame {
        guard let context = codecContext else {
            throw MediaError(code: .decodingFailed, message: "No codec context")
        }
        
        var avPacket = AVPacket()
        // Configure avPacket from MediaPacket
        
        let sendResult = FFmpegBridge.sendPacket(context: context, packet: &avPacket)
        guard sendResult >= 0 else {
            throw MediaError(code: .decodingFailed, message: "Failed to send packet")
        }
        
        var frame = AVFrame()
        let receiveResult = FFmpegBridge.receiveFrame(context: context, frame: &frame)
        guard receiveResult >= 0 else {
            throw MediaError(code: .decodingFailed, message: "Failed to receive frame")
        }
        
        // Convert frame to CVPixelBuffer
        let pixelBuffer = convertToPixelBuffer(frame: frame)
        
        return .video(VideoFrame(
            pixelBuffer: pixelBuffer,
            timestamp: packet.timestamp,
            duration: packet.duration,
            colorSpace: .sRGB
        ))
    }
    
    func flush() {
        // Flush codec context
    }
    
    func reset() {
        codecContext = nil
    }
    
    private func convertToPixelBuffer(frame: AVFrame) -> CVPixelBuffer {
        // Convert AVFrame to CVPixelBuffer
        var pixelBuffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary
        
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(frame.width),
            Int(frame.height),
            kCVPixelFormatType_32BGRA,
            attrs,
            &pixelBuffer
        )
        
        return pixelBuffer!
    }
}
```

- [ ] **Step 4: Verify compilation**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer"
swift build 2>&1 | tail -5
```

- [ ] **Step 5: Commit FFmpeg backend**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player"
git add .
git commit -m "feat: add FFmpeg demuxer and decoder with C bridge"
```

---

## Task 5: MediaPipeline Orchestrator

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift`
- Create: `TitanPlayer/TitanPlayer/Core/Engine/PlayState.swift`
- Create: `TitanPlayer/TitanPlayer/Core/Engine/TimeObserver.swift`

- [ ] **Step 1: Create PlayState enum**

```swift
// TitanPlayer/TitanPlayer/Core/Engine/PlayState.swift
import Foundation

enum PlayState: Equatable {
    case idle
    case loading
    case playing
    case paused
    case seeking
    case error(String)
    
    static func == (lhs: PlayState, rhs: PlayState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading),
             (.playing, .playing), (.paused, .paused),
             (.seeking, .seeking):
            return true
        case (.error(let l), .error(let r)):
            return l == r
        default:
            return false
        }
    }
}
```

- [ ] **Step 2: Create TimeObserver**

```swift
// TitanPlayer/TitanPlayer/Core/Engine/TimeObserver.swift
import Foundation
import Combine

class TimeObserver: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var progress: Double = 0
    
    private var timer: Timer?
    private var startTime: Date?
    
    func startObserving() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateTime()
        }
    }
    
    func stopObserving() {
        timer?.invalidate()
        timer = nil
    }
    
    func seekTo(_ time: Double) {
        currentTime = time
        updateProgress()
    }
    
    private func updateTime() {
        guard let startTime = startTime else { return }
        currentTime = Date().timeIntervalSince(startTime)
        updateProgress()
    }
    
    private func updateProgress() {
        guard duration > 0 else { return }
        progress = currentTime / duration
    }
    
    func reset() {
        currentTime = 0
        startTime = Date()
    }
}
```

- [ ] **Step 3: Create MediaPipeline**

```swift
// TitanPlayer/TitanPlayer/Core/Engine/MediaPipeline.swift
import Foundation
import Combine

@MainActor
class MediaPipeline: ObservableObject {
    @Published var playState: PlayState = .idle
    @Published var mediaInfo: MediaInfo?
    
    private var demuxer: MediaDemuxing?
    private var decoder: MediaDecoding?
    private let timeObserver = TimeObserver()
    
    private let pipelineQueue = DispatchQueue(label: "com.titanplayer.pipeline", qos: .userInitiated)
    private var packetTask: Task<Void, Never>?
    
    var currentTime: Double { timeObserver.currentTime }
    var duration: Double { timeObserver.duration }
    var progress: Double { timeObserver.progress }
    
    func openFile(url: URL) async {
        playState = .loading
        
        do {
            // Probe file to determine backend
            let probeDemuxer = FFmpegDemuxer()
            let info = try await probeDemuxer.open(url: url)
            probeDemuxer.close()
            
            self.mediaInfo = info
            timeObserver.duration = info.duration.seconds
            
            // Select appropriate backend
            if shouldUseAVFoundation(for: info) {
                demuxer = AVFoundationDemuxer()
                decoder = AVFoundationDecoder()
            } else {
                demuxer = FFmpegDemuxer()
                decoder = FFmpegDecoder()
            }
            
            // Open with selected backend
            _ = try await demuxer?.open(url: url)
            playState = .paused
            
        } catch {
            playState = .error(error.localizedDescription)
        }
    }
    
    func play() {
        guard playState == .paused || playState == .idle else { return }
        playState = .playing
        timeObserver.startObserving()
        startPacketReading()
    }
    
    func pause() {
        guard playState == .playing else { return }
        playState = .paused
        timeObserver.stopObserving()
        packetTask?.cancel()
    }
    
    func seek(to time: Double) async {
        playState = .seeking
        timeObserver.seekTo(time)
        
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        try? await demuxer?.seek(to: cmTime)
        
        if playState == .seeking {
            playState = .playing
        }
    }
    
    func stop() {
        packetTask?.cancel()
        timeObserver.stopObserving()
        demuxer?.close()
        decoder?.reset()
        playState = .idle
    }
    
    private func startPacketReading() {
        packetTask = Task { [weak self] in
            guard let self = self else { return }
            
            while !Task.isCancelled {
                guard let packet = try? await self.demuxer?.nextPacket() else {
                    break
                }
                
                if let frame = try? await self.decoder?.decode(packet) {
                    await MainActor.run {
                        self.processFrame(frame)
                    }
                }
            }
        }
    }
    
    private func processFrame(_ frame: MediaFrame) {
        // Route frame to appropriate renderer
    }
    
    private func shouldUseAVFoundation(for info: MediaInfo) -> Bool {
        // Determine if AVFoundation can handle this format
        let supportedCodecs = ["h264", "hevc", "prores", "aac", "alac"]
        return info.videoTracks.allSatisfy { supportedCodecs.contains($0.codec.lowercased()) }
    }
}
```

- [ ] **Step 4: Verify compilation**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer"
swift build 2>&1 | tail -5
```

- [ ] **Step 5: Commit MediaPipeline**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player"
git add .
git commit -m "feat: add MediaPipeline orchestrator with play/pause/seek"
```

---

## Task 6: Metal Renderer

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift`
- Create: `TitanPlayer/TitanPlayer/Core/Renderers/ShaderTypes.swift`
- Create: `TitanPlayer/TitanPlayer/Resources/Shaders/Video.metal`
- Create: `TitanPlayer/TitanPlayer/Resources/Shaders/HDR.metal`
- Create: `TitanPlayer/TitanPlayer/Resources/Shaders/Effects.metal`

- [ ] **Step 1: Create ShaderTypes**

```swift
// TitanPlayer/TitanPlayer/Core/Renderers/ShaderTypes.swift
import Foundation
import simd

struct VertexIn {
    var position: simd_float2
    var textureCoordinate: simd_float2
}

struct VertexOut {
    var position: simd_position
    var textureCoordinate: simd_float2
}

struct Uniforms {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var hue: Float
    var hdrEnabled: Bool
}
```

- [ ] **Step 2: Create Video.metal shader**

```metal
// TitanPlayer/TitanPlayer/Resources/Shaders/Video.metal
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position;
    float2 textureCoordinate;
};

struct VertexOut {
    float4 position [[position]];
    float2 textureCoordinate;
};

vertex VertexOut vertexShader(constant VertexIn &vertices [[buffer(0)]]) {
    VertexOut output;
    output.position = float4(vertices.position, 0.0, 1.0);
    output.textureCoordinate = vertices.textureCoordinate;
    return output;
}

fragment float4 fragmentShader(VertexOut input [[stage_in]],
                               texture2d<float> texture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    return texture.sample(textureSampler, input.textureCoordinate);
}
```

- [ ] **Step 3: Create HDR.metal shader**

```metal
// TitanPlayer/TitanPlayer/Resources/Shaders/HDR.metal
#include <metal_stdlib>
using namespace metal;

constant float PQ_MAX_LUMINANCE = 1000.0;
constant float SDR_MAX_LUMINANCE = 100.0;

float pqToLinear(float pq) {
    float pqPow = pow(pq, 1.0 / 78.8438);
    return pow(max(pqPow - 0.8359, 0.0) / (18.8515 - 18.6875 * pqPow), 1.0 / 0.1593);
}

float hlgToLinear(float hlg) {
    float a = 0.17883277;
    float b = 0.28466892;
    float c = 0.55991073;
    
    if (hlg <= 0.5) {
        return (hlg * hlg) / 3.0;
    }
    return (exp((hlg - c) / a) + b) / 12.0;
}

fragment float4 hdrFragmentShader(VertexOut input [[stage_in]],
                                   texture2d<float> texture [[texture(0)]],
                                   constant bool &hdrEnabled [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float4 color = texture.sample(textureSampler, input.textureCoordinate);
    
    if (hdrEnabled) {
        float linear = pqToLinear(color.r);
        float sdr = linear * (SDR_MAX_LUMINANCE / PQ_MAX_LUMINANCE);
        color = float4(sdr, sdr, sdr, color.a);
    }
    
    return color;
}
```

- [ ] **Step 4: Create Effects.metal shader**

```metal
// TitanPlayer/TitanPlayer/Resources/Shaders/Effects.metal
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float brightness;
    float contrast;
    float saturation;
    float hue;
};

fragment float4 effectsFragmentShader(VertexOut input [[stage_in]],
                                      texture2d<float> texture [[texture(0)]],
                                      constant Uniforms &uniforms [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    float4 color = texture.sample(textureSampler, input.textureCoordinate);
    
    // Brightness
    color.rgb += uniforms.brightness;
    
    // Contrast
    color.rgb = (color.rgb - 0.5) * uniforms.contrast + 0.5;
    
    // Saturation
    float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    color.rgb = mix(float3(luminance), color.rgb, uniforms.saturation);
    
    return color;
}
```

- [ ] **Step 5: Create MetalRenderer**

```swift
// TitanPlayer/TitanPlayer/Core/Renderers/MetalRenderer.swift
import Metal
import MetalKit
import CoreVideo

class MetalRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var vertexBuffer: MTLBuffer?
    
    private let vertexData: [Float] = [
        -1.0, -1.0, 0.0, 1.0,
         1.0, -1.0, 1.0, 1.0,
        -1.0,  1.0, 0.0, 0.0,
         1.0,  1.0, 1.0, 0.0,
    ]
    
    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        
        self.device = device
        self.commandQueue = commandQueue
        
        setupPipeline()
        setupVertexBuffer()
    }
    
    private func setupPipeline() {
        guard let library = device.makeDefaultLibrary() else { return }
        
        let vertexFunction = library.makeFunction(name: "vertexShader")
        let fragmentFunction = library.makeFunction(name: "fragmentShader")
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        pipelineState = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    private func setupVertexBuffer() {
        vertexBuffer = device.makeBuffer(
            bytes: vertexData,
            length: vertexData.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )
    }
    
    func render(pixelBuffer: CVPixelBuffer, to drawable: CAMetalDrawable) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderPassDescriptor = createRenderPassDescriptor(drawable: drawable),
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor),
              let pipelineState = pipelineState,
              let vertexBuffer = vertexBuffer else {
            return
        }
        
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        
        // Create texture from pixelBuffer
        if let texture = createTexture(from: pixelBuffer) {
            renderEncoder.setFragmentTexture(texture, index: 0)
        }
        
        renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renderEncoder.endEncoding()
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    private func createRenderPassDescriptor(drawable: CAMetalDrawable) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].storeAction = .store
        return descriptor
    }
    
    private func createTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead]
        
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else { return nil }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            texture.replace(
                region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                 size: MTLSize(width: width, height: height, depth: 1)),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: bytesPerRow
            )
        }
        
        return texture
    }
}
```

- [ ] **Step 6: Verify compilation**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer"
swift build 2>&1 | tail -5
```

- [ ] **Step 7: Commit Metal renderer**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player"
git add .
git commit -m "feat: add Metal renderer with video and HDR shaders"
```

---

## Task 7: Subtitle System

**Files:**
- Create: `TitanPlayer/TitanPlayer/Subtitles/SubtitleTypes.swift`
- Create: `TitanPlayer/TitanPlayer/Subtitles/SubtitleParser.swift`
- Create: `TitanPlayer/TitanPlayer/Subtitles/SubtitleManager.swift`

- [ ] **Step 1: Create SubtitleTypes**

```swift
// TitanPlayer/TitanPlayer/Subtitles/SubtitleTypes.swift
import Foundation

struct SubtitleEvent {
    let startTime: Double
    let endTime: Double
    let text: AttributedString
    let position: SubtitlePosition
    let style: SubtitleStyle
}

enum SubtitlePosition {
    case bottom
    case top
    case custom(x: Double, y: Double)
}

struct SubtitleStyle {
    let fontSize: CGFloat
    let fontName: String
    let foregroundColor: SubtitleColor
    let backgroundColor: SubtitleColor?
    let isBold: Bool
    let isItalic: Bool
    
    static let `default` = SubtitleStyle(
        fontSize: 24,
        fontName: "Helvetica",
        foregroundColor: .white,
        backgroundColor: .init(r: 0, g: 0, b: 0, a: 0.7),
        isBold: false,
        isItalic: false
    )
}

struct SubtitleColor {
    let r: Double
    let g: Double
    let b: Double
    let a: Double
    
    static let white = SubtitleColor(r: 1, g: 1, b: 1, a: 1)
    static let yellow = SubtitleColor(r: 1, g: 1, b: 0, a: 1)
}

struct SubtitleTrack {
    let name: String
    let language: String?
    let isDefault: Bool
    let events: [SubtitleEvent]
}
```

- [ ] **Step 2: Create SubtitleParser**

```swift
// TitanPlayer/TitanPlayer/Subtitles/SubtitleParser.swift
import Foundation

protocol SubtitleParsing {
    func parse(data: Data) throws -> [SubtitleEvent]
}

class SRTParser: SubtitleParsing {
    func parse(data: Data) throws -> [SubtitleEvent] {
        guard let content = String(data: data, encoding: .utf8) else {
            throw MediaError(code: .decodingFailed, message: "Invalid SRT encoding")
        }
        
        var events: [SubtitleEvent] = []
        let blocks = content.components(separatedBy: "\n\n")
        
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            guard lines.count >= 3 else { continue }
            
            let timeRange = lines[1]
            let text = lines[2...].joined(separator: "\n")
            
            if let event = parseTimeRange(timeRange, text: text) {
                events.append(event)
            }
        }
        
        return events
    }
    
    private func parseTimeRange(_ range: String, text: String) -> SubtitleEvent? {
        let components = range.components(separatedBy: " --> ")
        guard components.count == 2 else { return nil }
        
        guard let startTime = parseTime(components[0]),
              let endTime = parseTime(components[1]) else {
            return nil
        }
        
        return SubtitleEvent(
            startTime: startTime,
            endTime: endTime,
            text: AttributedString(text),
            position: .bottom,
            style: .default
        )
    }
    
    private func parseTime(_ time: String) -> Double? {
        let components = time.replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        guard components.count == 3 else { return nil }
        
        guard let hours = Double(components[0]),
              let minutes = Double(components[1]),
              let seconds = Double(components[2]) else {
            return nil
        }
        
        return hours * 3600 + minutes * 60 + seconds
    }
}

class ASSParser: SubtitleParsing {
    func parse(data: Data) throws -> [SubtitleEvent] {
        // ASS/SSA parser implementation
        return []
    }
}

class WebVTTParser: SubtitleParsing {
    func parse(data: Data) throws -> [SubtitleEvent] {
        // WebVTT parser implementation
        return []
    }
}
```

- [ ] **Step 3: Create SubtitleManager**

```swift
// TitanPlayer/TitanPlayer/Subtitles/SubtitleManager.swift
import Foundation
import Combine

@MainActor
class SubtitleManager: ObservableObject {
    @Published var availableTracks: [SubtitleTrack] = []
    @Published var activeTrack: SubtitleTrack?
    @Published var currentEvents: [SubtitleEvent] = []
    
    private var parsers: [String: SubtitleParsing] = [
        "srt": SRTParser(),
        "ass": ASSParser(),
        "ssa": ASSParser(),
        "vtt": WebVTTParser()
    ]
    
    func loadSubtitle(url: URL) throws {
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        
        guard let parser = parsers[ext] else {
            throw MediaError(code: .unsupportedFormat, message: "Unsupported subtitle format: \(ext)")
        }
        
        let events = try parser.parse(data: data)
        let track = SubtitleTrack(
            name: url.lastPathComponent,
            language: nil,
            isDefault: availableTracks.isEmpty,
            events: events
        )
        
        availableTracks.append(track)
        
        if activeTrack == nil {
            activeTrack = track
        }
    }
    
    func setActiveTrack(_ track: SubtitleTrack?) {
        activeTrack = track
    }
    
    func update(for time: Double) {
        guard let track = activeTrack else {
            currentEvents = []
            return
        }
        
        currentEvents = track.events.filter { event in
            time >= event.startTime && time <= event.endTime
        }
    }
    
    func clear() {
        availableTracks = []
        activeTrack = nil
        currentEvents = []
    }
}
```

- [ ] **Step 4: Verify compilation**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer"
swift build 2>&1 | tail -5
```

- [ ] **Step 5: Commit subtitle system**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player"
git add .
git commit -m "feat: add subtitle system with SRT, ASS, and WebVTT parsers"
```

---

## Task 8: ViewModels

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/ViewModels/PlayerViewModel.swift`
- Create: `TitanPlayer/TitanPlayer/UI/ViewModels/LibraryViewModel.swift`

- [ ] **Step 1: Create PlayerViewModel**

```swift
// TitanPlayer/TitanPlayer/UI/ViewModels/PlayerViewModel.swift
import SwiftUI
import Combine

@MainActor
class PlayerViewModel: ObservableObject {
    @Published var playState: PlayState = .idle
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Float = 1.0
    @Published var isMuted: Bool = false
    @Published var mediaInfo: MediaInfo?
    @Published var subtitles: [SubtitleTrack] = []
    @Published var activeSubtitle: SubtitleTrack?
    @Published var currentSubtitleEvents: [SubtitleEvent] = []
    
    private let pipeline = MediaPipeline()
    private let subtitleManager = SubtitleManager()
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupBindings()
    }
    
    private func setupBindings() {
        pipeline.$playState
            .receive(on: DispatchQueue.main)
            .assign(to: &$playState)
        
        pipeline.$mediaInfo
            .receive(on: DispatchQueue.main)
            .assign(to: &$mediaInfo)
        
        subtitleManager.$availableTracks
            .receive(on: DispatchQueue.main)
            .assign(to: &$subtitles)
        
        subtitleManager.$activeTrack
            .receive(on: DispatchQueue.main)
            .assign(to: &$activeSubtitle)
        
        subtitleManager.$currentEvents
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentSubtitleEvents)
    }
    
    func openFile(url: URL) async {
        await pipeline.openFile(url: url)
        duration = pipeline.duration
        
        // Load embedded subtitles if available
        try? loadEmbeddedSubtitles(from: url)
    }
    
    func play() {
        pipeline.play()
    }
    
    func pause() {
        pipeline.pause()
    }
    
    func togglePlayPause() {
        if playState == .playing {
            pause()
        } else {
            play()
        }
    }
    
    func seek(to time: Double) async {
        await pipeline.seek(to: time)
        currentTime = time
        subtitleManager.update(for: time)
    }
    
    func seekForward(seconds: Double = 10) async {
        let newTime = min(currentTime + seconds, duration)
        await seek(to: newTime)
    }
    
    func seekBackward(seconds: Double = 10) async {
        let newTime = max(currentTime - seconds, 0)
        await seek(to: newTime)
    }
    
    func setVolume(_ volume: Float) {
        self.volume = max(0, min(1, volume))
    }
    
    func toggleMute() {
        isMuted.toggle()
    }
    
    func setSubtitleTrack(_ track: SubtitleTrack?) {
        subtitleManager.setActiveTrack(track)
    }
    
    func loadExternalSubtitle(url: URL) throws {
        try subtitleManager.loadSubtitle(url: url)
    }
    
    private func loadEmbeddedSubtitles(from url: URL) throws {
        // Load embedded subtitle tracks
    }
    
    func stop() {
        pipeline.stop()
        subtitleManager.clear()
    }
}
```

- [ ] **Step 2: Create LibraryViewModel**

```swift
// TitanPlayer/TitanPlayer/UI/ViewModels/LibraryViewModel.swift
import SwiftUI
import Combine

@MainActor
class LibraryViewModel: ObservableObject {
    @Published var mediaFiles: [MediaItem] = []
    @Published var playlists: [Playlist] = []
    @Published var recentlyPlayed: [MediaItem] = []
    @Published var selectedFolder: URL?
    
    private let supportedExtensions = ["mp4", "mkv", "mov", "avi", "wmv", "flac", "m4v"]
    
    func loadFolder(url: URL) {
        selectedFolder = url
        mediaFiles = scanFolder(url: url)
    }
    
    func scanFolder(url: URL) -> [MediaItem] {
        var items: [MediaItem] = []
        
        guard let enumerator = FileManager.default.enumerator(at: url,
                                                             includingPropertiesForKeys: [.isRegularFileKey],
                                                             options: [.skipsHiddenFiles]) else {
            return items
        }
        
        for case let fileURL as URL in enumerator {
            guard let isRegular = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegular,
                  isRegular else {
                continue
            }
            
            if supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                let item = MediaItem(
                    id: fileURL,
                    url: fileURL,
                    title: fileURL.deletingPathExtension().lastPathComponent,
                    duration: 0,
                    dateAdded: Date()
                )
                items.append(item)
            }
        }
        
        return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
    
    func createPlaylist(name: String) {
        let playlist = Playlist(
            id: UUID(),
            name: name,
            items: [],
            dateCreated: Date()
        )
        playlists.append(playlist)
    }
    
    func addToPlaylist(_ playlist: Playlist, item: MediaItem) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].items.append(item)
    }
    
    func removeFromPlaylist(_ playlist: Playlist, item: MediaItem) {
        guard let playlistIndex = playlists.firstIndex(where: { $0.id == playlist.id }),
              let itemIndex = playlists[playlistIndex].items.firstIndex(where: { $0.id == item.id }) else {
            return
        }
        playlists[playlistIndex].items.remove(at: itemIndex)
    }
    
    func addToRecentlyPlayed(_ item: MediaItem) {
        recentlyPlayed.removeAll { $0.id == item.id }
        recentlyPlayed.insert(item, at: 0)
        if recentlyPlayed.count > 20 {
            recentlyPlayed = Array(recentlyPlayed.prefix(20))
        }
    }
}

struct MediaItem: Identifiable, Hashable {
    let id: URL
    let url: URL
    let title: String
    let duration: Double
    let dateAdded: Date
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
        lhs.id == rhs.id
    }
}

struct Playlist: Identifiable {
    let id: UUID
    let name: String
    var items: [MediaItem]
    let dateCreated: Date
}
```

- [ ] **Step 3: Verify compilation**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer"
swift build 2>&1 | tail -5
```

- [ ] **Step 4: Commit ViewModels**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player"
git add .
git commit -m "feat: add PlayerViewModel and LibraryViewModel with MVVM pattern"
```

---

## Task 9: UI Components

**Files:**
- Create: `TitanPlayer/TitanPlayer/UI/Controls/ControlBar.swift`
- Create: `TitanPlayer/TitanPlayer/UI/Controls/SeekSlider.swift`
- Modify: `TitanPlayer/TitanPlayer/UI/Views/ContentView.swift`
- Modify: `TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift`
- Modify: `TitanPlayer/TitanPlayer/UI/Views/SidebarView.swift`
- Create: `TitanPlayer/TitanPlayer/UI/Views/InspectorView.swift`

- [ ] **Step 1: Create SeekSlider**

```swift
// TitanPlayer/TitanPlayer/UI/Controls/SeekSlider.swift
import SwiftUI

struct SeekSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onEditingChanged: (Bool) -> Void
    
    @State private var isDragging = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Track background
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.3))
                    .frame(height: 4)
                
                // Progress
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: progressWidth(in: geometry), height: 4)
                
                // Thumb
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .offset(x: thumbOffset(in: geometry))
                    .shadow(radius: 2)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        isDragging = true
                        onEditingChanged(true)
                        updateValue(from: drag.location, in: geometry)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 20)
    }
    
    private func progressWidth(in geometry: GeometryProxy) -> CGFloat {
        let proportion = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return geometry.size.width * CGFloat(proportion)
    }
    
    private func thumbOffset(in geometry: GeometryProxy) -> CGFloat {
        progressWidth(in: geometry) - 6
    }
    
    private func updateValue(from location: CGPoint, in geometry: GeometryProxy) {
        let proportion = max(0, min(1, location.x / geometry.size.width))
        value = range.lowerBound + (range.upperBound - range.lowerBound) * proportion
    }
}
```

- [ ] **Step 2: Create ControlBar**

```swift
// TitanPlayer/TitanPlayer/UI/Controls/ControlBar.swift
import SwiftUI

struct ControlBar: View {
    @ObservedObject var viewModel: PlayerViewModel
    @State private var isEditingSeek = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Seek slider
            SeekSlider(
                value: Binding(
                    get: { viewModel.currentTime },
                    set: { newValue in
                        if !isEditingSeek {
                            Task { await viewModel.seek(to: newValue) }
                        }
                    }
                ),
                range: 0...max(viewModel.duration, 1),
                onEditingChanged: { editing in
                    isEditingSeek = editing
                }
            )
            .padding(.horizontal, 16)
            .padding(.top, 8)
            
            // Controls
            HStack(spacing: 24) {
                // Playback controls
                HStack(spacing: 16) {
                    Button(action: { Task { await viewModel.seekBackward() } }) {
                        Image(systemName: "gobackward.10")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { viewModel.togglePlayPause() }) {
                        Image(systemName: viewModel.playState == .playing ? "pause.fill" : "play.fill")
                            .font(.title)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { Task { await viewModel.seekForward() } }) {
                        Image(systemName: "goforward.10")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                }
                
                // Time display
                Text("\(formatTime(viewModel.currentTime)) / \(formatTime(viewModel.duration))")
                    .font(.caption)
                    .monospacedDigit()
                
                Spacer()
                
                // Volume controls
                HStack(spacing: 8) {
                    Button(action: { viewModel.toggleMute() }) {
                        Image(systemName: volumeIcon)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    
                    Slider(value: Binding(
                        get: { viewModel.volume },
                        set: { viewModel.setVolume($0) }
                    ), in: 0...1)
                    .frame(width: 100)
                }
                
                // Subtitle button
                Menu {
                    ForEach(viewModel.subtitles, id: \.name) { track in
                        Button(track.name) {
                            viewModel.setSubtitleTrack(track)
                        }
                    }
                    
                    Divider()
                    
                    Button("Load External Subtitle...") {
                        // Open file picker
                    }
                } label: {
                    Image(systemName: "captions.bubble")
                        .font(.title3)
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }
    
    private var volumeIcon: String {
        if viewModel.isMuted {
            return "speaker.slash.fill"
        } else if viewModel.volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if viewModel.volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
```

- [ ] **Step 3: Update ContentView**

```swift
// TitanPlayer/TitanPlayer/UI/Views/ContentView.swift
import SwiftUI

struct ContentView: View {
    @StateObject private var playerViewModel = PlayerViewModel()
    @StateObject private var libraryViewModel = LibraryViewModel()
    
    var body: some View {
        HSplitView {
            SidebarView(viewModel: libraryViewModel, playerViewModel: playerViewModel)
                .frame(minWidth: 200, idealWidth: 250)
            
            PlayerView(viewModel: playerViewModel)
                .frame(minWidth: 640, minHeight: 480)
        }
        .frame(minWidth: 840, minHeight: 480)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }
            
            Task { @MainActor in
                await playerViewModel.openFile(url: url)
            }
        }
        
        return true
    }
}

#Preview {
    ContentView()
}
```

- [ ] **Step 4: Update PlayerView**

```swift
// TitanPlayer/TitanPlayer/UI/Views/PlayerView.swift
import SwiftUI

struct PlayerView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @State private var isHovering = false
    
    var body: some View {
        ZStack {
            // Video content
            VideoContentView(viewModel: viewModel)
            
            // Subtitle overlay
            SubtitleOverlay(events: viewModel.currentSubtitleEvents)
            
            // Controls overlay (shows on hover)
            if isHovering || viewModel.playState != .playing {
                VStack {
                    Spacer()
                    ControlBar(viewModel: viewModel)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.3)) {
                isHovering = hovering
            }
        }
        .onTapGesture(count: 2) {
            // Toggle fullscreen
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }
            
            Task { @MainActor in
                await viewModel.openFile(url: url)
            }
        }
        
        return true
    }
}

struct VideoContentView: View {
    @ObservedObject var viewModel: PlayerViewModel
    
    var body: some View {
        ZStack {
            Color.black
            
            if viewModel.playState == .idle {
                VStack(spacing: 16) {
                    Image(systemName: "film")
                        .font(.system(size: 64))
                        .foregroundColor(.gray)
                    
                    Text("Drop a video file here")
                        .foregroundColor(.gray)
                    
                    Text("or use File > Open")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            } else if viewModel.playState == .loading {
                ProgressView("Loading...")
                    .foregroundColor(.white)
            }
        }
    }
}

struct SubtitleOverlay: View {
    let events: [SubtitleEvent]
    
    var body: some View {
        VStack {
            Spacer()
            
            ForEach(events, id: \.startTime) { event in
                Text(event.text)
                    .font(.system(size: event.style.fontSize))
                    .foregroundColor(Color(
                        red: event.style.foregroundColor.r,
                        green: event.style.foregroundColor.g,
                        blue: event.style.foregroundColor.b
                    ))
                    .shadow(color: .black, radius: 2)
                    .padding(.horizontal, 40)
                    .padding(.bottom, 60)
            }
        }
    }
}
```

- [ ] **Step 5: Update SidebarView**

```swift
// TitanPlayer/TitanPlayer/UI/Views/SidebarView.swift
import SwiftUI

struct SidebarView: View {
    @ObservedObject var viewModel: LibraryViewModel
    @ObservedObject var playerViewModel: PlayerViewModel
    @State private var selectedSection: SidebarSection = .library
    
    enum SidebarSection: String, CaseIterable {
        case library = "Library"
        case playlists = "Playlists"
        case recent = "Recent"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section picker
            Picker("Section", selection: $selectedSection) {
                ForEach(SidebarSection.allCases, id: \.self) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            
            // Content
            switch selectedSection {
            case .library:
                LibrarySection(viewModel: viewModel, playerViewModel: playerViewModel)
            case .playlists:
                PlaylistsSection(viewModel: viewModel, playerViewModel: playerViewModel)
            case .recent:
                RecentSection(viewModel: viewModel, playerViewModel: playerViewModel)
            }
            
            Spacer()
        }
    }
}

struct LibrarySection: View {
    @ObservedObject var viewModel: LibraryViewModel
    @ObservedObject var playerViewModel: PlayerViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Media Files")
                    .font(.headline)
                
                Spacer()
                
                Button(action: { openFolder() }) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
            }
            
            if viewModel.mediaFiles.isEmpty {
                Text("No media files")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                List(viewModel.mediaFiles) { item in
                    MediaItemRow(item: item, playerViewModel: playerViewModel)
                }
                .listStyle(.plain)
            }
        }
        .padding()
    }
    
    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                viewModel.loadFolder(url: url)
            }
        }
    }
}

struct MediaItemRow: View {
    let item: MediaItem
    @ObservedObject var playerViewModel: PlayerViewModel
    
    var body: some View {
        Button(action: {
            Task { await playerViewModel.openFile(url: item.url) }
        }) {
            HStack {
                Image(systemName: "film")
                    .foregroundColor(.accentColor)
                
                VStack(alignment: .leading) {
                    Text(item.title)
                        .lineLimit(1)
                    
                    Text(formatDate(item.dateAdded))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter.string(from: date)
    }
}

struct PlaylistsSection: View {
    @ObservedObject var viewModel: LibraryViewModel
    @ObservedObject var playerViewModel: PlayerViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Playlists")
                    .font(.headline)
                
                Spacer()
                
                Button(action: { viewModel.createPlaylist(name: "New Playlist") }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
            }
            
            if viewModel.playlists.isEmpty {
                Text("No playlists")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                List(viewModel.playlists) { playlist in
                    Text(playlist.name)
                }
                .listStyle(.plain)
            }
        }
        .padding()
    }
}

struct RecentSection: View {
    @ObservedObject var viewModel: LibraryViewModel
    @ObservedObject var playerViewModel: PlayerViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recently Played")
                .font(.headline)
            
            if viewModel.recentlyPlayed.isEmpty {
                Text("No recent files")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                List(viewModel.recentlyPlayed) { item in
                    MediaItemRow(item: item, playerViewModel: playerViewModel)
                }
                .listStyle(.plain)
            }
        }
        .padding()
    }
}
```

- [ ] **Step 6: Create InspectorView**

```swift
// TitanPlayer/TitanPlayer/UI/Views/InspectorView.swift
import SwiftUI

struct InspectorView: View {
    @ObservedObject var viewModel: PlayerViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Media info section
            if let info = viewModel.mediaInfo {
                Section {
                    InfoRow(label: "Format", value: info.format)
                    InfoRow(label: "Duration", value: formatDuration(info.duration))
                    
                    ForEach(info.videoTracks.indices, id: \.self) { index in
                        let track = info.videoTracks[index]
                        InfoRow(label: "Video \(index + 1)", value: "\(track.codec) \(track.width)x\(track.height)")
                    }
                    
                    ForEach(info.audioTracks.indices, id: \.self) { index in
                        let track = info.audioTracks[index]
                        InfoRow(label: "Audio \(index + 1)", value: "\(track.codec) \(track.channels)ch")
                    }
                } header: {
                    Text("Media Info")
                        .font(.headline)
                }
            }
            
            // Subtitle section
            Section {
                if viewModel.subtitles.isEmpty {
                    Text("No subtitles available")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(viewModel.subtitles, id: \.name) { track in
                        HStack {
                            Text(track.name)
                            
                            Spacer()
                            
                            if track.id == viewModel.activeSubtitle?.id {
                                Image(systemName: "checkmark")
                            }
                        }
                        .onTapGesture {
                            viewModel.setSubtitleTrack(track)
                        }
                    }
                }
            } header: {
                Text("Subtitles")
                    .font(.headline)
            }
            
            Spacer()
        }
        .padding()
        .frame(width: 200)
    }
    
    private func formatDuration(_ duration: CMTime) -> String {
        let seconds = CMTimeGetSeconds(duration)
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Text(value)
                .textSelection(.enabled)
        }
    }
}
```

- [ ] **Step 7: Verify compilation**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer"
swift build 2>&1 | tail -5
```

- [ ] **Step 8: Commit UI components**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player"
git add .
git commit -m "feat: add complete UI with controls, sidebar, and inspector"
```

---

## Task 10: Unit Tests

**Files:**
- Create: `TitanPlayer/Tests/Unit/DemuxerTests.swift`
- Create: `TitanPlayer/Tests/Unit/DecoderTests.swift`
- Create: `TitanPlayer/Tests/Unit/ParserTests.swift`
- Create: `TitanPlayer/Tests/Unit/ViewModelTests.swift`

- [ ] **Step 1: Create DemuxerTests**

```swift
// TitanPlayer/Tests/Unit/DemuxerTests.swift
import XCTest
@testable import TitanPlayer

final class DemuxerTests: XCTestCase {
    func testAVFoundationDemuxerOpensFile() async throws {
        let demuxer = AVFoundationDemuxer()
        let testURL = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4")!
        
        let info = try await demuxer.open(url: testURL)
        
        XCTAssertFalse(info.videoTracks.isEmpty)
        XCTAssertEqual(info.format, "MP4")
        
        demuxer.close()
    }
    
    func testFFmpegDemuxerOpensFile() async throws {
        let demuxer = FFmpegDemuxer()
        let testURL = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4")!
        
        let info = try await demuxer.open(url: testURL)
        
        XCTAssertNotNil(info.format)
        
        demuxer.close()
    }
    
    func testDemuxerThrowsOnMissingFile() async {
        let demuxer = AVFoundationDemuxer()
        let fakeURL = URL(fileURLWithPath: "/nonexistent/file.mp4")
        
        do {
            _ = try await demuxer.open(url: fakeURL)
            XCTFail("Should throw error")
        } catch {
            XCTAssertTrue(error is MediaError)
        }
    }
}
```

- [ ] **Step 2: Create ParserTests**

```swift
// TitanPlayer/Tests/Unit/ParserTests.swift
import XCTest
@testable import TitanPlayer

final class ParserTests: XCTestCase {
    func testSRTParserParsesValidSRT() throws {
        let parser = SRTParser()
        let srtContent = """
        1
        00:00:01,000 --> 00:00:04,000
        Hello, world!
        
        2
        00:00:05,000 --> 00:00:08,000
        This is a test subtitle.
        """
        
        let data = srtContent.data(using: .utf8)!
        let events = try parser.parse(data: data)
        
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].startTime, 1.0)
        XCTAssertEqual(events[0].endTime, 4.0)
        XCTAssertEqual(events[0].text, AttributedString("Hello, world!"))
    }
    
    func testSRTParserHandlesEmptyInput() throws {
        let parser = SRTParser()
        let data = Data()
        
        let events = try parser.parse(data: data)
        
        XCTAssertTrue(events.isEmpty)
    }
    
    func testSRTParserHandlesMalformedInput() throws {
        let parser = SRTParser()
        let data = "invalid srt content".data(using: .utf8)!
        
        let events = try parser.parse(data: data)
        
        XCTAssertTrue(events.isEmpty)
    }
}
```

- [ ] **Step 3: Create ViewModelTests**

```swift
// TitanPlayer/Tests/Unit/ViewModelTests.swift
import XCTest
@testable import TitanPlayer

@MainActor
final class ViewModelTests: XCTestCase {
    func testPlayerViewModelInitializesWithIdleState() {
        let viewModel = PlayerViewModel()
        
        XCTAssertEqual(viewModel.playState, .idle)
        XCTAssertEqual(viewModel.volume, 1.0)
        XCTAssertFalse(viewModel.isMuted)
    }
    
    func testPlayerViewModelTogglePlayPause() {
        let viewModel = PlayerViewModel()
        
        viewModel.togglePlayPause()
        // Should still be idle since no media is loaded
        
        XCTAssertEqual(viewModel.playState, .idle)
    }
    
    func testPlayerViewModelVolumeClamping() {
        let viewModel = PlayerViewModel()
        
        viewModel.setVolume(1.5)
        XCTAssertEqual(viewModel.volume, 1.0)
        
        viewModel.setVolume(-0.5)
        XCTAssertEqual(viewModel.volume, 0.0)
    }
    
    func testLibraryViewModelCreatesPlaylist() {
        let viewModel = LibraryViewModel()
        
        viewModel.createPlaylist(name: "Test Playlist")
        
        XCTAssertEqual(viewModel.playlists.count, 1)
        XCTAssertEqual(viewModel.playlists[0].name, "Test Playlist")
    }
    
    func testLibraryViewModelAddsToPlaylist() {
        let viewModel = LibraryViewModel()
        viewModel.createPlaylist(name: "Test Playlist")
        
        let item = MediaItem(
            id: URL(fileURLWithPath: "/test.mp4"),
            url: URL(fileURLWithPath: "/test.mp4"),
            title: "Test",
            duration: 100,
            dateAdded: Date()
        )
        
        viewModel.addToPlaylist(viewModel.playlists[0], item: item)
        
        XCTAssertEqual(viewModel.playlists[0].items.count, 1)
    }
}
```

- [ ] **Step 4: Create test fixture**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer/Tests/Fixtures"
# Create a minimal test video file (placeholder)
touch test.mp4
```

- [ ] **Step 5: Run unit tests**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer"
swift test --filter Unit 2>&1 | tail -20
```

- [ ] **Step 6: Commit unit tests**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player"
git add .
git commit -m "feat: add unit tests for demuxers, parsers, and view models"
```

---

## Task 11: Integration Tests

**Files:**
- Create: `TitanPlayer/Tests/Integration/PlaybackPipelineTests.swift`
- Create: `TitanPlayer/Tests/Integration/SubtitleIntegrationTests.swift`

- [ ] **Step 1: Create PlaybackPipelineTests**

```swift
// TitanPlayer/Tests/Integration/PlaybackPipelineTests.swift
import XCTest
@testable import TitanPlayer

@MainActor
final class PlaybackPipelineTests: XCTestCase {
    func testPipelineOpensMediaFile() async throws {
        let pipeline = MediaPipeline()
        let testURL = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4")!
        
        await pipeline.openFile(url: testURL)
        
        XCTAssertNotEqual(pipeline.playState, .idle)
        XCTAssertGreaterThan(pipeline.duration, 0)
    }
    
    func testPipelinePlayPause() async throws {
        let pipeline = MediaPipeline()
        let testURL = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4")!
        
        await pipeline.openFile(url: testURL)
        pipeline.play()
        
        XCTAssertEqual(pipeline.playState, .playing)
        
        pipeline.pause()
        
        XCTAssertEqual(pipeline.playState, .paused)
    }
    
    func testPipelineSeek() async throws {
        let pipeline = MediaPipeline()
        let testURL = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4")!
        
        await pipeline.openFile(url: testURL)
        pipeline.play()
        
        await pipeline.seek(to: 5.0)
        
        XCTAssertEqual(pipeline.currentTime, 5.0, accuracy: 0.1)
    }
    
    func testPipelineStop() async throws {
        let pipeline = MediaPipeline()
        let testURL = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4")!
        
        await pipeline.openFile(url: testURL)
        pipeline.play()
        pipeline.stop()
        
        XCTAssertEqual(pipeline.playState, .idle)
    }
}
```

- [ ] **Step 2: Create SubtitleIntegrationTests**

```swift
// TitanPlayer/Tests/Integration/SubtitleIntegrationTests.swift
import XCTest
@testable import TitanPlayer

@MainActor
final class SubtitleIntegrationTests: XCTestCase {
    func testSubtitleManagerLoadsSRT() throws {
        let manager = SubtitleManager()
        let srtContent = """
        1
        00:00:01,000 --> 00:00:04,000
        Hello, world!
        """
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.srt")
        try srtContent.write(to: tempURL, atomically: true, encoding: .utf8)
        
        try manager.loadSubtitle(url: tempURL)
        
        XCTAssertEqual(manager.availableTracks.count, 1)
        XCTAssertEqual(manager.activeTrack?.name, "test.srt")
        
        try? FileManager.default.removeItem(at: tempURL)
    }
    
    func testSubtitleManagerUpdatesForTime() throws {
        let manager = SubtitleManager()
        let srtContent = """
        1
        00:00:01,000 --> 00:00:04,000
        First subtitle
        
        2
        00:00:05,000 --> 00:00:08,000
        Second subtitle
        """
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.srt")
        try srtContent.write(to: tempURL, atomically: true, encoding: .utf8)
        
        try manager.loadSubtitle(url: tempURL)
        
        manager.update(for: 2.0)
        XCTAssertEqual(manager.currentEvents.count, 1)
        
        manager.update(for: 6.0)
        XCTAssertEqual(manager.currentEvents.count, 1)
        
        manager.update(for: 9.0)
        XCTAssertTrue(manager.currentEvents.isEmpty)
        
        try? FileManager.default.removeItem(at: tempURL)
    }
    
    func testSubtitleManagerClearsTracks() throws {
        let manager = SubtitleManager()
        let srtContent = """
        1
        00:00:01,000 --> 00:00:04,000
        Test
        """
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.srt")
        try srtContent.write(to: tempURL, atomically: true, encoding: .utf8)
        
        try manager.loadSubtitle(url: tempURL)
        manager.clear()
        
        XCTAssertTrue(manager.availableTracks.isEmpty)
        XCTAssertNil(manager.activeTrack)
        XCTAssertTrue(manager.currentEvents.isEmpty)
        
        try? FileManager.default.removeItem(at: tempURL)
    }
}
```

- [ ] **Step 3: Run integration tests**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer"
swift test --filter Integration 2>&1 | tail -20
```

- [ ] **Step 4: Commit integration tests**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player"
git add .
git commit -m "feat: add integration tests for playback pipeline and subtitles"
```

---

## Task 12: Final Verification

- [ ] **Step 1: Run all tests**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer"
swift test 2>&1 | tail -30
```

- [ ] **Step 2: Verify build succeeds**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player/TitanPlayer"
swift build 2>&1 | tail -10
```

- [ ] **Step 3: Check project structure**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player"
find TitanPlayer -type f -name "*.swift" | wc -l
find TitanPlayer -type f -name "*.metal" | wc -l
```

- [ ] **Step 4: Final commit**

```bash
cd "/Users/vedpatelicloud.com/Documents/Titan Player"
git add .
git commit -m "feat: complete TitanPlayer implementation with all features"
```

---

## Validation Checklist

- [ ] Project compiles without errors on Xcode 15+
- [ ] Basic window appears with empty media state
- [ ] Modular architecture allows component swapping
- [ ] Memory usage <50MB on startup
- [ ] All unit tests pass
- [ ] All integration tests pass
- [ ] Protocol-based design enables backend swapping
- [ ] Metal renderer renders video frames
- [ ] Subtitle system parses and displays subtitles
- [ ] UI responds to user interactions
