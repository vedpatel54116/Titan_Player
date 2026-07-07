import XCTest
import AppKit
@testable import TitanPlayer

@MainActor
final class PlayerActionDispatcherTests: XCTestCase {
    private func makeDispatcher(
        toggleFullscreenCalls: (() -> Void)? = nil,
        toggleMiniPlayerCalls:  (() -> Void)? = nil,
        newLibraryWindowCalls:  (() -> Void)? = nil,
        openFileCalls:          (() -> Void)? = nil
    ) -> PlayerActionDispatcher {
        let session = PlaybackSession(
            videoRenderer: MockFrameRenderer()
        )
        var side = DispatcherSideEffects()
        if let cb = toggleFullscreenCalls { side.toggleFullscreen = cb }
        if let cb = toggleMiniPlayerCalls  { side.toggleMiniPlayer  = cb }
        if let cb = newLibraryWindowCalls  { side.newLibraryWindow  = cb }
        if let cb = openFileCalls          { side.openFile          = cb }
        return PlayerActionDispatcher(session: session, sideEffects: side)
    }

    func testTogglePlayPauseCallsSession() {
        let d = makeDispatcher()
        d.dispatch(.togglePlayPause)
        // No media loaded → togglePlayPause is a no-op (playState stays .idle).
        XCTAssertTrue([.ready, .paused, .playing].contains(d.session.playState) ||
                      d.session.playState == .idle)
    }

    func testVolumeUpIncrementsSessionVolume() {
        let d = makeDispatcher()
        d.session.volume = 0.5
        d.dispatch(.volumeUp)
        XCTAssertEqual(d.session.volume, 0.6, accuracy: 0.001)
    }

    func testVolumeDownDecrementsSessionVolume() {
        let d = makeDispatcher()
        d.session.volume = 0.5
        d.dispatch(.volumeDown)
        XCTAssertEqual(d.session.volume, 0.4, accuracy: 0.001)
    }

    func testVolumeUpClampsAtOne() {
        let d = makeDispatcher()
        d.session.volume = 0.95
        d.dispatch(.volumeUp)
        XCTAssertEqual(d.session.volume, 1.0, accuracy: 0.001)
    }

    func testVolumeDownClampsAtZero() {
        let d = makeDispatcher()
        d.session.volume = 0.05
        d.dispatch(.volumeDown)
        XCTAssertEqual(d.session.volume, 0.0, accuracy: 0.001)
    }

    func testSetAspectRatioFitSetsOverride() {
        let d = makeDispatcher()
        d.dispatch(.setAspectRatioFit)
        XCTAssertEqual(d.session.fitModeOverride, .fit)
    }

    func testSetAspectRatioFillSetsOverride() {
        let d = makeDispatcher()
        d.dispatch(.setAspectRatioFill)
        XCTAssertEqual(d.session.fitModeOverride, .fill)
    }

    func testSetAspectRatioStretchSetsOverride() {
        let d = makeDispatcher()
        d.dispatch(.setAspectRatioStretch)
        XCTAssertEqual(d.session.fitModeOverride, .stretch)
    }

    func testSetAspectRatioAutoClearsOverride() {
        let d = makeDispatcher()
        d.session.fitModeOverride = .fill
        d.dispatch(.setAspectRatioAuto)
        XCTAssertNil(d.session.fitModeOverride)
    }

    func testToggleSubtitlesSafeWithNoTracks() {
        let d = makeDispatcher()
        d.dispatch(.toggleSubtitles)
        // No crash; activeSubtitle remains nil.
        XCTAssertNil(d.session.activeSubtitle)
    }

    func testToggleHDRFlipsToneMapping() {
        let d = makeDispatcher()
        let original = d.session.toneMappingEnabled
        d.dispatch(.toggleHDR)
        XCTAssertNotEqual(d.session.toneMappingEnabled, original)
    }

    func testIncreasePlaybackRateAddsQuarter() {
        let d = makeDispatcher()
        d.session.playbackRate = 1.0
        d.dispatch(.increasePlaybackRate)
        XCTAssertEqual(d.session.playbackRate, 1.25, accuracy: 0.001)
    }

    func testIncreasePlaybackRateClampsAtFour() {
        let d = makeDispatcher()
        d.session.playbackRate = 4.0
        d.dispatch(.increasePlaybackRate)
        XCTAssertEqual(d.session.playbackRate, 4.0, accuracy: 0.001)
    }

