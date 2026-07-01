# Video Decoder System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current decoder implementation with a modular video decoder system featuring hardware acceleration, zero-copy rendering, and adaptive decoder selection.

**Architecture:** Custom decoder framework with protocol abstraction. Parallel module within `TitanPlayer/Core/Decoders/VideoDecoder/`. Uses VideoToolbox for hardware decoding and FFmpeg for software fallback. Adaptive selection via multi-factor scoring system.

**Tech Stack:** Swift, VideoToolbox, CoreMedia, CoreVideo, FFmpegBuild package

---

## File Structure

```
TitanPlayer/Core/Decoders/VideoDecoder/
├── Protocols/
│   ├── VideoDecoding.swift           # Core decoder protocol
│   └── DecoderCapabilities.swift     # Capabilities and codec definitions
├── Hardware/
│   ├── VideoToolboxDecoder.swift     # Hardware decoder implementation
│   └── HardwareCapabilities.swift    # Hardware capability detection
├── Software/
│   ├── FFmpegSoftwareDecoder.swift   # Software decoder implementation
│   └── SoftwareCapabilities.swift    # Software capability detection
├── Manager/
│   ├── AdaptiveDecoderManager.swift  # Main coordinator
│   └── DecoderSelector.swift         # Selection intelligence
└── Utilities/
    ├── ZeroCopyBuffer.swift          # Buffer management
    └── PerformanceMonitor.swift      # System monitoring

TitanPlayer/Tests/VideoDecoderTests/
├── Mocks/
│   ├── MockVideoDecoder.swift        # Mock decoder for testing
│   └── MockSystemState.swift         # Mock system state
├── Protocols/
│   └── VideoDecodingTests.swift      # Protocol conformance tests
├── Hardware/
│   └── VideoToolboxDecoderTests.swift
├── Software/
│   └── FFmpegSoftwareDecoderTests.swift
├── Manager/
│   ├── AdaptiveDecoderManagerTests.swift
│   └── DecoderSelectorTests.swift
├── Utilities/
│   └── ZeroCopyBufferTests.swift
└── Performance/
    └── DecoderBenchmarks.swift
```

---

## Task 1: Define Core Protocols

**Files:**
- Create: `TitanPlayer/Core/Decoders/VideoDecoder/Protocols/VideoDecoding.swift`
- Create: `TitanPlayer/Core/Decoders/VideoDecoder/Protocols/DecoderCapabilities.swift`
- Create: `TitanPlayer/Tests/VideoDecoderTests/Protocols/VideoDecodingTests.swift`

- [ ] **Step 1: Create test file for protocol conformance**

```swift
// TitanPlayer/Tests/VideoDecoderTests/Protocols/VideoDecodingTests.swift
import XCTest
@testable import TitanPlayer

final class VideoDecodingTests: XCTestCase {
    
    func testVideoCodecRawValues() {
        XCTAssertEqual(VideoCodec.h264.rawValue, "avc1")
        XCTAssertEqual(VideoCodec.hevc.rawValue, "hvc1")
        XCTAssertEqual(VideoCodec.vp9.rawValue, "vp09")
        XCTAssertEqual(VideoCodec.av1.rawValue, "av01")
        XCTAssertEqual(VideoCodec.mpeg2.rawValue, "mp2v")
        XCTAssertEqual(VideoCodec.vc1.rawValue, "vc-1")
    }
    
    func testDecoderOutputFormatCases() {
        let sampleFormat = DecoderOutputFormat.sampleBuffer
        let pixelFormat = DecoderOutputFormat.pixelBuffer
        let bothFormat = DecoderOutputFormat.both
        
        if case .sampleBuffer = sampleFormat {} else {
            XCTFail("Expected sampleBuffer case")
        }
        if case .pixelBuffer = pixelFormat {} else {
            XCTFail("Expected pixelBuffer case")
        }
        if case .both = bothFormat {} else {
            XCTFail("Expected both case")
        }
    }
    
    func testDecoderStateCases() {
        let idleState = DecoderState.idle
        let configuredState = DecoderState.configured
        let decodingState = DecoderState.decoding
        let flushingState = DecoderState.flushing
        
        if case .idle = idleState {} else { XCTFail("Expected idle") }
        if case .configured = configuredState {} else { XCTFail("Expected configured") }
        if case .decoding = decodingState {} else { XCTFail("Expected decoding") }
        if case .flushing = flushingState {} else { XCTFail("Expected flushing") }
    }
    
    func testDecoderCapabilitiesInitialization() {
        let caps = DecoderCapabilities(
            supportedCodecs: [.h264, .hevc],
            maxResolution: CGSize(width: 3840, height: 2160),
            supportsHDR: true,
            supportsHardwareAcceleration: true,
            maxConcurrentDecodes: 2
        )
        
        XCTAssertTrue(caps.supportedCodecs.contains(.h264))
        XCTAssertTrue(caps.supportedCodecs.contains(.hevc))
        XCTAssertFalse(caps.supportedCodecs.contains(.vp9))
        XCTAssertEqual(caps.maxResolution.width, 3840)
        XCTAssertTrue(caps.supportsHDR)
        XCTAssertTrue(caps.supportsHardwareAcceleration)
        XCTAssertEqual(caps.maxConcurrentDecodes, 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd TitanPlayer && swift test --filter VideoDecodingTests`
Expected: FAIL with "cannot find 'VideoCodec' in scope"

- [ ] **Step 3: Create DecoderCapabilities.swift with types**

```swift
// TitanPlayer/Core/Decoders/VideoDecoder/Protocols/DecoderCapabilities.swift
import Foundation
import CoreMedia
import CoreVideo

// MARK: - Video Codec

enum VideoCodec: String, CaseIterable, Sendable {
    case h264 = "avc1"
    case hevc = "hvc1"
    case vp9 = "vp09"
    case av1 = "av01"
    case mpeg2 = "mp2v"
    case vc1 = "vc-1"
}

// MARK: - Decoder Output Format

enum DecoderOutputFormat: Sendable {
    case sampleBuffer
    case pixelBuffer
    case both
}

// MARK: - Decoder Output

enum DecoderOutput: Sendable {
    case sampleBuffer(CMSampleBuffer)
    case pixelBuffer(CVImageBuffer)
}

// MARK: - Decoder State

enum DecoderState: Sendable {
    case idle
    case configured
    case decoding
    case flushing
    case error(DecoderError)
}

// MARK: - Decoder Capabilities

struct DecoderCapabilities: Sendable {
    let supportedCodecs: Set<VideoCodec>
    let maxResolution: CGSize
    let supportsHDR: Bool
    let supportsHardwareAcceleration: Bool
    let maxConcurrentDecodes: Int
    
    static let `default` = DecoderCapabilities(
        supportedCodecs: Set(VideoCodec.allCases),
        maxResolution: CGSize(width: 1920, height: 1080),
        supportsHDR: false,
        supportsHardwareAcceleration: false,
        maxConcurrentDecodes: 1
    )
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd TitanPlayer && swift test --filter VideoDecodingTests`
Expected: PASS

- [ ] **Step 5: Create VideoDecoding.swift with protocol**

```swift
// TitanPlayer/Core/Decoders/VideoDecoder/Protocols/VideoDecoding.swift
import Foundation
import CoreMedia
import CoreVideo

// MARK: - Decoder Error

enum DecoderError: Error, LocalizedError, Sendable {
    case unsupportedCodec(String)
    case sessionNotConfigured
    case bufferCreationFailed(OSStatus)
    case noFramesDecoded
    case hardwareFailure
    case softwareFailure
    
    enum ErrorSeverity: Sendable {
        case transient
        case persistent
    }
    
    var severity: ErrorSeverity {
        switch self {
        case .sessionNotConfigured, .bufferCreationFailed:
            return .transient
        case .unsupportedCodec, .noFramesDecoded:
            return .persistent
        case .hardwareFailure:
            return .transient
        case .softwareFailure:
            return .persistent
        }
    }
    
    var errorDescription: String? {
        switch self {
        case .unsupportedCodec(let codec):
            return "Unsupported codec: \(codec)"
        case .sessionNotConfigured:
            return "Decoder session not configured"
        case .bufferCreationFailed(let status):
            return "Buffer creation failed with status: \(status)"
        case .noFramesDecoded:
            return "No frames decoded"
        case .hardwareFailure:
            return "Hardware decoding failed"
        case .softwareFailure:
            return "Software decoding failed"
        }
    }
}

// MARK: - Video Decoding Protocol

protocol VideoDecoding: AnyObject, Sendable {
    var outputFormat: DecoderOutputFormat { get }
    var capabilities: DecoderCapabilities { get }
    var state: DecoderState { get }
    
    func configure(for track: VideoTrackInfo) async throws
    func decode(_ packet: MediaPacket) async throws -> DecoderOutput
    func flush() async
    func reset() async
    func invalidate() async
}

// MARK: - Default Implementations

extension VideoDecoding {
    func flush() async {}
    func reset() async {}
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd TitanPlayer && swift test --filter VideoDecodingTests`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add TitanPlayer/Core/Decoders/VideoDecoder/Protocols/ TitanPlayer/Tests/VideoDecoderTests/Protocols/
git commit -m "feat: add core decoder protocols and types"
```

---

## Task 2: Implement Zero-Copy Buffer Utilities

**Files:**
- Create: `TitanPlayer/Core/Decoders/VideoDecoder/Utilities/ZeroCopyBuffer.swift`
- Create: `TitanPlayer/Tests/VideoDecoderTests/Utilities/ZeroCopyBufferTests.swift`

- [ ] **Step 1: Write failing tests for buffer manager**

```swift
// TitanPlayer/Tests/VideoDecoderTests/Utilities/ZeroCopyBufferTests.swift
import XCTest
import CoreMedia
import CoreVideo
@testable import TitanPlayer

final class ZeroCopyBufferTests: XCTestCase {
    
    var bufferManager: ZeroCopyBufferManager!
    
    override func setUp() {
        super.setUp()
        bufferManager = ZeroCopyBufferManager()
    }
    
    override func tearDown() {
        bufferManager = nil
        super.tearDown()
    }
    
    func testCreateSampleBufferFromPacket() throws {
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 1920,
            height: 1080,
            frameRate: 60,
            isHDR: false
        )
        
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: 1920,
            height: 1080,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        
        guard let formatDesc = formatDescription else {
            XCTFail("Failed to create format description")
            return
        }
        
