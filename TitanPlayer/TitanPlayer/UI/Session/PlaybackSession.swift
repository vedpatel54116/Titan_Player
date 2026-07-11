import SwiftUI
import Combine
import AVKit
import AVFAudio
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

    // Debug overlay state
    @Published var debugPixelFormat: String = "none"
    @Published var debugPipelineState: String = "idle"
    @Published var debugPendingFrameCount: Int = 0

    // Decoder health (from AdaptiveDecoderManager)
    @Published var decoderHealth: DecoderHealth = DecoderHealth(
        activeDecoder: "none", fallbackCount: 0, lastErrorCode: nil, pixelFormat: nil
    )

    @Published var subtitleFontSize: Float = 1.0
    @Published var subtitlePosition: SubtitlePosition = .bottom
    @Published var subtitleBackgroundOpacity: Float = 0.6

    var currentlyAccessedURL: URL? { bookmarkStore.currentlyAccessedURL }

    @Published var fileOpenError: String?
    @Published var errorMessage: String?
    @Published var initializationError: String?

    @Published var fitMode: FitMode = .fit
    @Published var fitModeOverride: FitMode? = nil

    let frameStore = FrameStore()
    let bookmarkStore = BookmarkStore()
    let shortcutManager = KeyboardShortcutManager()
    var analysis: VideoAnalysisManager?
    let displayCoordinator: DisplayCoordinator
    let streaming: StreamingManager
    let performance: PerformanceOptimizer

    nonisolated(unsafe) private var keyMonitorToken: Any?

    private let engine: PlaybackEngine
    var avPlayer: AVPlayer { engine.avPlayer }
    private let subtitleManager = SubtitleManager()
    private var cancellables = Set<AnyCancellable>()

    private func stopAccessingCurrentResource() {
        bookmarkStore.stopAccessing()
    }

    private func showFileAccessError(path: String, reason: String) {
        fileOpenError = "Could not open \"\(path)\". \(reason)"
    }

    private func showSandboxRestrictionError(path: String) {
        fileOpenError = "Could not open \"\(path)\". Sandbox restriction: The file is on an external volume and cannot be accessed without using the file picker first. Please use File > Open to select the file."
    }

    private static func describe(error: Error, for url: URL) -> String {
        let name = url.lastPathComponent
        if let playbackError = error as? PlaybackError {
            switch playbackError {
            case .invalidURL:
                return "Failed to open \"\(name)\": The file URL is invalid."
            case .noPlayableTracks:
                return "Failed to open \"\(name)\": The file contains no playable video or audio tracks. The codec may be unsupported."
            case .assetLoadFailed(let underlying):
                return "Failed to open \"\(name)\": \(underlying.localizedDescription)"
            case .assetLoadFailedWithStatus(let status, let underlying):
                return "Failed to open \"\(name)\": OSStatus \(status) — \(underlying.localizedDescription)"
            case .decodingFailed(let underlying):
                return "Failed to open \"\(name)\": Decoding failed — \(underlying.localizedDescription)"
            case .audioOutputFailed(let underlying):
                return "Failed to open \"\(name)\": Audio output failed — \(underlying.localizedDescription)"
            case .rateNotSupported:
                return "Failed to open \"\(name)\": The playback rate is not supported by this file."
            case .seekFailed:
                return "Failed to open \"\(name)\": Seeking within the file failed."
            }
        }
        if let mediaError = error as? MediaError {
            return "Failed to open \"\(name)\": \(mediaError.message)"
        }
        if let decoderError = error as? DecoderError {
            switch decoderError {
            case .unsupportedCodec(let codec):
                return "Failed to open \"\(name)\": Unsupported codec \"\(codec)\". No decoder is available for this format."
            case .sessionNotConfigured:
                return "Failed to open \"\(name)\": The decoder session was not properly configured."
            case .bufferCreationFailed(let status):
                return "Failed to open \"\(name)\": Could not allocate a decoding buffer (OSStatus \(status))."
            case .noFramesDecoded:
                return "Failed to open \"\(name)\": The decoder could not decode any frames from this file."
            case .hardwareFailure:
                return "Failed to open \"\(name)\": Hardware decoder failure. The device may not support this codec."
            case .softwareFailure:
                return "Failed to open \"\(name)\": Software decoder failure."
            case .noDecodersAvailable:
                return "Failed to open \"\(name)\": No decoder is available for this track."
            }
        }
        if let nsError = error as NSError? {
            let domain = nsError.domain
            let code = nsError.code
            if domain == "NSOSStatusErrorDomain" && code == -2004 { // 'fmt?' — file format not recognized
                return "Failed to open \"\(name)\": File format not recognized. The container may be corrupted or unsupported."
            }
            if domain == "AVFoundationErrorDomain" {
                switch code {
                case -11800:
                    return "Failed to open \"\(name)\": AVFoundation could not open the file. The format may be unsupported or the file may be corrupted."
                case -11821:
                    return "Failed to open \"\(name)\": Decoding failed. The video codec in this file is not supported."
                default:
                    break
                }
            }
        }
        return "Failed to open \"\(name)\": \(error.localizedDescription)"
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
        // Video analysis: own a VideoAnalysisManager that subscribes to the
        // session's frame store. Initialize early so `self` is fully available
        // before we register it as the renderer's delegate below.
        if let device = MTLCreateSystemDefaultDevice() {
            self.analysis = VideoAnalysisManager(metalDevice: device)
            analysis?.attach(frameStore: frameStore)
        }
        self.engine = PlaybackEngine(
            videoRenderer: engineVideoRenderer
        )
        let displayManager = DisplayManager()
        let airPlayController = AirPlayController(monitor: engine.avPlayer)
        self.displayCoordinator = DisplayCoordinator(
            displayManager: displayManager,
            airPlayController: airPlayController
        )
        self.streaming = StreamingManager.makeDefault()
        let perf = PerformanceOptimizer.makeDefault()
        if let metal = resolvedVideoRenderer as? MetalRenderer {
            perf.registerAdapter(RenderAdapter(target: metal))
        }
        perf.registerAdapter(DecoderAdapter(target: engine.adaptiveDecoderManager))
        perf.registerAdapter(StreamingAdapter(target: self.streaming))
        self.performance = perf
        if let metal = resolvedVideoRenderer as? MetalRenderer {
            metal.delegate = self
        }
        if MTLCreateSystemDefaultDevice() == nil && videoRenderer == nil {
            self.initializationError = "Metal GPU is not available. Video rendering will be unavailable."
        }
        installAudioTap()
        setupBindings()
        installKeyMonitor()
        displayCoordinator.rendererProvider = { [weak self] in
            self?.renderer as? MetalRenderer
        }
        displayCoordinator.audioDelayHandler = { [weak self] in
            self?.setAudioDelay($0)
        }
        displayCoordinator.installDisplayBindings()
        SessionLocator.shared.attach(self)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        Task { @MainActor in
            performance.startPerformanceMonitor()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let token = keyMonitorToken {
            NSEvent.removeMonitor(token)
        }
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
        #if DEBUG
        logger.debug("openFile called with URL: \(url.path, privacy: .public)")
        #endif

        // Stop accessing previous resource if any
        stopAccessingCurrentResource()

        // Create and store bookmark for new URL
        bookmarkStore.createBookmark(for: url)

        // Resolve bookmark to get fresh URL, with fallback to original URL
        var accessURL = url
        if let resolvedURL = bookmarkStore.resolveBookmark(for: url.path) {
            #if DEBUG
            logger.debug("Bookmark resolved successfully for: \(resolvedURL.path, privacy: .public)")
            #endif
            accessURL = resolvedURL
        } else {
            logger.warning("Failed to resolve bookmark for: \(url.path, privacy: .public), falling back to original URL")
        }

        // Start accessing security-scoped resource
        // For files dragged from Finder or on external volumes, the URL may not be
        // security-scoped, so startAccessingSecurityScopedResource() may return false.
        let accessing = bookmarkStore.startAccessing(accessURL)
        if !accessing {
            // Distinguish between picker URLs (non-fatal, picker grants transient access)
            // and non-picker URLs (drag-drop from external volumes, sandbox restriction)
            let isOnExternalVolume = accessURL.path.hasPrefix("/Volumes/")
            if isOnExternalVolume {
                // Drag-drop from external volume without picker: surface clear error
                logger.warning("startAccessingSecurityScopedResource() returned false for external volume URL: \(accessURL.path, privacy: .public). Sandbox restriction.")
                showSandboxRestrictionError(path: url.path)
                return
            } else {
                // User-selected URL from picker: non-fatal, picker grants transient access
                #if DEBUG
                logger.debug("startAccessingSecurityScopedResource() returned false for picker URL: \(accessURL.path, privacy: .public). Proceeding with transient access.")
                #endif
            }
        }

        // Load into engine
        do {
            #if DEBUG
            logger.debug("Loading file into engine: \(accessURL.path, privacy: .public)")
            #endif
            try await engine.load(url: accessURL)
            #if DEBUG
            logger.debug("File loaded successfully into engine: \(accessURL.path, privacy: .public)")
            #endif
            errorMessage = nil
            if url.pathExtension.lowercased() == "m3u8" || engine.compatibilityMode {
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
            stopAccessingCurrentResource()
            let message = Self.describe(error: error, for: url)
            showFileAccessError(path: url.path, reason: message)
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
        debugTimer?.invalidate()
        debugTimer = nil
        engine.teardown()
        engine.stop()
        subtitleManager.clear()
        performance.observe(settings: nil)
        stopAccessingCurrentResource()
        displayCoordinator.stop()
        if let token = keyMonitorToken {
            NSEvent.removeMonitor(token)
            keyMonitorToken = nil
        }
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func applicationWillTerminate() {
        engine.teardown()
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
        engine.adaptiveDecoderManager.decoderHealthPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$decoderHealth)
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

        // Poll MetalRenderer debug state at 2 Hz
        debugTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateDebugState()
        }
    }

    private var debugTimer: Timer?

    private func updateDebugState() {
        guard let metalRenderer = renderer as? MetalRenderer else {
            debugPixelFormat = "n/a"
            debugPipelineState = "no renderer"
            debugPendingFrameCount = 0
            return
        }
        let fmt = metalRenderer.lastPixelFormat
        debugPixelFormat = fmt != 0 ? fourCharCodeDebug(fmt) : "none"
        debugPipelineState = metalRenderer.debugPipelineState
        debugPendingFrameCount = metalRenderer.pendingFrameCount
    }

    private func fourCharCodeDebug(_ code: OSType) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08X", code)
    }

    /// Wire the audio tap via direct dependency injection through
    /// `AudioTapProvider` (no Mirror reflection). The closure feeds
    /// decoded PCM frames to both the loudness meter and the spatial
    /// audio engine.
    private func installAudioTap() {
        guard let meter = analysis?.audioMeter else { return }
        let router = AudioTapRouter(meter: meter) { [weak self] in
            self?.engine.activeSpatialAudioEngine
        }
        engine.audioTap = router.tapClosure
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
        let router = KeyEventRouter(shortcutManager: shortcutManager)

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

            if !KeyboardShortcutManager.isRecordingShortcut,
               let action = router.action(for: event) {
                dispatcher.dispatch(action)
                return nil   // consumed
            }

            // Cmd+Shift+D: toggle debug overlay
            if event.modifierFlags.contains(.command),
               event.modifierFlags.contains(.shift),
               event.charactersIgnoringModifiers == "d" {
                NotificationCenter.default.post(name: .toggleDebugOverlay, object: nil)
                return nil
            }

            return event   // not consumed
        }

        KeyboardLayoutMonitor.detectLayout()
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
