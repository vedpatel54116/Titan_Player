import XCTest
import CoreMedia
@testable import TitanPlayer

final class FitModeTests: XCTestCase {
    private func makeInfo(videoWidth: Int, videoHeight: Int) -> MediaInfo {
        MediaInfo(
            duration: CMTime(seconds: 60, preferredTimescale: 600),
            videoTracks: [VideoTrackInfo(
                codec: "h264", width: videoWidth, height: videoHeight,
                frameRate: 24, isHDR: false, extradata: nil)],
            audioTracks: [AudioTrackInfo(
                codec: "aac", sampleRate: 48000, channels: 2, language: "en")],
            subtitleTracks: [],
            format: "mp4")
    }

    func testFourThreeReturnsFit() {
        let info = makeInfo(videoWidth: 1440, videoHeight: 1080)
        XCTAssertEqual(resolveFitMode(for: info), .fit)
    }

    func testSquareReturnsFit() {
        let info = makeInfo(videoWidth: 1080, videoHeight: 1080)
        XCTAssertEqual(resolveFitMode(for: info), .fit)
    }

    func testUltrawideReturnsFit() {
        let info = makeInfo(videoWidth: 3440, videoHeight: 1440)
        XCTAssertEqual(resolveFitMode(for: info), .fit)
    }

    func testSixteenNineReturnsFit() {
        let info = makeInfo(videoWidth: 1920, videoHeight: 1080)
        XCTAssertEqual(resolveFitMode(for: info), .fit)
    }

    func testAudioOnlyReturnsFit() {
        let info = MediaInfo(
            duration: CMTime(seconds: 60, preferredTimescale: 600),
            videoTracks: [],
            audioTracks: [AudioTrackInfo(
                codec: "flac", sampleRate: 48000, channels: 2, language: nil)],
            subtitleTracks: [],
            format: "flac")
        XCTAssertEqual(resolveFitMode(for: info), .fit)
    }
}
