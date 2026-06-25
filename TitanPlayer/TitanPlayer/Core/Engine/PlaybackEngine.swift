import Foundation
import AVKit
import Combine

@MainActor
class PlaybackEngine: ObservableObject {
    @Published var state: PlaybackState = .idle
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var playbackRate: Float = 1.0
    @Published var lastError: PlaybackError?
    
    private let player = AVPlayer()
    private var timeObserver: Any?
    private let audioClock = AudioClock()
    private var cancellables = Set<AnyCancellable>()
    
    var onNextTrack: (() async -> URL?)?
    var onPlaybackEnded: (() -> Void)?
    
    init() {
        setupTimeObserver()
        setupAudioClockBinding()
    }
    
    deinit {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
    }
    
    func load(url: URL) async throws {
        state = .loading
        lastError = nil
        
        do {
            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            
            try await asset.loadTracks(withMediaType: .video)
            try await asset.loadTracks(withMediaType: .audio)
            
            let durationValue = try await asset.load(.duration)
            self.duration = CMTimeGetSeconds(durationValue)
            
            self.player.replaceCurrentItem(with: item)
            self.state = .ready
        } catch {
            self.state = .error(error.localizedDescription)
            self.lastError = .assetLoadFailed(error)
            throw error
        }
    }
    
    func play() {
        guard state == .ready || state == .paused else { return }
        player.play()
        player.rate = playbackRate
        audioClock.start()
        state = .playing
    }
    
    func pause() {
        guard state == .playing else { return }
        player.pause()
        audioClock.pause()
        state = .paused
    }
    
    func stop() {
        player.pause()
        player.seek(to: .zero)
        audioClock.stop()
        state = .idle
        currentTime = 0
    }
    
    func seek(to time: TimeInterval) async {
        state = .seeking
        let targetTime = CMTime(seconds: time, preferredTimescale: 600)
        await player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
        audioClock.seek(to: time)
        currentTime = time
        if state == .seeking {
            state = player.timeControlStatus == .playing ? .playing : .paused
        }
    }
    
    func setPlaybackRate(_ rate: Float) {
        let clampedRate = max(0.25, min(4.0, rate))
        playbackRate = clampedRate
        if state == .playing {
            player.rate = clampedRate
        }
    }
    
    func setAudioDelay(_ delay: TimeInterval) {
        audioDelay = max(-0.1, min(0.1, delay))
    }
    
    func advanceToNextTrack() async {
        guard let nextURL = await onNextTrack?() else { return }
        do {
            try await load(url: nextURL)
            play()
        } catch {
            // Handle error
        }
    }
    
    @Published var audioDelay: TimeInterval = 0
    
    private func setupTimeObserver() {
        let interval = CMTime(seconds: 1.0/60.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTime = CMTimeGetSeconds(time)
        }
    }
    
    private func setupAudioClockBinding() {
        audioClock.$currentTime
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentTime)
    }
}
