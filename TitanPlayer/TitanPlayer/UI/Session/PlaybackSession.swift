import SwiftUI
import Combine
@preconcurrency import AVKit
@preconcurrency import AVFAudio
import AppKit
import os

@MainActor
final class PlaybackSession: ObservableObject {
    private let logger = Logger(subsystem: "com.titanplayer.app", category: "FileOpen")

    @Published var playState: PlaybackState = .idle
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Float = 1.0
    @Published var isMuted: Bool = false
    @Published var mediaInfo: MediaInfo?
    @Published var subtitles: [SubtitleTrack] = []
    @Published var activeSubtitle: SubtitleTrack?
    @Published var currentSubtitleEvents: [SubtitleEvent] = []
    @Published var currentSubtitleBitmap: SubtitleBitmap?
    @Published var playbackRate: Float = 1.0
    @Published var audioDelay: TimeInterval = 0
    @Published var renderer: FrameRendering?

    @Published var isAudioOnly: Bool = false
    @Published var isHDRContent: Bool = false
    @Published var isCompatibilityMode: Bool = false
    @Published var toneMappingEnabled: Bool = true
    @Published var brightness: Float = 1.0

    @Published var subtitleFontSize: Float = 1.0
    @Published var subtitlePosition: SubtitlePosition = .bottom
    @Published var subtitleBackgroundOpacity: Float = 0.6

    @Published var fileOpenError: String?
    @Published var errorMessage: String?
    @Published var initializationError: String?

    @Published var fitMode: FitMode = .fit
    @Published var fitModeOverride: FitMode? = nil

    let frameStore = FrameStore()
    let shortcutManager = KeyboardShortcutManager()
    let displayCoordinator: DisplayCoordinator
    let telemetryCoordinator: PlaybackTelemetryCoordinator

    var displayManager: DisplayManager { displayCoordinator.displayManager }
    var airPlayController: AirPlayController { displayCoordinator.airPlayController }
    var analysis: VideoAnalysisManager? { telemetryCoordinator.analysis }
    var performance: PerformanceOptimizer { telemetryCoordinator.performance }
    let streaming: StreamingManager

    private var keyMonitorToken: Any?

    private let engine: PlaybackEngine
    var avPlayer: AVPlayer { engine.avPlayer }
    private let subtitleManager = SubtitleManager()
    private let bookmarks = BookmarkStore()
    private var cancellables = Set<AnyCancellable>()

    var currentlyAccessedURL: URL? { bookmarks.currentlyAccessedURL }

    // MARK: - Security-Scoped Bookmark Management

    func createBookmark(for url: URL) {
        bookmarks.createBookmark(for: url)
    }

    func resolveBookmark(for path: String) -> URL? {
        bookmarks.resolveBookmark(for: path)
    }

    func removeBookmark(for path: String) {
        bookmarks.removeBookmark(for: path)
    }

    func stopAccessingCurrentResource() {
        bookmarks.stopAccessingCurrentResource()
    }

    private func showFileAccessError(path: String, reason: String) {
        fileOpenError = "Could not open \"\(path)\". \(reason)"
    }

    private static func describe(error: Error, for url: URL) -> String {
        PlaybackErrorFormatter.describe(error, for: url)
    }

    func dismissFileOpenError() {
        fileOpenError = nil
    }

    func dismissErrorMessage() {
        errorMessage = nil
    }

    init(videoRenderer: VideoRenderer? = nil) {
        let resolvedVideoRenderer = videoRenderer ?? (try? MetalRenderer.make())
        self.renderer = resolvedVideoRenderer
        let engineVideoRenderer = resolvedVideoRenderer ?? NoOpFrameRenderer()
        if let metal = resolvedVideoRenderer as? MetalRenderer {
            metal.frameStore = frameStore
        }
        self.engine = PlaybackEngine(videoRenderer: engineVideoRenderer)
        self.streaming = StreamingManager.makeDefault()

        self.displayCoordinator = DisplayCoordinator(airPlayPlayer: engine.avPlayer)
        self.telemetryCoordinator = PlaybackTelemetryCoordinator(
            metalRenderer: resolvedVideoRenderer as? MetalRenderer,
            engine: engine,
            streaming: streaming,
            frameStore: frameStore
        )

        if let metal = resolvedVideoRenderer as? MetalRenderer {
            metal.delegate = self
        }
        if MTLCreateSystemDefaultDevice() == nil && videoRenderer == nil {
            self.initializationError = "Metal GPU is not available. Video rendering will be unavailable."
        }
        installAudioTap()
        setupBindings()
        installKeyMonitor()
        displayCoordinator.installDisplayBindings(renderer: renderer, engine: engine)
        SessionLocator.shared.attach(self)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        telemetryCoordinator.startMonitor()
    }

