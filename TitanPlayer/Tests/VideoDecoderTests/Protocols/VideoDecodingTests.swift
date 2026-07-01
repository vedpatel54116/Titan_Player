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
}