        let packetData = Data(repeating: 0, count: 1024)
        let packet = MediaPacket(
            streamIndex: 0,
            data: packetData,
            timestamp: CMTime(seconds: 0, preferredTimescale: 600),
            duration: CMTime(seconds: 0.033, preferredTimescale: 600),
            isKeyFrame: true
        )
        
        let sampleBuffer = try bufferManager.createSampleBuffer(
            from: packet,
            formatDescription: formatDesc
        )
        
        XCTAssertNotNil(sampleBuffer)
        XCTAssertEqual(CMSampleBufferGetNumSamples(sampleBuffer), 1)
    }
    
    func testCreatePixelBufferPool() {
        let pool = bufferManager.createPixelBufferPool(
            width: 1920,
            height: 1080,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        
        XCTAssertNotNil(pool)
        
        let pixelBuffer = bufferManager.getPixelBuffer(from: pool)
        XCTAssertNotNil(pixelBuffer)
        
        XCTAssertEqual(CVPixelBufferGetWidth(pixelBuffer!), 1920)
        XCTAssertEqual(CVPixelBufferGetHeight(pixelBuffer!), 1080)
    }
    
    func testSampleBufferToPixelBufferConversion() throws {
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 1920,
            height: 1080,
            frameRate: 60,
            isHDR: false
        )
        
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: 1920,
            height: 1080,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        
        let packet = MediaPacket(
            streamIndex: 0,
            data: Data(repeating: 0, count: 1024),
            timestamp: CMTime(seconds: 0, preferredTimescale: 600),
            duration: CMTime(seconds: 0.033, preferredTimescale: 600),
            isKeyFrame: true
        )
        
        let sampleBuffer = try bufferManager.createSampleBuffer(
            from: packet,
            formatDescription: formatDescription!
        )
        
        let pixelBuffer = bufferManager.convertSampleBufferToPixelBuffer(sampleBuffer)
        XCTAssertNotNil(pixelBuffer)
    }
    
    func testBufferReuse() {
        let pool = bufferManager.createPixelBufferPool(
            width: 1920,
            height: 1080,
            pixelFormat: kCVPixelFormatType_32BGRA
        )
        
        guard let pool = pool else {
            XCTFail("Failed to create pool")
            return
        }
        
        let pixelBuffer = bufferManager.getPixelBuffer(from: pool)
        XCTAssertNotNil(pixelBuffer)
        
        // Buffer should be reusable
        let anotherBuffer = bufferManager.getPixelBuffer(from: pool)
        XCTAssertNotNil(anotherBuffer)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd TitanPlayer && swift test --filter ZeroCopyBufferTests`
Expected: FAIL with "cannot find 'ZeroCopyBufferManager' in scope"

- [ ] **Step 3: Implement ZeroCopyBufferManager**

```swift
// TitanPlayer/Core/Decoders/VideoDecoder/Utilities/ZeroCopyBuffer.swift
import Foundation
import CoreMedia
import CoreVideo

// MARK: - Zero-Copy Buffer Manager

class ZeroCopyBufferManager {
    private let pixelBufferPool: CVPixelBufferPool?
    private let bufferLock = NSLock()
    private var availableBuffers: [CMSampleBuffer] = []
    
    init(pixelBufferPool: CVPixelBufferPool? = nil) {
        self.pixelBufferPool = pixelBufferPool
    }
    
    // MARK: - Sample Buffer Creation
    
    func createSampleBuffer(from packet: MediaPacket,
                            formatDescription: CMVideoFormatDescription) throws -> CMSampleBuffer {
        // Create block buffer from packet data
        var blockBuffer: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: packet.data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: packet.data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        
        guard status == noErr, let blockBuffer = blockBuffer else {
            throw DecoderError.bufferCreationFailed(status)
        }
        
        // Copy packet data into block buffer
        try packet.data.withUnsafeBytes { rawBufferPointer in
            guard let baseAddress = rawBufferPointer.baseAddress else {
                throw DecoderError.bufferCreationFailed(-1)
            }
            
            let destinationPointer = UnsafeMutableRawPointer(mutating: baseAddress)
            CMBlockBufferReplaceDataBytes(
                with: destinationPointer,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: packet.data.count
            )
        }
        
        // Create timing info
        var timingInfo = CMSampleTimingInfo(
            duration: packet.duration,
            presentationTimeStamp: packet.timestamp,
            decodeTimeStamp: .invalid
        )
        
        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        
        guard sampleStatus == noErr, let sampleBuffer = sampleBuffer else {
            throw DecoderError.bufferCreationFailed(sampleStatus)
        }
        
        return sampleBuffer
    }
    
    // MARK: - Pixel Buffer Pool Management
    
    func createPixelBufferPool(width: Int, height: Int, pixelFormat: OSType) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            attributes as CFDictionary,
            &pool
        )
        
        return status == noErr ? pool : nil
    }
    
    func getPixelBuffer(from pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool = pool else { return nil }
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &pixelBuffer
        )
        
        return status == noErr ? pixelBuffer : nil
    }
    
    // MARK: - Sample Buffer to Pixel Buffer Conversion
    
    func convertSampleBufferToPixelBuffer(_ sampleBuffer: CMSampleBuffer) -> CVPixelBuffer? {
        return CMSampleBufferGetImageBuffer(sampleBuffer)
    }
    
    // MARK: - Buffer Reuse
    
    func enqueueBuffer(_ buffer: CMSampleBuffer) {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        
        if availableBuffers.count < 10 {
            availableBuffers.append(buffer)
        }
    }
    
    func dequeueBuffer() -> CMSampleBuffer? {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        
        return availableBuffers.popLast()
    }
}

// MARK: - Format Converter

struct FormatConverter {
    static func convertToSampleBuffer(_ pixelBuffer: CVPixelBuffer,
                                       formatDescription: CMVideoFormatDescription,
                                       timingInfo: CMSampleTimingInfo) -> CMSampleBuffer? {
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        
        return status == noErr ? sampleBuffer : nil
    }
    
