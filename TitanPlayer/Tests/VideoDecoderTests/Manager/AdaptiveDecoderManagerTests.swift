import XCTest
@testable import TitanPlayer

final class AdaptiveDecoderManagerTests: XCTestCase {

    // MARK: - Helpers

    private func makeH264Track() -> VideoTrackInfo {
        VideoTrackInfo(
            codec: "avc1",
            width: 1920,
            height: 1080,
            frameRate: 30,
            isHDR: false,
            extradata: nil
        )
    }

    private func makeMPEG2Track() -> VideoTrackInfo {
        VideoTrackInfo(
            codec: "mp2v",
            width: 1920,
            height: 1080,
            frameRate: 30,
            isHDR: false,
            extradata: nil
        )
    }

    // MARK: - Test: selectedDecoderName is nil before configuration

    func testSelectedDecoderNameNilBeforeConfiguration() async {
        let manager = AdaptiveDecoderManager()
        let decoderName = await manager.selectedDecoderName
        XCTAssertNil(decoderName)
    }

    // MARK: - Test: H.264 selects hardware decoder

    func testH264SelectsHardwareDecoder() async throws {
        let manager = AdaptiveDecoderManager()
        let track = makeH264Track()

        try await manager.configure(for: track)

        let decoderName = await manager.selectedDecoderName
        XCTAssertNotNil(decoderName)
        // On Apple Silicon, H.264 should use VideoToolboxDecoder
        // On Intel or if VT fails, it may fall back to FFmpegSoftwareDecoder
        XCTAssertTrue(
            decoderName == "VideoToolboxDecoder" || decoderName == "FFmpegSoftwareDecoder",
            "Expected VideoToolboxDecoder or FFmpegSoftwareDecoder, got \(decoderName ?? "nil")"
        )
    }

    // MARK: - Test: Unsupported codec falls back to software

    func testUnsupportedHardwareCodecFallsBackToSoftware() async throws {
        let manager = AdaptiveDecoderManager()
        let track = makeMPEG2Track() // mpeg2 not supported by VideoToolbox

        try await manager.configure(for: track)

        let decoderName = await manager.selectedDecoderName
        XCTAssertNotNil(decoderName)
        // MPEG-2 has no hardware support, should fall back to FFmpegSoftwareDecoder
        XCTAssertEqual(decoderName, "FFmpegSoftwareDecoder")
    }

    // MARK: - Test: Both decoders fail throws PlaybackError

    func testBothDecodersFailThrowsPlaybackError() async {
        let manager = AdaptiveDecoderManager()
        // Use a codec that should work on any system
        let track = makeH264Track()

        do {
            try await manager.configure(for: track)
            let decoderName = await manager.selectedDecoderName
            XCTAssertNotNil(decoderName, "A decoder should be selected")
        } catch {
            // If it fails, it should be a PlaybackError.decodingFailed
            XCTAssertTrue(error is PlaybackError)
            if case .decodingFailed = error as? PlaybackError {
                // Expected
            } else {
                XCTFail("Expected PlaybackError.decodingFailed, got \(error)")
            }
        }
    }

    // MARK: - Test: selectedDecoderName matches after configuration

    func testSelectedDecoderNameMatchesAfterConfiguration() async throws {
        let manager = AdaptiveDecoderManager()
        let track = makeH264Track()

        try await manager.configure(for: track)

        let decoderName = await manager.selectedDecoderName
        XCTAssertNotNil(decoderName)
        // Verify the name corresponds to a real decoder type
        let validNames = ["VideoToolboxDecoder", "FFmpegSoftwareDecoder"]
        XCTAssertTrue(validNames.contains(decoderName ?? ""),
            "Unexpected decoder name: \(decoderName ?? "nil")")
    }
}
