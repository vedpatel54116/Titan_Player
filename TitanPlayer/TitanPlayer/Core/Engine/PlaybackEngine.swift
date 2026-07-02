import Foundation
import AVKit
import AVFAudio
import Combine
import os

@MainActor
class PlaybackEngine: ObservableObject, SynchronizationProvider {
    @Published var state: PlaybackState = .idle {
        didSet {
            if state == .ended {
                onPlaybackEnded?()
            }
        }
    }
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var playbackRate: Float = 1.0
    @Published var audioDelay: TimeInterval = 0
    var audioCurrentTime: TimeInterval { currentTime }
    @Published var lastError: PlaybackError?
    @Published var spatialAudioEnabled: Bool = true
    @Published var mediaInfo: MediaInfo? = nil
    @Published var compatibilityMode: Bool = false

    private let player = AVPlayer()

    var avPlayer: AVPlayer { player }
    private var timeObserver: Any?
    private var audioEngine = AVAudioEngine()
    private let audioClock = AudioClock()
    private var cancellables = Set<AnyCancellable>()
    private var notificationObservers: [Any] = []
    private var spatialAudioEngine: AudioEngine?

    private let videoRenderer: VideoRenderer
    private var mediaPipeline: MediaPipeline?

    var onNextTrack: (() async -> URL?)?
    var onPlaybackEnded: (() -> Void)?

    private let performanceMonitor: PerformanceMonitor
    private let performanceProbe: EnginePerformanceProbe
    private let adaptiveDecoderManager = AdaptiveDecoderManager()
    private let decoderLogger = Logger(subsystem: "com.titanplayer", category: "PlaybackEngine")

    var cpuUsage: Double { performanceProbe.cpuUsage }
    var memoryUsage: Int64 { performanceProbe.memoryUsage }

    init(videoRenderer: VideoRenderer,
         performanceMonitor: PerformanceMonitor = PerformanceMonitor()) {
        self.videoRenderer = videoRenderer
        self.performanceMonitor = performanceMonitor
        self.performanceProbe = EnginePerformanceProbe(monitor: performanceMonitor)
        setupRenderers(videoRenderer)
        setupNotifications()
        setupTimeObserver()
    }

    func _testInjectPerformance(cpu: Double? = nil, memoryBytes: Int64? = nil) {
        performanceProbe._testInject(cpu: cpu, bytes: memoryBytes)
    }

