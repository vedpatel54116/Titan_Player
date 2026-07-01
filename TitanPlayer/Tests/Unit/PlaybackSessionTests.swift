import XCTest
import CoreMedia
@testable import TitanPlayer

@MainActor
final class PlaybackSessionTests: XCTestCase {
    private func makeSession() -> PlaybackSession {
        PlaybackSession(videoRenderer: MockFrameRenderer())
    }

    func testInitialState() {
        let s = makeSession()
        XCTAssertEqual(s.playState, .idle)
        XCTAssertEqual(s.currentTime, 0, accuracy: 0.001)
        XCTAssertEqual(s.volume, 1.0, accuracy: 0.001)
        XCTAssertFalse(s.isMediaLoaded)
        XCTAssertFalse(s.isAudioOnly)
        XCTAssertFalse(s.isHDRContent)
        XCTAssertEqual(s.fitMode, .fit)
        XCTAssertNil(s.fitModeOverride)
        XCTAssertEqual(s.effectiveFitMode, .fit)
    }

    func testEffectiveFitModeOverridePrecedesSemantic() {
        let s = makeSession()
        s.fitModeOverride = .fill
        XCTAssertEqual(s.effectiveFitMode, .fill)
        s.fitModeOverride = nil
        XCTAssertEqual(s.effectiveFitMode, .fit)
    }

    func testIsMediaLoadedTrueWhenPlaying() {
        let s = makeSession()
        s.playState = .playing
        XCTAssertTrue(s.isMediaLoaded)
    }

    func testIsMediaLoadedFalseWhenError() {
        let s = makeSession()
        s.playState = .error("boom")
        XCTAssertFalse(s.isMediaLoaded)
    }

    func testIsHDRContentFlipsOnHDRDelegateCallback() {
        let s = makeSession()
        let r = MetalRenderer()
        r.delegate = s
        r.handleHDR(HDRMetadata(type: .hdr10, maxLuminance: 1000, minLuminance: 0))
        XCTAssertTrue(s.isHDRContent)
    }

    func testIsHDRContentStaysFalseForSDR() {
        let s = makeSession()
        XCTAssertFalse(s.isHDRContent)
    }

    func testResolveFitModeSetsFitModeForVideoInfo() {
        let s = makeSession()
        let info = MediaInfo(
            duration: CMTime(seconds: 60, preferredTimescale: 600),
            videoTracks: [VideoTrackInfo(
                codec: "h264", width: 1920, height: 1080,
                frameRate: 24, isHDR: false, extradata: nil)],
            audioTracks: [],
            subtitleTracks: [],
            format: "mp4")
        s.applyMediaInfo(info)
        XCTAssertEqual(s.fitMode, .fit)
        XCTAssertFalse(s.isAudioOnly)
    }

    func testResolveFitModeSetsAudioOnlyWhenNoVideoTracks() {
        let s = makeSession()
        let info = MediaInfo(
            duration: CMTime(seconds: 60, preferredTimescale: 600),
            videoTracks: [],
            audioTracks: [AudioTrackInfo(
                codec: "flac", sampleRate: 48000, channels: 2, language: nil)],
            subtitleTracks: [],
            format: "flac")
        s.applyMediaInfo(info)
        XCTAssertTrue(s.isAudioOnly)
        XCTAssertEqual(s.fitMode, .fit)
    }
}
