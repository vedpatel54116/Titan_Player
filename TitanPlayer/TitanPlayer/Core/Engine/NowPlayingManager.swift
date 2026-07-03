import Foundation
import MediaPlayer
import Combine

@MainActor
final class NowPlayingManager: ObservableObject {
    private let engine: PlaybackEngine
    private let commandCenter = MPRemoteCommandCenter.shared()
    private let infoCenter = MPNowPlayingInfoCenter.default()
    private var cancellables = Set<AnyCancellable>()
    
    @Published var isEnabled = true
    
    init(engine: PlaybackEngine) {
        self.engine = engine
        setupRemoteCommands()
        subscribeToEngineUpdates()
    }
    
    private func setupRemoteCommands() {
        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.engine.play()
            }
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.engine.pause()
            }
            return .success
        }
        
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                if self?.engine.state == .playing {
                    self?.engine.pause()
                } else {
                    self?.engine.play()
                }
            }
            return .success
        }
        
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                await self?.engine.seek(to: event.positionTime)
            }
            return .success
        }
        
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true
    }
    
    private func subscribeToEngineUpdates() {
        engine.$currentTime
            .combineLatest(engine.$duration, engine.$state)
            .sink { [weak self] time, duration, state in
                self?.updateNowPlaying(currentTime: time, duration: duration, state: state)
            }
            .store(in: &cancellables)
    }
    
    private func updateNowPlaying(currentTime: TimeInterval, duration: TimeInterval, state: PlaybackState) {
        var info: [String: Any] = [:]
        
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = state == .playing ? 1.0 : 0.0
        
        
        infoCenter.nowPlayingInfo = info
    }
}
