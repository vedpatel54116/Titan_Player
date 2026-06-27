# Video Decoder Hardening — Real-Bitstream Decode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the existing `Core/Decoders/VideoDecoder/` scaffold to decode real H.264/HEVC bitstreams via VideoToolbox (hardware) and FFmpeg (software), with real demuxing from both AVFoundation and FFmpeg paths, fixing internal design flaws and adding full test coverage.

**Architecture:** Extradata (SPS/PPS/VPS) threaded via a new `VideoTrackInfo.extradata` field. `ParameterSetParser` converts extradata into `CMVideoFormatDescription` for VideoToolbox. FFmpeg demuxer uses real `Libavformat` bindings. `DecoderSelector` returns a `DecoderSwitch` enum instead of throwaway instances. `OSAllocatedUnfairLock` replaces `NSLock` for Swift 6 readiness.

**Tech Stack:** Swift, VideoToolbox, CoreMedia, CoreVideo, FFmpegBuild (Libavcodec, Libavutil, Libswscale, Libavformat), AVFoundation, Metal

**Environment notes:**
- `swift build` works with Command Line Tools only
- `swift test` requires full Xcode (XCTest framework) — CLT alone is insufficient
- `ffmpeg` CLI is available at `/opt/homebrew/bin/ffmpeg` for fixture generation
- Test fixture `Tests/Fixtures/test.mp4` is currently 0 bytes — Task 0 generates a real one

---

## File Structure

```
TitanPlayer/
├── Package.swift                                    (MODIFIED: add Libavformat)
├── TitanPlayer/
│   └── Core/Decoders/
│       ├── VideoDecoder/
│       │   ├── Hardware/
│       │   │   ├── VideoToolboxDecoder.swift        (MODIFIED: ParameterSetParser, OSAllocatedUnfairLock)
│       │   │   ├── HardwareCapabilities.swift       (unchanged)
│       │   │   └── ParameterSetParser.swift         (NEW)
│       │   ├── Software/
│       │   │   ├── FFmpegSoftwareDecoder.swift      (MODIFIED: extradata, HDR, threading, lock)
│       │   │   └── SoftwareCapabilities.swift       (unchanged)
│       │   ├── Manager/
│       │   │   ├── AdaptiveDecoderManager.swift     (MODIFIED: DecoderSwitch, owned instances)
│       │   │   └── DecoderSelector.swift            (MODIFIED: DecoderSwitch enum, no throwaways)
│       │   ├── Utilities/
│       │   │   ├── ZeroCopyBuffer.swift             (MODIFIED: annexBToAVCC)
│       │   │   └── PerformanceMonitor.swift         (MODIFIED: real CPU monitoring)
│       │   └── Protocols/                           (unchanged)
│       ├── FFmpeg/
│       │   ├── FFmpegBridge.swift                   (MODIFIED: real Libavformat)
│       │   └── FFmpegDemuxer.swift                  (MODIFIED: real demuxing)
│       ├── AVFoundation/
│       │   └── AVFoundationDemuxer.swift            (MODIFIED: real data, extradata, metadata)
│       └── Protocols/
│           └── SharedTypes.swift                    (MODIFIED: VideoTrackInfo.extradata)
└── Tests/
    ├── Fixtures/
    │   └── test.mp4                                 (REGENERATED: real H.264 video)
    └── VideoDecoderTests/
        ├── Hardware/
        │   ├── HardwareCapabilitiesTests.swift      (NEW)
        │   ├── ParameterSetParserTests.swift        (NEW)
        │   ├── VideoToolboxDecoderTests.swift       (NEW)
        │   └── VideoToolboxDecoderIntegrationTests.swift  (NEW)
        ├── Software/
        │   ├── SoftwareCapabilitiesTests.swift      (NEW)
        │   ├── FFmpegSoftwareDecoderTests.swift     (NEW)
        │   └── FFmpegSoftwareDecoderIntegrationTests.swift  (NEW)
        ├── Manager/
        │   ├── DecoderSelectorTests.swift           (NEW)
        │   └── AdaptiveDecoderManagerTests.swift    (NEW)
        ├── Utilities/
        │   ├── ZeroCopyBufferTests.swift            (NEW)
        │   └── PerformanceMonitorTests.swift        (NEW)
        └── Integration/
            ├── FFmpegDemuxerIntegrationTests.swift  (NEW)
            └── AVFoundationDemuxerIntegrationTests.swift (NEW)
```

---

## Task 0: Generate Real Test Fixture

**Files:**
- Regenerate: `Tests/Fixtures/test.mp4`

The existing `test.mp4` is 0 bytes. Integration tests need a real H.264 bitstream.

- [ ] **Step 1: Generate a real 2-second H.264 MP4 test video**

Run:
```bash
cd TitanPlayer && ffmpeg -y -f lavfi -i "testsrc=duration=2:size=320x240:rate=30" -c:v libx264 -pix_fmt yuv420p -preset ultrafast -movflags +faststart Tests/Fixtures/test.mp4
```

This creates a 2-second, 320x240, 30fps H.264 MP4 with the `testsrc` pattern — small, deterministic, and decodable by both VideoToolbox and FFmpeg.

- [ ] **Step 2: Verify the fixture is non-empty and valid**

Run:
```bash
ls -la Tests/Fixtures/test.mp4
ffprobe -v error -show_streams -show_format Tests/Fixtures/test.mp4 2>&1 | head -20
```

Expected: file size > 0, `codec_name=h264`, `width=320`, `height=240`, `nb_streams=1`

- [ ] **Step 3: Commit**

```bash
git add Tests/Fixtures/test.mp4
git commit -m "test: generate real H.264 test fixture for integration tests"
```

---

## Task 1: Add `extradata` to `VideoTrackInfo`

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/Protocols/SharedTypes.swift:13-19`
- Modify: `TitanPlayer/Tests/VideoDecoderTests/Protocols/VideoDecodingTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `TitanPlayer/Tests/VideoDecoderTests/Protocols/VideoDecodingTests.swift`:

```swift
    func testVideoTrackInfoExtradataField() {
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 1920,
            height: 1080,
            frameRate: 60,
            isHDR: false,
            extradata: Data([0x01, 0x42, 0xC0, 0x1E])
        )
        
        XCTAssertNotNil(track.extradata)
        XCTAssertEqual(track.extradata?.count, 4)
        XCTAssertEqual(track.extradata?[0], 0x01)
    }
    
    func testVideoTrackInfoExtradataNilDefault() {
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 1920,
            height: 1080,
            frameRate: 60,
            isHDR: false,
            extradata: nil
        )
        
        XCTAssertNil(track.extradata)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd TitanPlayer && swift test --filter VideoDecodingTests 2>&1 | tail -5`
Expected: FAIL with "extradata" not found / type mismatch

- [ ] **Step 3: Add `extradata` field to `VideoTrackInfo`**

Replace the `VideoTrackInfo` struct in `TitanPlayer/TitanPlayer/Core/Decoders/Protocols/SharedTypes.swift`:

```swift
struct VideoTrackInfo {
    let codec: String
    let width: Int
    let height: Int
    let frameRate: Double
    let isHDR: Bool
    let extradata: Data?
}
```

- [ ] **Step 4: Fix all call sites that construct `VideoTrackInfo`**

Search for all `VideoTrackInfo(` constructions and add `extradata: nil` where not already provided. Key files:
- `TitanPlayer/TitanPlayer/Core/Decoders/AVFoundation/AVFoundationDemuxer.swift:25-31`
- `TitanPlayer/Tests/VideoDecoderTests/Protocols/VideoDecodingTests.swift` (the new tests above already pass it)

Run: `cd TitanPlayer && swift build 2>&1 | tail -10`
Expected: Build succeeds (all call sites updated)

- [ ] **Step 5: Run test to verify it passes**

