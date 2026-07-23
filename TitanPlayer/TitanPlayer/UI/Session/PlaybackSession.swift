//
//  PlaybackSession.swift
//  TitanPlayer
//
//  Central session facade that owns all playback subsystems and
//  exposes them to the SwiftUI layer via @Published properties.
//

import SwiftUI
import Combine
import AVFoundation
import os.log

@MainActor
final class PlaybackSession: ObservableObject {

    // MARK: - Published State

    @Published var playState: PlayState = .idle
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var volume: Float = 1.0
    @Published var isMuted: Bool = false
    @Published var playbackRate: Float = 1.0
    @Published var isLoading: Bool = false
    @Published var isMediaLoaded: Bool = false
    @Published var isAudioOnly: Bool = false
    @Published var isCompatibilityMode: Bool = false
    @Published var currentTitle: String?
    @Published var currentFileURL: URL?
    @Published var showingEngineError: Bool = false
    @Published var engineErrorMessage: String = ""
    @Published var effectiveFitMode: FitMode = .fit
    @Published var isMiniPlayerActive: Bool = false
    @Published var subtitleTracks: [SubtitleTrack] = []
    @Published var activeSubtitleTrack: Int? = nil
    @Published var audioTracks: [AudioTrack] = []
    @Published var activeAudioTrack: Int? = nil
    @Published var videoAnalysisEnabled: Bool = false

    // MARK: - Subsystems

    let engine: PlaybackEngine
    let renderer: FrameRendering
    let frameStore: FrameStore
    let analysis: VideoAnalysisManager
    let spatialAudio: SpatialAudioEngine
    let streamingManager: StreamingManager
    let subtitleManager: SubtitleManager
    let displayManager: DisplayManager
    let performanceOptimizer: PerformanceOptimizer

    private var bookmarkStore = BookmarkStore()
    private var activeBookmarkAccess: URL?
    private var cancellables = Set<AnyCancellable>()
    private let logger = Logger(subsystem: "com.titanplayer.app", category: "PlaybackSession")

    // MARK: - Init

    init() {
        // Create shared Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            logger.error("PlaybackSession: Metal is not available on this system")
            self.renderer = NoOpFrameRenderer()
            self.frameStore = FrameStore()
            self.engine = PlaybackEngine(renderer: NoOpFrameRenderer())
            self.analysis = VideoAnalysisManager()
            self.spatialAudio = SpatialAudioEngine()
            self.streamingManager = StreamingManager()
            self.subtitleManager = SubtitleManager()
            self.displayManager = DisplayManager()
            self.performanceOptimizer = PerformanceOptimizer()
            return
        }

        // Create renderer with shared device
        let metalRenderer: MetalRenderer
        do {
            metalRenderer = try MetalRenderer(device: device)
            self.renderer = metalRenderer
        } catch {
            logger.error("PlaybackSession: Failed to create MetalRenderer: \(error)")
            self.renderer = NoOpFrameRenderer()
        }

        self.frameStore = FrameStore()
        self.engine = PlaybackEngine(renderer: renderer)
        self.analysis = VideoAnalysisManager(metalDevice: device)
        self.spatialAudio = SpatialAudioEngine()
        self.streamingManager = StreamingManager()
        self.subtitleManager = SubtitleManager()
        self.displayManager = DisplayManager()
        self.performanceOptimizer = PerformanceOptimizer()

        setupBindings()
        setupAudioTap()