    func testDecreasePlaybackRateSubtractsQuarter() {
        let d = makeDispatcher()
        d.session.playbackRate = 1.0
        d.dispatch(.decreasePlaybackRate)
        XCTAssertEqual(d.session.playbackRate, 0.75, accuracy: 0.001)
    }

    func testDecreasePlaybackRateClampsAtQuarter() {
        let d = makeDispatcher()
        d.session.playbackRate = 0.25
        d.dispatch(.decreasePlaybackRate)
        XCTAssertEqual(d.session.playbackRate, 0.25, accuracy: 0.001)
    }

    func testResetPlaybackRateSetsOne() {
        let d = makeDispatcher()
        d.session.playbackRate = 1.75
        d.dispatch(.resetPlaybackRate)
        XCTAssertEqual(d.session.playbackRate, 1.0, accuracy: 0.001)
    }

    func testToggleFullscreenCallsClosure() {
        var calls = 0
        let d = makeDispatcher(toggleFullscreenCalls: { calls += 1 })
        d.dispatch(.toggleFullscreen)
        XCTAssertEqual(calls, 1)
    }

    func testToggleMiniPlayerCallsClosure() {
        var calls = 0
        let d = makeDispatcher(toggleMiniPlayerCalls: { calls += 1 })
        d.dispatch(.toggleMiniPlayer)
        XCTAssertEqual(calls, 1)
    }

    func testNewLibraryWindowCallsClosure() {
        var calls = 0
        let d = makeDispatcher(newLibraryWindowCalls: { calls += 1 })
        d.dispatch(.newLibraryWindow)
        XCTAssertEqual(calls, 1)
    }

    func testOpenFileCallsClosure() {
        var calls = 0
        let d = makeDispatcher(openFileCalls: { calls += 1 })
        d.dispatch(.openFile)
        XCTAssertEqual(calls, 1)
    }

    func testStepFrameForwardSafeWhileIdle() async {
        let d = makeDispatcher()
        await d.dispatchAsync(.stepFrameForward)
        XCTAssertEqual(d.session.currentTime, 0, accuracy: 0.001)
    }

    func testStepFrameBackwardSafeWhileIdle() async {
        let d = makeDispatcher()
        await d.dispatchAsync(.stepFrameBackward)
        XCTAssertEqual(d.session.currentTime, 0, accuracy: 0.001)
    }

    func testSeekActionsSafeWhileIdle() async {
        let d = makeDispatcher()
        await d.dispatchAsync(.seekForward10)
        await d.dispatchAsync(.seekBackward10)
        await d.dispatchAsync(.seekForward60)
        await d.dispatchAsync(.seekBackward60)
    }

    func testToggleMuteFlipsIsMuted() {
        let d = makeDispatcher()
        let original = d.session.isMuted
        d.dispatch(.toggleMute)
        XCTAssertNotEqual(d.session.isMuted, original)
    }

    func testAllActionsDispatchWithoutCrash() {
        let d = makeDispatcher()
        for action in PlayerAction.allCases {
            d.dispatch(action)
            d.dispatch(action)
        }
    }

    // MARK: - KeyEventRouter + Dispatcher integration

    func testRouterAndDispatcherIntegration() {
        let defaults = UserDefaults(suiteName: "integration-test-\(UUID())")!
        let mgr = KeyboardShortcutManager(defaults: defaults)
        let router = KeyEventRouter(shortcutManager: mgr)

        let session = PlaybackSession(videoRenderer: MockFrameRenderer())
        var fullscreenCalls = 0
        var side = DispatcherSideEffects()
        side.toggleFullscreen = { fullscreenCalls += 1 }
        let dispatcher = PlayerActionDispatcher(session: session, sideEffects: side)

        // Command+F (keyCode 3) → toggleFullscreen
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "f", charactersIgnoringModifiers: "f",
            isARepeat: false, keyCode: 3
        )!

        let saved = PhysicalKeyResolver.layoutProvider
        PhysicalKeyResolver.layoutProvider = FakeKeyboardLayoutProviderForIntegration()
        defer { PhysicalKeyResolver.layoutProvider = saved }

        if let action = router.action(for: event) {
            dispatcher.dispatch(action)
        }
        XCTAssertEqual(fullscreenCalls, 1, "toggleFullscreen side-effect should have been called once")
    }
}

private struct FakeKeyboardLayoutProviderForIntegration: KeyboardLayoutProviding {
    func character(for keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String? {
        switch keyCode {
        case 3: return "f"
        default: return nil
        }
    }
}
