import SwiftUI
import Combine

@MainActor
class PlayerViewModel: ObservableObject {
    @Published var playState: PlayState = .idle
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Float = 1.0
    @Published var isMuted: Bool = false
    @Published var mediaInfo: MediaInfo?
    @Published var subtitles: [SubtitleTrack] = []
    @Published var activeSubtitle: SubtitleTrack?
    @Published var currentSubtitleEvents: [SubtitleEvent] = []
    
    private let pipeline = MediaPipeline()
    private let subtitleManager = SubtitleManager()
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        setupBindings()
    }
    
    private func setupBindings() {
        pipeline.$playState
            .receive(on: DispatchQueue.main)
            .assign(to: &$playState)
        
        pipeline.$mediaInfo
            .receive(on: DispatchQueue.main)
            .assign(to: &$mediaInfo)
        
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
        await pipeline.openFile(url: url)
        duration = pipeline.duration
        
        // Load embedded subtitles if available
        try? loadEmbeddedSubtitles(from: url)
    }
    
    func play() {
        pipeline.play()
    }
    
    func pause() {
        pipeline.pause()
    }
    
    func togglePlayPause() {
        if playState == .playing {
            pause()
        } else {
            play()
        }
    }
    
    func seek(to time: Double) async {
        await pipeline.seek(to: time)
        currentTime = time
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
    }
    
    func toggleMute() {
        isMuted.toggle()
    }
    
    func setSubtitleTrack(_ track: SubtitleTrack?) {
        subtitleManager.setActiveTrack(track)
    }
    
    func loadExternalSubtitle(url: URL) throws {
        try subtitleManager.loadSubtitle(url: url)
    }
    
    private func loadEmbeddedSubtitles(from url: URL) throws {
        // Load embedded subtitle tracks
    }
    
    func stop() {
        pipeline.stop()
        subtitleManager.clear()
    }
}
