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
    @Published var currentTime: TimeInterval = 0 {
        didSet { _audioCurrentTimeBacking = currentTime }
    }
    @Published var duration: TimeInterval = 0
    @Published var playbackRate: Float = 1.0
    @Published var audioDelay: TimeInterval = 0
    nonisolated(unsafe) private var _audioCurrentTimeBacking: TimeInterval = 0
    nonisolated var audioCurrentTime: TimeInterval { _audioCurrentTimeBacking }
    @Published var lastError: PlaybackError?
    @Published var mediaPipelineError: Error?
    @Published var spatialAudioEnabled: Bool = true
    @Published var mediaInfo: MediaInfo? = nil
    @Published var compatibilityMode: Bool = false

    /// Publisher that emits `true` when playback has fallen back to the
    /// AVPlayerLayer (compatibility) path, allowing the UI to switch between
    /// the Metal view and the AVPlayer view.
    var compatibilityModePublisher: AnyPublisher<Bool, Never> {
        $compatibilityMode.eraseToAnyPublisher()
    }

    private let player = AVPlayer()

    var avPlayer: AVPlayer { player }
    private var timeObserver: Any?
    private let audioClock = AudioClock()
    private var cancellables = Set<AnyCancellable>()
    private var itemStatusCancellable: AnyCancellable?
    private var currentLoadURL: URL?
    private var notificationObservers: [Any] = []
    private var spatialAudioEngine: AudioEngine?
    private var isTornDown = false

    private let videoRenderer: VideoRenderer
    private var mediaPipeline: MediaPipeline?

    // Stub for future custom resource loading (e.g., for streaming URLs)
    // This can be replaced with a proper AVAssetResourceLoaderDelegate implementation
    // when needed for custom protocol handling or authentication.
    private var resourceLoaderDelegate: AVAssetResourceLoaderDelegate?

    var onNextTrack: (() async -> URL?)?
    var onPlaybackEnded: (() -> Void)?

    private let performanceMonitor: PerformanceMonitor
    private let performanceProbe: EnginePerformanceProbe
    let adaptiveDecoderManager = AdaptiveDecoderManager()
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

    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true

        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }

        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers = []

        itemStatusCancellable?.cancel()
        itemStatusCancellable = nil

        cancellables.removeAll()

        mediaPipeline?.stop(currentState: state)

        spatialAudioEngine?.stop()
        spatialAudioEngine = nil
    }

    deinit {
        #if DEBUG
        if !isTornDown {
            decoderLogger.warning("PlaybackEngine.deinit called without teardown() — ensure PlaybackSession.stop() or applicationWillTerminate is called")
        }
        #endif
    }

    func load(url: URL) async throws {
        state = .loading
        lastError = nil
        mediaPipelineError = nil
        self.compatibilityMode = false
        self.itemStatusCancellable = nil
        #if DEBUG
        decoderLogger.debug("load(url:) called for: \(url.path, privacy: .public)")
        #endif

        do {
            if url.pathExtension.lowercased() == "mpd" {
                #if DEBUG
                decoderLogger.debug("DASH stream detected, creating DASHPlayer for: \(url.path, privacy: .public)")
                #endif
                do {
                    let dashPlayer = DASHPlayerFactory.player(for: url)
                    let session = try await dashPlayer.streamSession(for: url)
                    #if DEBUG
                    decoderLogger.debug("DASH stream session opened, opening stream in MediaPipeline")
                    #endif
                    await mediaPipeline?.openStream(session: session)
                    self.mediaInfo = mediaPipeline?.mediaInfo
                    #if DEBUG
                    decoderLogger.debug("DASH stream loaded, state set to ready")
                    #endif
                    self.state = .ready
                } catch {
                    decoderLogger.warning("DASH pipeline failed (\(error.localizedDescription, privacy: .public)), falling back to AVPlayer compatibility mode")
                    self.mediaPipelineError = error
                    self.mediaInfo = nil
                    self.compatibilityMode = true
                    TelemetryManager.shared.record(.compatibilityModeActivated(
                        reason: error.localizedDescription,
                        source: .dash
                    ))

                    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                    let item = AVPlayerItem(asset: asset)

                    let videoTracks = try await asset.loadTracks(withMediaType: .video)
                    let audioTracks = try await asset.loadTracks(withMediaType: .audio)

                    guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
                        decoderLogger.error("No playable tracks found in DASH fallback for: \(url.path, privacy: .public)")
                        throw PlaybackError.noPlayableTracks
                    }

                    let durationValue = try await asset.load(.duration)
                    self.duration = CMTimeGetSeconds(durationValue)

                    self.currentLoadURL = url
                    self.itemStatusCancellable = observeItemStatus(item: item, url: url, source: .dash)
                    self.player.replaceCurrentItem(with: item)
                    #if DEBUG
                    decoderLogger.debug("DASH fallback: AVPlayerItem set on AVPlayer")
                    #endif
                }
            } else {
                #if DEBUG
                decoderLogger.debug("Creating AVURLAsset for: \(url.path, privacy: .public)")
                #endif
                let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                #if DEBUG
                decoderLogger.debug("AVURLAsset created, creating AVPlayerItem")
                #endif
                let item = AVPlayerItem(asset: asset)

                #if DEBUG
                decoderLogger.debug("Loading video tracks...")
                #endif
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                #if DEBUG
                decoderLogger.debug("Loaded \(videoTracks.count, privacy: .public) video track(s)")
                #endif

                #if DEBUG
                decoderLogger.debug("Loading audio tracks...")
                #endif
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                #if DEBUG
                decoderLogger.debug("Loaded \(audioTracks.count, privacy: .public) audio track(s)")
                #endif

                guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
                    decoderLogger.error("No playable tracks found in: \(url.path, privacy: .public)")
                    throw PlaybackError.noPlayableTracks
                }

                #if DEBUG
                decoderLogger.debug("Loading asset duration...")
                #endif
                let durationValue = try await asset.load(.duration)
                self.duration = CMTimeGetSeconds(durationValue)
                #if DEBUG
                decoderLogger.debug("Duration loaded: \(self.duration, privacy: .public) seconds")
                #endif

                // Try custom pipeline first — only set AVPlayerItem after we know
                // whether the MediaPipeline succeeded.
                var pipelineSucceeded = false
                #if DEBUG
                decoderLogger.debug("Opening file in MediaPipeline...")
                #endif
                do {
                    try await mediaPipeline?.openFile(url: url, adaptiveManager: adaptiveDecoderManager)
                    self.mediaInfo = mediaPipeline?.mediaInfo
                    pipelineSucceeded = true
                    #if DEBUG
                    decoderLogger.debug("MediaPipeline file opened successfully")
                    #endif
                } catch {
                    decoderLogger.warning("MediaPipeline failed (\(error.localizedDescription, privacy: .public)), falling back to AVPlayer compatibility mode")
                    self.mediaPipelineError = error
                    self.mediaInfo = nil
                    self.compatibilityMode = true
                    TelemetryManager.shared.record(.compatibilityModeActivated(
                        reason: error.localizedDescription,
                        source: .local
                    ))
                }

                // Now set up AVPlayerItem — in compatibility mode it drives
                // playback; in Metal mode it provides duration/track info.
                #if DEBUG
                decoderLogger.debug("Setting AVPlayerItem on AVPlayer...")
                #endif
                self.currentLoadURL = url
                self.itemStatusCancellable = observeItemStatus(item: item, url: url, source: .local)
                self.player.replaceCurrentItem(with: item)
                #if DEBUG
                decoderLogger.debug("AVPlayerItem set successfully (pipelineSucceeded: \(pipelineSucceeded))")
                #endif

                if let decoderName = await adaptiveDecoderManager.selectedDecoderName {
                    #if DEBUG
                    decoderLogger.debug("Selected decoder: \(decoderName) for \(url.lastPathComponent, privacy: .public)")
                    #endif
                }

                #if DEBUG
                decoderLogger.debug("Waiting for AVPlayerItem.status to become .readyToPlay")
                #endif
            }
        } catch {
            decoderLogger.error("Failed to load file: \(error.localizedDescription, privacy: .public)")
            self.state = .error(error.localizedDescription)
            self.lastError = (error as? PlaybackError) ?? .assetLoadFailed(error)
            var media = self.describeMedia(for: self.mediaInfo)
            if media.codec == "unknown" {
                let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                if let extracted = await self.withTimeout(seconds: 2.0, operation: {
                    let videoTracks = try await asset.loadTracks(withMediaType: .video)
                    guard let first = videoTracks.first else { return (codec: "unknown", resolution: "unknown") as (codec: String, resolution: String) }
                    // try? intentional: telemetry-only codec extraction — fallback to "unknown" is acceptable
                    let formatDescs = try? await first.load(.formatDescriptions)
                    let mediaSubType = formatDescs?.first.map { CMFormatDescriptionGetMediaSubType($0) }
                    let codec = mediaSubType.map { self.fourCharCodeToString($0) } ?? "unknown"
                    // try? intentional: telemetry-only size extraction — fallback to "unknown" is acceptable
                    let size = try? await first.load(.naturalSize)
                    let resolution = size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "unknown"
                    return (codec: codec, resolution: resolution) as (codec: String, resolution: String)
                }) {
                    media = extracted
                }
            }
            TelemetryManager.shared.record(.playbackFailed(
                codec: media.codec,
                resolution: media.resolution,
                errorCode: (error as? PlaybackError)?.errorDescription ?? error.localizedDescription,
                source: url.pathExtension.lowercased() == "mpd" ? .dash : .local
            ))
            throw error
        }
    }

    // MARK: - Item Status Observation

    private func observeItemStatus(item: AVPlayerItem, url: URL, source: PlaybackSource) -> AnyCancellable {
        item.publisher(for: \.status)
            .removeDuplicates()
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    guard self.state != .ready else { return }
                    // Don't transition to .ready from AVPlayer KVO unless
                    // compatibility mode is active (AVPlayer handles playback)
                    // or the custom pipeline already succeeded.
                    guard self.compatibilityMode || self.mediaPipelineError == nil else {
                        #if DEBUG
                        self.decoderLogger.debug("Deferring .ready — MediaPipeline has not succeeded yet")
                        #endif
                        return
                    }
                    self.duration = CMTimeGetSeconds(item.duration)
                    #if DEBUG
                    let label = source == .dash ? "DASH fallback " : ""
                    self.decoderLogger.debug("AVPlayerItem.status became .readyToPlay for \(label)\(url.path, privacy: .public)")
                    #endif
                    self.state = .ready
                case .failed:
                    let error = item.error as NSError?
                    let osStatus = OSStatus(error?.code ?? -1)
                    #if DEBUG
                    let label = source == .dash ? "DASH fallback " : ""
                    self.decoderLogger.error("""
                    AVPlayerItem.status became .failed for \(label)\(url.path, privacy: .public):
                      NSError: \(error?.description ?? "nil", privacy: .public)
                      UserInfo: \(error?.userInfo.description ?? "nil", privacy: .public)
                      OSStatus: \(osStatus)
                    """)
                    #endif
                    self.state = .error("Cannot Open: OSStatus \(osStatus)")
                    self.lastError = .assetLoadFailedWithStatus(
                        osStatus,
                        error ?? NSError(domain: "PlaybackEngine", code: -1)
                    )
                    let media = self.describeMedia(for: self.mediaInfo)
                    TelemetryManager.shared.record(.playbackFailed(
                        codec: media.codec,
                        resolution: media.resolution,
                        errorCode: "OSStatus \(osStatus)",
                        source: source
                    ))
                default:
                    break
                }
            }
    }

    func play() {
        guard state.canTransition(to: .playing) else { return }
        audioClock.rate = playbackRate
        audioClock.start()
        player.playImmediately(atRate: playbackRate)
        if let spatialAudioEngine = spatialAudioEngine, spatialAudioEnabled {
            do {
                try spatialAudioEngine.startEngine()
            } catch {
                decoderLogger.error("Spatial audio engine failed to start: \(error.localizedDescription, privacy: .public)")
                spatialAudioEnabled = false
                player.volume = 1
                TelemetryManager.shared.record(.compatibilityModeActivated(
                    reason: "Spatial audio start failed: \(error.localizedDescription)",
                    source: currentLoadURL?.pathExtension.lowercased() == "mpd" ? .dash : .local
                ))
            }
        }
        if !compatibilityMode {
            mediaPipeline?.play(currentState: state)
        }
        state = .playing
    }

    func pause() {
        guard state.canTransition(to: .paused) else { return }
        player.pause()
        audioClock.pause()
        if !compatibilityMode {
            mediaPipeline?.pause(currentState: state)
        }
        state = .paused
    }

    func stop() {
        player.pause()
        player.seek(to: .zero)
        audioClock.stop()
        spatialAudioEngine?.stop()
        if !compatibilityMode {
            mediaPipeline?.stop(currentState: state)
        }
        mediaInfo = nil
        itemStatusCancellable = nil
        currentLoadURL = nil
        state = .idle
        currentTime = 0
        duration = 0
    }

    func seek(to time: TimeInterval) async {
        guard state.canTransition(to: .seeking) else { return }
        let previousState = state
        state = .seeking
        let targetTime = CMTime(seconds: time, preferredTimescale: 600)
        await player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
        audioClock.seek(to: time)
        currentTime = time
        if !compatibilityMode {
            await mediaPipeline?.seek(to: time)
        }
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
        guard let spatialAudioEngine = spatialAudioEngine else {
            spatialAudioEnabled = enabled
            player.volume = enabled ? 0 : 1
            return
        }

        spatialAudioEngine.spatialAudioEnabled = enabled
        if enabled {
            do {
                try spatialAudioEngine.startEngine()
                spatialAudioEnabled = true
                player.volume = 0
            } catch {
                decoderLogger.error("Spatial audio engine failed to start: \(error.localizedDescription, privacy: .public)")
                spatialAudioEnabled = false
                spatialAudioEngine.spatialAudioEnabled = false
                TelemetryManager.shared.record(.compatibilityModeActivated(
                    reason: "Spatial audio start failed: \(error.localizedDescription)",
                    source: currentLoadURL?.pathExtension.lowercased() == "mpd" ? .dash : .local
                ))
            }
        } else {
            spatialAudioEngine.disableSpatialAudio()
            spatialAudioEnabled = false
            player.volume = 1
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

    private func describeMedia(for telemetry: MediaInfo?) -> (codec: String, resolution: String) {
        guard let track = telemetry?.videoTracks.first else {
            return (codec: "unknown", resolution: "unknown")
        }
        return (codec: track.codec, resolution: "\(track.width)x\(track.height)")
    }

    private func fourCharCodeToString(_ code: OSType) -> String {
        let bytes = [
            UInt8(truncatingIfNeeded: code >> 24),
            UInt8(truncatingIfNeeded: code >> 16),
            UInt8(truncatingIfNeeded: code >> 8),
            UInt8(truncatingIfNeeded: code)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "unknown"
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            // try? intentional: timeout wrapper — error means operation failed or was cancelled, both return nil
            group.addTask { try? await operation() }
            group.addTask {
                // try? intentional: timeout sentinel — cancellation is expected when operation wins the race
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
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
                let media = self.describeMedia(for: self.mediaInfo)
                TelemetryManager.shared.record(.playbackFailed(
                    codec: media.codec,
                    resolution: media.resolution,
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