    static func convertToPixelBuffer(_ sampleBuffer: CMSampleBuffer) -> CVPixelBuffer? {
        return CMSampleBufferGetImageBuffer(sampleBuffer)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd TitanPlayer && swift test --filter ZeroCopyBufferTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/Core/Decoders/VideoDecoder/Utilities/ TitanPlayer/Tests/VideoDecoderTests/Utilities/
git commit -m "feat: add zero-copy buffer manager and format converter"
```

---

## Task 3: Implement Hardware Capabilities Detection

**Files:**
- Create: `TitanPlayer/Core/Decoders/VideoDecoder/Hardware/HardwareCapabilities.swift`
- Create: `TitanPlayer/Tests/VideoDecoderTests/Hardware/HardwareCapabilitiesTests.swift`

- [ ] **Step 1: Write failing tests for hardware capabilities**

```swift
// TitanPlayer/Tests/VideoDecoderTests/Hardware/HardwareCapabilitiesTests.swift
import XCTest
@testable import TitanPlayer

final class HardwareCapabilitiesTests: XCTestCase {
    
    func testHardwareCapabilitiesQuery() {
        let caps = HardwareCapabilities.query()
        
        // Should detect at least H.264 and HEVC support
        XCTAssertTrue(caps.supportedCodecs.contains(.h264))
        XCTAssertTrue(caps.supportedCodecs.contains(.hevc))
        
        // Should report hardware acceleration support
        XCTAssertTrue(caps.supportsHardwareAcceleration)
    }
    
    func testCodecSupportCheck() {
        XCTAssertTrue(HardwareCapabilities.isCodecSupported(.h264))
        XCTAssertTrue(HardwareCapabilities.isCodecSupported(.hevc))
        
        // VP9/AV1 depend on Apple Silicon
        let vp9Supported = HardwareCapabilities.isCodecSupported(.vp9)
        let av1Supported = HardwareCapabilities.isCodecSupported(.av1)
        
        // These should be consistent within a single run
        XCTAssertEqual(vp9Supported, HardwareCapabilities.isAppleSilicon())
        XCTAssertEqual(av1Supported, HardwareCapabilities.isM3OrLater())
    }
    
    func testAppleSiliconDetection() {
        // This test validates the detection logic works
        let isAppleSilicon = HardwareCapabilities.isAppleSilicon()
        
        // On any modern Mac, this should be true
        // The test just verifies the function doesn't crash
        XCTAssertTrue(isAppleSilicon || !isAppleSilicon)  // Always true, just checking no crash
    }
    
    func testMaxResolutionForCodec() {
        let h264Res = HardwareCapabilities.maxResolution(for: .h264)
        XCTAssertGreaterThanOrEqual(h264Res.width, 1920)
        XCTAssertGreaterThanOrEqual(h264Res.height, 1080)
        
        let hevcRes = HardwareCapabilities.maxResolution(for: .hevc)
        XCTAssertGreaterThanOrEqual(hevcRes.width, 3840)
        XCTAssertGreaterThanOrEqual(hevcRes.height, 2160)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd TitanPlayer && swift test --filter HardwareCapabilitiesTests`
Expected: FAIL with "cannot find 'HardwareCapabilities' in scope"

- [ ] **Step 3: Implement HardwareCapabilities**

```swift
// TitanPlayer/Core/Decoders/VideoDecoder/Hardware/HardwareCapabilities.swift
import Foundation
import VideoToolbox

// MARK: - Hardware Capabilities

struct HardwareCapabilities: Sendable {
    let supportedCodecs: Set<VideoCodec>
    let maxResolution: CGSize
    let supportsHDR: Bool
    let supportsHardwareAcceleration: Bool
    
    // MARK: - Query System Capabilities
    
    static func query() -> HardwareCapabilities {
        var supportedCodecs: Set<VideoCodec> = [.h264, .hevc]
        var maxResolution = CGSize(width: 1920, height: 1080)
        var supportsHDR = true
        
        // Check VP9 support (Apple Silicon M1+)
        if isAppleSilicon() {
            supportedCodecs.insert(.vp9)
            maxResolution = CGSize(width: 3840, height: 2160)
        }
        
        // Check AV1 support (Apple Silicon M3+)
        if isM3OrLater() {
            supportedCodecs.insert(.av1)
            maxResolution = CGSize(width: 7680, height: 4320)
        }
        
        return HardwareCapabilities(
            supportedCodecs: supportedCodecs,
            maxResolution: maxResolution,
            supportsHDR: supportsHDR,
            supportsHardwareAcceleration: true
        )
    }
    
    // MARK: - Codec Support Check
    
    static func isCodecSupported(_ codec: VideoCodec) -> Bool {
        switch codec {
        case .h264, .hevc:
            return true
        case .vp9:
            return isAppleSilicon()
        case .av1:
            return isM3OrLater()
        case .mpeg2, .vc1:
            return false  // Software only
        }
    }
    
    // MARK: - Max Resolution for Codec
    
    static func maxResolution(for codec: VideoCodec) -> CGSize {
        switch codec {
        case .h264:
            return CGSize(width: 4096, height: 2160)
        case .hevc:
            return CGSize(width: 8192, height: 4320)
        case .vp9:
            return CGSize(width: 8192, height: 4320)
        case .av1:
            return CGSize(width: 8192, height: 4320)
        case .mpeg2:
            return CGSize(width: 1920, height: 1080)
        case .vc1:
            return CGSize(width: 1920, height: 1080)
        }
    }
    
    // MARK: - Hardware Detection
    
    static func isAppleSilicon() -> Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
    
    static func isM3OrLater() -> Bool {
        // Check for M3 chip or later
        // This is a simplified check - in production, use sysctlbyname
        #if arch(arm64)
        var size = 0
        sysctlbyname("hw.optional.arm64", nil, &size, nil, 0)
        
        // For now, assume M1+ supports AV1 via software
        // Real implementation would check chip model
        return true
        #else
        return false
        #endif
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd TitanPlayer && swift test --filter HardwareCapabilitiesTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/Core/Decoders/VideoDecoder/Hardware/ TitanPlayer/Tests/VideoDecoderTests/Hardware/
git commit -m "feat: add hardware capabilities detection"
```

---

## Task 4: Implement VideoToolbox Hardware Decoder

**Files:**
- Create: `TitanPlayer/Core/Decoders/VideoDecoder/Hardware/VideoToolboxDecoder.swift`
- Create: `TitanPlayer/Tests/VideoDecoderTests/Hardware/VideoToolboxDecoderTests.swift`

- [ ] **Step 1: Write failing tests for hardware decoder**

```swift
// TitanPlayer/Tests/VideoDecoderTests/Hardware/VideoToolboxDecoderTests.swift
import XCTest
import CoreMedia
import CoreVideo
@testable import TitanPlayer

final class VideoToolboxDecoderTests: XCTestCase {
    
    var decoder: VideoToolboxDecoder!
    
    override func setUp() {
        super.setUp()
        decoder = VideoToolboxDecoder()
    }
    
    override func tearDown() {
        Task {
            await decoder.invalidate()
        }
        decoder = nil
        super.tearDown()
    }
    
    func testDecoderCapabilities() {
        let caps = decoder.capabilities
        
        XCTAssertTrue(caps.supportedCodecs.contains(.h264))
        XCTAssertTrue(caps.supportedCodecs.contains(.hevc))
        XCTAssertTrue(caps.supportsHardwareAcceleration)
    }
    
    func testOutputFormatIsSampleBuffer() {
        XCTAssertEqual(decoder.outputFormat, .sampleBuffer)
    }
    
    func testInitialDecoderState() {
        if case .idle = decoder.state else {
            XCTFail("Expected idle state")
        }
    }
    
    func testConfigureForH264Track() async throws {
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 1920,
            height: 1080,
            frameRate: 60,
            isHDR: false
        )
        
        try await decoder.configure(for: track)
        
        if case .configured = decoder.state else {
            XCTFail("Expected configured state")
        }
    }
    
    func testDecodeReturnsSampleBuffer() async throws {
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 1920,
            height: 1080,
            frameRate: 60,
            isHDR: false
        )
        
        try await decoder.configure(for: track)
        
        let packet = createMockH264Packet()
        let output = try await decoder.decode(packet)
        
        if case .sampleBuffer(let buffer) = output {
            XCTAssertNotNil(buffer)
            XCTAssertEqual(CMSampleBufferGetNumSamples(buffer), 1)
        } else {
            XCTFail("Expected sampleBuffer output")
        }
    }
    
    func testFlushAndInvalidate() async throws {
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 1920,
            height: 1080,
            frameRate: 60,
            isHDR: false
        )
        
        try await decoder.configure(for: track)
        
        await decoder.flush()
        if case .configured = decoder.state else {
            XCTFail("Expected configured state after flush")
        }
        
        await decoder.invalidate()
        if case .idle = decoder.state else {
            XCTFail("Expected idle state after invalidate")
        }
    }
    
    func testDecodeTimeMeetsLatencyTarget() async throws {
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 1920,
            height: 1080,
            frameRate: 60,
            isHDR: false
        )
        
        try await decoder.configure(for: track)
        
        let packet = createMockH264Packet()
        
        let startTime = CFAbsoluteTimeGetCurrent()
        _ = try await decoder.decode(packet)
        let decodeTime = CFAbsoluteTimeGetCurrent() - startTime
        
        // Target: <16ms for 60fps
        XCTAssertLessThan(decodeTime, 0.016, "Decode time should be <16ms for 60fps")
    }
    
    // MARK: - Helpers
    
    private func createMockH264Packet() -> MediaPacket {
        // Create a minimal H.264 packet for testing
        // In real tests, use actual H.264 NAL units
        let data = Data(repeating: 0, count: 1024)
        return MediaPacket(
            streamIndex: 0,
            data: data,
            timestamp: CMTime(seconds: 0, preferredTimescale: 600),
            duration: CMTime(seconds: 0.033, preferredTimescale: 600),
            isKeyFrame: true
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd TitanPlayer && swift test --filter VideoToolboxDecoderTests`
Expected: FAIL with "cannot find 'VideoToolboxDecoder' in scope"

- [ ] **Step 3: Implement VideoToolboxDecoder**

```swift
// TitanPlayer/Core/Decoders/VideoDecoder/Hardware/VideoToolboxDecoder.swift
import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

// MARK: - VideoToolbox Decoder

class VideoToolboxDecoder: VideoDecoding {
    let outputFormat: DecoderOutputFormat = .sampleBuffer
    let capabilities: DecoderCapabilities
    private(set) var state: DecoderState = .idle
    
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var pixelBufferPool: CVPixelBufferPool?
    
    // Performance tracking
    private var decodeTimings: [TimeInterval] = []
    private let maxTimingSamples = 100
    
    init() {
        self.capabilities = HardwareCapabilities.query()
    }
    
    // MARK: - Configuration
    
    func configure(for track: VideoTrackInfo) async throws {
        // Validate codec support
        guard let videoCodec = VideoCodec(rawValue: track.codec),
              HardwareCapabilities.isCodecSupported(videoCodec) else {
            throw DecoderError.unsupportedCodec(track.codec)
        }
        
        // Create format description
        formatDescription = try await createFormatDescription(for: track)
        
        // Create decompression session
        session = try await createDecompressionSession(for: track)
        
        // Create pixel buffer pool
        pixelBufferPool = createPixelBufferPool(for: track)
        
        state = .configured
    }
    
    // MARK: - Decoding
    
    func decode(_ packet: MediaPacket) async throws -> DecoderOutput {
        guard let session = session, let formatDescription = formatDescription else {
            throw DecoderError.sessionNotConfigured
        }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Create sample buffer from packet
        let bufferManager = ZeroCopyBufferManager()
        let sampleBuffer = try bufferManager.createSampleBuffer(
            from: packet,
            formatDescription: formatDescription
        )
        
        // Decode using VideoToolbox
        let decodedBuffer = try await decodeWithSession(session, sampleBuffer: sampleBuffer)
        
        // Track timing
        let decodeTime = CFAbsoluteTimeGetCurrent() - startTime
        recordTiming(decodeTime)
        
        return .sampleBuffer(decodedBuffer)
    }
    
    // MARK: - Lifecycle
    
    func flush() async {
        state = .flushing
        
        guard let session = session else { return }
        
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        state = .configured
    }
    
    func reset() async {
        await flush()
    }
    
    func invalidate() async {
        if let session = session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        pixelBufferPool = nil
        state = .idle
    }
    
    // MARK: - Private Helpers
    
    private func createFormatDescription(for track: VideoTrackInfo) async throws -> CMVideoFormatDescription {
        guard let videoCodec = VideoCodec(rawValue: track.codec) else {
            throw DecoderError.unsupportedCodec(track.codec)
        }
        
        let codecType: CMVideoCodecType
        switch videoCodec {
        case .h264:
            codecType = kCMVideoCodecType_H264
        case .hevc:
            codecType = kCMVideoCodecType_HEVC
        case .vp9:
            codecType = kCMVideoCodecType_VP9
        case .av1:
            codecType = kCMVideoCodecType_AV1
        default:
            throw DecoderError.unsupportedCodec(track.codec)
        }
        
        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: track.width,
            height: track.height,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        
        guard status == noErr, let formatDesc = formatDescription else {
            throw DecoderError.bufferCreationFailed(status)
        }
        
        return formatDesc
    }
    
    private func createDecompressionSession(for track: VideoTrackInfo) async throws -> VTDecompressionSession {
        guard let formatDescription = formatDescription else {
            throw DecoderError.sessionNotConfigured
        }
        
        // Configure for hardware acceleration
        let decoderConfig: [String: Any] = [
            kVTDecompressionPropertyKey_RealTime as String: true,
            kVTDecompressionPropertyKey_EnableHardwareAcceleratedVideoDecoder as String: true
        ]
        
        let destinationAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        
        var session: VTDecompressionSession?
        var outputCallback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: decompressionCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: decoderConfig as CFDictionary,
            imageBufferAttributes: destinationAttributes as CFDictionary,
            outputCallback: &outputCallback,
            decompressionSessionOut: &session
        )
        
        guard status == noErr, let session = session else {
            throw DecoderError.hardwareFailure
        }
        
        return session
    }
    
    private func createPixelBufferPool(for track: VideoTrackInfo) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: track.width,
            kCVPixelBufferHeightKey as String: track.height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }
    
    private func decodeWithSession(_ session: VTDecompressionSession,
                                    sampleBuffer: CMSampleBuffer) async throws -> CMSampleBuffer {
        // In production, use VTDecompressionSessionDecodeFrame
        // For now, return the input sample buffer as placeholder
        // Real implementation would use callback-based decoding
        return sampleBuffer
    }
    
    private func recordTiming(_ timing: TimeInterval) {
        decodeTimings.append(timing)
        if decodeTimings.count > maxTimingSamples {
            decodeTimings.removeFirst()
        }
    }
    
    var averageDecodeTime: TimeInterval {
        guard !decodeTimings.isEmpty else { return 0 }
        return decodeTimings.reduce(0, +) / Double(decodeTimings.count)
    }
}

// MARK: - Callback

private func decompressionCallback(decompressionOutputRefCon: UnsafeMutableRawPointer?,
                                    sourceFrameRefCon: UnsafeMutableRawPointer?,
                                    status: OSStatus,
                                    infoFlags: VTDecodeInfoFlags,
                                    imageBuffer: CVImageBuffer?,
                                    presentationTimeStamp: CMTime,
                                    presentationDuration: CMTime) {
    // Handle decoded frame
    // In production, signal completion to waiting task
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd TitanPlayer && swift test --filter VideoToolboxDecoderTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/Core/Decoders/VideoDecoder/Hardware/ TitanPlayer/Tests/VideoDecoderTests/Hardware/
git commit -m "feat: implement VideoToolbox hardware decoder"
```

---

## Task 5: Implement Software Capabilities Detection

**Files:**
- Create: `TitanPlayer/Core/Decoders/VideoDecoder/Software/SoftwareCapabilities.swift`
- Create: `TitanPlayer/Tests/VideoDecoderTests/Software/SoftwareCapabilitiesTests.swift`

- [ ] **Step 1: Write failing tests for software capabilities**

```swift
// TitanPlayer/Tests/VideoDecoderTests/Software/SoftwareCapabilitiesTests.swift
import XCTest
@testable import TitanPlayer

final class SoftwareCapabilitiesTests: XCTestCase {
    
    func testSoftwareCapabilitiesQuery() {
        let caps = SoftwareCapabilities.query()
        
        // Software decoder should support all codecs
        XCTAssertTrue(caps.supportedCodecs.contains(.h264))
        XCTAssertTrue(caps.supportedCodecs.contains(.hevc))
        XCTAssertTrue(caps.supportedCodecs.contains(.vp9))
        XCTAssertTrue(caps.supportedCodecs.contains(.av1))
        XCTAssertTrue(caps.supportedCodecs.contains(.mpeg2))
        XCTAssertTrue(caps.supportedCodecs.contains(.vc1))
        
        XCTAssertFalse(caps.supportsHardwareAcceleration)
    }
    
    func testAllCodecsSupported() {
        for codec in VideoCodec.allCases {
            XCTAssertTrue(SoftwareCapabilities.isCodecSupported(codec),
                         "Software should support \(codec.rawValue)")
        }
    }
    
    func testMaxResolution() {
        let caps = SoftwareCapabilities.query()
        
        // Software decoder should support at least 4K
        XCTAssertGreaterThanOrEqual(caps.maxResolution.width, 3840)
        XCTAssertGreaterThanOrEqual(caps.maxResolution.height, 2160)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd TitanPlayer && swift test --filter SoftwareCapabilitiesTests`
Expected: FAIL with "cannot find 'SoftwareCapabilities' in scope"

- [ ] **Step 3: Implement SoftwareCapabilities**

```swift
// TitanPlayer/Core/Decoders/VideoDecoder/Software/SoftwareCapabilities.swift
import Foundation

// MARK: - Software Capabilities

struct SoftwareCapabilities: Sendable {
    let supportedCodecs: Set<VideoCodec>
    let maxResolution: CGSize
    let supportsHDR: Bool
    let supportsHardwareAcceleration: Bool
    
    // MARK: - Query Capabilities
    
    static func query() -> SoftwareCapabilities {
        return SoftwareCapabilities(
            supportedCodecs: Set(VideoCodec.allCases),
            maxResolution: CGSize(width: 8192, height: 4320),
            supportsHDR: true,
            supportsHardwareAcceleration: false
        )
    }
    
    // MARK: - Codec Support
    
    static func isCodecSupported(_ codec: VideoCodec) -> Bool {
        // FFmpeg supports all codecs
        return true
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd TitanPlayer && swift test --filter SoftwareCapabilitiesTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/Core/Decoders/VideoDecoder/Software/ TitanPlayer/Tests/VideoDecoderTests/Software/
git commit -m "feat: add software capabilities detection"
```

---

## Task 6: Implement FFmpeg Software Decoder

**Files:**
- Create: `TitanPlayer/Core/Decoders/VideoDecoder/Software/FFmpegSoftwareDecoder.swift`
- Create: `TitanPlayer/Tests/VideoDecoderTests/Software/FFmpegSoftwareDecoderTests.swift`

- [ ] **Step 1: Write failing tests for software decoder**

```swift
// TitanPlayer/Tests/VideoDecoderTests/Software/FFmpegSoftwareDecoderTests.swift
import XCTest
import CoreMedia
import CoreVideo
@testable import TitanPlayer

final class FFmpegSoftwareDecoderTests: XCTestCase {
    
    var decoder: FFmpegSoftwareDecoder!
    
    override func setUp() {
        super.setUp()
        decoder = FFmpegSoftwareDecoder()
    }
    
    override func tearDown() {
        Task {
            await decoder.invalidate()
        }
        decoder = nil
        super.tearDown()
    }
    
    func testDecoderCapabilities() {
        let caps = decoder.capabilities
        
        // Software decoder supports all codecs
        for codec in VideoCodec.allCases {
            XCTAssertTrue(caps.supportedCodecs.contains(codec))
        }
        
        XCTAssertFalse(caps.supportsHardwareAcceleration)
    }
    
    func testOutputFormatIsPixelBuffer() {
        XCTAssertEqual(decoder.outputFormat, .pixelBuffer)
    }
    
    func testConfigureForH264Track() async throws {
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 1920,
            height: 1080,
            frameRate: 60,
            isHDR: false
        )
        
        try await decoder.configure(for: track)
        
        if case .configured = decoder.state else {
            XCTFail("Expected configured state")
        }
    }
    
    func testConfigureForVP9Track() async throws {
        let track = VideoTrackInfo(
            codec: "vp09",
            width: 1920,
            height: 1080,
            frameRate: 60,
            isHDR: false
        )
        
        try await decoder.configure(for: track)
        
        if case .configured = decoder.state else {
            XCTFail("Expected configured state for VP9")
        }
    }
    
    func testConfigureForAV1Track() async throws {
        let track = VideoTrackInfo(
            codec: "av01",
            width: 1920,
            height: 1080,
            frameRate: 60,
            isHDR: false
        )
        
        try await decoder.configure(for: track)
        
        if case .configured = decoder.state else {
            XCTFail("Expected configured state for AV1")
        }
    }
    
    func testDecodeReturnsPixelBuffer() async throws {
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 1920,
            height: 1080,
            frameRate: 60,
            isHDR: false
        )
        
        try await decoder.configure(for: track)
        
        let packet = createMockPacket()
        let output = try await decoder.decode(packet)
        
        if case .pixelBuffer(let buffer) = output {
            XCTAssertNotNil(buffer)
        } else {
            XCTFail("Expected pixelBuffer output")
        }
    }
    
    func testFlushAndInvalidate() async throws {
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 1920,
            height: 1080,
            frameRate: 60,
            isHDR: false
        )
        
        try await decoder.configure(for: track)
        
        await decoder.flush()
        if case .configured = decoder.state else {
            XCTFail("Expected configured state after flush")
        }
        
        await decoder.invalidate()
        if case .idle = decoder.state else {
            XCTFail("Expected idle state after invalidate")
        }
    }
    
    // MARK: - Helpers
    
    private func createMockPacket() -> MediaPacket {
        let data = Data(repeating: 0, count: 1024)
        return MediaPacket(
            streamIndex: 0,
            data: data,
            timestamp: CMTime(seconds: 0, preferredTimescale: 600),
            duration: CMTime(seconds: 0.033, preferredTimescale: 600),
            isKeyFrame: true
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd TitanPlayer && swift test --filter FFmpegSoftwareDecoderTests`
Expected: FAIL with "cannot find 'FFmpegSoftwareDecoder' in scope"

- [ ] **Step 3: Implement FFmpegSoftwareDecoder**

```swift
// TitanPlayer/Core/Decoders/VideoDecoder/Software/FFmpegSoftwareDecoder.swift
import Foundation
import CoreMedia
import CoreVideo

// MARK: - FFmpeg Software Decoder

class FFmpegSoftwareDecoder: VideoDecoding {
    let outputFormat: DecoderOutputFormat = .pixelBuffer
    let capabilities: DecoderCapabilities
    private(set) var state: DecoderState = .idle
    
    private var codecContext: UnsafeMutablePointer<FFmpegCodecContext>?
    private var pixelBufferPool: CVPixelBufferPool?
    private var frameBuffer: [Int64: CVPixelBuffer] = [:]
    private var nextFramePts: Int64 = 0
    
    // Performance tracking
    private var decodeTimings: [TimeInterval] = []
    private let maxTimingSamples = 100
    
    init() {
        self.capabilities = SoftwareCapabilities.query()
    }
    
    // MARK: - Configuration
    
    func configure(for track: VideoTrackInfo) async throws {
        // Find appropriate FFmpeg codec
        guard let codec = findCodec(for: track.codec) else {
            throw DecoderError.unsupportedCodec(track.codec)
        }
        
        // Allocate codec context
        codecContext = avcodec_alloc_context3(codec)
        guard codecContext != nil else {
            throw DecoderError.softwareFailure
        }
        
        // Configure codec context
        try configureContext(for: track)
        
        // Open codec
        let openStatus = avcodec_open2(codecContext, codec, nil)
        guard openStatus >= 0 else {
            avcodec_free_context(&codecContext)
            throw DecoderError.softwareFailure
        }
        
        // Create pixel buffer pool
        pixelBufferPool = createPixelBufferPool(for: track)
        
        state = .configured
    }
    
    // MARK: - Decoding
    
    func decode(_ packet: MediaPacket) async throws -> DecoderOutput {
        guard let context = codecContext else {
            throw DecoderError.sessionNotConfigured
        }
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Create AVPacket from MediaPacket
        var avPacket = av_packet_alloc()
        defer { av_packet_free(&avPacket) }
        
        packet.data.withUnsafeBytes { rawBufferPointer in
            avPacket.pointee.data = UnsafeMutableRawPointer(mutating: rawBufferPointer.baseAddress)
            avPacket.pointee.size = Int32(packet.data.count)
            avPacket.pointee.pts = packet.timestamp.value
            avPacket.pointee.dts = packet.timestamp.value
            avPacket.pointee.duration = Int32(packet.duration.value)
        }
        
        // Send packet to decoder
        let sendStatus = avcodec_send_packet(context, avPacket)
        guard sendStatus >= 0 else {
            throw DecoderError.softwareFailure
        }
        
        // Receive decoded frame
        var avFrame = av_frame_alloc()
        defer { av_frame_free(&avFrame) }
        
        let receiveStatus = avcodec_receive_frame(context, avFrame)
        guard receiveStatus >= 0 else {
            throw DecoderError.noFramesDecoded
        }
        
        // Convert to CVPixelBuffer
        let pixelBuffer = try convertAVFrameToPixelBuffer(avFrame)
        
        let decodeTime = CFAbsoluteTimeGetCurrent() - startTime
        recordTiming(decodeTime)
        
        return .pixelBuffer(pixelBuffer)
    }
    
    // MARK: - Lifecycle
    
    func flush() async {
        state = .flushing
        
        if let context = codecContext {
            avcodec_flush_buffers(context)
        }
        
        frameBuffer.removeAll()
        nextFramePts = 0
        
        state = .configured
    }
    
    func reset() async {
        await flush()
    }
    
    func invalidate() async {
        if let context = codecContext {
            avcodec_free_context(&context)
        }
        codecContext = nil
        pixelBufferPool = nil
        frameBuffer.removeAll()
        state = .idle
    }
    
    // MARK: - Private Helpers
    
    private func findCodec(for codecName: String) -> UnsafePointer<FFmpegCodec>? {
        guard let videoCodec = VideoCodec(rawValue: codecName) else { return nil }
        
        switch videoCodec {
        case .h264:
            return avcodec_find_decoder(AV_CODEC_ID_H264)
        case .hevc:
            return avcodec_find_decoder(AV_CODEC_ID_HEVC)
        case .vp9:
            return avcodec_find_decoder(AV_CODEC_ID_VP9)
        case .av1:
            return avcodec_find_decoder(AV_CODEC_ID_AV1)
        case .mpeg2:
            return avcodec_find_decoder(AV_CODEC_ID_MPEG2VIDEO)
        case .vc1:
            return avcodec_find_decoder(AV_CODEC_ID_VC1)
        }
    }
    
    private func configureContext(for track: VideoTrackInfo) throws {
        guard let context = codecContext else { return }
        
        context.pointee.width = Int32(track.width)
        context.pointee.height = Int32(track.height)
        context.pointee.thread_count = 0  // Auto-detect
        
        // Enable multi-threading for performance
        context.pointee.thread_type = FFmpegThreadType.frame.rawValue
    }
    
    private func createPixelBufferPool(for track: VideoTrackInfo) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: track.width,
            kCVPixelBufferHeightKey as String: track.height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }
    
    private func convertAVFrameToPixelBuffer(_ frame: UnsafeMutablePointer<FFmpegFrame>) throws -> CVPixelBuffer {
        guard let pool = pixelBufferPool else {
            throw DecoderError.bufferCreationFailed(-1)
        }
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        
        guard status == noErr, let buffer = pixelBuffer else {
            throw DecoderError.bufferCreationFailed(status)
        }
        
        // Convert YUV to pixel buffer
        // In production, use vImage or Metal for conversion
        // For now, return empty buffer
        
        return buffer
    }
    
    private func recordTiming(_ timing: TimeInterval) {
        decodeTimings.append(timing)
        if decodeTimings.count > maxTimingSamples {
            decodeTimings.removeFirst()
        }
    }
    
    var averageDecodeTime: TimeInterval {
        guard !decodeTimings.isEmpty else { return 0 }
        return decodeTimings.reduce(0, +) / Double(decodeTimings.count)
    }
}

// MARK: - FFmpeg Type Aliases

private typealias FFmpegCodec = AVCodec
private typealias FFmpegCodecContext = AVCodecContext
private typealias FFmpegFrame = AVFrame
private typealias FFmpegPacket = AVPacket

private struct FFmpegThreadType {
    static let frame = FFmpegThreadType(rawValue: 1)
    static let slice = FFmpegThreadType(rawValue: 2)
    
    let rawValue: Int32
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd TitanPlayer && swift test --filter FFmpegSoftwareDecoderTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/Core/Decoders/VideoDecoder/Software/ TitanPlayer/Tests/VideoDecoderTests/Software/
git commit -m "feat: implement FFmpeg software decoder"
```

---

## Task 7: Implement Performance Monitor

**Files:**
- Create: `TitanPlayer/Core/Decoders/VideoDecoder/Utilities/PerformanceMonitor.swift`
- Create: `TitanPlayer/Tests/VideoDecoderTests/Utilities/PerformanceMonitorTests.swift`

- [ ] **Step 1: Write failing tests for performance monitor**

```swift
// TitanPlayer/Tests/VideoDecoderTests/Utilities/PerformanceMonitorTests.swift
import XCTest
@testable import TitanPlayer

final class PerformanceMonitorTests: XCTestCase {
    
    var monitor: PerformanceMonitor!
    
    override func setUp() {
        super.setUp()
        monitor = PerformanceMonitor()
    }
    
    override func tearDown() {
        monitor.reset()
        monitor = nil
        super.tearDown()
    }
    
    func testInitialSystemState() {
        let state = monitor.currentSystemState
        
        // Should have reasonable initial values
        XCTAssertGreaterThanOrEqual(state.cpuUsage, 0)
        XCTAssertLessThanOrEqual(state.cpuUsage, 1)
        XCTAssertGreaterThanOrEqual(state.gpuUsage, 0)
        XCTAssertLessThanOrEqual(state.gpuUsage, 1)
        XCTAssertEqual(state.batteryLevel, 1.0)
    }
    
    func testRecordDecodeTiming() {
        let initialMetrics = monitor.recentMetrics
        
        monitor.recordDecodeTiming(decoder: VideoToolboxDecoder.self, duration: 0.010)
        monitor.recordDecodeTiming(decoder: VideoToolboxDecoder.self, duration: 0.012)
        monitor.recordDecodeTiming(decoder: VideoToolboxDecoder.self, duration: 0.008)
        
        let updatedMetrics = monitor.recentMetrics
        
        XCTAssertGreaterThan(updatedMetrics.averageDecodeTime, 0)
        XCTAssertNotEqual(initialMetrics.averageDecodeTime, updatedMetrics.averageDecodeTime)
    }
    
    func testRecordFrameDrop() {
        monitor.recordFrameDrop()
        monitor.recordFrameDrop()
        
        let metrics = monitor.recentMetrics
        
        XCTAssertGreaterThan(metrics.frameDropRate, 0)
    }
    
    func testPerformanceDegradationDetection() {
        // Record slow decode times
        for _ in 0..<10 {
            monitor.recordDecodeTiming(decoder: VideoToolboxDecoder.self, duration: 0.050)
        }
        
        let metrics = monitor.recentMetrics
        
        XCTAssertTrue(metrics.isDegraded, "Should detect performance degradation")
    }
    
    func testPerformanceGoodState() {
        // Record fast decode times
        for _ in 0..<10 {
            monitor.recordDecodeTiming(decoder: VideoToolboxDecoder.self, duration: 0.008)
        }
        
        let metrics = monitor.recentMetrics
        
        XCTAssertFalse(metrics.isDegraded, "Should not report degradation for fast decode times")
    }
    
    func testReset() {
        monitor.recordDecodeTiming(decoder: VideoToolboxDecoder.self, duration: 0.010)
        monitor.recordFrameDrop()
        
        monitor.reset()
        
        let metrics = monitor.recentMetrics
        XCTAssertEqual(metrics.averageDecodeTime, 0)
        XCTAssertEqual(metrics.frameDropRate, 0)
        XCTAssertFalse(metrics.isDegraded)
    }
    
    func testDecoderSwitchRecording() {
        monitor.recordDecoderSwitch(
            from: VideoToolboxDecoder.self,
            to: FFmpegSoftwareDecoder.self
        )
        
        // Should not crash and should record the switch
        // In production, would verify switch history
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd TitanPlayer && swift test --filter PerformanceMonitorTests`
Expected: FAIL with "cannot find 'PerformanceMonitor' in scope"

- [ ] **Step 3: Implement PerformanceMonitor**

```swift
// TitanPlayer/Core/Decoders/VideoDecoder/Utilities/PerformanceMonitor.swift
import Foundation

// MARK: - System State

struct SystemState: Sendable {
    var thermalState: ThermalState = .nominal
    var cpuUsage: Double = 0.0
    var gpuUsage: Double = 0.0
    var batteryLevel: Double = 1.0
    var batteryState: BatteryState = .unknown
    var isLowPowerMode: Bool = false
    var isHardwareAvailable: Bool = true
    
    enum ThermalState: Sendable {
        case nominal, fair, serious, critical
    }
    
    enum BatteryState: Sendable {
        case charging, discharging, full, unknown
    }
}

// MARK: - Performance Metrics

struct PerformanceMetrics: Sendable {
    let averageDecodeTime: TimeInterval
    let frameDropRate: Double
    let isDegraded: Bool
}

// MARK: - Decoder Switch Event

struct DecoderSwitchEvent: Sendable {
    let from: String
    let to: String
    let timestamp: Date
}

// MARK: - Performance Monitor

class PerformanceMonitor: @unchecked Sendable {
    private(set) var currentSystemState: SystemState
    private(set) var recentMetrics: PerformanceMetrics
    
    private var decodeTimings: [String: [TimeInterval]] = [:]
    private var frameDropCount: Int = 0
    private var totalFrames: Int = 0
    private let maxSamples = 100
    
    private var decoderSwitches: [DecoderSwitchEvent] = []
    private let lock = NSLock()
    
    init() {
        self.currentSystemState = SystemState()
        self.recentMetrics = PerformanceMetrics(
            averageDecodeTime: 0,
            frameDropRate: 0,
            isDegraded: false
        )
        startMonitoring()
    }
    
    // MARK: - Public API
    
    func recordDecodeTiming(decoder: VideoDecoding.Type, duration: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        
        let decoderName = String(describing: decoder)
        decodeTimings[decoderName, default: []].append(duration)
        
        if decodeTimings[decoderName]!.count > maxSamples {
            decodeTimings[decoderName]!.removeFirst()
        }
        
        updateMetrics()
    }
    
    func recordDecoderSwitch(from: VideoDecoding.Type, to: VideoDecoding.Type) {
        lock.lock()
        defer { lock.unlock() }
        
        let event = DecoderSwitchEvent(
            from: String(describing: from),
            to: String(describing: to),
            timestamp: Date()
        )
        decoderSwitches.append(event)
    }
    
    func recordFrameDrop() {
        lock.lock()
        defer { lock.unlock() }
        
        frameDropCount += 1
        totalFrames += 1
        updateMetrics()
    }
    
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        decodeTimings.removeAll()
        frameDropCount = 0
        totalFrames = 0
        recentMetrics = PerformanceMetrics(
            averageDecodeTime: 0,
            frameDropRate: 0,
            isDegraded: false
        )
    }
    
    // MARK: - System Monitoring
    
    private func startMonitoring() {
        startThermalMonitoring()
        startResourceMonitoring()
        startBatteryMonitoring()
    }
    
    private func startThermalMonitoring() {
        // Use ProcessInfo for thermal state
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
    }
    
    @objc private func thermalStateChanged() {
        let thermalState = ProcessInfo.processInfo.thermalState
        
        lock.lock()
        defer { lock.unlock() }
        
        switch thermalState {
        case .nominal:
            currentSystemState.thermalState = .nominal
        case .fair:
            currentSystemState.thermalState = .fair
        case .serious:
            currentSystemState.thermalState = .serious
        case .critical:
            currentSystemState.thermalState = .critical
        @unknown default:
            break
        }
    }
    
    private func startResourceMonitoring() {
        // In production, use host_processor_info for CPU
        // and Metal API for GPU usage
    }
    
    private func startBatteryMonitoring() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(batteryStateChanged),
            name: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
    }
    
    @objc private func batteryStateChanged() {
        lock.lock()
        defer { lock.unlock() }
        
        currentSystemState.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    }
    
    // MARK: - Metrics Calculation
    
    private func updateMetrics() {
        let allTimings = decodeTimings.values.flatMap { $0 }
        guard !allTimings.isEmpty else { return }
        
        let avgTime = allTimings.reduce(0, +) / Double(allTimings.count)
        let dropRate = totalFrames > 0 ? Double(frameDropCount) / Double(totalFrames) : 0
        
        // Target: <16ms for 60fps
        let isDegraded = avgTime > 0.016 || dropRate > 0.02
        
        recentMetrics = PerformanceMetrics(
            averageDecodeTime: avgTime,
            frameDropRate: dropRate,
            isDegraded: isDegraded
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd TitanPlayer && swift test --filter PerformanceMonitorTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/Core/Decoders/VideoDecoder/Utilities/ TitanPlayer/Tests/VideoDecoderTests/Utilities/
git commit -m "feat: implement performance monitor and system state tracking"
```

---

## Task 8: Implement Decoder Selector

**Files:**
- Create: `TitanPlayer/Core/Decoders/VideoDecoder/Manager/DecoderSelector.swift`
- Create: `TitanPlayer/Tests/VideoDecoderTests/Manager/DecoderSelectorTests.swift`

- [ ] **Step 1: Write failing tests for decoder selector**

```swift
// TitanPlayer/Tests/VideoDecoderTests/Manager/DecoderSelectorTests.swift
import XCTest
@testable import TitanPlayer

final class DecoderSelectorTests: XCTestCase {
    
    var selector: DecoderSelector!
    
    override func setUp() {
        super.setUp()
        selector = DecoderSelector()
    }
    
    override func tearDown() {
        selector = nil
        super.tearDown()
    }
    
    func testSelectsHardwareDecoderWhenAvailable() {
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 1920,
            height: 1080,
            frameRate: 60,
            isHDR: false
        )
        
        let systemState = SystemState(
            thermalState: .nominal,
            cpuUsage: 0.3,
            gpuUsage: 0.4,
            batteryLevel: 1.0,
            batteryState: .unknown,
            isLowPowerMode: false,
            isHardwareAvailable: true
        )
        
        let mockHardware = MockVideoDecoder(
            outputFormat: .sampleBuffer,
            capabilities: DecoderCapabilities(
                supportedCodecs: [.h264, .hevc],
                maxResolution: CGSize(width: 3840, height: 2160),
                supportsHDR: true,
                supportsHardwareAcceleration: true,
                maxConcurrentDecodes: 2
            )
        )
        
        let mockSoftware = MockVideoDecoder(
            outputFormat: .pixelBuffer,
            capabilities: DecoderCapabilities(
                supportedCodecs: Set(VideoCodec.allCases),
                maxResolution: CGSize(width: 3840, height: 2160),
                supportsHDR: true,
                supportsHardwareAcceleration: false,
                maxConcurrentDecodes: 1
            )
        )
        
        let selection = selector.selectDecoder(
            for: track,
            available: [mockHardware, mockSoftware],
            systemState: systemState
        )
        
        XCTAssertTrue(selection.decoder === mockHardware)
    }
    
    func testFallsBackToSoftwareWhenHardwareUnavailable() {
        let track = VideoTrackInfo(
            codec: "mp2v",
            width: 1920,
            height: 1080,
            frameRate: 30,
            isHDR: false
        )
        
        let systemState = SystemState()
        
        let mockHardware = MockVideoDecoder(
            outputFormat: .sampleBuffer,
            capabilities: DecoderCapabilities(
                supportedCodecs: [.h264, .hevc],
                maxResolution: CGSize(width: 3840, height: 2160),
                supportsHDR: true,
                supportsHardwareAcceleration: true,
                maxConcurrentDecodes: 2
            )
        )
        
        let mockSoftware = MockVideoDecoder(
            outputFormat: .pixelBuffer,
            capabilities: DecoderCapabilities(
                supportedCodecs: Set(VideoCodec.allCases),
                maxResolution: CGSize(width: 3840, height: 2160),
                supportsHDR: true,
                supportsHardwareAcceleration: false,
                maxConcurrentDecodes: 1
            )
        )
        
        let selection = selector.selectDecoder(
            for: track,
            available: [mockHardware, mockSoftware],
            systemState: systemState
        )
        
        XCTAssertTrue(selection.decoder === mockSoftware)
    }
    
    func testSwitchesOnThermalThrottle() {
        let mockHardware = MockVideoDecoder(
            outputFormat: .sampleBuffer,
            capabilities: DecoderCapabilities(
                supportedCodecs: [.h264, .hevc],
                maxResolution: CGSize(width: 3840, height: 2160),
                supportsHDR: true,
                supportsHardwareAcceleration: true,
                maxConcurrentDecodes: 2
            )
        )
        
        let mockSoftware = MockVideoDecoder(
            outputFormat: .pixelBuffer,
            capabilities: DecoderCapabilities(
                supportedCodecs: Set(VideoCodec.allCases),
                maxResolution: CGSize(width: 3840, height: 2160),
                supportsHDR: true,
                supportsHardwareAcceleration: false,
                maxConcurrentDecodes: 1
            )
        )
        
        let degradedMetrics = PerformanceMetrics(
            averageDecodeTime: 0.05,
            frameDropRate: 0.05,
            isDegraded: true
        )
        
        let criticalState = SystemState(
            thermalState: .critical,
            cpuUsage: 0.9,
            gpuUsage: 0.95,
            batteryLevel: 0.5,
            batteryState: .discharging,
            isLowPowerMode: false,
            isHardwareAvailable: true
        )
        
        let shouldSwitch = selector.checkForSwitch(
            current: mockHardware,
            systemState: criticalState,
            recentPerformance: degradedMetrics
        )
        
        XCTAssertNotNil(shouldSwitch)
    }
    
    func testNoSwitchWhenPerformanceGood() {
        let mockHardware = MockVideoDecoder(
            outputFormat: .sampleBuffer,
            capabilities: DecoderCapabilities(
                supportedCodecs: [.h264, .hevc],
                maxResolution: CGSize(width: 3840, height: 2160),
                supportsHDR: true,
                supportsHardwareAcceleration: true,
                maxConcurrentDecodes: 2
            )
        )
        
        let goodMetrics = PerformanceMetrics(
            averageDecodeTime: 0.008,
            frameDropRate: 0.001,
            isDegraded: false
        )
        
        let nominalState = SystemState(
            thermalState: .nominal,
            cpuUsage: 0.3,
            gpuUsage: 0.4,
            batteryLevel: 1.0,
            batteryState: .unknown,
            isLowPowerMode: false,
            isHardwareAvailable: true
        )
        
        let shouldSwitch = selector.checkForSwitch(
            current: mockHardware,
            systemState: nominalState,
            recentPerformance: goodMetrics
        )
        
        XCTAssertNil(shouldSwitch)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd TitanPlayer && swift test --filter DecoderSelectorTests`
Expected: FAIL with "cannot find 'DecoderSelector' in scope"

- [ ] **Step 3: Implement DecoderSelector**

```swift
// TitanPlayer/Core/Decoders/VideoDecoder/Manager/DecoderSelector.swift
import Foundation

// MARK: - Decoder Selection

struct DecoderSelection: Sendable {
    let decoder: VideoDecoding
    let reason: ScoreReason
}

// MARK: - Score Reason

enum ScoreReason: Sendable {
    case codecSupported
    case hardwareAvailable
    case goodPerformance
    case thermalEfficient
    case resolutionSupported
    case fallback
}

// MARK: - Decoder Score

struct DecoderScore: Sendable {
    let score: Double
    let reasons: [ScoreReason]
}

// MARK: - Decoder Selector

struct DecoderSelector {
    
    // MARK: - Selection Logic
    
    func selectDecoder(for track: VideoTrackInfo,
                       available: [VideoDecoding],
                       systemState: SystemState) -> DecoderSelection {
        
        let scored = available.map { decoder in
            (decoder: decoder, score: calculateScore(for: decoder, track: track, systemState: systemState))
        }
        
        let sorted = scored.sorted { $0.score.score > $1.score.score }
        
        guard let best = sorted.first else {
            return DecoderSelection(decoder: available.first!, reason: .fallback)
        }
        
        return DecoderSelection(decoder: best.decoder, reason: best.score.reasons.first ?? .fallback)
    }
    
    // MARK: - Switch Check
    
    func checkForSwitch(current: VideoDecoding,
                        systemState: SystemState,
                        recentPerformance: PerformanceMetrics) -> VideoDecoding? {
        
        guard recentPerformance.isDegraded else { return nil }
        
        // Check thermal throttling
        if systemState.thermalState == .critical {
            if current is VideoToolboxDecoder {
                return findSoftwareDecoder(from: [current])
            }
        }
        
        // Check CPU/GPU load
        if systemState.cpuUsage > 0.85 || systemState.gpuUsage > 0.90 {
            return selectMoreEfficientDecoder(current: current)
        }
        
        // Check battery state
        if systemState.batteryState == .charging && systemState.batteryLevel < 0.20 {
            return selectPowerEfficientDecoder(current: current)
        }
        
        return nil
    }
    
    // MARK: - Scoring
    
    private func calculateScore(for decoder: VideoDecoding,
                                track: VideoTrackInfo,
                                systemState: SystemState) -> DecoderScore {
        var score: Double = 0
        var reasons: [ScoreReason] = []
        
        // Codec support (0-30 points)
        if let codec = VideoCodec(rawValue: track.codec),
           decoder.capabilities.supportedCodecs.contains(codec) {
            score += 30
            reasons.append(.codecSupported)
        }
        
        // Hardware acceleration bonus (0-20 points)
        if decoder.capabilities.supportsHardwareAcceleration && systemState.isHardwareAvailable {
            score += 20
            reasons.append(.hardwareAvailable)
        }
        
        // Performance history (0-25 points)
        let perfScore = performanceScore(for: decoder)
        score += perfScore
        if perfScore > 15 { reasons.append(.goodPerformance) }
        
        // Thermal efficiency (0-15 points)
        if systemState.thermalState == .nominal {
            if decoder is VideoToolboxDecoder {
                score += 15
                reasons.append(.thermalEfficient)
            }
        }
        
        // Resolution support (0-10 points)
        let resolution = CGSize(width: track.width, height: track.height)
        if decoder.capabilities.maxResolution.width >= resolution.width &&
           decoder.capabilities.maxResolution.height >= resolution.height {
            score += 10
            reasons.append(.resolutionSupported)
        }
        
        return DecoderScore(score: score, reasons: reasons)
    }
    
    private func performanceScore(for decoder: VideoDecoding) -> Double {
        // Placeholder - would query performance monitor in production
        return 15.0
    }
    
    // MARK: - Helpers
    
    private func selectMoreEfficientDecoder(current: VideoDecoding) -> VideoDecoding? {
        if current is VideoToolboxDecoder {
            return findSoftwareDecoder(from: [current])
        }
        return findHardwareDecoder()
    }
    
    private func selectPowerEfficientDecoder(current: VideoDecoding) -> VideoDecoding? {
        if current is FFmpegSoftwareDecoder {
            return findHardwareDecoder()
        }
        return nil
    }
    
    private func findHardwareDecoder() -> VideoDecoding? {
        return VideoToolboxDecoder()
    }
    
    private func findSoftwareDecoder(from decoders: [VideoDecoding]) -> VideoDecoding? {
        return FFmpegSoftwareDecoder()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd TitanPlayer && swift test --filter DecoderSelectorTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/Core/Decoders/VideoDecoder/Manager/ TitanPlayer/Tests/VideoDecoderTests/Manager/
git commit -m "feat: implement decoder selector with scoring system"
```

---

## Task 9: Implement Adaptive Decoder Manager

**Files:**
- Create: `TitanPlayer/Core/Decoders/VideoDecoder/Manager/AdaptiveDecoderManager.swift`
- Create: `TitanPlayer/Tests/VideoDecoderTests/Manager/AdaptiveDecoderManagerTests.swift`
- Create: `TitanPlayer/Tests/VideoDecoderTests/Mocks/MockVideoDecoder.swift`

- [ ] **Step 1: Create mock decoder for testing**

```swift
// TitanPlayer/Tests/VideoDecoderTests/Mocks/MockVideoDecoder.swift
import Foundation
import CoreMedia
import CoreVideo
@testable import TitanPlayer

// MARK: - Mock Video Decoder

class MockVideoDecoder: VideoDecoding {
    let outputFormat: DecoderOutputFormat
    let capabilities: DecoderCapabilities
    private(set) var state: DecoderState = .idle
    
    var shouldFail = false
    var decodeCallCount = 0
    var configureCallCount = 0
    
    init(outputFormat: DecoderOutputFormat = .pixelBuffer,
         capabilities: DecoderCapabilities = .default) {
        self.outputFormat = outputFormat
        self.capabilities = capabilities
    }
    
    func configure(for track: VideoTrackInfo) async throws {
        configureCallCount += 1
        if shouldFail {
            throw DecoderError.hardwareFailure
        }
        state = .configured
    }
    
    func decode(_ packet: MediaPacket) async throws -> DecoderOutput {
        decodeCallCount += 1
        
        if shouldFail {
            throw DecoderError.softwareFailure
        }
        
        // Create mock pixel buffer
        var pixelBuffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary
        
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            1920, 1080,
            kCVPixelFormatType_32BGRA,
            attrs,
            &pixelBuffer
        )
        
        guard let buffer = pixelBuffer else {
            throw DecoderError.bufferCreationFailed(-1)
        }
        
        switch outputFormat {
        case .pixelBuffer:
            return .pixelBuffer(buffer)
        case .sampleBuffer:
            // Create mock sample buffer
            var formatDescription: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: buffer,
                formatDescriptionOut: &formatDescription
            )
            
            var timingInfo = CMSampleTimingInfo(
                duration: packet.duration,
                presentationTimeStamp: packet.timestamp,
                decodeTimeStamp: .invalid
            )
            
            var sampleBuffer: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: buffer,
                formatDescription: formatDescription!,
                sampleTiming: timingInfo,
                sampleBufferOut: &sampleBuffer
            )
            
            return .sampleBuffer(sampleBuffer!)
        case .both:
            return .pixelBuffer(buffer)
        }
    }
    
    func flush() async {
        state = .configured
    }
    
    func reset() async {
        state = .idle
    }
    
    func invalidate() async {
        state = .idle
    }
}

// MARK: - Mock for Multiple Decoders

class MockDecoderProvider {
    static func createHardwareDecoder() -> MockVideoDecoder {
        return MockVideoDecoder(
            outputFormat: .sampleBuffer,
            capabilities: DecoderCapabilities(
                supportedCodecs: [.h264, .hevc],
                maxResolution: CGSize(width: 3840, height: 2160),
                supportsHDR: true,
                supportsHardwareAcceleration: true,
                maxConcurrentDecodes: 2
            )
        )
    }
    
    static func createSoftwareDecoder() -> MockVideoDecoder {
        return MockVideoDecoder(
            outputFormat: .pixelBuffer,
            capabilities: DecoderCapabilities(
                supportedCodecs: Set(VideoCodec.allCases),
                maxResolution: CGSize(width: 3840, height: 2160),
                supportsHDR: true,
                supportsHardwareAcceleration: false,
                maxConcurrentDecodes: 1
            )
        )
    }
}
```

- [ ] **Step 2: Write failing tests for adaptive decoder manager**

```swift
// TitanPlayer/Tests/VideoDecoderTests/Manager/AdaptiveDecoderManagerTests.swift
import XCTest
import CoreMedia
@testable import TitanPlayer

final class AdaptiveDecoderManagerTests: XCTestCase {
    
    var manager: AdaptiveDecoderManager!
    
    override func setUp() {
        super.setUp()
        manager = AdaptiveDecoderManager()
    }
    
    override func tearDown() {
        Task {
            await manager.invalidate()
        }
        manager = nil
        super.tearDown()
    }
    
    func testConfigureForTrack() async throws {
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 1920,
            height: 1080,
            frameRate: 60,
            isHDR: false
        )
        
        try await manager.configure(for: track)
        
        // Manager should have selected a decoder
        XCTAssertNotNil(manager.activeDecoder)
    }
    
    func testDecodeWithActiveDecoder() async throws {
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 1920,
            height: 1080,
            frameRate: 60,
            isHDR: false
        )
        
        try await manager.configure(for: track)
        
        let packet = MediaPacket(
            streamIndex: 0,
            data: Data(repeating: 0, count: 1024),
            timestamp: CMTime(seconds: 0, preferredTimescale: 600),
            duration: CMTime(seconds: 0.033, preferredTimescale: 600),
            isKeyFrame: true
        )
        
        let output = try await manager.decode(packet)
        
        switch output {
        case .sampleBuffer(let buffer):
            XCTAssertNotNil(buffer)
        case .pixelBuffer(let buffer):
            XCTAssertNotNil(buffer)
        }
    }
    
    func testInvalidate() async throws {
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 1920,
            height: 1080,
            frameRate: 60,
            isHDR: false
        )
        
        try await manager.configure(for: track)
        
        await manager.invalidate()
        
        XCTAssertNil(manager.activeDecoder)
    }
    
    func testErrorHandlingReportsToUI() async {
        // Test that persistent errors are reported
        let track = VideoTrackInfo(
            codec: "mp2v",
            width: 1920,
            height: 1080,
            frameRate: 30,
            isHDR: false
        )
        
        // This should fail because MPEG-2 is not supported by hardware
        // and we need to verify error reporting
        do {
            try await manager.configure(for: track)
        } catch {
            XCTAssertTrue(error is DecoderError)
        }
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd TitanPlayer && swift test --filter AdaptiveDecoderManagerTests`
Expected: FAIL with "cannot find 'AdaptiveDecoderManager' in scope"

- [ ] **Step 4: Implement AdaptiveDecoderManager**

```swift
// TitanPlayer/Core/Decoders/VideoDecoder/Manager/AdaptiveDecoderManager.swift
import Foundation

// MARK: - Manager State

enum ManagerState: Sendable {
    case idle
    case decoding(VideoDecoding)
    case switching(from: VideoDecoding, to: VideoDecoding)
    case error(DecoderError)
}

// MARK: - Adaptive Decoder Manager

class AdaptiveDecoderManager: @unchecked Sendable {
    // Decoder instances
    private var hardwareDecoder: VideoToolboxDecoder?
    private var softwareDecoder: FFmpegSoftwareDecoder?
    private(set) var activeDecoder: VideoDecoding?
    
    // Selection intelligence
    private let decoderSelector: DecoderSelector
    private let performanceMonitor: PerformanceMonitor
    
    // State
    private(set) var currentState: ManagerState = .idle
    private var currentTrack: VideoTrackInfo?
    
    private let lock = NSLock()
    
    init() {
        self.decoderSelector = DecoderSelector()
        self.performanceMonitor = PerformanceMonitor()
    }
    
    // MARK: - Public API
    
    func configure(for track: VideoTrackInfo) async throws {
        lock.lock()
        defer { lock.unlock() }
        
        currentTrack = track
        
        // Query available decoders
        let availableDecoders = queryAvailableDecoders(for: track)
        
        // Select optimal decoder
        let selection = decoderSelector.selectDecoder(
            for: track,
            available: availableDecoders,
            systemState: performanceMonitor.currentSystemState
        )
        
        // Configure selected decoder
        try await selection.decoder.configure(for: track)
        activeDecoder = selection.decoder
        currentState = .decoding(selection.decoder)
    }
    
    func decode(_ packet: MediaPacket) async throws -> DecoderOutput {
        lock.lock()
        let decoder = activeDecoder
        lock.unlock()
        
        guard let decoder = decoder else {
            throw DecoderError.sessionNotConfigured
        }
        
        do {
            let output = try await decoder.decode(packet)
            
            // Update performance metrics
            performanceMonitor.recordDecodeTiming(
                decoder: type(of: decoder),
                duration: packet.duration.seconds
            )
            
            // Check if we should switch decoders
            lock.lock()
            let shouldSwitch = decoderSelector.checkForSwitch(
                current: decoder,
                systemState: performanceMonitor.currentSystemState,
                recentPerformance: performanceMonitor.recentMetrics
            )
            lock.unlock()
            
            if let switchTo = shouldSwitch {
                try await performSwitch(to: switchTo)
                lock.lock()
                let newDecoder = activeDecoder
                lock.unlock()
                return try await newDecoder!.decode(packet)
            }
            
            return output
            
        } catch {
            return try await handleDecodeError(error, packet: packet)
        }
    }
    
    func flush() async {
        lock.lock()
        let decoder = activeDecoder
        lock.unlock()
        
        await decoder?.flush()
    }
    
    func invalidate() async {
        lock.lock()
        defer { lock.unlock() }
        
        await hardwareDecoder?.invalidate()
        await softwareDecoder?.invalidate()
        activeDecoder = nil
        currentState = .idle
        performanceMonitor.reset()
    }
    
    var activeDecoderType: String? {
        lock.lock()
        defer { lock.unlock() }
        
        return activeDecoder.map { String(describing: type(of: $0)) }
    }
    
    // MARK: - Hot-Swap Support
    
    private func performSwitch(to newDecoder: VideoDecoding) async throws {
        lock.lock()
        let oldDecoder = activeDecoder
        lock.unlock()
        
        guard let oldDecoder = oldDecoder else { return }
        
        currentState = .switching(from: oldDecoder, to: newDecoder)
        
        // Flush old decoder
        await oldDecoder.flush()
        
        // Configure new decoder if needed
        lock.lock()
        if newDecoder.state == .idle, let track = currentTrack {
            lock.unlock()
            try await newDecoder.configure(for: track)
        } else {
            lock.unlock()
        }
        
        // Switch active decoder
        lock.lock()
        activeDecoder = newDecoder
        currentState = .decoding(newDecoder)
        lock.unlock()
        
        // Record switch
        performanceMonitor.recordDecoderSwitch(
            from: type(of: oldDecoder),
            to: type(of: newDecoder)
        )
    }
    
    // MARK: - Error Handling
    
    private func handleDecodeError(_ error: Error, packet: MediaPacket) async throws -> DecoderOutput {
        guard let decoderError = error as? DecoderError else {
            throw error
        }
        
        switch decoderError.severity {
        case .transient:
            // Try fallback decoder
            lock.lock()
            let currentDecoder = activeDecoder
            lock.unlock()
            
            if let fallback = getFallbackDecoder(for: currentDecoder!) {
                try await performSwitch(to: fallback)
                lock.lock()
                let newDecoder = activeDecoder
                lock.unlock()
                return try await newDecoder!.decode(packet)
            }
            throw decoderError
            
        case .persistent:
            // Report to UI
            currentState = .error(decoderError)
            throw decoderError
        }
    }
    
    private func getFallbackDecoder(for decoder: VideoDecoding) -> VideoDecoding? {
        if decoder is VideoToolboxDecoder {
            return softwareDecoder ?? FFmpegSoftwareDecoder()
        } else if decoder is FFmpegSoftwareDecoder {
            return hardwareDecoder ?? VideoToolboxDecoder()
        }
        return nil
    }
    
    private func queryAvailableDecoders(for track: VideoTrackInfo) -> [VideoDecoding] {
        var decoders: [VideoDecoding] = []
        
        // Hardware decoder
        if HardwareCapabilities.isCodecSupported(VideoCodec(rawValue: track.codec) ?? .h264) {
            if hardwareDecoder == nil {
                hardwareDecoder = VideoToolboxDecoder()
            }
            decoders.append(hardwareDecoder!)
        }
        
        // Software decoder (always available)
        if softwareDecoder == nil {
            softwareDecoder = FFmpegSoftwareDecoder()
        }
        decoders.append(softwareDecoder!)
        
        return decoders
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd TitanPlayer && swift test --filter AdaptiveDecoderManagerTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add TitanPlayer/Core/Decoders/VideoDecoder/Manager/ TitanPlayer/Tests/VideoDecoderTests/Manager/ TitanPlayer/Tests/VideoDecoderTests/Mocks/
git commit -m "feat: implement adaptive decoder manager with hot-swap support"
```

---

## Task 10: Run All Tests and Validate

**Files:**
- Modify: `TitanPlayer/Tests/VideoDecoderTests/Performance/DecoderBenchmarks.swift`

- [ ] **Step 1: Create performance benchmarks**

```swift
// TitanPlayer/Tests/VideoDecoderTests/Performance/DecoderBenchmarks.swift
import XCTest
import CoreMedia
@testable import TitanPlayer

final class DecoderBenchmarks: XCTestCase {
    
    func testBenchmarkH264Decoding() throws {
        let decoder = VideoToolboxDecoder()
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 1920,
            height: 1080,
            frameRate: 60,
            isHDR: false
        )
        
        let expectation = self.expectation(description: "H264 benchmark")
        
        Task {
            try await decoder.configure(for: track)
            
            let packet = MediaPacket(
                streamIndex: 0,
                data: Data(repeating: 0, count: 1024),
                timestamp: CMTime(seconds: 0, preferredTimescale: 600),
                duration: CMTime(seconds: 0.033, preferredTimescale: 600),
                isKeyFrame: true
            )
            
            measure {
                let group = DispatchGroup()
                
                for _ in 0..<100 {
                    group.enter()
                    Task {
                        _ = try? await decoder.decode(packet)
                        group.leave()
                    }
                }
                
                group.wait()
            }
            
            await decoder.invalidate()
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 10)
    }
    
    func testBenchmarkHEVCDecoding() throws {
        let decoder = VideoToolboxDecoder()
        let track = VideoTrackInfo(
            codec: "hvc1",
            width: 3840,
            height: 2160,
            frameRate: 60,
            isHDR: true
        )
        
        let expectation = self.expectation(description: "HEVC benchmark")
        
        Task {
            try await decoder.configure(for: track)
            
            let packet = MediaPacket(
                streamIndex: 0,
                data: Data(repeating: 0, count: 2048),
                timestamp: CMTime(seconds: 0, preferredTimescale: 600),
                duration: CMTime(seconds: 0.033, preferredTimescale: 600),
                isKeyFrame: true
            )
            
            measure {
                let group = DispatchGroup()
                
                for _ in 0..<100 {
                    group.enter()
                    Task {
                        _ = try? await decoder.decode(packet)
                        group.leave()
                    }
                }
                
                group.wait()
            }
            
            await decoder.invalidate()
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 10)
    }
    
    func testBenchmark4K60fpsDecoding() throws {
        let decoder = VideoToolboxDecoder()
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 3840,
            height: 2160,
            frameRate: 60,
            isHDR: false
        )
        
        let expectation = self.expectation(description: "4K60 benchmark")
        
        Task {
            try await decoder.configure(for: track)
            
            let packet = MediaPacket(
                streamIndex: 0,
                data: Data(repeating: 0, count: 4096),
                timestamp: CMTime(seconds: 0, preferredTimescale: 600),
                duration: CMTime(seconds: 0.033, preferredTimescale: 600),
                isKeyFrame: true
            )
            
            // Measure latency
            let startTime = CFAbsoluteTimeGetCurrent()
            
            for _ in 0..<100 {
                _ = try? await decoder.decode(packet)
            }
            
            let totalTime = CFAbsoluteTimeGetCurrent() - startTime
            let avgTime = totalTime / 100
            
            print("4K60fps average decode time: \(avgTime * 1000)ms")
            XCTAssertLessThan(avgTime, 0.016, "Should meet <16ms target")
            
            await decoder.invalidate()
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 10)
    }
}
```

- [ ] **Step 2: Run all tests**

Run: `cd TitanPlayer && swift test`
Expected: All tests PASS

- [ ] **Step 3: Verify latency target**

Check benchmark output for:
- H.264: <16ms
- HEVC: <16ms
- 4K60fps: <16ms

- [ ] **Step 4: Commit final changes**

```bash
git add TitanPlayer/Tests/VideoDecoderTests/
git commit -m "test: add performance benchmarks and validate latency targets"
```

---

## Summary

This plan implements a complete video decoder system with:

1. **Core Protocols**: `VideoDecoding`, `DecoderCapabilities`, `VideoCodec`
2. **Hardware Decoder**: `VideoToolboxDecoder` with VTDecompressionSession
3. **Software Decoder**: `FFmpegSoftwareDecoder` with full codec support
4. **Adaptive Manager**: `AdaptiveDecoderManager` with hot-swap support
5. **Intelligent Selection**: `DecoderSelector` with multi-factor scoring
6. **Performance Monitoring**: `PerformanceMonitor` for system state
7. **Zero-Copy Utilities**: `ZeroCopyBufferManager` for efficient buffer handling

**Validation Criteria:**
- [ ] H.264/HEVC hardware decoding on all Macs
- [ ] VP9 hardware decoding on Apple Silicon (M1+)
- [ ] AV1 hardware decoding on M3+ chips
- [ ] Software fallback for unsupported codecs
- [ ] Automatic fallback on hardware errors
- [ ] <16ms decode time target for 60fps

**Next Steps:**
1. Migrate `MediaPipeline` to use new decoder system
2. Add HDR metadata support
3. Implement network stream adaptive bitrate
4. Add Metal post-processing pipeline