    var isMediaLoaded: Bool {
        if case .error = playState { return false }
        return playState != .idle
    }

    var effectiveFitMode: FitMode {
        fitModeOverride ?? fitMode
    }

    func applyMediaInfo(_ info: MediaInfo) {
        self.mediaInfo = info
        self.isAudioOnly = info.videoTracks.isEmpty && !info.audioTracks.isEmpty
        self.fitMode = resolveFitMode(for: info)
        self.fitModeOverride = nil
    }

    func openFile(url: URL) async {
        logger.info("openFile called with URL: \(url.path, privacy: .public)")

        // Stop accessing previous resource if any
        bookmarks.stopAccessingCurrentResource()

        // Create and store bookmark for new URL
        bookmarks.createBookmark(for: url)

        // Resolve bookmark to get fresh URL, start security-scoped access
        let accessURL = bookmarks.startAccessing(url: url)

        // Load into engine
        do {
            logger.info("Loading file into engine: \(accessURL.path, privacy: .public)")
            try await engine.load(url: accessURL)
            logger.info("File loaded successfully into engine: \(accessURL.path, privacy: .public)")
            errorMessage = nil
            if url.pathExtension.lowercased() == "m3u8" {
                streaming.load(url: url)
                streaming.attach(player: engine.avPlayer)
            }
            let videoTrack = mediaInfo?.videoTracks.first
            let decoderIsHW = await engine.adaptiveDecoderManager.activeDecoderType?.contains("VideoToolbox") ?? false
            performance.observe(
                settings: CurrentPlaybackSettings(
                    decoderIsHW: decoderIsHW,
                    resolution: CGSize(
                        width: videoTrack?.width ?? 1920,
                        height: videoTrack?.height ?? 1080
                    ),
                    currentBitrate: streaming.observedBitrate > 0
                        ? Int(streaming.observedBitrate) : 0,
                    isStreaming: url.pathExtension.lowercased() == "m3u8",
                    audioEngineActive: !isAudioOnly
                )
            )
            performance.optimizeForCurrentState()
        } catch {
            logger.error("Failed to load file into engine: \(error.localizedDescription, privacy: .public)")
            bookmarks.stopAccessingCurrentResource()
            let message = Self.describe(error: error, for: url)
            showFileAccessError(path: url.path, reason: error.localizedDescription)
            errorMessage = message
        }
    }

    func play() { engine.play() }
    func pause() { engine.pause() }

    func togglePlayPause() {
        if playState == .playing {
            pause()
        } else if playState == .ready || playState == .paused {
            play()
        }
        performance.optimizeForCurrentState()
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
    }

    func toggleMute() { isMuted.toggle() }

    func setPlaybackRate(_ rate: Float) { engine.setPlaybackRate(rate) }
    func setAudioDelay(_ delay: TimeInterval) { engine.setAudioDelay(delay) }

    func setSubtitleTrack(_ track: SubtitleTrack?) {
        subtitleManager.setActiveTrack(track)
    }

    func loadExternalSubtitle(url: URL) throws {
        try subtitleManager.loadSubtitle(url: url)
    }

    func stop() {
        engine.stop()
        subtitleManager.clear()
        performance.observe(settings: nil)
        stopAccessingCurrentResource()
        displayCoordinator.teardown()
    }

    @objc private func applicationWillTerminate() {
        stopAccessingCurrentResource()
    }

    var lastErrorMessage: String? {
        if case .error(let message) = playState { return message }
        return nil
    }

    func stepFrameForward() async {
        guard playState == .paused || playState == .ready else { return }
        let fps = mediaInfo?.videoTracks.first?.frameRate ?? 24
        await seek(to: currentTime + 1.0 / fps)
    }