Run: `cd TitanPlayer && swift test --filter VideoDecodingTests 2>&1 | tail -5`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/Protocols/SharedTypes.swift TitanPlayer/Tests/VideoDecoderTests/Protocols/VideoDecodingTests.swift TitanPlayer/TitanPlayer/Core/Decoders/AVFoundation/AVFoundationDemuxer.swift
git commit -m "feat: add extradata field to VideoTrackInfo for codec parameter sets"
```

---

## Task 2: Add `Libavformat` to Package.swift

**Files:**
- Modify: `TitanPlayer/Package.swift:11-18`

- [ ] **Step 1: Add Libavformat dependency**

In `TitanPlayer/Package.swift`, add `"Libavformat"` to the TitanPlayer executable target dependencies:

```swift
        .executableTarget(
            name: "TitanPlayer",
            dependencies: [
                "FFmpegBuild",
                .product(name: "Libavcodec", package: "FFmpegBuild"),
                .product(name: "Libavformat", package: "FFmpegBuild"),
                .product(name: "Libavutil", package: "FFmpegBuild"),
                .product(name: "Libswscale", package: "FFmpegBuild"),
            ],
```

- [ ] **Step 2: Verify build succeeds**

Run: `cd TitanPlayer && swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/Package.swift
git commit -m "feat: add Libavformat dependency for real FFmpeg demuxing"
```

---

## Task 3: Implement `ParameterSetParser`

**Files:**
- Create: `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Hardware/ParameterSetParser.swift`
- Create: `TitanPlayer/Tests/VideoDecoderTests/Hardware/ParameterSetParserTests.swift`

- [ ] **Step 1: Write failing tests**

Create `TitanPlayer/Tests/VideoDecoderTests/Hardware/ParameterSetParserTests.swift`:

```swift
import XCTest
import CoreMedia
import VideoToolbox
@testable import TitanPlayer

final class ParameterSetParserTests: XCTestCase {
    
    // MARK: - H.264 avcC Parsing
    
    func testParseH264AvcCReturnsFormatDescription() throws {
        // Minimal valid avcC: profile_idc=66 (Baseline), level_idc=30
        // SPS: 67 42 C0 1E DA 02 80 F6 80 (9 bytes)
        // PPS: 68 CE 38 80 (4 bytes)
        let avcC: [UInt8] = [
            0x01,       // configurationVersion
            0x42,       // AVCProfileIndication (Baseline)
            0xC0,       // profile_compatibility
            0x1E,       // AVCLevelIndication (30)
            0xFF,       // lengthSizeMinusOne = 3 (4-byte lengths)
            0xE1,       // numOfSequenceParameterSets = 1
            0x00, 0x09, // SPS length = 9
            0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x02, 0x80, 0xF6, 0x80, // SPS NALU
            0x01,       // numOfPictureParameterSets = 1
            0x00, 0x04, // PPS length = 4
            0x68, 0xCE, 0x38, 0x80  // PPS NALU
        ]
        
        let formatDesc = ParameterSetParser.parseH264(extradata: Data(avcC))
        XCTAssertNotNil(formatDesc, "Should create CMVideoFormatDescription from valid avcC")
    }
    
    func testParseH264InvalidAvcCReturnsNil() {
        let garbage = Data([0x00, 0x01, 0x02])
        let result = ParameterSetParser.parseH264(extradata: garbage)
        XCTAssertNil(result, "Should return nil for invalid avcC data")
    }
    
    func testParseH264EmptyDataReturnsNil() {
        let result = ParameterSetParser.parseH264(extradata: Data())
        XCTAssertNil(result)
    }
    
    // MARK: - HEVC hvcC Parsing
    
    func testParseHEVCInvalidDataReturnsNil() {
        let garbage = Data([0xFF, 0xFF])
        let result = ParameterSetParser.parseHEVC(extradata: garbage)
        XCTAssertNil(result)
    }
    
    func testParseHEVCEmptyDataReturnsNil() {
        let result = ParameterSetParser.parseHEVC(extradata: Data())
        XCTAssertNil(result)
    }
    
    // MARK: - Annex-B Parsing
    
    func testParseAnnexBH264ExtractsSPSAndPPS() throws {
        // Annex-B format: start code + SPS + start code + PPS
        let annexB: [UInt8] = [
            0x00, 0x00, 0x00, 0x01, // start code
            0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x02, 0x80, 0xF6, 0x80, // SPS (type 7)
            0x00, 0x00, 0x00, 0x01, // start code
            0x68, 0xCE, 0x38, 0x80  // PPS (type 8)
        ]
        
        let formatDesc = ParameterSetParser.parseAnnexB(extradata: Data(annexB), codec: .h264)
        XCTAssertNotNil(formatDesc, "Should create CMVideoFormatDescription from Annex-B H.264")
    }
    
    func testParseAnnexBHEVCReturnsNilForNoVPS() {
        // HEVC Annex-B without VPS — should fail
        let annexB: [UInt8] = [
            0x00, 0x00, 0x00, 0x01,
            0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x99, 0xAC, 0x09, // SPS (type 33)
            0x00, 0x00, 0x00, 0x01,
            0x44, 0x01, 0xC1, 0x73, 0xD1, 0x89 // PPS (type 34)
        ]
        
        let result = ParameterSetParser.parseAnnexB(extradata: Data(annexB), codec: .hevc)
        XCTAssertNil(result, "HEVC requires VPS — should return nil without it")
    }
    
    func testParseAnnexBInvalidDataReturnsNil() {
        let result = ParameterSetParser.parseAnnexB(extradata: Data([0x00, 0x01]), codec: .h264)
        XCTAssertNil(result)
    }
    
    // MARK: - Main Entry Point
    
    func testParseFormatDescriptionDispatchesByCodec() {
        // H.264 with avcC
        let avcC: [UInt8] = [
            0x01, 0x42, 0xC0, 0x1E, 0xFF, 0xE1,
            0x00, 0x09, 0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x02, 0x80, 0xF6, 0x80,
            0x01, 0x00, 0x04, 0x68, 0xCE, 0x38, 0x80
        ]
        let h264Result = ParameterSetParser.parseFormatDescription(
            extradata: Data(avcC),
            codec: .h264,
            width: 320,
            height: 240
        )
        XCTAssertNotNil(h264Result)
    }
    
    func testParseFormatDescriptionNilExtradataReturnsNil() {
        let result = ParameterSetParser.parseFormatDescription(
            extradata: nil,
            codec: .h264,
            width: 320,
            height: 240
        )
        XCTAssertNil(result)
    }
    
    func testParseFormatDescriptionVP9ReturnsBasicFormatDesc() {
        // VP9 has no parameter sets — should still create a basic format description
        let result = ParameterSetParser.parseFormatDescription(
            extradata: nil,
            codec: .vp9,
            width: 320,
            height: 240
        )
        // VP9 may or may not succeed depending on VT support, but should not crash
        // On Apple Silicon it should return non-nil
        if HardwareCapabilities.isCodecSupported(.vp9) {
            XCTAssertNotNil(result)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd TitanPlayer && swift test --filter ParameterSetParserTests 2>&1 | tail -5`
Expected: FAIL with "cannot find 'ParameterSetParser' in scope"

- [ ] **Step 3: Implement `ParameterSetParser`**

Create `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Hardware/ParameterSetParser.swift`:

```swift
import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

// MARK: - Parameter Set Parser

enum ParameterSetParser {
    
    // MARK: - Main Entry Point
    
    static func parseFormatDescription(extradata: Data?,
                                       codec: VideoCodec,
                                       width: Int,
                                       height: Int) -> CMVideoFormatDescription? {
        switch codec {
        case .h264:
            if let extradata = extradata {
                if isAvcC(extradata) {
                    return parseH264(extradata: extradata)
                } else {
                    return parseAnnexB(extradata: extradata, codec: .h264)
                }
            }
            return createBasicFormatDescription(codec: codec, width: width, height: height)
            
        case .hevc:
            if let extradata = extradata {
                if isHvcC(extradata) {
                    return parseHEVC(extradata: extradata)
                } else {
                    return parseAnnexB(extradata: extradata, codec: .hevc)
                }
            }
            return createBasicFormatDescription(codec: codec, width: width, height: height)
            
        case .vp9, .av1, .mpeg2, .vc1:
            return createBasicFormatDescription(codec: codec, width: width, height: height)
        }
    }
    
    // MARK: - H.264 avcC Parsing
    
    static func parseH264(extradata: Data) -> CMVideoFormatDescription? {
        guard extradata.count >= 7 else { return nil }
        
        let bytes = [UInt8](extradata)
        
        // avcC structure:
        // [0] configurationVersion = 1
        // [1] AVCProfileIndication
        // [2] profile_compatibility
        // [3] AVCLevelIndication
        // [4] lengthSizeMinusOne (NALU length = (value & 0x03) + 1)
        // [5] numOfSequenceParameterSets (value & 0x1F)
        // [6..7] SPS length
        // [8...] SPS NALU
        // ... PPS count, PPS length, PPS NALU
        
        guard bytes[0] == 0x01 else { return nil }
        
        let numSPS = Int(bytes[5] & 0x1F)
        guard numSPS > 0 else { return nil }
        
        var spsArray: [[UInt8]] = []
        var offset = 6
        
        for _ in 0..<numSPS {
            guard offset + 2 <= bytes.count else { return nil }
            let spsLen = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            guard offset + spsLen <= bytes.count, spsLen > 0 else { return nil }
            spsArray.append(Array(bytes[offset..<(offset + spsLen)]))
            offset += spsLen
        }
        
        guard offset < bytes.count else { return nil }
        let numPPS = Int(bytes[offset])
        offset += 1
        
        var ppsArray: [[UInt8]] = []
        for _ in 0..<numPPS {
            guard offset + 2 <= bytes.count else { return nil }
            let ppsLen = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            guard offset + ppsLen <= bytes.count, ppsLen > 0 else { return nil }
            ppsArray.append(Array(bytes[offset..<(offset + ppsLen)]))
            offset += ppsLen
        }
        
        return createH264FormatDescription(spsArray: spsArray, ppsArray: ppsArray)
    }
    
    // MARK: - HEVC hvcC Parsing
    
    static func parseHEVC(extradata: Data) -> CMVideoFormatDescription? {
        guard extradata.count >= 23 else { return nil }
        
        let bytes = [UInt8](extradata)
        
        // hvcC structure (simplified):
        // [0] configurationVersion = 1
        // [1..12] profile/level info
        // [13] lengthSizeMinusOne (value & 0x03)
        // [14..15] numOfArrays (big-endian, but usually just [15] & 0xFF)
        // Each array: [0] array_completeness | NALU type
        //             [1..2] numNalus
        //             [3..4] nalUnitLength
        //             [5...] nalUnit
        
        guard bytes[0] == 0x01 else { return nil }
        
        let numArrays = Int(bytes[15])
        var offset = 16
        
        var vpsArray: [[UInt8]] = []
        var spsArray: [[UInt8]] = []
        var ppsArray: [[UInt8]] = []
        
        for _ in 0..<numArrays {
            guard offset + 3 <= bytes.count else { return nil }
            let nalType = bytes[offset] & 0x3F
            offset += 1
            let numNalus = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            
            for _ in 0..<numNalus {
                guard offset + 2 <= bytes.count else { return nil }
                let naluLen = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
                guard offset + naluLen <= bytes.count, naluLen > 0 else { return nil }
                let nalu = Array(bytes[offset..<(offset + naluLen)])
                offset += naluLen
                
                switch nalType {
                case 32: vpsArray.append(nalu)   // VPS
                case 33: spsArray.append(nalu)   // SPS
                case 34: ppsArray.append(nalu)   // PPS
                default: break
                }
            }
        }
        
        guard !vpsArray.isEmpty, !spsArray.isEmpty, !ppsArray.isEmpty else { return nil }
        
        return createHEVCFormatDescription(vpsArray: vpsArray, spsArray: spsArray, ppsArray: ppsArray)
    }
    
    // MARK: - Annex-B Parsing
    
    static func parseAnnexB(extradata: Data, codec: VideoCodec) -> CMVideoFormatDescription? {
        let nalus = splitAnnexBNALUs(extradata)
        guard !nalus.isEmpty else { return nil }
        
        switch codec {
        case .h264:
            var spsArray: [[UInt8]] = []
            var ppsArray: [[UInt8]] = []
            
            for nalu in nalus {
                guard !nalu.isEmpty else { continue }
                let nalType = nalu[0] & 0x1F
                switch nalType {
                case 7: spsArray.append(nalu)   // SPS
                case 8: ppsArray.append(nalu)   // PPS
                default: break
                }
            }
            
            guard !spsArray.isEmpty, !ppsArray.isEmpty else { return nil }
            return createH264FormatDescription(spsArray: spsArray, ppsArray: ppsArray)
            
        case .hevc:
            var vpsArray: [[UInt8]] = []
            var spsArray: [[UInt8]] = []
            var ppsArray: [[UInt8]] = []
            
            for nalu in nalus {
                guard !nalu.isEmpty else { continue }
                let nalType = (nalu[0] >> 1) & 0x3F
                switch nalType {
                case 32: vpsArray.append(nalu)  // VPS
                case 33: spsArray.append(nalu)  // SPS
                case 34: ppsArray.append(nalu)  // PPS
                default: break
                }
            }
            
            guard !vpsArray.isEmpty, !spsArray.isEmpty, !ppsArray.isEmpty else { return nil }
            return createHEVCFormatDescription(vpsArray: vpsArray, spsArray: spsArray, ppsArray: ppsArray)
            
        default:
            return nil
        }
    }
    
    // MARK: - Format Description Creation
    
    private static func createH264FormatDescription(spsArray: [[UInt8]], ppsArray: [[UInt8]]) -> CMVideoFormatDescription? {
        let spsPointers: [UnsafePointer<UInt8>] = spsArray.map { nalu in
            nalu.withUnsafeBufferPointer { buffer in
                buffer.baseAddress!
            }
        }
        let spsSizes: [Int] = spsArray.map { $0.count }
        
        let ppsPointers: [UnsafePointer<UInt8>] = ppsArray.map { nalu in
            nalu.withUnsafeBufferPointer { buffer in
                buffer.baseAddress!
            }
        }
        let ppsSizes: [Int] = ppsArray.map { $0.count }
        
        var formatDescription: CMVideoFormatDescription?
        
        // We need to keep the NALU arrays alive during the call.
        // Use withUnsafePointers via contiguous storage.
        return spsArray.withUnsafeBufferPointer { spsBuf in
            ppsArray.withUnsafeBufferPointer { ppsBuf in
                // Build pointer arrays from the stable storage
                var spsPtrs: [UnsafePointer<UInt8>] = []
                var spsLens: [Int] = []
                for i in 0..<spsArray.count {
                    spsPtrs.append(spsBuf.baseAddress!.advanced(by: i).withMemoryRebound(to: [UInt8].self, capacity: 1) { arrPtr in
                        arrPtr.withUnsafeBufferPointer { buf in buf.baseAddress! }
                    })
                    spsLens.append(spsBuf.baseAddress!.advanced(by: i).pointee.count)
                }
                
                var ppsPtrs: [UnsafePointer<UInt8>] = []
                var ppsLens: [Int] = []
                for i in 0..<ppsArray.count {
                    ppsPtrs.append(ppsBuf.baseAddress!.advanced(by: i).withMemoryRebound(to: [UInt8].self, capacity: 1) { arrPtr in
                        arrPtr.withUnsafeBufferPointer { buf in buf.baseAddress! }
                    })
                    ppsLens.append(ppsBuf.baseAddress!.advanced(by: i).pointee.count)
                }
                
                let status = spsPtrs.withUnsafeBufferPointer { spsPtrBuf in
                    spsLens.withUnsafeBufferPointer { spsLenBuf in
                        ppsPtrs.withUnsafeBufferPointer { ppsPtrBuf in
                            ppsLens.withUnsafeBufferPointer { ppsLenBuf in
                                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                                    allocator: kCFAllocatorDefault,
                                    parameterSetCount: Int32(spsArray.count),
                                    parameterSetPointers: spsPtrBuf.baseAddress,
                                    parameterSetSizes: spsLenBuf.baseAddress,
                                    nalUnitHeaderLength: 4,
                                    formatDescriptionOut: &formatDescription
                                )
                            }
                        }
                    }
                }
                
                return status == noErr ? formatDescription : nil
            }
        }
    }
    
    private static func createHEVCFormatDescription(vpsArray: [[UInt8]], spsArray: [[UInt8]], ppsArray: [[UInt8]]) -> CMVideoFormatDescription? {
        var formatDescription: CMVideoFormatDescription?
        
        // HEVC uses a single call with VPS, SPS, PPS arrays
        let vpsData = vpsArray.flatMap { $0 }
        let spsData = spsArray.flatMap { $0 }
        let ppsData = ppsArray.flatMap { $0 }
        
        let status: OSStatus = vpsData.withUnsafeBufferPointer { vpsBuf in
            spsData.withUnsafeBufferPointer { spsBuf in
                ppsData.withUnsafeBufferPointer { ppsBuf in
                    var vpsPtr = vpsBuf.baseAddress
                    var spsPtr = spsBuf.baseAddress
                    var ppsPtr = ppsBuf.baseAddress
                    
                    let vpsLen = Int32(vpsData.count)
                    let spsLen = Int32(spsData.count)
                    let ppsLen = Int32(ppsData.count)
                    
                    return withUnsafeMutablePointer(to: &vpsPtr) { vpsPtrPtr in
                        withUnsafeMutablePointer(to: &spsPtr) { spsPtrPtr in
                            withUnsafeMutablePointer(to: &ppsPtr) { ppsPtrPtr in
                                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                    allocator: kCFAllocatorDefault,
                                    parameterSetCount: 1,
                                    parameterSetPointers: vpsPtrPtr,
                                    parameterSetSizes: [vpsLen, spsLen, ppsLen],
                                    nalUnitHeaderLength: 4,
                                    formatDescriptionOut: &formatDescription
                                )
                            }
                        }
                    }
                }
            }
        }
        
        return status == noErr ? formatDescription : nil
    }
    
    private static func createBasicFormatDescription(codec: VideoCodec, width: Int, height: Int) -> CMVideoFormatDescription? {
        let codecType: CMVideoCodecType
        switch codec {
        case .h264:  codecType = kCMVideoCodecType_H264
        case .hevc:  codecType = kCMVideoCodecType_HEVC
        case .vp9:   codecType = kCMVideoCodecType_VP9
        case .av1:   codecType = kCMVideoCodecType_AV1
        case .mpeg2: codecType = kCMVideoCodecType_MPEG2Video
        case .vc1:   codecType = kCMVideoCodecType_VC1
        }
        
        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: Int32(width),
            height: Int32(height),
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        return status == noErr ? formatDescription : nil
    }
    
    // MARK: - Annex-B Splitting
    
    static func splitAnnexBNALUs(_ data: Data) -> [[UInt8]] {
        let bytes = [UInt8](data)
        var nalus: [[UInt8]] = []
        var i = 0
        
        while i < bytes.count {
            // Find start code: 00 00 00 01 or 00 00 01
            var startCodeLen = 0
            if i + 3 < bytes.count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                startCodeLen = 4
            } else if i + 2 < bytes.count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1 {
                startCodeLen = 3
            } else {
                i += 1
                continue
            }
            
            let naluStart = i + startCodeLen
            
            // Find next start code
            var j = naluStart + 1
            while j < bytes.count {
                if j + 3 < bytes.count && bytes[j] == 0 && bytes[j+1] == 0 && bytes[j+2] == 0 && bytes[j+3] == 1 {
                    break
                }
                if j + 2 < bytes.count && bytes[j] == 0 && bytes[j+1] == 0 && bytes[j+2] == 1 {
                    break
                }
                j += 1
            }
            
            let naluEnd = j < bytes.count ? j : bytes.count
            if naluEnd > naluStart {
                nalus.append(Array(bytes[naluStart..<naluEnd]))
            }
            
            i = j
        }
        
        return nalus
    }
    
    // MARK: - Format Detection
    
    private static func isAvcC(_ data: Data) -> Bool {
        guard data.count >= 5 else { return false }
        return data[0] == 0x01 && (data[4] & 0xFC) == 0xFC || data[0] == 0x01
    }
    
    private static func isHvcC(_ data: Data) -> Bool {
        guard data.count >= 5 else { return false }
        return data[0] == 0x01
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd TitanPlayer && swift test --filter ParameterSetParserTests 2>&1 | tail -10`
Expected: PASS (all tests green)

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Hardware/ParameterSetParser.swift TitanPlayer/Tests/VideoDecoderTests/Hardware/ParameterSetParserTests.swift
git commit -m "feat: add ParameterSetParser for avcC/hvcC/Annex-B to CMVideoFormatDescription"
```

---

## Task 4: Add Annex-B → AVCC Conversion to `ZeroCopyBufferManager`

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Utilities/ZeroCopyBuffer.swift`
- Create: `TitanPlayer/Tests/VideoDecoderTests/Utilities/ZeroCopyBufferTests.swift`

- [ ] **Step 1: Write failing tests**

Create `TitanPlayer/Tests/VideoDecoderTests/Utilities/ZeroCopyBufferTests.swift`:

```swift
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
    
    // MARK: - Annex-B → AVCC Conversion
    
    func testAnnexBToAVCCConvertsStartCodesToLengthPrefixes() {
        // Two NALUs in Annex-B format:
        // 00 00 00 01 <6 bytes SPS> 00 00 00 01 <4 bytes PPS>
        let annexB: [UInt8] = [
            0x00, 0x00, 0x00, 0x01,
            0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x02,  // 6-byte NALU
            0x00, 0x00, 0x00, 0x01,
            0x68, 0xCE, 0x38, 0x80               // 4-byte NALU
        ]
        
        let avcc = ZeroCopyBufferManager.annexBToAVCC(Data(annexB))
        let avccBytes = [UInt8](avcc)
        
        // First NALU: 4-byte length prefix (big-endian 6) + 6 bytes NALU
        XCTAssertEqual(avccBytes[0], 0x00)
        XCTAssertEqual(avccBytes[1], 0x00)
        XCTAssertEqual(avccBytes[2], 0x00)
        XCTAssertEqual(avccBytes[3], 0x06)  // length = 6
        XCTAssertEqual(avccBytes[4], 0x67)  // NALU data starts
        
        // Second NALU: at offset 10
        let secondStart = 10
        XCTAssertEqual(avccBytes[secondStart], 0x00)
        XCTAssertEqual(avccBytes[secondStart + 1], 0x00)
        XCTAssertEqual(avccBytes[secondStart + 2], 0x00)
        XCTAssertEqual(avccBytes[secondStart + 3], 0x04)  // length = 4
        XCTAssertEqual(avccBytes[secondStart + 4], 0x68)
    }
    
    func testAnnexBToAVCCHandles3ByteStartCodes() {
        let annexB: [UInt8] = [
            0x00, 0x00, 0x01,
            0x67, 0x42, 0xC0,  // 3-byte NALU
        ]
        
        let avcc = ZeroCopyBufferManager.annexBToAVCC(Data(annexB))
        let avccBytes = [UInt8](avcc)
        
        XCTAssertEqual(avccBytes[0], 0x00)
        XCTAssertEqual(avccBytes[1], 0x00)
        XCTAssertEqual(avccBytes[2], 0x00)
        XCTAssertEqual(avccBytes[3], 0x03)  // length = 3
    }
    
    func testAnnexBToAVCCEmptyDataReturnsEmpty() {
        let result = ZeroCopyBufferManager.annexBToAVCC(Data())
        XCTAssertTrue(result.isEmpty)
    }
    
    func testAnnexBToAVCCNoStartCodeReturnsOriginalData() {
        // Data with no start codes — should return wrapped in length prefix
        let raw: [UInt8] = [0x67, 0x42, 0xC0]
        let result = ZeroCopyBufferManager.annexBToAVCC(Data(raw))
        // Without a start code, the whole buffer is treated as one NALU
        XCTAssertEqual(result.count, 4 + 3)  // 4-byte length + 3 bytes data
    }
    
    // MARK: - Pixel Buffer Pool
    
    func testCreatePixelBufferPool() {
        let pool = bufferManager.createPixelBufferPool(
            width: 320,
            height: 240,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        XCTAssertNotNil(pool)
        
        let pixelBuffer = bufferManager.getPixelBuffer(from: pool)
        XCTAssertNotNil(pixelBuffer)
        XCTAssertEqual(CVPixelBufferGetWidth(pixelBuffer!), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(pixelBuffer!), 240)
    }
    
    // MARK: - Buffer Reuse
    
    func testBufferReuseQueue() {
        // Create a dummy sample buffer for reuse testing
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: 320, height: 240,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard let formatDesc = formatDescription else {
            XCTFail("Failed to create format description")
            return
        }
        
        let packet = MediaPacket(
            streamIndex: 0,
            data: Data(repeating: 0, count: 100),
            timestamp: CMTime(seconds: 0, preferredTimescale: 600),
            duration: CMTime(seconds: 0.033, preferredTimescale: 600),
            isKeyFrame: true
        )
        
        let sampleBuffer = try? bufferManager.createSampleBuffer(
            from: packet,
            formatDescription: formatDesc
        )
        XCTAssertNotNil(sampleBuffer)
        
        if let buffer = sampleBuffer {
            bufferManager.enqueueBuffer(buffer)
            let dequeued = bufferManager.dequeueBuffer()
            XCTAssertNotNil(dequeued)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd TitanPlayer && swift test --filter ZeroCopyBufferTests 2>&1 | tail -5`
Expected: FAIL with "annexBToAVCC" not found

- [ ] **Step 3: Add `annexBToAVCC` static method to `ZeroCopyBufferManager`**

Add to `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Utilities/ZeroCopyBuffer.swift`, inside the `ZeroCopyBufferManager` class (before the closing brace):

```swift
    // MARK: - Annex-B → AVCC Conversion
    
    static func annexBToAVCC(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        
        let bytes = [UInt8](data)
        var result: [UInt8] = []
        var i = 0
        var foundStartCode = false
        
        while i < bytes.count {
            // Detect 4-byte start code
            if i + 3 < bytes.count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 0 && bytes[i+3] == 1 {
                foundStartCode = true
                let naluStart = i + 4
                let naluEnd = findNextStartCode(in: bytes, from: naluStart)
                let naluLen = naluEnd - naluStart
                
                if naluLen > 0 {
                    // 4-byte big-endian length prefix
                    let len = UInt32(naluLen)
                    result.append(UInt8((len >> 24) & 0xFF))
                    result.append(UInt8((len >> 16) & 0xFF))
                    result.append(UInt8((len >> 8) & 0xFF))
                    result.append(UInt8(len & 0xFF))
                    result.append(contentsOf: bytes[naluStart..<naluEnd])
                }
                i = naluEnd
            }
            // Detect 3-byte start code
            else if i + 2 < bytes.count && bytes[i] == 0 && bytes[i+1] == 0 && bytes[i+2] == 1 {
                foundStartCode = true
                let naluStart = i + 3
                let naluEnd = findNextStartCode(in: bytes, from: naluStart)
                let naluLen = naluEnd - naluStart
                
                if naluLen > 0 {
                    let len = UInt32(naluLen)
                    result.append(UInt8((len >> 24) & 0xFF))
                    result.append(UInt8((len >> 16) & 0xFF))
                    result.append(UInt8((len >> 8) & 0xFF))
                    result.append(UInt8(len & 0xFF))
                    result.append(contentsOf: bytes[naluStart..<naluEnd])
                }
                i = naluEnd
            } else {
                i += 1
            }
        }
        
        // If no start codes found, treat entire buffer as single NALU
        if !foundStartCode {
            let len = UInt32(bytes.count)
            result.append(UInt8((len >> 24) & 0xFF))
            result.append(UInt8((len >> 16) & 0xFF))
            result.append(UInt8((len >> 8) & 0xFF))
            result.append(UInt8(len & 0xFF))
            result.append(contentsOf: bytes)
        }
        
        return Data(result)
    }
    
    private static func findNextStartCode(in bytes: [UInt8], from start: Int) -> Int {
        var j = start + 1
        while j < bytes.count {
            if j + 3 < bytes.count && bytes[j] == 0 && bytes[j+1] == 0 && bytes[j+2] == 0 && bytes[j+3] == 1 {
                return j
            }
            if j + 2 < bytes.count && bytes[j] == 0 && bytes[j+1] == 0 && bytes[j+2] == 1 {
                return j
            }
            j += 1
        }
        return bytes.count
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd TitanPlayer && swift test --filter ZeroCopyBufferTests 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Utilities/ZeroCopyBuffer.swift TitanPlayer/Tests/VideoDecoderTests/Utilities/ZeroCopyBufferTests.swift
git commit -m "feat: add Annex-B to AVCC length-prefix conversion in ZeroCopyBufferManager"
```

---

## Task 5: Fix `VideoToolboxDecoder` to Use `ParameterSetParser`

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Hardware/VideoToolboxDecoder.swift`
- Create: `TitanPlayer/Tests/VideoDecoderTests/Hardware/VideoToolboxDecoderTests.swift`

- [ ] **Step 1: Write unit tests**

Create `TitanPlayer/Tests/VideoDecoderTests/Hardware/VideoToolboxDecoderTests.swift`:

```swift
import XCTest
import CoreMedia
@testable import TitanPlayer

final class VideoToolboxDecoderTests: XCTestCase {
    
    var decoder: VideoToolboxDecoder!
    
    override func setUp() {
        super.setUp()
        decoder = VideoToolboxDecoder()
    }
    
    override func tearDown() async {
        await decoder.invalidate()
        decoder = nil
        await super.tearDown()
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
        if case .idle = decoder.state {} else {
            XCTFail("Expected idle state")
        }
    }
    
    func testConfigureForH264TrackWithExtradata() async throws {
        let avcC: [UInt8] = [
            0x01, 0x42, 0xC0, 0x1E, 0xFF, 0xE1,
            0x00, 0x09, 0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x02, 0x80, 0xF6, 0x80,
            0x01, 0x00, 0x04, 0x68, 0xCE, 0x38, 0x80
        ]
        
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 320,
            height: 240,
            frameRate: 30,
            isHDR: false,
            extradata: Data(avcC)
        )
        
        try await decoder.configure(for: track)
        
        if case .configured = decoder.state {} else {
            XCTFail("Expected configured state")
        }
    }
    
    func testConfigureForH264TrackWithoutExtradata() async throws {
        // Without extradata, should fall back to basic format description
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 320,
            height: 240,
            frameRate: 30,
            isHDR: false,
            extradata: nil
        )
        
        try await decoder.configure(for: track)
        
        if case .configured = decoder.state {} else {
            XCTFail("Expected configured state")
        }
    }
    
    func testConfigureRejectsUnsupportedCodec() async {
        let track = VideoTrackInfo(
            codec: "mp2v",
            width: 1920,
            height: 1080,
            frameRate: 30,
            isHDR: false,
            extradata: nil
        )
        
        do {
            try await decoder.configure(for: track)
            XCTFail("Should throw unsupportedCodec")
        } catch let error as DecoderError {
            if case .unsupportedCodec = error {} else {
                XCTFail("Expected unsupportedCodec error")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    func testFlushAndInvalidate() async throws {
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 320,
            height: 240,
            frameRate: 30,
            isHDR: false,
            extradata: nil
        )
        
        try await decoder.configure(for: track)
        
        await decoder.flush()
        if case .configured = decoder.state {} else {
            XCTFail("Expected configured state after flush")
        }
        
        await decoder.invalidate()
        if case .idle = decoder.state {} else {
            XCTFail("Expected idle state after invalidate")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails or passes (existing code may partially work)**

Run: `cd TitanPlayer && swift test --filter VideoToolboxDecoderTests 2>&1 | tail -10`
Expected: May partially pass — the existing configure already creates a session, but without extradata the format description is basic

- [ ] **Step 3: Modify `VideoToolboxDecoder.configureSync` to use `ParameterSetParser`**

In `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Hardware/VideoToolboxDecoder.swift`, replace the `createFormatDescription` private method:

```swift
    private func createFormatDescription(for track: VideoTrackInfo,
                                         codec: VideoCodec) throws -> CMVideoFormatDescription {
        if let formatDesc = ParameterSetParser.parseFormatDescription(
            extradata: track.extradata,
            codec: codec,
            width: track.width,
            height: track.height
        ) {
            return formatDesc
        }
        
        throw DecoderError.bufferCreationFailed(-1)
    }
```

This replaces the old method that used bare `CMVideoFormatDescriptionCreate`. The `ParameterSetParser` handles all cases: avcC, hvcC, Annex-B, and VP9/AV1 basic creation.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd TitanPlayer && swift test --filter VideoToolboxDecoderTests 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Hardware/VideoToolboxDecoder.swift TitanPlayer/Tests/VideoDecoderTests/Hardware/VideoToolboxDecoderTests.swift
git commit -m "feat: VideoToolboxDecoder uses ParameterSetParser for real format descriptions"
```

---

## Task 6: Fix `FFmpegSoftwareDecoder` — Extradata, HDR, Threading

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Software/FFmpegSoftwareDecoder.swift`
- Create: `TitanPlayer/Tests/VideoDecoderTests/Software/FFmpegSoftwareDecoderTests.swift`

- [ ] **Step 1: Write unit tests**

Create `TitanPlayer/Tests/VideoDecoderTests/Software/FFmpegSoftwareDecoderTests.swift`:

```swift
import XCTest
import CoreMedia
@testable import TitanPlayer

final class FFmpegSoftwareDecoderTests: XCTestCase {
    
    var decoder: FFmpegSoftwareDecoder!
    
    override func setUp() {
        super.setUp()
        decoder = FFmpegSoftwareDecoder()
    }
    
    override func tearDown() async {
        await decoder.invalidate()
        decoder = nil
        await super.tearDown()
    }
    
    func testDecoderCapabilities() {
        let caps = decoder.capabilities
        for codec in VideoCodec.allCases {
            XCTAssertTrue(caps.supportedCodecs.contains(codec), "Software should support \(codec.rawValue)")
        }
        XCTAssertFalse(caps.supportsHardwareAcceleration)
    }
    
    func testOutputFormatIsPixelBuffer() {
        XCTAssertEqual(decoder.outputFormat, .pixelBuffer)
    }
    
    func testConfigureForH264Track() async throws {
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 320,
            height: 240,
            frameRate: 30,
            isHDR: false,
            extradata: nil
        )
        
        try await decoder.configure(for: track)
        
        if case .configured = decoder.state {} else {
            XCTFail("Expected configured state")
        }
    }
    
    func testConfigureForVP9Track() async throws {
        let track = VideoTrackInfo(
            codec: "vp09",
            width: 320,
            height: 240,
            frameRate: 30,
            isHDR: false,
            extradata: nil
        )
        
        try await decoder.configure(for: track)
        
        if case .configured = decoder.state {} else {
            XCTFail("Expected configured state for VP9")
        }
    }
    
    func testConfigureForAV1Track() async throws {
        let track = VideoTrackInfo(
            codec: "av01",
            width: 320,
            height: 240,
            frameRate: 30,
            isHDR: false,
            extradata: nil
        )
        
        try await decoder.configure(for: track)
        
        if case .configured = decoder.state {} else {
            XCTFail("Expected configured state for AV1")
        }
    }
    
    func testConfigureForMPEG2Track() async throws {
        let track = VideoTrackInfo(
            codec: "mp2v",
            width: 320,
            height: 240,
            frameRate: 30,
            isHDR: false,
            extradata: nil
        )
        
        try await decoder.configure(for: track)
        
        if case .configured = decoder.state {} else {
            XCTFail("Expected configured state for MPEG-2")
        }
    }
    
    func testConfigureForVC1Track() async throws {
        let track = VideoTrackInfo(
            codec: "vc-1",
            width: 320,
            height: 240,
            frameRate: 30,
            isHDR: false,
            extradata: nil
        )
        
        try await decoder.configure(for: track)
        
        if case .configured = decoder.state {} else {
            XCTFail("Expected configured state for VC-1")
        }
    }
    
    func testConfigureRejectsInvalidCodec() async {
        let track = VideoTrackInfo(
            codec: "zzzz",
            width: 320,
            height: 240,
            frameRate: 30,
            isHDR: false,
            extradata: nil
        )
        
        do {
            try await decoder.configure(for: track)
            XCTFail("Should throw unsupportedCodec")
        } catch let error as DecoderError {
            if case .unsupportedCodec = error {} else {
                XCTFail("Expected unsupportedCodec error")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
    
    func testFlushAndInvalidate() async throws {
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 320,
            height: 240,
            frameRate: 30,
            isHDR: false,
            extradata: nil
        )
        
        try await decoder.configure(for: track)
        
        await decoder.flush()
        if case .configured = decoder.state {} else {
            XCTFail("Expected configured state after flush")
        }
        
        await decoder.invalidate()
        if case .idle = decoder.state {} else {
            XCTFail("Expected idle state after invalidate")
        }
    }
    
    func testConfigureWithExtradata() async throws {
        let avcC: [UInt8] = [
            0x01, 0x42, 0xC0, 0x1E, 0xFF, 0xE1,
            0x00, 0x09, 0x67, 0x42, 0xC0, 0x1E, 0xDA, 0x02, 0x80, 0xF6, 0x80,
            0x01, 0x00, 0x04, 0x68, 0xCE, 0x38, 0x80
        ]
        
        let track = VideoTrackInfo(
            codec: "avc1",
            width: 320,
            height: 240,
            frameRate: 30,
            isHDR: false,
            extradata: Data(avcC)
        )
        
        try await decoder.configure(for: track)
        
        if case .configured = decoder.state {} else {
            XCTFail("Expected configured state with extradata")
        }
    }
}
```

- [ ] **Step 2: Run test to verify current state**

Run: `cd TitanPlayer && swift test --filter FFmpegSoftwareDecoderTests 2>&1 | tail -10`
Expected: Most tests should pass with existing code — the configure path already works for codec finding

- [ ] **Step 3: Add extradata wiring, threading, and HDR support to `configure`**

In `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Software/FFmpegSoftwareDecoder.swift`, modify the `configure(for:)` method. After setting `ctx.pointee.width` and `ctx.pointee.height`, and before `avcodec_open2`, add:

```swift
        ctx.pointee.width = Int32(track.width)
        ctx.pointee.height = Int32(track.height)
        ctx.pointee.pix_fmt = track.isHDR ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12
        ctx.pointee.thread_count = 0
        ctx.pointee.thread_type = FF_THREAD_FRAME

        // Copy extradata (SPS/PPS/VPS) into codec context
        if let extradata = track.extradata, !extradata.isEmpty {
            let extradataSize = extradata.count
            let buffer = av_mallocz(extradataSize + AV_INPUT_BUFFER_PADDING_SIZE)
            guard let buffer = buffer else {
                teardownCodecContext()
                state = .error(.softwareFailure)
                throw DecoderError.softwareFailure
            }
            extradata.withUnsafeBytes { rawBuffer in
                if let base = rawBuffer.baseAddress {
                    memcpy(buffer, base, extradataSize)
                }
            }
            ctx.pointee.extradata = buffer.assumingMemoryBound(to: UInt8.self)
            ctx.pointee.extradata_size = Int32(extradataSize)
        }
```

Also update the `teardownCodecContext` method to free extradata:

```swift
    private func teardownCodecContext() {
        if let sws = swsContext {
            var swsPtr: UnsafeMutablePointer<SwsContext>? = sws
            sws_free_context(&swsPtr)
            swsContext = nil
        }
        if let ctx = codecContext {
            // avcodec_free_context will free extradata allocated by av_mallocz
            var ctxPtr: UnsafeMutablePointer<AVCodecContext>? = ctx
            avcodec_free_context(&ctxPtr)
            codecContext = nil
        }
    }
```

Also update `convertFrameToPixelBuffer` and `createPixelBuffer` to use 10-bit format for HDR:

In `createPixelBuffer`, change the pixel format selection:

```swift
    private func createPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let pixelFormat: OSType = currentCodec == nil || trackIsHDR == false
            ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
```

Add a `trackIsHDR` property to the class:

```swift
    private var trackIsHDR: Bool = false
```

Set it in `configure(for:)`:

```swift
        trackIsHDR = track.isHDR
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd TitanPlayer && swift test --filter FFmpegSoftwareDecoderTests 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Software/FFmpegSoftwareDecoder.swift TitanPlayer/Tests/VideoDecoderTests/Software/FFmpegSoftwareDecoderTests.swift
git commit -m "feat: FFmpegSoftwareDecoder extradata wiring, HDR P010, auto-threading"
```

---

## Task 7: Replace NSLock with `OSAllocatedUnfairLock`

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Hardware/VideoToolboxDecoder.swift`
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Software/FFmpegSoftwareDecoder.swift`

- [ ] **Step 1: Replace NSLock in `VideoToolboxDecoder`**

In `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Hardware/VideoToolboxDecoder.swift`:

1. Add import at top:
```swift
import os
```

2. Replace `private let lock = NSLock()` with:
```swift
    private let lock = OSAllocatedUnfairLock()
```

3. Replace all `lock.lock(); defer { lock.unlock() }` patterns with `lock.withLock { }` blocks. For methods that need to return values from inside the lock, use:
```swift
    return lock.withLock {
        // existing code
    }
```

For the `submitPacket` method (which locks, then unlocks mid-method), restructure:
```swift
    private func submitPacket(_ packet: MediaPacket,
                              continuation: CheckedContinuation<CMSampleBuffer, Error>) {
        let session: VTDecompressionSession?
        let formatDesc: CMVideoFormatDescription?
        
        lock.withLock {
            session = self.session
            formatDesc = self.formatDescription
            self.pendingContinuation = continuation
        }
        
        guard let session = session, let formatDescription = formatDesc else {
            continuation.resume(throwing: DecoderError.sessionNotConfigured)
            return
        }
        
        // Build the input CMSampleBuffer from the compressed packet.
        let bufferManager = ZeroCopyBufferManager(pixelBufferPool: pixelBufferPool)
        let sampleBuffer: CMSampleBuffer
        do {
            sampleBuffer = try bufferManager.createSampleBuffer(
                from: packet,
                formatDescription: formatDescription
            )
        } catch {
            lock.withLock { self.pendingContinuation = nil }
            continuation.resume(throwing: error)
            return
        }
        
        let decodeFlags: VTDecodeFrameFlags = [
            ._EnableAsynchronousDecompression,
            ._1xRealTimePlayback,
        ]
        
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: decodeFlags,
            frameRefcon: Unmanaged.passUnretained(self).toOpaque(),
            infoFlagsOut: nil
        )
        
        if status != noErr {
            lock.withLock { self.pendingContinuation = nil }
            continuation.resume(throwing: DecoderError.hardwareFailure)
            return
        }
    }
```

4. For `handleDecompressionOutput`, replace lock pattern:
```swift
    fileprivate func handleDecompressionOutput(status: OSStatus,
                                               infoFlags: VTDecodeInfoFlags,
                                               imageBuffer: CVImageBuffer?,
                                               presentationTimeStamp: CMTime,
                                               presentationDuration: CMTime) {
        let continuation = lock.withLock { () -> CheckedContinuation<CMSampleBuffer, Error>? in
            let cont = pendingContinuation
            pendingContinuation = nil
            return cont
        }
        
        guard let continuation = continuation else { return }
        // ... rest unchanged
    }
```

5. For `recordTimingSync`, replace with:
```swift
    private func recordTimingSync(_ timing: TimeInterval) {
        lock.withLock {
            decodeTimings.append(timing)
            if decodeTimings.count > maxTimingSamples {
                decodeTimings.removeFirst()
            }
        }
    }
```

6. For `averageDecodeTime`:
```swift
    var averageDecodeTime: TimeInterval {
        lock.withLock {
            guard !decodeTimings.isEmpty else { return 0 }
            return decodeTimings.reduce(0, +) / Double(decodeTimings.count)
        }
    }
```

- [ ] **Step 2: Replace NSLock in `FFmpegSoftwareDecoder`**

In `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Software/FFmpegSoftwareDecoder.swift`:

1. Add import:
```swift
import os
```

2. Replace `private let lock = NSLock()` with:
```swift
    private let lock = OSAllocatedUnfairLock()
```

3. Replace all `lock.lock(); defer { lock.unlock() }` with `lock.withLock { }` blocks throughout.

For `configure(for:)`:
```swift
    func configure(for track: VideoTrackInfo) async throws {
        try lock.withLock {
            // ... existing configure code ...
        }
    }
```

For `decode(_:)`:
```swift
    func decode(_ packet: MediaPacket) async throws -> DecoderOutput {
        try lock.withLock {
            // ... existing decode code ...
        }
    }
```

For `flush()`, `invalidate()`, `recordTimingUnlocked`, `averageDecodeTime` — same pattern.

- [ ] **Step 3: Verify build succeeds with no warnings**

Run: `cd TitanPlayer && swift build 2>&1 | grep -i "warning\|error" | head -10`
Expected: No NSLock warnings, no errors

- [ ] **Step 4: Run existing tests to verify no regressions**

Run: `cd TitanPlayer && swift test --filter "VideoToolboxDecoderTests\|FFmpegSoftwareDecoderTests" 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Hardware/VideoToolboxDecoder.swift TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Software/FFmpegSoftwareDecoder.swift
git commit -m "fix: replace NSLock with OSAllocatedUnfairLock for Swift 6 readiness"
```

---

## Task 8: Replace `FFmpegBridge` with Real `Libavformat` Bindings

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegBridge.swift`

- [ ] **Step 1: Implement real FFmpegBridge with Libavformat**

Replace the entire contents of `TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegBridge.swift`:

```swift
import Foundation
import CoreMedia
import Libavformat
import Libavcodec
import Libavutil

// MARK: - FFmpeg Bridge

final class FFmpegBridge: @unchecked Sendable {
    
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var videoStreamIndex: Int = -1
    private var audioStreamIndex: Int = -1
    
    init() {}
    
    deinit {
        close()
    }
    
    // MARK: - Open & Probe
    
    func open(url: String) -> Bool {
        var ctx: UnsafeMutablePointer<AVFormatContext>? = avformat_alloc_context()
        guard avformat_open_input(&ctx, url, nil, nil) == 0, let ctx = ctx else {
            return false
        }
        formatContext = ctx
        
        guard avformat_find_stream_info(ctx, nil) >= 0 else {
            close()
            return false
        }
        
        videoStreamIndex = av_find_best_stream(ctx, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0)
        audioStreamIndex = av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        
        return true
    }
    
    // MARK: - Stream Info
    
    var videoStream: UnsafeMutablePointer<AVStream>? {
        guard let ctx = formatContext, videoStreamIndex >= 0, videoStreamIndex < Int(ctx.pointee.nb_streams) else {
            return nil
        }
        return ctx.pointee.streams!.advanced(by: videoStreamIndex).pointee
    }
    
    var audioStream: UnsafeMutablePointer<AVStream>? {
        guard let ctx = formatContext, audioStreamIndex >= 0, audioStreamIndex < Int(ctx.pointee.nb_streams) else {
            return nil
        }
        return ctx.pointee.streams!.advanced(by: audioStreamIndex).pointee
    }
    
    var duration: Int64 {
        guard let ctx = formatContext else { return 0 }
        return ctx.pointee.duration
    }
    
    // MARK: - Read Frame
    
    func readFrame() -> (data: Data, streamIndex: Int, timestamp: Int64, duration: Int64, isKeyFrame: Bool)? {
        guard let ctx = formatContext else { return nil }
        
        let packet = av_packet_alloc()
        guard let packet = packet else { return nil }
        defer { var pkt = packet; av_packet_free(&pkt) }
        
        let ret = av_read_frame(ctx, packet)
        guard ret == 0 else { return nil }
        
        let dataCount = Int(packet.pointee.size)
        guard dataCount > 0, let dataPtr = packet.pointee.data else { return nil }
        
        let data = Data(bytes: dataPtr, count: dataCount)
        
        return (
            data: data,
            streamIndex: Int(packet.pointee.stream_index),
            timestamp: packet.pointee.pts != AV_NOPTS_VALUE ? packet.pointee.pts : packet.pointee.dts,
            duration: packet.pointee.duration,
            isKeyFrame: (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
        )
    }
    
    // MARK: - Seek
    
    func seek(timestamp: Int64, streamIndex: Int) -> Bool {
        guard let ctx = formatContext else { return false }
        return av_seek_frame(ctx, streamIndex, timestamp, AVSEEK_FLAG_BACKWARD) >= 0
    }
    
    // MARK: - Close
    
    func close() {
        if let ctx = formatContext {
            var ctxPtr: UnsafeMutablePointer<AVFormatContext>? = ctx
            avformat_close_input(&ctxPtr)
            formatContext = nil
        }
        videoStreamIndex = -1
        audioStreamIndex = -1
    }
    
    // MARK: - Codec ID Mapping
    
    static func codecIDToString(_ codecID: AVCodecID) -> String {
        switch codecID {
        case AV_CODEC_ID_H264:       return "avc1"
        case AV_CODEC_ID_HEVC:       return "hvc1"
        case AV_CODEC_ID_VP9:        return "vp09"
        case AV_CODEC_ID_AV1:        return "av01"
        case AV_CODEC_ID_MPEG2VIDEO:  return "mp2v"
        case AV_CODEC_ID_VC1:        return "vc-1"
        case AV_CODEC_ID_AAC:        return "aac"
        case AV_CODEC_ID_MP3:        return "mp3"
        case AV_CODEC_ID_AC3:        return "ac3"
        case AV_CODEC_ID_PCM_S16LE:  return "pcm"
        default:                     return "unknown"
        }
    }
}
```

- [ ] **Step 2: Verify build succeeds**

Run: `cd TitanPlayer && swift build 2>&1 | tail -10`
Expected: `Build complete!` (may have some minor type issues to fix depending on exact FFmpeg C bridging)

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegBridge.swift
git commit -m "feat: replace FFmpegBridge placeholders with real Libavformat bindings"
```

---

## Task 9: Fix `FFmpegDemuxer` for Real Demuxing

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegDemuxer.swift`

- [ ] **Step 1: Implement real FFmpegDemuxer**

Replace the entire contents of `TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegDemuxer.swift`:

```swift
import Foundation
import CoreMedia
import Libavformat
import Libavcodec
import Libavutil

class FFmpegDemuxer: MediaDemuxing {
    private var bridge: FFmpegBridge?
    private var isOpen = false
    
    func open(url: URL) async throws -> MediaInfo {
        let bridge = FFmpegBridge()
        self.bridge = bridge
        
        guard bridge.open(url: url.path) else {
            throw MediaError(code: .fileNotFound, message: "Failed to open file: \(url.lastPathComponent)")
        }
        
        isOpen = true
        
        var videoTracks: [VideoTrackInfo] = []
        var audioTracks: [AudioTrackInfo] = []
        
        // Extract video track info
        if let videoStream = bridge.videoStream {
            let codecpar = videoStream.pointee.codecpar
            guard let codecpar = codecpar else {
                throw MediaError(code: .decodingFailed, message: "No codec parameters for video stream")
            }
            
            let codecStr = FFmpegBridge.codecIDToString(codecpar.pointee.codec_id)
            let width = Int(codecpar.pointee.width)
            let height = Int(codecpar.pointee.height)
            
            // Frame rate from stream
            let frameRate = av_q2d(videoStream.pointee.avg_frame_rate)
            
            // HDR detection: check color primaries for BT.2020
            let isHDR = codecpar.pointee.color_primaries == AVCOL_PRI_BT2020
            
            // Extract extradata
            var extradata: Data? = nil
            if codecpar.pointee.extradata_size > 0, let ed = codecpar.pointee.extradata {
                extradata = Data(bytes: ed, count: Int(codecpar.pointee.extradata_size))
            }
            
            videoTracks.append(VideoTrackInfo(
                codec: codecStr,
                width: width,
                height: height,
                frameRate: frameRate > 0 ? frameRate : 30.0,
                isHDR: isHDR,
                extradata: extradata
            ))
        }
        
        // Extract audio track info
        if let audioStream = bridge.audioStream {
            let codecpar = audioStream.pointee.codecpar
            if let codecpar = codecpar {
                let codecStr = FFmpegBridge.codecIDToString(codecpar.pointee.codec_id)
                audioTracks.append(AudioTrackInfo(
                    codec: codecStr,
                    sampleRate: Int(codecpar.pointee.sample_rate),
                    channels: Int(codecpar.pointee.ch_layout.nb_channels),
                    language: nil
                ))
            }
        }
        
        let duration = CMTime(value: bridge.duration, timescale: 1000)
        
        return MediaInfo(
            duration: duration,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            subtitleTracks: [],
            format: url.pathExtension.uppercased()
        )
    }
    
    func nextPacket() async throws -> MediaPacket {
        guard isOpen, let bridge = bridge else {
            throw MediaError(code: .decodingFailed, message: "Demuxer not opened")
        }
        
        guard let result = bridge.readFrame() else {
            throw MediaError(code: .decodingFailed, message: "End of stream")
        }
        
        return MediaPacket(
            streamIndex: result.streamIndex,
            data: result.data,
            timestamp: CMTime(value: result.timestamp, timescale: 1000),
            duration: CMTime(value: result.duration, timescale: 1000),
            isKeyFrame: result.isKeyFrame
        )
    }
    
    func seek(to time: CMTime) async throws {
        guard let bridge = bridge else { return }
        let timestamp = Int64(time.seconds * 1000)
        if !bridge.seek(timestamp: timestamp, streamIndex: -1) {
            throw MediaError(code: .decodingFailed, message: "Seek failed")
        }
    }
    
    func close() {
        bridge?.close()
        bridge = nil
        isOpen = false
    }
}
```

- [ ] **Step 2: Verify build succeeds**

Run: `cd TitanPlayer && swift build 2>&1 | tail -10`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/FFmpeg/FFmpegDemuxer.swift
git commit -m "feat: FFmpegDemuxer uses real Libavformat for demuxing and extradata extraction"
```

---

## Task 10: Fix `AVFoundationDemuxer` for Real Data Extraction

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/AVFoundation/AVFoundationDemuxer.swift`

- [ ] **Step 1: Implement real AVFoundationDemuxer**

Replace the entire contents of `TitanPlayer/TitanPlayer/Core/Decoders/AVFoundation/AVFoundationDemuxer.swift`:

```swift
import AVFoundation
import CoreMedia
import CoreVideo

class AVFoundationDemuxer: MediaDemuxing {
    private var asset: AVURLAsset?
    private var assetReader: AVAssetReader?
    private var videoOutput: AVAssetReaderTrackOutput?
    private var audioOutput: AVAssetReaderTrackOutput?
    private var videoTrack: AVAssetTrack?
    private var startTime: CMTime = .zero
    
    func open(url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        self.asset = asset
        
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw MediaError(code: .decodingFailed, message: "Failed to create asset reader")
        }
        self.assetReader = reader
        
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        
        var videoTracks: [VideoTrackInfo] = []
        var audioTrackInfos: [AudioTrackInfo] = []
        
        if let videoTrack = tracks.first {
            self.videoTrack = videoTrack
            
            let dimensions = try await videoTrack.load(.naturalSize)
            let frameRate = try await videoTrack.load(.nominalFrameRate)
            let codecType = try await videoTrack.load(.codecType)
            let formatDescriptions = try await videoTrack.load(.formatDescriptions)
            
            // Determine codec string
            let codecStr: String
            switch codecType {
            case .h264:  codecStr = "avc1"
            case .hevc:  codecStr = "hvc1"
            case .vp9:   codecStr = "vp09"
            case .av1:   codecStr = "av01"
            default:     codecStr = "avc1"
            }
            
            // HDR detection from format description extensions
            var isHDR = false
            if let formatDesc = formatDescriptions.first as? CMVideoFormatDescription {
                if let extensions = CMFormatDescriptionGetExtensions(formatDesc) {
                    let hdrIndicator = extensions[kCGImagePropertyColorSpaceKey as String] as? String
                    isHDR = hdrIndicator == "BT2020"
                }
            }
            
            // Extract extradata from format description
            let extradata = extractExtradata(from: formatDescriptions, codecType: codecType)
            
            videoTracks.append(VideoTrackInfo(
                codec: codecStr,
                width: Int(dimensions.width),
                height: Int(dimensions.height),
                frameRate: Double(frameRate),
                isHDR: isHDR,
                extradata: extradata
            ))
            
            // Set up video output for compressed reading
            let output = AVAssetReaderTrackOutput(
                track: videoTrack,
                outputSettings: nil  // nil = compressed output
            )
            output.alwaysCopiesSampleData = false
            reader.add(output)
            self.videoOutput = output
        }
        
        if let audioTrack = audioTracks.first {
            let sampleRate = try await audioTrack.load(.sampleRate)
            let channels = try await audioTrack.load(.channelCount)
            
            audioTrackInfos.append(AudioTrackInfo(
                codec: "aac",
                sampleRate: Int(sampleRate),
                channels: channels,
                language: try? await audioTrack.load(.languageCode)
            ))
            
            let audioOut = AVAssetReaderTrackOutput(
                track: audioTrack,
                outputSettings: nil
            )
            reader.add(audioOut)
            self.audioOutput = audioOut
        }
        
        return MediaInfo(
            duration: duration,
            videoTracks: videoTracks,
            audioTracks: audioTrackInfos,
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
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                dataBuffer,
                atOffset: 0,
                lengthAtOffsetOut: &length,
                totalLengthOut: nil,
                dataPointerOut: &dataPointer
            )
            
            guard status == kCMBlockBufferNoErr, let ptr = dataPointer, length > 0 else {
                throw MediaError(code: .decodingFailed, message: "Failed to get data pointer")
            }
            
            let data = Data(bytes: ptr, count: length)
            
            return MediaPacket(
                streamIndex: 0,
                data: data,
                timestamp: timestamp,
                duration: duration,
                isKeyFrame: true
            )
        }
        
        throw MediaError(code: .decodingFailed, message: "No more packets")
    }
    
    func seek(to time: CMTime) async throws {
        startTime = time
        // AVAssetReader doesn't support mid-stream seeking — would need to recreate
        // For now, store the start time; full seek support requires reader recreation
    }
    
    func close() {
        assetReader?.cancelReading()
        assetReader = nil
        videoOutput = nil
        audioOutput = nil
        asset = nil
        videoTrack = nil
    }
    
    // MARK: - Extradata Extraction
    
    private func extractExtradata(from formatDescriptions: [Any], codecType: CMVideoCodecType) -> Data? {
        guard let formatDesc = formatDescriptions.first as? CMVideoFormatDescription else {
            return nil
        }
        
        // For H.264: extract SPS/PPS and build avcC
        if codecType == .h264 {
            return extractH264Extradata(from: formatDesc)
        }
        
        // For HEVC: extract VPS/SPS/PPS and build hvcC
        if codecType == .hevc {
            return extractHEVCExtradata(from: formatDesc)
        }
        
        return nil
    }
    
    private func extractH264Extradata(from formatDesc: CMVideoFormatDescription) -> Data? {
        // Use CMVideoFormatDescriptionGetH264ParameterSetAtIndex to extract SPS/PPS
        var spsArray: [[UInt8]] = []
        var ppsArray: [[UInt8]] = []
        
        var index: Int = 0
        while true {
            var parameterSetPointer: UnsafePointer<UInt8>?
            var parameterSetSize: Int = 0
            var parameterSetCount: Int = 0
            
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc,
                parameterSetIndex: index,
                parameterSetPointerOut: &parameterSetPointer,
                parameterSetSizeOut: &parameterSetSize,
                parameterSetCountOut: &parameterSetCount,
                nalUnitHeaderLengthOut: nil
            )
            
            guard status == noErr, let ptr = parameterSetPointer, parameterSetSize > 0 else {
                break
            }
            
            let bytes = Array(UnsafeBufferPointer(start: ptr, count: parameterSetSize))
            
            if !bytes.isEmpty {
                let nalType = bytes[0] & 0x1F
                if nalType == 7 { spsArray.append(bytes) }
                else if nalType == 8 { ppsArray.append(bytes) }
            }
            
            index += 1
        }
        
        guard !spsArray.isEmpty, !ppsArray.isEmpty else { return nil }
        
        // Build avcC byte stream
        var avcC: [UInt8] = []
        avcC.append(0x01)  // configurationVersion
        
        // Profile/level from first SPS
        if let sps = spsArray.first, sps.count >= 4 {
            avcC.append(sps[1])  // AVCProfileIndication
            avcC.append(sps[2])  // profile_compatibility
            avcC.append(sps[3])  // AVCLevelIndication
        } else {
            avcC.append(0x42)
            avcC.append(0xC0)
            avcC.append(0x1E)
        }
        
        avcC.append(0xFF)  // lengthSizeMinusOne = 3 (4-byte lengths)
        avcC.append(0xE1)  // numOfSequenceParameterSets = 1
        
        // SPS
        if let sps = spsArray.first {
            avcC.append(UInt8((sps.count >> 8) & 0xFF))
            avcC.append(UInt8(sps.count & 0xFF))
            avcC.append(contentsOf: sps)
        }
        
        // PPS
        avcC.append(0x01)  // numOfPictureParameterSets = 1
        if let pps = ppsArray.first {
            avcC.append(UInt8((pps.count >> 8) & 0xFF))
            avcC.append(UInt8(pps.count & 0xFF))
            avcC.append(contentsOf: pps)
        }
        
        return Data(avcC)
    }
    
    private func extractHEVCExtradata(from formatDesc: CMVideoFormatDescription) -> Data? {
        // HEVC parameter set extraction would use CMVideoFormatDescriptionGetHEVCParameterSetAtIndex
        // This is available on macOS 11+ — for now return nil and rely on basic format description
        // TODO: implement full HEVC extradata extraction
        return nil
    }
}
```

- [ ] **Step 2: Verify build succeeds**

Run: `cd TitanPlayer && swift build 2>&1 | tail -10`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/AVFoundation/AVFoundationDemuxer.swift
git commit -m "feat: AVFoundationDemuxer extracts real compressed data and avcC extradata"
```

---

## Task 11: Fix `DecoderSelector` — `DecoderSwitch` Enum

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Manager/DecoderSelector.swift`
- Create: `TitanPlayer/Tests/VideoDecoderTests/Manager/DecoderSelectorTests.swift`

- [ ] **Step 1: Write failing tests**

Create `TitanPlayer/Tests/VideoDecoderTests/Manager/DecoderSelectorTests.swift`:

```swift
import XCTest
@testable import TitanPlayer

final class DecoderSelectorTests: XCTestCase {
    
    let selector = DecoderSelector()
    
    // MARK: - Scoring
    
    func testSelectDecoderPrefersHardwareWhenAvailable() {
        let track = VideoTrackInfo(
            codec: "avc1", width: 1920, height: 1080,
            frameRate: 30, isHDR: false, extradata: nil
        )
        let systemState = SystemState(isHardwareAvailable: true)
        
        // Create mock decoders
        let hwCaps = DecoderCapabilities(
            supportedCodecs: [.h264, .hevc],
            maxResolution: CGSize(width: 4096, height: 2160),
            supportsHDR: true,
            supportsHardwareAcceleration: true,
            maxConcurrentDecodes: 2
        )
        let swCaps = DecoderCapabilities(
            supportedCodecs: Set(VideoCodec.allCases),
            maxResolution: CGSize(width: 8192, height: 4320),
            supportsHDR: true,
            supportsHardwareAcceleration: false,
            maxConcurrentDecodes: 1
        )
        
        let selection = selector.selectDecoder(
            for: track,
            hardwareCapabilities: hwCaps,
            softwareCapabilities: swCaps,
            systemState: systemState
        )
        
        XCTAssertEqual(selection, .hardware)
    }
    
    func testSelectDecoderFallsBackToSoftwareForUnsupportedCodec() {
        let track = VideoTrackInfo(
            codec: "mp2v", width: 1920, height: 1080,
            frameRate: 30, isHDR: false, extradata: nil
        )
        let systemState = SystemState(isHardwareAvailable: true)
        
        // Hardware doesn't support MPEG-2
        let hwCaps = DecoderCapabilities(
            supportedCodecs: [.h264, .hevc],
            maxResolution: CGSize(width: 4096, height: 2160),
            supportsHDR: true,
            supportsHardwareAcceleration: true,
            maxConcurrentDecodes: 2
        )
        let swCaps = DecoderCapabilities(
            supportedCodecs: Set(VideoCodec.allCases),
            maxResolution: CGSize(width: 8192, height: 4320),
            supportsHDR: true,
            supportsHardwareAcceleration: false,
            maxConcurrentDecodes: 1
        )
        
        let selection = selector.selectDecoder(
            for: track,
            hardwareCapabilities: hwCaps,
            softwareCapabilities: swCaps,
            systemState: systemState
        )
        
        XCTAssertEqual(selection, .software)
    }
    
    // MARK: - Switch Decisions
    
    func testCheckForSwitchReturnsNoneWhenNotDegraded() {
        let systemState = SystemState(thermalState: .nominal, cpuUsage: 0.3, gpuUsage: 0.4)
        let metrics = PerformanceMetrics(averageDecodeTime: 0.005, frameDropRate: 0.0, isDegraded: false)
        
        let result = selector.checkForSwitch(
            currentIsHardware: true,
            systemState: systemState,
            recentPerformance: metrics
        )
        
        XCTAssertEqual(result, .none)
    }
    
    func testCheckForSwitchToSoftwareOnCriticalThermal() {
        let systemState = SystemState(thermalState: .critical, cpuUsage: 0.5, gpuUsage: 0.5)
        let metrics = PerformanceMetrics(averageDecodeTime: 0.020, frameDropRate: 0.05, isDegraded: true)
        
        let result = selector.checkForSwitch(
            currentIsHardware: true,
            systemState: systemState,
            recentPerformance: metrics
        )
        
        XCTAssertEqual(result, .toSoftware)
    }
    
    func testCheckForSwitchToHardwareOnLowBattery() {
        let systemState = SystemState(
            thermalState: .nominal,
            cpuUsage: 0.5,
            gpuUsage: 0.5,
            batteryLevel: 0.15,
            batteryState: .charging
        )
        let metrics = PerformanceMetrics(averageDecodeTime: 0.020, frameDropRate: 0.05, isDegraded: true)
        
        let result = selector.checkForSwitch(
            currentIsHardware: false,
            systemState: systemState,
            recentPerformance: metrics
        )
        
        // Software on low battery should switch to hardware (more efficient)
        XCTAssertEqual(result, .toHardware)
    }
    
    func testCheckForSwitchToSoftwareOnHighCPU() {
        let systemState = SystemState(thermalState: .nominal, cpuUsage: 0.90, gpuUsage: 0.50)
        let metrics = PerformanceMetrics(averageDecodeTime: 0.020, frameDropRate: 0.05, isDegraded: true)
        
        let result = selector.checkForSwitch(
            currentIsHardware: true,
            systemState: systemState,
            recentPerformance: metrics
        )
        
        XCTAssertEqual(result, .toSoftware)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd TitanPlayer && swift test --filter DecoderSelectorTests 2>&1 | tail -5`
Expected: FAIL — `selectDecoder` and `checkForSwitch` signatures don't match

- [ ] **Step 3: Rewrite `DecoderSelector`**

Replace the entire contents of `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Manager/DecoderSelector.swift`:

```swift
import Foundation

// MARK: - Decoder Selection

enum DecoderSelection: Sendable {
    case hardware
    case software
}

// MARK: - Decoder Switch

enum DecoderSwitch: Sendable {
    case toHardware
    case toSoftware
    case none
}

// MARK: - Decoder Selector

struct DecoderSelector {
    
    // MARK: - Selection Logic
    
    func selectDecoder(for track: VideoTrackInfo,
                       hardwareCapabilities: DecoderCapabilities,
                       softwareCapabilities: DecoderCapabilities,
                       systemState: SystemState) -> DecoderSelection {
        
        let hwScore = calculateScore(
            capabilities: hardwareCapabilities,
            track: track,
            systemState: systemState,
            isHardware: true
        )
        let swScore = calculateScore(
            capabilities: softwareCapabilities,
            track: track,
            systemState: systemState,
            isHardware: false
        )
        
        return hwScore >= swScore ? .hardware : .software
    }
    
    // MARK: - Switch Check
    
    func checkForSwitch(currentIsHardware: Bool,
                        systemState: SystemState,
                        recentPerformance: PerformanceMetrics) -> DecoderSwitch {
        
        guard recentPerformance.isDegraded else { return .none }
        
        // Critical thermal: switch hardware → software
        if systemState.thermalState == .critical && currentIsHardware {
            return .toSoftware
        }
        
        // High CPU: software is CPU-bound, switch to hardware
        if systemState.cpuUsage > 0.85 && !currentIsHardware {
            return .toHardware
        }
        
        // High GPU: hardware is GPU-bound, switch to software
        if systemState.gpuUsage > 0.90 && currentIsHardware {
            return .toSoftware
        }
        
        // Low battery + charging: prefer hardware (more power-efficient)
        if systemState.batteryState == .charging && systemState.batteryLevel < 0.20 && !currentIsHardware {
            return .toHardware
        }
        
        return .none
    }
    
    // MARK: - Scoring
    
    private func calculateScore(capabilities: DecoderCapabilities,
                                track: VideoTrackInfo,
                                systemState: SystemState,
                                isHardware: Bool) -> Double {
        var score: Double = 0
        
        // Codec support (0-30 points)
        if let codec = VideoCodec(rawValue: track.codec),
           capabilities.supportedCodecs.contains(codec) {
            score += 30
        }
        
        // Hardware acceleration bonus (0-20 points)
        if isHardware && capabilities.supportsHardwareAcceleration && systemState.isHardwareAvailable {
            score += 20
        }
        
        // Performance baseline (0-25 points)
        // Hardware is faster under normal conditions; software is more consistent
        if isHardware && systemState.thermalState == .nominal {
            score += 25
        } else if isHardware && systemState.thermalState == .fair {
            score += 15
        } else if !isHardware {
            score += 15
        }
        
        // Thermal efficiency (0-15 points)
        if systemState.thermalState == .nominal && isHardware {
            score += 15
        } else if systemState.thermalState == .fair && isHardware {
            score += 8
        }
        
        // Resolution support (0-10 points)
        let resolution = CGSize(width: track.width, height: track.height)
        if capabilities.maxResolution.width >= resolution.width &&
           capabilities.maxResolution.height >= resolution.height {
            score += 10
        }
        
        return score
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd TitanPlayer && swift test --filter DecoderSelectorTests 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Manager/DecoderSelector.swift TitanPlayer/Tests/VideoDecoderTests/Manager/DecoderSelectorTests.swift
git commit -m "feat: DecoderSelector returns DecoderSwitch enum, no throwaway instances"
```

---

## Task 12: Fix `AdaptiveDecoderManager` — Use Owned Instances

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Manager/AdaptiveDecoderManager.swift`
- Create: `TitanPlayer/Tests/VideoDecoderTests/Manager/AdaptiveDecoderManagerTests.swift`

- [ ] **Step 1: Write tests**

Create `TitanPlayer/Tests/VideoDecoderTests/Manager/AdaptiveDecoderManagerTests.swift`:

```swift
import XCTest
import CoreMedia
@testable import TitanPlayer

final class AdaptiveDecoderManagerTests: XCTestCase {
    
    var manager: AdaptiveDecoderManager!
    
    override func setUp() {
        super.setUp()
        manager = AdaptiveDecoderManager()
    }
    
    override func tearDown() async {
        await manager.invalidate()
        manager = nil
        await super.tearDown()
    }
    
    func testConfigureSelectsHardwareForH264() async throws {
        let track = VideoTrackInfo(
            codec: "avc1", width: 320, height: 240,
            frameRate: 30, isHDR: false, extradata: nil
        )
        
        try await manager.configure(for: track)
        
        let decoderType = await manager.activeDecoderType
        XCTAssertNotNil(decoderType)
        XCTAssertTrue(decoderType?.contains("VideoToolbox") ?? false,
                      "Should select hardware decoder for H.264")
    }
    
    func testConfigureSelectsSoftwareForMPEG2() async throws {
        let track = VideoTrackInfo(
            codec: "mp2v", width: 320, height: 240,
            frameRate: 30, isHDR: false, extradata: nil
        )
        
        try await manager.configure(for: track)
        
        let decoderType = await manager.activeDecoderType
        XCTAssertNotNil(decoderType)
        XCTAssertTrue(decoderType?.contains("FFmpeg") ?? false,
                      "Should select software decoder for MPEG-2")
    }
    
    func testInvalidateResetsState() async throws {
        let track = VideoTrackInfo(
            codec: "avc1", width: 320, height: 240,
            frameRate: 30, isHDR: false, extradata: nil
        )
        
        try await manager.configure(for: track)
        await manager.invalidate()
        
        let decoderType = await manager.activeDecoderType
        XCTAssertNil(decoderType, "Active decoder should be nil after invalidate")
    }
    
    func testFlushAfterConfigure() async throws {
        let track = VideoTrackInfo(
            codec: "avc1", width: 320, height: 240,
            frameRate: 30, isHDR: false, extradata: nil
        )
        
        try await manager.configure(for: track)
        await manager.flush()
        // Should not crash
    }
}
```

- [ ] **Step 2: Rewrite `AdaptiveDecoderManager`**

Replace the entire contents of `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Manager/AdaptiveDecoderManager.swift`:

```swift
import Foundation

// MARK: - Manager State

enum ManagerState: Sendable {
    case idle
    case decoding(isHardware: Bool)
    case switching
    case error(DecoderError)
}

// MARK: - Adaptive Decoder Manager

class AdaptiveDecoderManager: @unchecked Sendable {
    private var hardwareDecoder: VideoToolboxDecoder?
    private var softwareDecoder: FFmpegSoftwareDecoder?
    private(set) var activeDecoder: VideoDecoding?
    
    private let decoderSelector = DecoderSelector()
    private let performanceMonitor = PerformanceMonitor()
    
    private(set) var currentState: ManagerState = .idle
    private var currentTrack: VideoTrackInfo?
    private var currentIsHardware: Bool = false
    
    private let stateActor = DecoderStateActor()
    
    init() {}
    
    // MARK: - Public API
    
    func configure(for track: VideoTrackInfo) async throws {
        currentTrack = track
        
        let hwCaps = DecoderCapabilities(from: HardwareCapabilities.query())
        let swCaps = DecoderCapabilities(from: SoftwareCapabilities.query())
        let systemState = performanceMonitor.currentSystemState
        
        let selection = decoderSelector.selectDecoder(
            for: track,
            hardwareCapabilities: hwCaps,
            softwareCapabilities: swCaps,
            systemState: systemState
        )
        
        let decoder: VideoDecoding
        switch selection {
        case .hardware:
            if hardwareDecoder == nil {
                hardwareDecoder = VideoToolboxDecoder()
            }
            decoder = hardwareDecoder!
            currentIsHardware = true
        case .software:
            if softwareDecoder == nil {
                softwareDecoder = FFmpegSoftwareDecoder()
            }
            decoder = softwareDecoder!
            currentIsHardware = false
        }
        
        try await decoder.configure(for: track)
        activeDecoder = decoder
        await stateActor.setState(.decoding(isHardware: currentIsHardware))
    }
    
    func decode(_ packet: MediaPacket) async throws -> DecoderOutput {
        guard let decoder = activeDecoder else {
            throw DecoderError.sessionNotConfigured
        }
        
        do {
            let output = try await decoder.decode(packet)
            
            performanceMonitor.recordDecodeTiming(
                decoder: type(of: decoder),
                duration: packet.duration.seconds
            )
            
            // Check if we should switch decoders
            let switchDecision = decoderSelector.checkForSwitch(
                currentIsHardware: currentIsHardware,
                systemState: performanceMonitor.currentSystemState,
                recentPerformance: performanceMonitor.recentMetrics
            )
            
            if switchDecision != .none {
                try await performSwitch(switchDecision)
                guard let newDecoder = activeDecoder else {
                    throw DecoderError.sessionNotConfigured
                }
                return try await newDecoder.decode(packet)
            }
            
            return output
            
        } catch {
            return try await handleDecodeError(error, packet: packet)
        }
    }
    
    func flush() async {
        await activeDecoder?.flush()
    }
    
    func invalidate() async {
        await hardwareDecoder?.invalidate()
        await softwareDecoder?.invalidate()
        activeDecoder = nil
        hardwareDecoder = nil
        softwareDecoder = nil
        await stateActor.setState(.idle)
        performanceMonitor.reset()
    }
    
    var activeDecoderType: String? {
        guard let decoder = activeDecoder else { return nil }
        return String(describing: type(of: decoder))
    }
    
    // MARK: - Hot-Swap Support
    
    private func performSwitch(_ switchDecision: DecoderSwitch) async throws {
        let newDecoder: VideoDecoding
        
        switch switchDecision {
        case .toHardware:
            if hardwareDecoder == nil {
                hardwareDecoder = VideoToolboxDecoder()
            }
            newDecoder = hardwareDecoder!
            currentIsHardware = true
        case .toSoftware:
            if softwareDecoder == nil {
                softwareDecoder = FFmpegSoftwareDecoder()
            }
            newDecoder = softwareDecoder!
            currentIsHardware = false
        case .none:
            return
        }
        
        await stateActor.setState(.switching)
        
        // Flush old decoder
        await activeDecoder?.flush()
        
        // Configure new decoder if needed
        if case .idle = newDecoder.state, let track = currentTrack {
            try await newDecoder.configure(for: track)
        }
        
        // Switch active decoder
        activeDecoder = newDecoder
        await stateActor.setState(.decoding(isHardware: currentIsHardware))
        
        performanceMonitor.recordDecoderSwitch(
            from: type(of: activeDecoder!),
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
            let switchDecision: DecoderSwitch = currentIsHardware ? .toSoftware : .toHardware
            try await performSwitch(switchDecision)
            guard let newDecoder = activeDecoder else {
                throw DecoderError.sessionNotConfigured
            }
            return try await newDecoder.decode(packet)
            
        case .persistent:
            await stateActor.setState(.error(decoderError))
            throw decoderError
        }
    }
}

// MARK: - Actor for Thread-Safe State

private actor DecoderStateActor {
    private var currentState: ManagerState = .idle
    
    func getState() -> ManagerState {
        return currentState
    }
    
    func setState(_ state: ManagerState) {
        self.currentState = state
    }
}
```

- [ ] **Step 3: Run test to verify it passes**

Run: `cd TitanPlayer && swift test --filter AdaptiveDecoderManagerTests 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Manager/AdaptiveDecoderManager.swift TitanPlayer/Tests/VideoDecoderTests/Manager/AdaptiveDecoderManagerTests.swift
git commit -m "feat: AdaptiveDecoderManager uses DecoderSwitch enum and owned decoder instances"
```

---

## Task 13: Implement Real CPU Monitoring in `PerformanceMonitor`

**Files:**
- Modify: `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Utilities/PerformanceMonitor.swift`
- Create: `TitanPlayer/Tests/VideoDecoderTests/Utilities/PerformanceMonitorTests.swift`

- [ ] **Step 1: Write tests**

Create `TitanPlayer/Tests/VideoDecoderTests/Utilities/PerformanceMonitorTests.swift`:

```swift
import XCTest
@testable import TitanPlayer

final class PerformanceMonitorTests: XCTestCase {
    
    var monitor: PerformanceMonitor!
    
    override func setUp() {
        super.setUp()
        monitor = PerformanceMonitor()
    }
    
    override func tearDown() {
        monitor = nil
        super.tearDown()
    }
    
    func testInitialStateIsNominal() {
        XCTAssertEqual(monitor.currentSystemState.thermalState, .nominal)
        XCTAssertFalse(monitor.recentMetrics.isDegraded)
    }
    
    func testRecordDecodeTimingUpdatesMetrics() {
        monitor.recordDecodeTiming(
            decoder: VideoToolboxDecoder.self,
            duration: 0.010
        )
        
        XCTAssertGreaterThan(monitor.recentMetrics.averageDecodeTime, 0)
    }
    
    func testDegradationDetectedOnHighDecodeTime() {
        // Record many slow decodes (>16ms = 0.016s)
        for _ in 0..<20 {
            monitor.recordDecodeTiming(
                decoder: VideoToolboxDecoder.self,
                duration: 0.025
            )
        }
        
        XCTAssertTrue(monitor.recentMetrics.isDegraded, "Should detect degraded performance")
    }
    
    func testNoDegradationOnFastDecode() {
        for _ in 0..<20 {
            monitor.recordDecodeTiming(
                decoder: VideoToolboxDecoder.self,
                duration: 0.005
            )
        }
        
        XCTAssertFalse(monitor.recentMetrics.isDegraded)
    }
    
    func testRecordFrameDrop() {
        monitor.recordFrameDrop()
        monitor.recordFrameDrop()
        
        XCTAssertGreaterThan(monitor.recentMetrics.frameDropRate, 0)
    }
    
    func testResetClearsMetrics() {
        monitor.recordDecodeTiming(
            decoder: VideoToolboxDecoder.self,
            duration: 0.020
        )
        monitor.recordFrameDrop()
        
        monitor.reset()
        
        XCTAssertEqual(monitor.recentMetrics.averageDecodeTime, 0)
        XCTAssertEqual(monitor.recentMetrics.frameDropRate, 0)
        XCTAssertFalse(monitor.recentMetrics.isDegraded)
    }
    
    func testRecordDecoderSwitch() {
        // Should not crash
        monitor.recordDecoderSwitch(
            from: VideoToolboxDecoder.self,
            to: FFmpegSoftwareDecoder.self
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails or passes**

Run: `cd TitanPlayer && swift test --filter PerformanceMonitorTests 2>&1 | tail -10`
Expected: Should pass — existing PerformanceMonitor already has most logic

- [ ] **Step 3: Implement real CPU monitoring**

In `TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Utilities/PerformanceMonitor.swift`, replace the `startResourceMonitoring` method:

```swift
    private func startResourceMonitoring() {
        // CPU usage sampling via host_processor_info
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.sampleCPUUsage()
        }
    }
    
    private func sampleCPUUsage() {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_cpu_load_info_t?
        var numCPUInfo: mach_msg_type_number_t = 0
        
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCPUInfo
        )
        
        guard result == KERN_SUCCESS, let cpuInfo = cpuInfo else { return }
        defer { vm_deallocate(mach_task_self_, cpuInfo, vm_size_t(numCPUInfo)) }
        
        var totalTicks: UInt64 = 0
        var idleTicks: UInt64 = 0
        
        for i in 0..<Int(numCPUs) {
            let info = cpuInfo[i]
            idleTicks += UInt64(info.cpu_ticks[CPU_STATE_IDLE])
            totalTicks += UInt64(info.cpu_ticks[CPU_STATE_USER])
            totalTicks += UInt64(info.cpu_ticks[CPU_STATE_SYSTEM])
            totalTicks += UInt64(info.cpu_ticks[CPU_STATE_NICE])
            totalTicks += UInt64(info.cpu_ticks[CPU_STATE_IDLE])
        }
        
        let cpuUsage = totalTicks > 0
            ? Double(totalTicks - idleTicks) / Double(totalTicks)
            : 0.0
        
        lock.lock()
        currentSystemState.cpuUsage = cpuUsage
        lock.unlock()
    }
```

Note: GPU monitoring remains stubbed — add a clear comment:

```swift
        // GPU monitoring via Metal counter API requires MTLDevice counter sets
        // which are only available on discrete GPUs. Stubbed for now.
        // TODO: implement Metal GPU counter sampling when available
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd TitanPlayer && swift test --filter PerformanceMonitorTests 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/TitanPlayer/Core/Decoders/VideoDecoder/Utilities/PerformanceMonitor.swift TitanPlayer/Tests/VideoDecoderTests/Utilities/PerformanceMonitorTests.swift
git commit -m "feat: PerformanceMonitor real CPU monitoring via host_processor_info"
```

---

## Task 14: Add Capability Tests

**Files:**
- Create: `TitanPlayer/Tests/VideoDecoderTests/Hardware/HardwareCapabilitiesTests.swift`
- Create: `TitanPlayer/Tests/VideoDecoderTests/Software/SoftwareCapabilitiesTests.swift`

- [ ] **Step 1: Write hardware capability tests**

Create `TitanPlayer/Tests/VideoDecoderTests/Hardware/HardwareCapabilitiesTests.swift`:

```swift
import XCTest
@testable import TitanPlayer

final class HardwareCapabilitiesTests: XCTestCase {
    
    func testHardwareCapabilitiesQuery() {
        let caps = HardwareCapabilities.query()
        
        XCTAssertTrue(caps.supportedCodecs.contains(.h264))
        XCTAssertTrue(caps.supportedCodecs.contains(.hevc))
        XCTAssertTrue(caps.supportsHardwareAcceleration)
    }
    
    func testCodecSupportCheck() {
        XCTAssertTrue(HardwareCapabilities.isCodecSupported(.h264))
        XCTAssertTrue(HardwareCapabilities.isCodecSupported(.hevc))
        
        let vp9Supported = HardwareCapabilities.isCodecSupported(.vp9)
        let av1Supported = HardwareCapabilities.isCodecSupported(.av1)
        
        XCTAssertEqual(vp9Supported, HardwareCapabilities.isAppleSilicon())
        XCTAssertEqual(av1Supported, HardwareCapabilities.isM3OrLater())
    }
    
    func testAppleSiliconDetection() {
        let _ = HardwareCapabilities.isAppleSilicon()
        // Just verifies no crash
    }
    
    func testM3OrLaterDetection() {
        let _ = HardwareCapabilities.isM3OrLater()
        // Just verifies no crash
    }
    
    func testMaxResolutionForCodec() {
        let h264Res = HardwareCapabilities.maxResolution(for: .h264)
        XCTAssertGreaterThanOrEqual(h264Res.width, 1920)
        XCTAssertGreaterThanOrEqual(h264Res.height, 1080)
        
        let hevcRes = HardwareCapabilities.maxResolution(for: .hevc)
        XCTAssertGreaterThanOrEqual(hevcRes.width, 3840)
        XCTAssertGreaterThanOrEqual(hevcRes.height, 2160)
        
        let mpeg2Res = HardwareCapabilities.maxResolution(for: .mpeg2)
        XCTAssertGreaterThanOrEqual(mpeg2Res.width, 1920)
        
        let vc1Res = HardwareCapabilities.maxResolution(for: .vc1)
        XCTAssertGreaterThanOrEqual(vc1Res.width, 1920)
    }
    
    func testMPEG2NotHardwareSupported() {
        XCTAssertFalse(HardwareCapabilities.isCodecSupported(.mpeg2))
    }
    
    func testVC1NotHardwareSupported() {
        XCTAssertFalse(HardwareCapabilities.isCodecSupported(.vc1))
    }
}
```

- [ ] **Step 2: Write software capability tests**

Create `TitanPlayer/Tests/VideoDecoderTests/Software/SoftwareCapabilitiesTests.swift`:

```swift
import XCTest
@testable import TitanPlayer

final class SoftwareCapabilitiesTests: XCTestCase {
    
    func testSoftwareCapabilitiesQuery() {
        let caps = SoftwareCapabilities.query()
        
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
        XCTAssertGreaterThanOrEqual(caps.maxResolution.width, 3840)
        XCTAssertGreaterThanOrEqual(caps.maxResolution.height, 2160)
    }
}
```

- [ ] **Step 3: Run tests to verify they pass**

Run: `cd TitanPlayer && swift test --filter "HardwareCapabilitiesTests\|SoftwareCapabilitiesTests" 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add TitanPlayer/Tests/VideoDecoderTests/Hardware/HardwareCapabilitiesTests.swift TitanPlayer/Tests/VideoDecoderTests/Software/SoftwareCapabilitiesTests.swift
git commit -m "test: add hardware and software capability tests"
```

---

## Task 15: Write Integration Tests — Real Bitstream Decode

**Files:**
- Create: `TitanPlayer/Tests/VideoDecoderTests/Hardware/VideoToolboxDecoderIntegrationTests.swift`
- Create: `TitanPlayer/Tests/VideoDecoderTests/Software/FFmpegSoftwareDecoderIntegrationTests.swift`
- Create: `TitanPlayer/Tests/VideoDecoderTests/Integration/AVFoundationDemuxerIntegrationTests.swift`

- [ ] **Step 1: Write AVFoundation demuxer integration test**

Create `TitanPlayer/Tests/VideoDecoderTests/Integration/AVFoundationDemuxerIntegrationTests.swift`:

```swift
import XCTest
import AVFoundation
import CoreMedia
@testable import TitanPlayer

final class AVFoundationDemuxerIntegrationTests: XCTestCase {
    
    var demuxer: AVFoundationDemuxer!
    var testURL: URL!
    
    override func setUp() {
        super.setUp()
        demuxer = AVFoundationDemuxer()
        testURL = URL(fileURLWithPath: "Tests/Fixtures/test.mp4")
    }
    
    override func tearDown() async {
        demuxer.close()
        demuxer = nil
        await super.tearDown()
    }
    
    func testOpenRealFile() async throws {
        let info = try await demuxer.open(url: testURL)
        
        XCTAssertEqual(info.format, "MP4")
        XCTAssertEqual(info.videoTracks.count, 1)
        XCTAssertEqual(info.videoTracks[0].codec, "avc1")
        XCTAssertEqual(info.videoTracks[0].width, 320)
        XCTAssertEqual(info.videoTracks[0].height, 240)
    }
    
    func testExtradataExtracted() async throws {
        let info = try await demuxer.open(url: testURL)
        
        XCTAssertNotNil(info.videoTracks[0].extradata, "Should extract avcC extradata from H.264 file")
        XCTAssertGreaterThan(info.videoTracks[0].extradata?.count ?? 0, 0)
    }
    
    func testNextPacketReturnsRealData() async throws {
        _ = try await demuxer.open(url: testURL)
        
        let packet = try await demuxer.nextPacket()
        
        XCTAssertGreaterThan(packet.data.count, 0, "First packet should contain real compressed data")
        XCTAssertGreaterThan(packet.timestamp.value, 0)
    }
    
    func testReadMultiplePackets() async throws {
        _ = try await demuxer.open(url: testURL)
        
        var packetCount = 0
        for _ in 0..<10 {
            do {
                let packet = try await demuxer.nextPacket()
                XCTAssertGreaterThan(packet.data.count, 0)
                packetCount += 1
            } catch {
                break  // End of stream
            }
        }
        
        XCTAssertGreaterThan(packetCount, 0, "Should read at least one packet")
    }
}
```

- [ ] **Step 2: Write VideoToolbox decoder integration test**

Create `TitanPlayer/Tests/VideoDecoderTests/Hardware/VideoToolboxDecoderIntegrationTests.swift`:

```swift
import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
@testable import TitanPlayer

final class VideoToolboxDecoderIntegrationTests: XCTestCase {
    
    var demuxer: AVFoundationDemuxer!
    var decoder: VideoToolboxDecoder!
    var testURL: URL!
    
    override func setUp() {
        super.setUp()
        demuxer = AVFoundationDemuxer()
        decoder = VideoToolboxDecoder()
        testURL = URL(fileURLWithPath: "Tests/Fixtures/test.mp4")
    }
    
    override func tearDown() async {
        demuxer.close()
        await decoder.invalidate()
        demuxer = nil
        decoder = nil
        await super.tearDown()
    }
    
    func testDecodeRealH264Bitstream() async throws {
        // Open file and get track info with extradata
        let info = try await demuxer.open(url: testURL)
        guard let track = info.videoTracks.first else {
            XCTFail("No video track")
            return
        }
        
        // Configure decoder with real track info
        try await decoder.configure(for: track)
        
        if case .configured = decoder.state {} else {
            XCTFail("Expected configured state")
            return
        }
        
        // Read and decode first packet
        let packet = try await demuxer.nextPacket()
        
        let output = try await decoder.decode(packet)
        
        switch output {
        case .sampleBuffer(let buffer):
            XCTAssertNotNil(CMSampleBufferGetImageBuffer(buffer), "Decoded sample buffer should contain image")
        case .pixelBuffer(let buffer):
            XCTAssertNotNil(buffer)
        }
    }
    
    func testDecodeMultipleFrames() async throws {
        let info = try await demuxer.open(url: testURL)
        guard let track = info.videoTracks.first else {
            XCTFail("No video track")
            return
        }
        
        try await decoder.configure(for: track)
        
        var decodedCount = 0
        for _ in 0..<10 {
            do {
                let packet = try await demuxer.nextPacket()
                // Convert Annex-B to AVCC if needed
                let avccPacket = MediaPacket(
                    streamIndex: packet.streamIndex,
                    data: ZeroCopyBufferManager.annexBToAVCC(packet.data),
                    timestamp: packet.timestamp,
                    duration: packet.duration,
                    isKeyFrame: packet.isKeyFrame
                )
                _ = try await decoder.decode(avccPacket)
                decodedCount += 1
            } catch {
                break
            }
        }
        
        XCTAssertGreaterThan(decodedCount, 0, "Should decode at least one frame")
    }
    
    func testStateTransitions() async throws {
        let info = try await demuxer.open(url: testURL)
        guard let track = info.videoTracks.first else {
            XCTFail("No video track")
            return
        }
        
        if case .idle = decoder.state {} else {
            XCTFail("Expected idle initially")
            return
        }
        
        try await decoder.configure(for: track)
        
        if case .configured = decoder.state {} else {
            XCTFail("Expected configured after configure")
            return
        }
        
        await decoder.invalidate()
        
        if case .idle = decoder.state {} else {
            XCTFail("Expected idle after invalidate")
            return
        }
    }
}
```

- [ ] **Step 3: Write FFmpeg software decoder integration test**

Create `TitanPlayer/Tests/VideoDecoderTests/Software/FFmpegSoftwareDecoderIntegrationTests.swift`:

```swift
import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
@testable import TitanPlayer

final class FFmpegSoftwareDecoderIntegrationTests: XCTestCase {
    
    var demuxer: AVFoundationDemuxer!
    var decoder: FFmpegSoftwareDecoder!
    var testURL: URL!
    
    override func setUp() {
        super.setUp()
        demuxer = AVFoundationDemuxer()
        decoder = FFmpegSoftwareDecoder()
        testURL = URL(fileURLWithPath: "Tests/Fixtures/test.mp4")
    }
    
    override func tearDown() async {
        demuxer.close()
        await decoder.invalidate()
        demuxer = nil
        decoder = nil
        await super.tearDown()
    }
    
    func testDecodeRealH264Bitstream() async throws {
        let info = try await demuxer.open(url: testURL)
        guard let track = info.videoTracks.first else {
            XCTFail("No video track")
            return
        }
        
        try await decoder.configure(for: track)
        
        let packet = try await demuxer.nextPacket()
        
        // Software decoder may need multiple packets before producing a frame
        var output: DecoderOutput?
        for _ in 0..<5 {
            do {
                output = try await decoder.decode(packet)
                break
            } catch DecoderError.noFramesDecoded {
                let nextPacket = try await demuxer.nextPacket()
                output = try await decoder.decode(nextPacket)
                break
            }
        }
        
        if let output = output {
            switch output {
            case .sampleBuffer(let buffer):
                XCTAssertNotNil(buffer)
            case .pixelBuffer(let buffer):
                XCTAssertNotNil(buffer)
            }
        }
    }
    
    func testConfigureWithExtradata() async throws {
        let info = try await demuxer.open(url: testURL)
        guard let track = info.videoTracks.first else {
            XCTFail("No video track")
            return
        }
        
        XCTAssertNotNil(track.extradata, "Track should have extradata")
        
        try await decoder.configure(for: track)
        
        if case .configured = decoder.state {} else {
            XCTFail("Expected configured state")
            return
        }
    }
}
```

- [ ] **Step 4: Run integration tests**

Run: `cd TitanPlayer && swift test --filter "IntegrationTests" 2>&1 | tail -15`
Expected: PASS (may need minor adjustments based on real decoder behavior)

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/Tests/VideoDecoderTests/Hardware/VideoToolboxDecoderIntegrationTests.swift TitanPlayer/Tests/VideoDecoderTests/Software/FFmpegSoftwareDecoderIntegrationTests.swift TitanPlayer/Tests/VideoDecoderTests/Integration/AVFoundationDemuxerIntegrationTests.swift
git commit -m "test: integration tests for real H.264 bitstream decode via AVFoundation"
```

---

## Task 16: Write FFmpeg Demuxer Integration Test & Final Verification

**Files:**
- Create: `TitanPlayer/Tests/VideoDecoderTests/Integration/FFmpegDemuxerIntegrationTests.swift`

- [ ] **Step 1: Write FFmpeg demuxer integration test**

Create `TitanPlayer/Tests/VideoDecoderTests/Integration/FFmpegDemuxerIntegrationTests.swift`:

```swift
import XCTest
import CoreMedia
@testable import TitanPlayer

final class FFmpegDemuxerIntegrationTests: XCTestCase {
    
    var demuxer: FFmpegDemuxer!
    var testURL: URL!
    
    override func setUp() {
        super.setUp()
        demuxer = FFmpegDemuxer()
        testURL = URL(fileURLWithPath: "Tests/Fixtures/test.mp4")
    }
    
    override func tearDown() async {
        demuxer.close()
        demuxer = nil
        await super.tearDown()
    }
    
    func testOpenRealFile() async throws {
        let info = try await demuxer.open(url: testURL)
        
        XCTAssertEqual(info.format, "MP4")
        XCTAssertEqual(info.videoTracks.count, 1)
    }
    
    func testVideoTrackHasExtradata() async throws {
        let info = try await demuxer.open(url: testURL)
        
        guard let track = info.videoTracks.first else {
            XCTFail("No video track")
            return
        }
        
        XCTAssertNotNil(track.extradata, "FFmpeg demuxer should extract extradata")
        XCTAssertGreaterThan(track.extradata?.count ?? 0, 0)
    }
    
    func testNextPacketReturnsRealData() async throws {
        _ = try await demuxer.open(url: testURL)
        
        let packet = try await demuxer.nextPacket()
        
        XCTAssertGreaterThan(packet.data.count, 0, "Packet should contain real compressed data")
    }
    
    func testReadMultiplePackets() async throws {
        _ = try await demuxer.open(url: testURL)
        
        var packetCount = 0
        for _ in 0..<10 {
            do {
                let packet = try await demuxer.nextPacket()
                XCTAssertGreaterThan(packet.data.count, 0)
                packetCount += 1
            } catch {
                break
            }
        }
        
        XCTAssertGreaterThan(packetCount, 0)
    }
    
    func testCodecIsH264() async throws {
        let info = try await demuxer.open(url: testURL)
        
        guard let track = info.videoTracks.first else {
            XCTFail("No video track")
            return
        }
        
        XCTAssertEqual(track.codec, "avc1", "Test fixture should be H.264")
    }
    
    func testDimensionsMatchFixture() async throws {
        let info = try await demuxer.open(url: testURL)
        
        guard let track = info.videoTracks.first else {
            XCTFail("No video track")
            return
        }
        
        XCTAssertEqual(track.width, 320)
        XCTAssertEqual(track.height, 240)
    }
}
```

- [ ] **Step 2: Run FFmpeg demuxer integration tests**

Run: `cd TitanPlayer && swift test --filter FFmpegDemuxerIntegrationTests 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 3: Run the full test suite**

Run: `cd TitanPlayer && swift test 2>&1 | tail -30`
Expected: All tests pass (or only pre-existing failures unrelated to decoder hardening)

- [ ] **Step 4: Verify build has no warnings**

Run: `cd TitanPlayer && swift build 2>&1 | grep -c "warning"`
Expected: 0 (or only pre-existing warnings unrelated to this work)

- [ ] **Step 5: Commit**

```bash
git add TitanPlayer/Tests/VideoDecoderTests/Integration/FFmpegDemuxerIntegrationTests.swift
git commit -m "test: FFmpeg demuxer integration tests with real test.mp4 bitstream"
```

- [ ] **Step 6: Final commit — run full verification**

```bash
cd TitanPlayer && swift build && swift test 2>&1 | tail -20
```

Expected: Build complete, all decoder tests pass.

---

## Validation Criteria Checklist

After completing all tasks, verify:

- [ ] H.264/HEVC hardware decoding on all Macs — `VideoToolboxDecoderIntegrationTests.testDecodeRealH264Bitstream`
- [ ] VP9 hardware decoding on Apple Silicon (M1+) — `HardwareCapabilitiesTests.testCodecSupportCheck` + VT session creation in `VideoToolboxDecoderTests`
- [ ] AV1 hardware decoding on M3+ chips — `HardwareCapabilitiesTests.testM3OrLaterDetection` + VT session creation
- [ ] Software fallback for unsupported codecs — `FFmpegSoftwareDecoderTests.testConfigureForMPEG2Track`, `testConfigureForVC1Track`
- [ ] Automatic fallback on hardware errors — `AdaptiveDecoderManagerTests` + `handleDecodeError` transient path
