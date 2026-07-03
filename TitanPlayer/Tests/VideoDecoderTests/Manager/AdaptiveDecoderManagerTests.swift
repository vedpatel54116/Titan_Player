import XCTest
@testable import TitanPlayer

final class AdaptiveDecoderManagerTests: XCTestCase {

    // MARK: - Test: VideoDecodingAdapter compiles with correct protocol

    func testVideoDecodingAdapterConformsToMediaDecoding() {
        let decoder = VideoToolboxDecoder()
        let adapter = VideoDecodingAdapter(decoder: decoder)
        // Verify adapter conforms to MediaDecoding
        let _: MediaDecoding = adapter
        XCTAssertNotNil(adapter)
    }

    // MARK: - Test: PlaybackError has decodingFailed case

    func testPlaybackErrorHasDecodingFailedCase() {
        let underlyingError = DecoderError.unsupportedCodec("test")
        let error = PlaybackError.decodingFailed(underlyingError)
        if case .decodingFailed(let wrapped, _) = error {
            XCTAssertTrue(wrapped is DecoderError)
        } else {
            XCTFail("Expected decodingFailed case")
        }
    }

    // MARK: - Test: DecoderError severity classification

    func testDecoderErrorSeverityForHardwareFailure() {
        let error = DecoderError.hardwareFailure
        XCTAssertEqual(error.severity, .transient)
    }

    func testDecoderErrorSeverityForUnsupportedCodec() {
        let error = DecoderError.unsupportedCodec("vp09")
        XCTAssertEqual(error.severity, .persistent)
    }

    func testDecoderErrorSeverityForSoftwareFailure() {
        let error = DecoderError.softwareFailure
        XCTAssertEqual(error.severity, .persistent)
    }

    // MARK: - Test: VideoCodec raw values

    func testVideoCodecRawValues() {
        XCTAssertEqual(VideoCodec.h264.rawValue, "avc1")
        XCTAssertEqual(VideoCodec.hevc.rawValue, "hvc1")
        XCTAssertEqual(VideoCodec.vp9.rawValue, "vp09")
        XCTAssertEqual(VideoCodec.av1.rawValue, "av01")
        XCTAssertEqual(VideoCodec.mpeg2.rawValue, "mp2v")
        XCTAssertEqual(VideoCodec.vc1.rawValue, "vc-1")
    }
}
