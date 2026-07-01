import XCTest
import AppKit
@testable import TitanPlayer

@MainActor
final class TouchBarControllerTests: XCTestCase {
    private func makeController() -> (TouchBarController, PlaybackSession) {
        let session = PlaybackSession(
            videoRenderer: MockFrameRenderer(),
            audioRenderer: MockAudioRenderer()
        )
        let ctrl = TouchBarController(session: session)
        return (ctrl, session)
    }

    func testTogglePlayPauseFlipsReadyToPlaying() {
        let (ctrl, session) = makeController()
        session.playState = .ready
        ctrl.togglePlayPause()
        XCTAssertEqual(session.playState, .playing)
    }

    func testTogglePlayPauseFlipsPlayingToPaused() {
        let (ctrl, session) = makeController()
        session.playState = .playing
        ctrl.togglePlayPause()
        XCTAssertEqual(session.playState, .paused)
    }

    func testSkipBackwardDecrementsCurrentTime() async {
        let (ctrl, session) = makeController()
        session.currentTime = 30
        await ctrl.skipBackward()
        XCTAssertEqual(session.currentTime, 20, accuracy: 0.001)
    }

    func testSkipForwardIncrementsCurrentTime() async {
        let (ctrl, session) = makeController()
        session.currentTime = 30
        await ctrl.skipForward()
        XCTAssertEqual(session.currentTime, 40, accuracy: 0.001)
    }

    func testVolumeChangedUpdatesSessionVolume() {
        let (ctrl, session) = makeController()
        session.volume = 0.5
        let slider = NSSlider(value: 0.8, minValue: 0, maxValue: 1,
                               target: nil, action: nil)
        ctrl.volumeChanged(slider)
        XCTAssertEqual(session.volume, 0.8, accuracy: 0.001)
    }

    func testVolumeChangedClampsBelowZero() {
        let (ctrl, session) = makeController()
        session.volume = 0.5
        let slider = NSSlider(value: -0.5, minValue: -1, maxValue: 1,
                               target: nil, action: nil)
        ctrl.volumeChanged(slider)
        XCTAssertEqual(session.volume, 0.0, accuracy: 0.001)
    }

    func testSessionWeakRefReleased() {
        let ctrl: TouchBarController
        do {
            let session = PlaybackSession(
                videoRenderer: MockFrameRenderer(),
                audioRenderer: MockAudioRenderer())
            ctrl = TouchBarController(session: session)
        }
        XCTAssertNil(ctrl.session)
    }

    func testOpenMiniPlayerClosureSwitches() {
        let (ctrl, _) = makeController()
        var calls = 0
        ctrl.openMini = { calls += 1 }
        ctrl.openMiniPlayer()
        XCTAssertEqual(calls, 1)
    }

    func testOpenLibraryActionClosureSwitches() {
        let (ctrl, _) = makeController()
        var calls = 0
        ctrl.newLibraryWindow = { calls += 1 }
        ctrl.openLibraryAction()
        XCTAssertEqual(calls, 1)
    }
}
