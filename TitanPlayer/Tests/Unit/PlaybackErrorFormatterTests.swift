import XCTest
@testable import TitanPlayer

final class PlaybackErrorFormatterTests: XCTestCase {
    private let sampleURL = URL(fileURLWithPath: "/path/to/test.mp4")

    private func describe(_ error: Error) -> String {
        PlaybackErrorFormatter.describe(error, for: sampleURL)
    }

    // MARK: - PlaybackError

    func testInvalidURL() {
        let result = describe(PlaybackError.invalidURL)
        XCTAssertEqual(result, "Failed to open \"test.mp4\": The file URL is invalid.")
    }

    func testNoPlayableTracks() {
        let result = describe(PlaybackError.noPlayableTracks)
        XCTAssertEqual(result, "Failed to open \"test.mp4\": The file contains no playable video or audio tracks. The codec may be unsupported.")
    }

    func testDecodingFailed() {
        let underlying = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad frame"])
        let result = describe(PlaybackError.decodingFailed(underlying, retryable: false))
        XCTAssertTrue(result.contains("Decoding failed"))
        XCTAssertTrue(result.contains("bad frame"))
    }

    // MARK: - MediaError

    func testMediaError() {
        let mediaError = MediaError(code: .unsupportedFormat, message: "Container not supported")
        let result = describe(mediaError)
        XCTAssertEqual(result, "Failed to open \"test.mp4\": Container not supported")
    }

    // MARK: - DecoderError

    func testUnsupportedCodec() {
        let result = describe(DecoderError.unsupportedCodec("av1"))
        XCTAssertEqual(result, "Failed to open \"test.mp4\": Unsupported codec \"av1\". No decoder is available for this format.")
    }

    func testHardwareFailure() {
        let result = describe(DecoderError.hardwareFailure)
        XCTAssertEqual(result, "Failed to open \"test.mp4\": Hardware decoder failure. The device may not support this codec.")
    }

    func testNoFramesDecoded() {
        let result = describe(DecoderError.noFramesDecoded)
        XCTAssertEqual(result, "Failed to open \"test.mp4\": The decoder could not decode any frames from this file.")
    }

    // MARK: - NSError domains

    func testOSStatusErrorDomainFormatNotRecognized() {
        let error = NSError(domain: "NSOSStatusErrorDomain", code: -2004)
        let result = describe(error)
        XCTAssertEqual(result, "Failed to open \"test.mp4\": File format not recognized. The container may be corrupted or unsupported.")
    }

    func testAVFoundationErrorDomainCannotOpen() {
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11800)
        let result = describe(error)
        XCTAssertEqual(result, "Failed to open \"test.mp4\": AVFoundation could not open the file. The format may be unsupported or the file may be corrupted.")
    }

    func testAVFoundationErrorDomainCodecUnsupported() {
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11821)
        let result = describe(error)
        XCTAssertEqual(result, "Failed to open \"test.mp4\": Decoding failed. The video codec in this file is not supported.")
    }

    func testUnknownErrorFallback() {
        let error = NSError(domain: "com.example", code: 42, userInfo: [NSLocalizedDescriptionKey: "Something went wrong"])
        let result = describe(error)
        XCTAssertEqual(result, "Failed to open \"test.mp4\": Something went wrong")
    }
}
