import SwiftUI
import Combine

@MainActor
class PlayerViewModel: ObservableObject {
    @Published var playState: PlaybackState = .idle
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Float = 1.0
    @Published var isMuted: Bool = false
    @Published var mediaInfo: MediaInfo?
    @Published var subtitles: [SubtitleTrack] = []
    @Published var activeSubtitle: SubtitleTrack?
    @Published var currentSubtitleEvents: [SubtitleEvent] = []
    @Published var playbackRate: Float = 1.0
    @Published var audioDelay: TimeInterval = 0
    
    private let engine = PlaybackEngine()
    private let subtitleManager = SubtitleManager()
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupBindings()
    }
    
    private func setupBindings() {
        engine.$state
            .receive(on: DispatchQueue.main)
            .assign(to: &$playState)
        
        engine.$currentTime
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentTime)
        
        engine.$duration
            .receive(on: DispatchQueue.main)
            .assign(to: &$duration)
        
        engine.$playbackRate
            .receive(on: DispatchQueue.main)
            .assign(to: &$playbackRate)
        
        engine.$audioDelay
            .receive(on: DispatchQueue.main)
            .assign(to: &$audioDelay)
        
        subtitleManager.$availableTracks
            .receive(on: DispatchQueue.main)
            .assign(to: &$subtitles)
        
        subtitleManager.$activeTrack
            .receive(on: DispatchQueue.main)
            .assign(to: &$activeSubtitle)
        
        subtitleManager.$currentEvents
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentSubtitleEvents)
    }
    
    func openFile(url: URL) async {
        do {
            try await engine.load(url: url)
        } catch {
            // Error handled by engine.lastError
        }
    }
    
    func play() {
        engine.play()
    }
    
    func pause() {
        engine.pause()
    }
    
    func togglePlayPause() {
        if playState == .playing {
            pause()
        } else if playState == .ready || playState == .paused {
            play()
        }
    }
    
    func seek(to time: Double) async {
        await engine.seek(to: time)
        subtitleManager.update(for: time)
    }
    
    func seekForward(seconds: Double = 10) async {
        let newTime = min(currentTime + seconds, duration)
        await seek(to: newTime)
    }
    
    func seekBackward(seconds: Double = 10) async {
        let newTime = max(currentTime - seconds, 0)
        await seek(to: newTime)
    }
    
    func setVolume(_ volume: Float) {
        self.volume = max(0, min(1, volume))
        // TODO: Wire to engine when audio output is ready
    }
    
    func toggleMute() {
        isMuted.toggle()
    }
    
    func setPlaybackRate(_ rate: Float) {
        engine.setPlaybackRate(rate)
    }
    
    func setAudioDelay(_ delay: TimeInterval) {
        engine.setAudioDelay(delay)
    }
    
    func setSubtitleTrack(_ track: SubtitleTrack?) {
        subtitleManager.setActiveTrack(track)
    }
    
    func loadExternalSubtitle(url: URL) throws {
        try subtitleManager.loadSubtitle(url: url)
    }
    
    func stop() {
        engine.stop()
        subtitleManager.clear()
    }
}
