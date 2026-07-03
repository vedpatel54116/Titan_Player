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

    @Published var subtitleFontSize: Float = 1.0
    @Published var subtitlePosition: SubtitlePosition = .bottom
    @Published var subtitleBackgroundOpacity: Float = 0.6

    @Published var currentlyAccessedURL: URL?
    @Published var fileOpenError: String?
    @Published var errorMessage: String?
    @Published var initializationError: String?

    private let bookmarkDefaultsKey = "SecurityScopedBookmarks"

    @Published var fitMode: FitMode = .fit
    @Published var fitModeOverride: FitMode? = nil

    let frameStore = FrameStore()
    let shortcutManager = KeyboardShortcutManager()
    var analysis: VideoAnalysisManager?
    let displayManager: DisplayManager
    let airPlayController: AirPlayController
    let streaming: StreamingManager
    let performance: PerformanceOptimizer

    private var keyMonitorToken: Any?
    private var secondaryDisplayWindow: ExternalDisplayWindow?

    private let engine: PlaybackEngine
    var avPlayer: AVPlayer { engine.avPlayer }
    private let subtitleManager = SubtitleManager()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Security-Scoped Bookmark Management

    func createBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var bookmarks = UserDefaults.standard.dictionary(forKey: bookmarkDefaultsKey) as? [String: Data] ?? [:]
            bookmarks[url.path] = bookmarkData
            UserDefaults.standard.set(bookmarks, forKey: bookmarkDefaultsKey)
        } catch {
            NSLog("[BookmarkManager] Failed to create bookmark for %@: %@", url.path, error.localizedDescription)
        }
    }

    func resolveBookmark(for path: String) -> URL? {
        guard let bookmarks = UserDefaults.standard.dictionary(forKey: bookmarkDefaultsKey) as? [String: Data],
              let bookmarkData = bookmarks[path] else {
            return nil
        }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                NSLog("[BookmarkManager] Stale bookmark detected for path: %@", path)
                removeBookmark(for: path)
                return nil
            }

            return url
        } catch {
            NSLog("[BookmarkManager] Failed to resolve bookmark for %@: %@", path, error.localizedDescription)
            removeBookmark(for: path)
            return nil
        }
    }

    func removeBookmark(for path: String) {
        var bookmarks = UserDefaults.standard.dictionary(forKey: bookmarkDefaultsKey) as? [String: Data] ?? [:]
        bookmarks.removeValue(forKey: path)
        UserDefaults.standard.set(bookmarks, forKey: bookmarkDefaultsKey)
        NSLog("[BookmarkManager] Removed stale bookmark for path: %@", path)
    }

    func stopAccessingCurrentResource() {
        if let currentURL = currentlyAccessedURL {
            currentURL.stopAccessingSecurityScopedResource()
            NSLog("[BookmarkManager] Stopped accessing: %@", currentURL.path)
            currentlyAccessedURL = nil
        }
    }

    private func showFileAccessError(path: String, reason: String) {
        fileOpenError = "Could not open \"\(path)\". \(reason)"
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
        self.displayManager = DisplayManager()
        self.airPlayController = AirPlayController(monitor: engine.avPlayer)
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
        installDisplayBindings()
        SessionLocator.shared.attach(self)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        Task.detached(priority: .background) { [performance] in
            performance.startPerformanceMonitor()
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
        logger.info("openFile called with URL: \(url.path, privacy: .public)")

        // Stop accessing previous resource if any
        stopAccessingCurrentResource()

        // Create and store bookmark for new URL
        createBookmark(for: url)

        // Resolve bookmark to get fresh URL, with fallback to original URL
        var accessURL = url
        if let resolvedURL = resolveBookmark(for: url.path) {
            logger.info("Bookmark resolved successfully for: \(resolvedURL.path, privacy: .public)")
            accessURL = resolvedURL
        } else {
            logger.warning("Failed to resolve bookmark for: \(url.path, privacy: .public), falling back to original URL")
        }

        // Start accessing security-scoped resource
        // For files dragged from Finder or on external volumes, the URL may not be
        // security-scoped, so startAccessingSecurityScopedResource() may return false.
        // We log the failure but still attempt to access the file.
        let accessing = accessURL.startAccessingSecurityScopedResource()
        if !accessing {
            logger.warning("startAccessingSecurityScopedResource() returned false for: \(accessURL.path, privacy: .public). Proceeding with file access attempt.")
        } else {
            logger.info("Security-scoped access started successfully for: \(accessURL.path, privacy: .public)")
        }

        // Track the accessed URL for cleanup when playback stops or app closes
        currentlyAccessedURL = accessURL

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
            stopAccessingCurrentResource()
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
        secondaryDisplayWindow?.close()
        secondaryDisplayWindow = nil
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

    private func installDisplayBindings() {
        displayManager.$activeDisplay
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] config in
                guard let self else { return }
                guard let screen = ScreenLookup.screen(forStableID: config.stableID),
                      let metal = self.renderer as? MetalRenderer else { return }
                metal.updateDisplayCapabilitiesAsynchronously(for: screen)
            }
            .store(in: &cancellables)

        displayManager.events
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .connected(let config):
                    self.handleDisplayConnected(config)
                case .disconnected(let stableID):
                    self.handleDisplayDisconnected(stableID)
                case .primaryChanged(let config):
                    self.handlePrimaryChanged(config)
                case .refreshed:
                    break
                }
            }
            .store(in: &cancellables)

        airPlayController.$currentAudioDelayOffset
            .removeDuplicates()
            .sink { [weak self] offset in
                self?.engine.setAudioDelay(offset)
            }
            .store(in: &cancellables)
    }

    private func handleDisplayConnected(_ config: ExternalDisplayConfig) {
        guard config.stableID != displayManager.primaryDisplay?.stableID else { return }
        guard let metal = renderer as? MetalRenderer else { return }
        guard let screen = ScreenLookup.screen(forStableID: config.stableID) else { return }

        let detector = DisplayCapabilityDetector()
        let caps = detector.detectCapabilities(for: screen)
        let icc = detector.detectICCProfile(for: screen)

        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let window = ExternalDisplayWindow(device: device)
        window.show(on: screen)
        secondaryDisplayWindow = window

        metal.addDisplayTarget(
            stableID: config.stableID,
            layer: window.metalLayer,
            capabilities: caps,
            iccProfile: icc
        )
    }

    private func handleDisplayDisconnected(_ stableID: String) {
        guard let metal = renderer as? MetalRenderer else { return }
        metal.removeDisplayTarget(stableID: stableID)

        secondaryDisplayWindow?.close()
        secondaryDisplayWindow = nil
    }

    private func handlePrimaryChanged(_ config: ExternalDisplayConfig) {
        if let screen = ScreenLookup.screen(forStableID: config.stableID),
           let window = NSApp.keyWindow ?? NSApp.windows.first {
            window.setFrameOrigin(screen.frame.origin)
        }

        guard let metal = renderer as? MetalRenderer else { return }

        if let oldSecondary = displayManager.secondaryDisplay {
            metal.removeDisplayTarget(stableID: oldSecondary.stableID)
            secondaryDisplayWindow?.close()
            secondaryDisplayWindow = nil
        }

        if let secondary = displayManager.secondaryDisplay,
           let screen = ScreenLookup.screen(forStableID: secondary.stableID) {
            let detector = DisplayCapabilityDetector()
            let caps = detector.detectCapabilities(for: screen)
            let icc = detector.detectICCProfile(for: screen)

            guard let device = MTLCreateSystemDefaultDevice() else { return }
            let window = ExternalDisplayWindow(device: device)
            window.show(on: screen)
            secondaryDisplayWindow = window

            metal.addDisplayTarget(
                stableID: secondary.stableID,
                layer: window.metalLayer,
                capabilities: caps,
                iccProfile: icc
            )
        }
    }

    /// Wire the audio tap via direct dependency injection through
    /// `AudioTapProvider` (no Mirror reflection). The closure feeds
    /// decoded PCM frames to both the loudness meter and the spatial
    /// audio engine.
    private func installAudioTap() {
        guard let meter = analysis?.audioMeter else { return }
        engine.audioTap = { [weak self] frame in
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
