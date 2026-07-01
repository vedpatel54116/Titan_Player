import Foundation
import AppKit

struct DispatcherSideEffects {
    var toggleFullscreen: () -> Void = {}
    var toggleMiniPlayer: () -> Void = {}
    var newLibraryWindow: () -> Void = {}
    var openFile: () -> Void = {}
}

@MainActor
final class PlayerActionDispatcher {
    let session: PlaybackSession
    private let sideEffects: DispatcherSideEffects

    init(session: PlaybackSession,
         sideEffects: DispatcherSideEffects = DispatcherSideEffects()) {
        self.session = session
        self.sideEffects = sideEffects
    }

    func dispatch(_ action: PlayerAction) {
        switch action {
        case .togglePlayPause:
            session.togglePlayPause()
        case .seekForward10:
            Task { await session.seekForward() }
        case .seekBackward10:
            Task { await session.seekBackward() }
        case .seekForward60:
            Task { await session.seekForward(seconds: 60) }
        case .seekBackward60:
            Task { await session.seekBackward(seconds: 60) }
        case .stepFrameForward:
            Task { await session.stepFrameForward() }
        case .stepFrameBackward:
            Task { await session.stepFrameBackward() }
        case .toggleMute:
            session.toggleMute()
        case .volumeUp:
            session.setVolume(min(session.volume + 0.1, 1))
        case .volumeDown:
            session.setVolume(max(session.volume - 0.1, 0))
        case .toggleFullscreen:
            sideEffects.toggleFullscreen()
        case .toggleMiniPlayer:
            sideEffects.toggleMiniPlayer()
        case .newLibraryWindow:
            sideEffects.newLibraryWindow()
        case .openFile:
            sideEffects.openFile()
        case .setAspectRatioFit:
            session.fitModeOverride = .fit
        case .setAspectRatioFill:
            session.fitModeOverride = .fill
        case .setAspectRatioStretch:
            session.fitModeOverride = .stretch
        case .setAspectRatioAuto:
            session.fitModeOverride = nil
        case .toggleSubtitles:
            if session.activeSubtitle != nil {
                session.setSubtitleTrack(nil)
            } else if let first = session.subtitles.first {
                session.setSubtitleTrack(first)
            }
        case .toggleHDR:
            session.toneMappingEnabled.toggle()
        case .increasePlaybackRate:
            session.setPlaybackRate(min(session.playbackRate + 0.25, 4))
        case .decreasePlaybackRate:
            session.setPlaybackRate(max(session.playbackRate - 0.25, 0.25))
        case .resetPlaybackRate:
            session.setPlaybackRate(1.0)
        case .toggleWaveform:
            session.analysis.waveformEnabled.toggle()
        case .toggleVectorscope:
            session.analysis.vectorscopeEnabled.toggle()
        case .toggleHistogram:
            session.analysis.histogramEnabled.toggle()
        case .toggleAudioMeters:
            session.analysis.audioMeteringEnabled.toggle()
        }
    }

    func dispatchAsync(_ action: PlayerAction) async {
        dispatch(action)
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}
