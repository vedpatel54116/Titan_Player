import XCTest
import CoreMedia
@testable import TitanPlayer

final class MediaTypesTests: XCTestCase {
    func test_mediaInfoHoldsTracksAndDuration() {
        let duration = CMTime(value: 60, timescale: 1)
        let video = VideoTrackInfo(
            codec: "avc1",
            width: 1920,
            height: 1080,
            frameRate: 30,
            isHDR: false,
            extradata: nil
        )
        let audio = AudioTrackInfo(
            codec: "aac",
            sampleRate: 48_000,
            channels: 2,
            language: "en"
        )
        let subtitle = SubtitleTrackInfo(
            codec: "mov_text",
            language: "en",
            isSDH: false,
            isForced: false
        )
        let info = MediaInfo(
            duration: duration,
            videoTracks: [video],
            audioTracks: [audio],
            subtitleTracks: [subtitle],
            format: "mp4"
        )
        XCTAssertEqual(info.videoTracks.count, 1)
        XCTAssertEqual(info.audioTracks.first?.channels, 2)
        XCTAssertEqual(info.subtitleTracks.first?.language, "en")
        XCTAssertEqual(info.format, "mp4")
    }

    func test_videoTrackInfoCarriesHDRAndExtradata() {
        let data = Data([0x01, 0x02, 0x03])
        let track = VideoTrackInfo(
            codec: "hvc1",
            width: 3840,
            height: 2160,
            frameRate: 60,
            isHDR: true,
            extradata: data
        )
        XCTAssertTrue(track.isHDR)
        XCTAssertEqual(track.extradata, data)
        XCTAssertEqual(track.frameRate, 60.0, accuracy: 0.001)
    }

    func test_subtitleTrackCarriesOptionalForced() {
        let forced = SubtitleTrackInfo(codec: "webvtt", language: "fr", isSDH: false, isForced: true)
        XCTAssertTrue(forced.isForced)
        let sdh = SubtitleTrackInfo(codec: "webvtt", language: "en", isSDH: true, isForced: false)
        XCTAssertTrue(sdh.isSDH)
    }
}
