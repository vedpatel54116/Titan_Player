import SwiftUI
import Combine
import AVFAudio
import AppKit

@MainActor
final class PlaybackSession: ObservableObject {
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
    @Published var toneMappingEnabled: Bool = true
    @Published var brightness: Float = 1.0

    @Published var subtitleFontSize: Float = 1.0
    @Published var subtitlePosition: SubtitlePosition = .bottom
    @Published var subtitleBackgroundOpacity: Float = 0.6

    @Published var currentlyAccessedURL: URL?

    private let bookmarkDefaultsKey = "SecurityScopedBookmarks"

    @Published var fitMode: FitMode = .fit
    @Published var fitModeOverride: FitMode? = nil

    let frameStore = FrameStore()
    let shortcutManager = KeyboardShortcutManager()
    var analysis: VideoAnalysisManager
    let displayManager: DisplayManager
    let airPlayController: AirPlayController
    let streaming: StreamingManager
    let performance: PerformanceOptimizer

    private var keyMonitorToken: Any?
    private var secondaryDisplayWindow: ExternalDisplayWindow?

    private let engine: PlaybackEngine
    private let subtitleManager = SubtitleManager()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Security-Scoped Bookmark Management

    private func createBookmark(for url: URL) {
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

    private func resolveBookmark(for path: String) -> URL? {
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

    private func removeBookmark(for path: String) {
        var bookmarks = UserDefaults.standard.dictionary(forKey: bookmarkDefaultsKey) as? [String: Data] ?? [:]
        bookmarks.removeValue(forKey: path)
        UserDefaults.standard.set(bookmarks, forKey: bookmarkDefaultsKey)
        NSLog("[BookmarkManager] Removed stale bookmark for path: %@", path)
    }

    private func startAccessingBookmark(for url: URL) -> Bool {
        let accessing = url.startAccessingSecurityScopedResource()
        if !accessing {
            NSLog("[BookmarkManager] Failed to start accessing security-scoped resource for: %@", url.path)
        }
        return accessing
    }

    private func stopAccessingCurrentResource() {
        if let currentURL = currentlyAccessedURL {
            currentURL.stopAccessingSecurityScopedResource()
            NSLog("[BookmarkManager] Stopped accessing: %@", currentURL.path)
            currentlyAccessedURL = nil
        }
    }

    private func showStaleBookmarkAlert(path: String) {
        let alert = NSAlert()
        alert.messageText = "File Unavailable"
        alert.informativeText = "The file at \"\(path)\" may have been moved or deleted. Please open the file again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    init(videoRenderer: VideoRenderer? = nil, audioRenderer: AudioRenderer? = nil) {
        let resolvedVideoRenderer = videoRenderer ?? (try? MetalRenderer.make())
        let resolvedAudioRenderer = audioRenderer ?? AVAudioEngineRenderer()
        self.renderer = resolvedVideoRenderer
        let engineVideoRenderer = resolvedVideoRenderer ?? NoOpFrameRenderer()
        if let metal = resolvedVideoRenderer as? MetalRenderer {
            metal.frameStore = frameStore
        }
        // Video analysis: own a VideoAnalysisManager that subscribes to the
        // session's frame store. Initialize early so `self` is fully available
        // before we register it as the renderer's delegate below.
        let device = MTLCreateSystemDefaultDevice()
            ?? MTLCreateSystemDefaultDevice()!
        self.analysis = VideoAnalysisManager(metalDevice: device)
        analysis.attach(frameStore: frameStore)
        self.engine = PlaybackEngine(
            videoRenderer: engineVideoRenderer,
            audioRenderer: resolvedAudioRenderer
        )
        self.displayManager = DisplayManager()
        self.airPlayController = AirPlayController(monitor: engine.avPlayer)
        self.streaming = StreamingManager.makeDefault()
        self.performance = PerformanceOptimizer.makeDefault()
        if let metal = resolvedVideoRenderer as? MetalRenderer {
            metal.delegate = self
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
        // Stop accessing previous resource if any
        stopAccessingCurrentResource()

        // Create and store bookmark for new URL
        createBookmark(for: url)

        // Resolve bookmark to get fresh URL
        guard let resolvedURL = resolveBookmark(for: url.path) else {
            showStaleBookmarkAlert(path: url.path)
            return
        }

        // Start accessing security-scoped resource
        guard startAccessingBookmark(for: resolvedURL) else {
            playState = .error("Cannot access file at \(url.path). Check file permissions.")
            return
        }

        // Track the accessed URL
        currentlyAccessedURL = resolvedURL

        // Load into engine
        do {
            try await engine.load(url: resolvedURL)
            if url.pathExtension.lowercased() == "m3u8" {
                streaming.load(url: url)
                streaming.attach(player: engine.avPlayer)
            }
            let videoTrack = mediaInfo?.videoTracks.first
            performance.observe(
                settings: CurrentPlaybackSettings(
                    decoderIsHW: false,
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
            stopAccessingCurrentResource()
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

        let device = MTLCreateSystemDefaultDevice()!
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

            let device = MTLCreateSystemDefaultDevice()!
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

    /// Install the audio-tap on every decoder that the playback engine exposes.
    /// Today `MediaPipeline` doesn't expose its decoder publicly, so the wiring
    /// is best-effort: when a decoder becomes downcastable from `MediaPipeline`,
    /// it gets the session-owned meter bound. Until then, the audio meter
    /// remains dormant (and `audioMeter.metering` stays at `.zero`).
    private func installAudioTap() {
        var decoder = decoderFromEngine()
        let meter = analysis.audioMeter
        decoder?.audioTap = { frame in
            Task { @MainActor in
                meter.consume(frame: frame)
            }
        }
    }

    /// Best-effort accessor that walks the engine's reflection to find any
    /// `MediaDecoding`-conforming decoder. This avoids leaking the `MediaPipeline`
    /// internal property shape while still allowing the session to wire the tap.
    private func decoderFromEngine() -> MediaDecoding? {
        let mirror = Mirror(reflecting: engine)
        for child in mirror.children {
            if let d = child.value as? MediaDecoding { return d }
            // One level deeper for MediaPipeline wrapping.
            let inner = Mirror(reflecting: child.value)
            for grandchild in inner.children {
                if let d = grandchild.value as? MediaDecoding { return d }
            }
        }
        return nil
    }

    private func installKeyMonitor() {
        let side = DispatcherSideEffects(
            toggleFullscreen: { NSApp.keyWindow?.toggleFullScreen(nil) },
            toggleMiniPlayer: {
                SessionLocator.MiniWindowController.shared.toggle { _ in MiniPlayerView() }
            },
            newLibraryWindow: { TitanCommands.openLibraryPanel() },
            openFile:         { TitanCommands.openFileUsingPanel(session: self) }
        )
        let dispatcher = PlayerActionDispatcher(session: self, sideEffects: side)

        keyMonitorToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard let window = event.window else { return event }
            let identifier = window.identifier?.rawValue ?? window.title ?? ""
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