    func stepFrameBackward() async {
        guard playState == .paused || playState == .ready else { return }
        let fps = mediaInfo?.videoTracks.first?.frameRate ?? 24
        await seek(to: max(currentTime - 1.0 / fps, 0))
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
        engine.$compatibilityMode
            .receive(on: DispatchQueue.main)
            .assign(to: &$isCompatibilityMode)
        subtitleManager.$availableTracks
            .receive(on: DispatchQueue.main)
            .assign(to: &$subtitles)
        subtitleManager.$activeTrack
            .receive(on: DispatchQueue.main)
            .assign(to: &$activeSubtitle)
        subtitleManager.$currentEvents
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentSubtitleEvents)
        subtitleManager.$currentBitmap
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentSubtitleBitmap)
    }

    /// Wire the audio tap via a typed `audioTapSource` accessor on the
    /// engine. No Mirror reflection. The closure feeds decoded PCM frames
    /// to both the loudness meter and the spatial audio engine.
    private func installAudioTap() {
        guard let meter = analysis?.audioMeter else { return }
        guard var decoder = engine.audioTapSource else {
            logger.warning("installAudioTap: no decoder available (audioTapSource is nil)")
            return
        }
        decoder.audioTap = { [weak self] frame in
            Task { @MainActor in
                meter.consume(frame: frame)
                if let spatialEngine = self?.engine.activeSpatialAudioEngine,
                   spatialEngine.isRunning {
                    let buf = Self.makePCMBuffer(from: frame)
                    spatialEngine.processAudioBuffer(buf)
                }
            }
        }
    }

    /// Convert a decoded `AudioFrame` into an `AVAudioPCMBuffer` suitable
    /// for feeding into `AudioEngine.processAudioBuffer(_:)`.
    private nonisolated static func makePCMBuffer(from frame: AudioFrame) -> AVAudioPCMBuffer {
        let ch  = frame.format.channels
        let rate = frame.format.sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate),
                                   channels: AVAudioChannelCount(ch))!
        let total = frame.buffer.count
        let frames = total / ch
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames))!
        buf.frameLength = UInt32(frames)
        let src = frame.buffer
        if frame.format.isInterleaved {
            for c in 0..<ch {
                let dst = buf.floatChannelData![c]
                for i in 0..<frames { dst[i] = src[i * ch + c] }
            }
        } else {
            for c in 0..<ch {
                let dst = buf.floatChannelData![c]
                for i in 0..<frames { dst[i] = src[c * frames + i] }
            }
        }
        return buf
    }

    private func installKeyMonitor() {
        let side = DispatcherSideEffects(
            toggleFullscreen: { NSApp.keyWindow?.toggleFullScreen(nil) },
            toggleMiniPlayer: { [weak self] in
                guard let self else { return }
                SessionLocator.MiniWindowController.shared.toggle(
                    using: { _ in MiniPlayerView() },
                    session: self
                )
            },
            newLibraryWindow: { TitanCommands.openLibraryPanel() },
            openFile:         { TitanCommands.openFileUsingPanel(session: self) }
        )
        let dispatcher = PlayerActionDispatcher(session: self, sideEffects: side)

        keyMonitorToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard let window = event.window else { return event }
            let identifier = window.identifier?.rawValue ?? window.title
            let belongsToScene =
                identifier.contains("main")   ||
                identifier.contains("mini")   ||
                identifier.contains("Mini")   ||
                identifier.contains("Library") ||
                identifier.contains("library") ||
                identifier.contains("TitanPlayer")
            guard belongsToScene else { return event }

            let keyName = Self.keyString(for: event)
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            for action in PlayerAction.allCases {
                guard let binding = self.shortcutManager.binding(for: action) else { continue }
                if binding.key == keyName && binding.modifiers == mods {
                    dispatcher.dispatch(action)
                    return nil
                }
            }
            return event
        }
    }

    private static func keyString(for event: NSEvent) -> String {
        switch event.specialKey {
        case .leftArrow:  return "leftarrow"
        case .rightArrow: return "rightarrow"
        case .upArrow:    return "uparrow"
        case .downArrow:  return "downarrow"
        default:
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if chars == " " { return "space" }
            return chars
        }
    }
}

extension PlaybackSession: MetalRendererDelegate {
    func renderer(_ renderer: MetalRenderer, didDetectHDRMode mode: HDRMode) {
        switch mode {
        case .sdr:
            isHDRContent = false
        default:
            isHDRContent = true
        }
    }

    func renderer(_ renderer: MetalRenderer, didUpdateDisplayCapabilities caps: DisplayCapabilities) {
    }
}

private final class NoOpFrameRenderer: FrameRendering {
    func render(_ frame: VideoFrame) async throws {}
    func handleHDR(_ metadata: HDRMetadata) {}
    func updateDisplayCapabilities(for screen: NSScreen) {}
    func resetDynamicHDRParams() {}
}