        // Start performance monitoring
        Task {
            performanceOptimizer.startPerformanceMonitor()
        }
    }

    // MARK: - Bindings

    private func setupBindings() {
        // Engine state -> Session state
        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.playState = state
                self?.isMediaLoaded = (state == .ready || state == .playing || state == .paused)
                self?.isLoading = (state == .loading)
            }
            .store(in: &cancellables)

        // Engine time -> Session time
        engine.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                self?.currentTime = time
            }
            .store(in: &cancellables)

        // Engine duration -> Session duration
        engine.$duration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                self?.duration = duration
            }
            .store(in: &cancellables)

        // Engine compatibility mode
        engine.$compatibilityMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isCompat in
                self?.isCompatibilityMode = isCompat
            }
            .store(in: &cancellables)

        // Engine audio-only detection
        engine.$isAudioOnly
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isAudio in
                self?.isAudioOnly = isAudio
            }
            .store(in: &cancellables)

        // Subtitle manager -> Session
        subtitleManager.$tracks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tracks in
                self?.subtitleTracks = tracks
            }
            .store(in: &cancellables)

        subtitleManager.$activeTrackIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] index in
                self?.activeSubtitleTrack = index
            }
            .store(in: &cancellables)
    }

    private func setupAudioTap() {
        engine.onDecodedAudio = { [weak self] buffer in
            self?.spatialAudio.processAudioBuffer(buffer)
        }
    }

    // MARK: - File Opening

    /// Open a local media file with full validation, bookmark management,
    /// and error handling.
    func openFile(url: URL) async throws {
        logger.info("PlaybackSession: openFile: \(url.lastPathComponent)")

        // 1. Validate file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            let error = PlaybackError.fileNotFound(url.lastPathComponent)
            logger.error("PlaybackSession: File not found: \(url.path)")
            showEngineError(error.localizedDescription)
            throw error
        }

        // 2. Check if already playing this exact file
        if currentFileURL == url && (playState == .playing || playState == .paused) {
            logger.info("PlaybackSession: File already open, seeking to start")
            seek(to: 0)
            return
        }

        // 3. Stop current playback
        stopPlayback()

        // 4. Release previous security-scoped resource
        releaseBookmarkAccess()

        // 5. Create and persist security-scoped bookmark
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            bookmarkStore.save(bookmark: bookmarkData, for: url)
            logger.info("PlaybackSession: Bookmark saved for \(url.lastPathComponent)")
        } catch {
            logger.warning("PlaybackSession: Could not create bookmark: \(error)")
            // Non-fatal -- continue without bookmark
        }

        // 6. Start accessing security-scoped resource
        let didStartAccess = url.startAccessingSecurityScopedResource()
        if didStartAccess {
            activeBookmarkAccess = url
            logger.info("PlaybackSession: Security-scoped access granted")
        } else {
            logger.warning("PlaybackSession: Security-scoped access denied -- attempting direct access")
            // In non-sandboxed (Direct) builds, this is expected
            // In sandboxed (App Store) builds, this means the bookmark failed
        }

        // 7. Update UI state
        currentFileURL = url
        currentTitle = url.deletingPathExtension().lastPathComponent
        isLoading = true

        // 8. Load into engine
        do {
            try await engine.load(url: url)
            isLoading = false
            logger.info("PlaybackSession: File loaded successfully: \(url.lastPathComponent)")

            // 9. Load subtitles if available
            loadSubtitles(for: url)

            // 10. Auto-play
            play()

        } catch {
            isLoading = false
            currentFileURL = nil
            currentTitle = nil
            releaseBookmarkAccess()

            logger.error("PlaybackSession: Engine load failed: \(error)")
            showEngineError("Cannot play \"\(url.lastPathComponent)\": \(error.localizedDescription)")
            throw error
        }
    }

    /// Open a streaming URL (HLS, DASH, HTTP).
    func openStreamingURL(_ url: URL) async throws {
        logger.info("PlaybackSession: openStreamingURL: \(url.absoluteString)")

        stopPlayback()
        releaseBookmarkAccess()

        currentFileURL = url
        currentTitle = url.lastPathComponent
        isLoading = true

        do {
            try await engine.load(url: url)
            isLoading = false
            play()
        } catch {
            isLoading = false
            currentFileURL = nil
            currentTitle = nil
            showEngineError("Cannot open stream: \(error.localizedDescription)")
            throw error
        }
    }

    /// Resolve a security-scoped bookmark and open the file.
    func openFromBookmark(_ bookmarkData: Data) async throws {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            let error = PlaybackError.bookmarkResolutionFailed
            showEngineError("Cannot resolve saved file reference. The file may have been moved or deleted.")
            throw error
        }

        if isStale {
            logger.warning("PlaybackSession: Bookmark is stale, recreating")
        }

        try await openFile(url: url)
    }

    // MARK: - Playback Controls

    func play() {
        engine.play()
    }

    func pause() {
        engine.pause()
    }

    func togglePlayPause() {
        switch playState {
        case .playing:
            pause()
        case .paused, .ready:
            play()
        case .ended:
            seek(to: 0)
            play()
        default:
            break
        }
    }

    func stopPlayback() {
        engine.stop()
        subtitleManager.clear()
        currentFileURL = nil
        currentTitle = nil
        isMediaLoaded = false
        isAudioOnly = false
    }

    func seek(to time: TimeInterval) {
        engine.seek(to: time)
    }

    func seekForward(_ seconds: TimeInterval = 10) {
        seek(to: min(currentTime + seconds, duration))
    }

    func seekBackward(_ seconds: TimeInterval = 10) {
        seek(to: max(currentTime - seconds, 0))
    }

    func setVolume(_ vol: Float) {
        volume = vol
        engine.setVolume(vol)
    }

    func toggleMute() {
        isMuted.toggle()
        engine.setMuted(isMuted)
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        engine.setRate(rate)
    }

    func setFitMode(_ mode: FitMode) {
        effectiveFitMode = mode
    }

    // MARK: - Mini Player

    func toggleMiniPlayer() {
        isMiniPlayerActive.toggle()
    }

    // MARK: - Subtitles

    func selectSubtitleTrack(_ index: Int?) {
        subtitleManager.selectTrack(index)
    }

    private func loadSubtitles(for videoURL: URL) {
        // Look for subtitle files with the same base name
        let directory = videoURL.deletingLastPathComponent()
        let baseName = videoURL.deletingPathExtension().lastPathComponent
        let subtitleExtensions = ["srt", "vtt", "ass", "ssa", "sub", "idx"]

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        let matchingSubtitles = contents.filter { fileURL in
            let name = fileURL.deletingPathExtension().lastPathComponent
            let ext = fileURL.pathExtension.lowercased()
            return name.hasPrefix(baseName) && subtitleExtensions.contains(ext)
        }

        for subtitleURL in matchingSubtitles {
            subtitleManager.loadSubtitleFile(subtitleURL)
        }

        logger.info("PlaybackSession: Found \(matchingSubtitles.count) subtitle file(s)")
    }

    // MARK: - Error Handling

    func showEngineError(_ message: String) {
        engineErrorMessage = message
        showingEngineError = true
    }

    func dismissEngineError() {
        showingEngineError = false
        engineErrorMessage = ""
    }

    // MARK: - Bookmark Management

    private func releaseBookmarkAccess() {
        if let url = activeBookmarkAccess {
            url.stopAccessingSecurityScopedResource()
            activeBookmarkAccess = nil
            logger.info("PlaybackSession: Released security-scoped access")
        }
    }

    // MARK: - Cleanup

    func shutdown() {
        stopPlayback()
        releaseBookmarkAccess()
        performanceOptimizer.stopPerformanceMonitor()
        spatialAudio.stopEngine()
        cancellables.removeAll()
    }
}

// MARK: - Playback Error

enum PlaybackError: LocalizedError {
    case fileNotFound(String)
    case bookmarkResolutionFailed
    case unsupportedFormat(String)
    case engineLoadFailed(String)
    case securityScopedAccessDenied

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let name):
            return "File not found: \(name)"
        case .bookmarkResolutionFailed:
            return "Cannot resolve saved file reference. The file may have been moved or deleted."
        case .unsupportedFormat(let ext):
            return "Unsupported file format: .\(ext)"
        case .engineLoadFailed(let reason):
            return "Playback engine failed: \(reason)"
        case .securityScopedAccessDenied:
            return "Access to this file was denied. Please re-select the file."
        }
    }
}