    deinit {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
        }
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func load(url: URL) async throws {
        state = .loading
        lastError = nil
        self.compatibilityMode = false
        decoderLogger.info("load(url:) called for: \(url.path, privacy: .public)")

        do {
            if url.pathExtension.lowercased() == "mpd" {
                decoderLogger.info("DASH stream detected, creating DASHPlayer for: \(url.path, privacy: .public)")
                let dashPlayer = DASHPlayerFactory.player(for: url)
                let session = try await dashPlayer.streamSession(for: url)
                decoderLogger.info("DASH stream session opened, opening stream in MediaPipeline")
                await mediaPipeline?.openStream(session: session)
                self.mediaInfo = mediaPipeline?.mediaInfo
                decoderLogger.info("DASH stream loaded, state set to ready")
                self.state = .ready
            } else {
                decoderLogger.info("Creating AVURLAsset for: \(url.path, privacy: .public)")
                let asset = AVURLAsset(url: url)
                decoderLogger.info("AVURLAsset created, creating AVPlayerItem")
                let item = AVPlayerItem(asset: asset)

                decoderLogger.info("Loading video tracks...")
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                decoderLogger.info("Loaded \(videoTracks.count, privacy: .public) video track(s)")

                decoderLogger.info("Loading audio tracks...")
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                decoderLogger.info("Loaded \(audioTracks.count, privacy: .public) audio track(s)")

                guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
                    decoderLogger.error("No playable tracks found in: \(url.path, privacy: .public)")
                    throw PlaybackError.noPlayableTracks
                }

                decoderLogger.info("Loading asset duration...")
                let durationValue = try await asset.load(.duration)
                self.duration = CMTimeGetSeconds(durationValue)
                decoderLogger.info("Duration loaded: \(self.duration, privacy: .public) seconds")

                decoderLogger.info("Setting AVPlayerItem on AVPlayer...")
                self.player.replaceCurrentItem(with: item)
                decoderLogger.info("AVPlayerItem set successfully")

                decoderLogger.info("Opening file in MediaPipeline...")
                do {
                    try await mediaPipeline?.openFile(url: url, adaptiveManager: adaptiveDecoderManager)
                    self.mediaInfo = mediaPipeline?.mediaInfo
                    decoderLogger.info("MediaPipeline file opened successfully")
                } catch {
                    decoderLogger.warning("MediaPipeline failed (\(error.localizedDescription, privacy: .public)), falling back to AVPlayer compatibility mode")
                    self.mediaInfo = nil
                    self.compatibilityMode = true
                    TelemetryManager.shared.record(.compatibilityModeActivated(
                        reason: error.localizedDescription,
                        source: url.pathExtension.lowercased() == "mpd" ? .dash : .local
                    ))
                }

                if let decoderName = await adaptiveDecoderManager.selectedDecoderName {
                    decoderLogger.info("Selected decoder: \(decoderName) for \(url.lastPathComponent, privacy: .public)")
                }

                decoderLogger.info("Setting state to ready")
                self.state = .ready
            }
        } catch {
            decoderLogger.error("Failed to load file: \(error.localizedDescription, privacy: .public)")
            self.state = .error(error.localizedDescription)
            self.lastError = (error as? PlaybackError) ?? .assetLoadFailed(error)
            TelemetryManager.shared.record(.playbackFailed(
                codec: "unknown",
                resolution: "unknown",
                errorCode: (error as? PlaybackError)?.errorDescription ?? error.localizedDescription,
                source: url.pathExtension.lowercased() == "mpd" ? .dash : .local
            ))
            throw error
        }
    }

    func play() {
        guard state == .ready || state == .paused || state == .ended else { return }
        audioClock.rate = playbackRate
        audioClock.start()
        player.playImmediately(atRate: playbackRate)
        if let spatialAudioEngine = spatialAudioEngine, spatialAudioEnabled {
            try? spatialAudioEngine.startEngine()
        }
        mediaPipeline?.play()
        state = .playing
    }

    func pause() {
        guard state == .playing else { return }
        player.pause()
        audioClock.pause()
        mediaPipeline?.pause()
        state = .paused
    }

    func stop() {
        player.pause()
        player.seek(to: .zero)
        audioClock.stop()
        spatialAudioEngine?.stop()
        mediaPipeline?.stop()
        mediaInfo = nil
        state = .idle
        currentTime = 0
        duration = 0
    }

    func seek(to time: TimeInterval) async {
        guard state == .ready || state == .playing || state == .paused || state == .ended else { return }
        let previousState = state
        state = .seeking
        let targetTime = CMTime(seconds: time, preferredTimescale: 600)
        await player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
        audioClock.seek(to: time)
        currentTime = time
        await mediaPipeline?.seek(to: time)
        if state == .seeking {
            state = previousState == .playing ? .playing : .ready
        }
    }

    func setPlaybackRate(_ rate: Float) {
        let clampedRate = max(0.25, min(4.0, rate))
        playbackRate = clampedRate
        audioClock.rate = clampedRate
        if state == .playing {
            player.rate = clampedRate
        }
        mediaPipeline?.setPlaybackRate(clampedRate)
    }

    func setAudioDelay(_ delay: TimeInterval) {
        audioDelay = max(-0.1, min(0.1, delay))
    }

    /// Read-only access to the spatial audio engine for audio-tap wiring.
    var activeSpatialAudioEngine: AudioEngine? { spatialAudioEngine }

    func setSpatialAudioEngine(_ engine: AudioEngine) {
        spatialAudioEngine = engine
        engine.spatialAudioEnabled = spatialAudioEnabled
    }

    func setSpatialAudioEnabled(_ enabled: Bool) {
        spatialAudioEnabled = enabled
        spatialAudioEngine?.spatialAudioEnabled = enabled
        if enabled {
            spatialAudioEngine?.enableSpatialAudio()
        } else {
            spatialAudioEngine?.disableSpatialAudio()
        }
    }

    func advanceToNextTrack() async {
        guard let nextURL = await onNextTrack?() else { return }
        do {
            try await load(url: nextURL)
            play()
        } catch {
            state = .error(error.localizedDescription)
            lastError = (error as? PlaybackError) ?? .assetLoadFailed(error)
        }
    }

    private func setupRenderers(_ videoRenderer: VideoRenderer) {
        mediaPipeline = MediaPipeline(videoRenderer: videoRenderer)
        mediaPipeline?.synchronizationProvider = self
    }

    private func setupNotifications() {
        let center = NotificationCenter.default

        let endObserver = center.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self = self, self.player.currentItem === notification.object as? AVPlayerItem else { return }
                self.state = .ended
                await self.advanceToNextTrack()
            }
        }
        notificationObservers.append(endObserver)

        let failedObserver = center.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self = self, self.player.currentItem === notification.object as? AVPlayerItem else { return }
                self.state = .error("Playback failed")
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                self.lastError = .decodingFailed(error ?? NSError(domain: "PlaybackEngine", code: -1))
                TelemetryManager.shared.record(.playbackFailed(
                    codec: "unknown",
                    resolution: "unknown",
                    errorCode: error?.localizedDescription ?? "Playback failed",
                    source: .local
                ))
            }
        }
        notificationObservers.append(failedObserver)
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = CMTimeGetSeconds(time)
            }
        }
    }
}

extension PlaybackEngine: AudioTappable, AudioTapProvider {
    var audioTap: AudioTap? {
        get { mediaPipeline?.audioTap }
        set { mediaPipeline?.audioTap = newValue }
    }
}
