import Foundation
import Combine
import CoreMedia
import os

@MainActor
class MediaPipeline: ObservableObject {
    enum PipelinePhase: Equatable {
        case idle
        case loading
        case decoding
        case paused
        case stopped
        case error(String)

        static func == (lhs: PipelinePhase, rhs: PipelinePhase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading), (.decoding, .decoding),
                 (.paused, .paused), (.stopped, .stopped):
                return true
            case (.error(let l), .error(let r)):
                return l == r
            default:
                return false
            }
        }
    }

    private(set) var phase: PipelinePhase = .idle
    @Published var mediaInfo: MediaInfo?
    @Published var playbackRate: Float = 1.0
    
    private var demuxer: MediaDemuxing?
    private var decoder: MediaDecoding?
    private let timeObserver = TimeObserver()
    private let videoRenderer: VideoRenderer
    nonisolated(unsafe) weak var synchronizationProvider: SynchronizationProvider?
    var renderer: (any FrameRendering)? { videoRenderer }

    @Published private(set) var rendererDegraded = false
    private let renderFailureLock = OSAllocatedUnfairLock<Int>(initialState: 0)
    private let rendererDegradedThreshold = 5

    private let syncTolerance: TimeInterval = 0.04  // 40ms tolerance
    private var packetTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.titanplayer", category: "MediaPipeline")
    
    var currentTime: Double { timeObserver.currentTime }
    var duration: Double { timeObserver.duration }
    var progress: Double { timeObserver.progress }
    
    func setPlaybackRate(_ rate: Float) {
        playbackRate = max(0.25, min(4.0, rate))
    }
    
    func openFile(url: URL, adaptiveManager: AdaptiveDecoderManager? = nil) async throws {
        phase = .loading
        renderFailureLock.withLock { $0 = 0 }
        rendererDegraded = false
        let ext = url.pathExtension.lowercased()
        #if DEBUG
        logger.debug("openFile called for: \(url.path, privacy: .public) (ext: \(ext, privacy: .public))")
        #endif

        switch Self.backend(for: ext) {
        case .avFoundationDirect:
            // Standard container formats — skip FFmpeg probing entirely
            #if DEBUG
            logger.debug("Backend: AVFoundation (direct) for \(ext, privacy: .public)")
            #endif
            let avDemuxer = AVFoundationDemuxer()
            do {
                #if DEBUG
                logger.debug("Starting AVFoundation demuxing for: \(url.path, privacy: .public)")
                #endif
                let info = try await avDemuxer.open(url: url)
                self.mediaInfo = info
                timeObserver.duration = info.duration.seconds
                demuxer = avDemuxer
                decoder = AVFoundationDecoder()
                if let videoTrack = info.videoTracks.first {
                    try decoder?.configure(for: videoTrack)
                    #if DEBUG
                    logger.debug("Decoder configured for video track: \(videoTrack.codec, privacy: .public)")
                    #endif
                }
                phase = .paused
                #if DEBUG
                logger.debug("AVFoundation (direct) demuxing completed, state set to paused")
                #endif
                return
            } catch let error as MediaError {
                let detailed = "\(error.message) — \(ext.uppercased()) file: \(url.lastPathComponent)"
                logger.error("AVFoundation demuxing failed: \(detailed, privacy: .public)")
                throw MediaError(code: error.code, message: detailed)
            }

        case .ffmpegPreferred:
            // Containers where FFmpeg may have better demuxing — try FFmpeg, fall back to AVFoundation
            #if DEBUG
            logger.debug("Backend: attempting FFmpeg for \(ext, privacy: .public)")
            #endif
            let probeDemuxer = FFmpegDemuxer()
            do {
                #if DEBUG
                logger.debug("Starting FFmpeg demuxing for: \(url.path, privacy: .public)")
                #endif
                let info = try await probeDemuxer.open(url: url)
                self.mediaInfo = info
                timeObserver.duration = info.duration.seconds
                #if DEBUG
                logger.debug("FFmpeg demuxing successful, \(info.videoTracks.count, privacy: .public) video track(s), \(info.audioTracks.count, privacy: .public) audio track(s)")
                #endif

                if let videoTrack = info.videoTracks.first, let manager = adaptiveManager {
                    try await manager.configure(for: videoTrack)
                    guard let activeDecoder = manager.activeDecoder else {
                        throw MediaError(code: .decodingFailed, message: "AdaptiveDecoderManager has no active decoder after configure()")
                    }
                    demuxer = probeDemuxer
                    decoder = VideoDecodingAdapter(decoder: activeDecoder)
                    #if DEBUG
                    logger.debug("Adaptive decoder configured for video track")
                    #endif
                } else {
                    demuxer = probeDemuxer
                    decoder = FFmpegDecoder()
                    #if DEBUG
                    logger.debug("FFmpeg decoder configured")
                    #endif
                }

                if let videoTrack = info.videoTracks.first {
                    try decoder?.configure(for: videoTrack)
                    #if DEBUG
                    logger.debug("Decoder configured for video track: \(videoTrack.codec, privacy: .public)")
                    #endif
                }
                #if DEBUG
                logger.debug("Backend: FFmpeg succeeded for \(ext, privacy: .public)")
                #endif
                phase = .paused
                return
            } catch {
                logger.warning("Backend: FFmpeg failed for \(ext, privacy: .public), falling back to AVFoundation — \(error.localizedDescription, privacy: .public)")
                probeDemuxer.close()
            }

        case .avFoundationFallback:
            // Fallback: use AVFoundation
            #if DEBUG
            logger.debug("Backend: AVFoundation (fallback) for \(ext, privacy: .public)")
            #endif
            let avDemuxer = AVFoundationDemuxer()
            do {
                #if DEBUG
                logger.debug("Starting AVFoundation (fallback) demuxing for: \(url.path, privacy: .public)")
                #endif
                let info = try await avDemuxer.open(url: url)
                self.mediaInfo = info
                timeObserver.duration = info.duration.seconds
                demuxer = avDemuxer
                decoder = AVFoundationDecoder()
                if let videoTrack = info.videoTracks.first {
                    try decoder?.configure(for: videoTrack)
                    #if DEBUG
                    logger.debug("Decoder configured for video track: \(videoTrack.codec, privacy: .public)")
                    #endif
                }
                phase = .paused
                #if DEBUG
                logger.debug("AVFoundation (fallback) demuxing completed, state set to paused")
                #endif
                return
            } catch let error as MediaError {
                let detailed = "\(error.message) — \(ext.uppercased()) file: \(url.lastPathComponent)"
                logger.error("AVFoundation (fallback) demuxing failed: \(detailed, privacy: .public)")
                throw MediaError(code: error.code, message: detailed)
            }
        }
    }
    
    func openStream(session: DASHStreamSession) async {
        phase = .loading
        renderFailureLock.withLock { $0 = 0 }
        rendererDegraded = false

        do {
            let info = try await session.open()
            self.mediaInfo = info
            timeObserver.duration = info.duration.seconds

            self.demuxer = session

            if let videoTrack = info.videoTracks.first {
                decoder = FFmpegDecoder()
                try decoder?.configure(for: videoTrack)
            }

            phase = .paused
        } catch {
            phase = .error(error.localizedDescription)
        }
    }
    
    func play(currentState: PlaybackState) {
        phase = .decoding
        timeObserver.startObserving()
        startPacketReading()
    }
    
    func pause(currentState: PlaybackState) {
        phase = .paused
        timeObserver.stopObserving()
        packetTask?.cancel()
    }
    
    func seek(to time: Double) async {
        timeObserver.seekTo(time)
        
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        do {
            try await demuxer?.seek(to: cmTime)
        } catch {
            logger.warning("Demuxer seek failed: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    func stop(currentState: PlaybackState) {
        packetTask?.cancel()
        timeObserver.stopObserving()
        demuxer?.close()
        decoder?.reset()
        renderFailureLock.withLock { $0 = 0 }
        rendererDegraded = false
        phase = .stopped
    }
    
    private func startPacketReading() {
        #if DEBUG
        logger.debug("Starting packet reading loop")
        #endif
        let currentDemuxer = demuxer
        let currentDecoder = decoder
        let currentRenderer = videoRenderer
        let currentSyncProvider = synchronizationProvider
        let log = logger
        packetTask = Task { [weak self] in
            Self.runPacketReadingLoop(
                demuxer: currentDemuxer,
                decoder: currentDecoder,
                renderer: currentRenderer,
                syncProvider: currentSyncProvider,
                timeObserver: self?.timeObserver,
                onRenderFail: { [weak self] error in self?.didRenderFail(error) },
                onRenderSuccess: { [weak self] in self?.didRenderSucceed() },
                logger: log
            )
        }
    }

    /// Nonisolated decode loop — runs entirely off MainActor.
    /// Only the final sync-check + frame-processing hop touches MainActor.
    private nonisolated static func runPacketReadingLoop(
        demuxer: MediaDemuxing?,
        decoder: MediaDecoding?,
        renderer: VideoRenderer,
        syncProvider: SynchronizationProvider?,
        timeObserver: TimeObserver?,
        onRenderFail: @escaping @Sendable (Error) -> Void,
        onRenderSuccess: @escaping @Sendable () -> Void,
        logger: Logger
    ) {
        let syncTolerance: TimeInterval = 0.04

        Task { [demuxer, decoder, renderer, syncProvider, timeObserver, onRenderFail, onRenderSuccess, logger] in
            var frameCount = 0
            while !Task.isCancelled {
                let packet: MediaPacket?
                do {
                    packet = try await demuxer?.nextPacket()
                } catch {
                    logger.warning("Demuxer nextPacket failed: \(error.localizedDescription, privacy: .public)")
                    break
                }
                guard let packet else {
                    #if DEBUG
                    logger.debug("No more packets available, ending packet reading loop")
                    #endif
                    break
                }

                let decodedFrame: MediaFrame?
                do {
                    decodedFrame = try await decoder?.decode(packet)
                } catch {
                    logger.warning("Decoder failed: \(error.localizedDescription, privacy: .public)")
                    continue
                }
                guard let frame = decodedFrame else { continue }
                frameCount += 1
                if frameCount == 1 {
                    #if DEBUG
                    logger.debug("First frame decoded successfully")
                    #endif
                }

                if case let .video(videoFrame) = frame {
                    let framePTS = CMTimeGetSeconds(videoFrame.timestamp)

                    // Snapshot audio clock on background thread — avoids MainActor hop
                    let audioTime = syncProvider?.audioCurrentTime ?? 0
                    let drift = framePTS - audioTime

                    // Drop frame if behind audio clock
                    if drift < -syncTolerance { continue }

                    // Sleep if ahead of audio clock
                    if drift > syncTolerance {
                        let waitTime = min(drift - syncTolerance, 0.05)
                        let nanoseconds = UInt64(waitTime * 1_000_000_000)
                        // try? intentional: Task.sleep throws on cancellation which is handled by the isCancelled check below
                        try? await Task.sleep(nanoseconds: nanoseconds)
                        if Task.isCancelled { break }
                    }

                    // Single MainActor hop: sync check + time update + render dispatch
                    await MainActor.run { [logger] in
                        let freshAudioTime = syncProvider?.audioCurrentTime ?? audioTime
                        let freshDrift = framePTS - freshAudioTime
                        if freshDrift < -syncTolerance { return }

                        if let syncProvider {
                            timeObserver?.updateDrift(audioTime: freshAudioTime, videoTime: framePTS)
                        }
                        timeObserver?.update(to: videoFrame.timestamp)

                        Task { @MainActor in
                            do {
                                try await renderer.render(videoFrame)
                                onRenderSuccess()
                            } catch {
                                onRenderFail(error)
                            }
                        }
                    }
                }
            }
            #if DEBUG
            logger.debug("Packet reading loop ended, total frames decoded: \(frameCount)")
            #endif
        }
    }

    // Test seam — exposes frame processing to XCTest without making it `public`.
    func processFrameForTest(_ frame: MediaFrame) {
        guard case let .video(videoFrame) = frame else { return }
        let framePTS = CMTimeGetSeconds(videoFrame.timestamp)
        let audioTime = synchronizationProvider?.audioCurrentTime ?? 0
        timeObserver.updateDrift(audioTime: audioTime, videoTime: framePTS)
        timeObserver.update(to: videoFrame.timestamp)
        Task { @MainActor in
            do {
                try await videoRenderer.render(videoFrame)
                self.didRenderSucceed()
            } catch {
                self.didRenderFail(error)
            }
        }
    }

    func shouldDropFrameForTest(_ framePTS: TimeInterval) -> Bool {
        guard let provider = synchronizationProvider else { return false }
        let audioTime = provider.audioCurrentTime
        let drift = framePTS - audioTime
        return drift < -syncTolerance
    }
    
    private nonisolated func didRenderFail(_ error: Error) {
        let count = renderFailureLock.withLock { value in
            value += 1
            return value
        }
        let threshold = rendererDegradedThreshold
        logger.warning("Renderer failed (\(count)/\(threshold)): \(error.localizedDescription, privacy: .public)")
        if count >= threshold {
            Task { @MainActor in
                guard !self.rendererDegraded else { return }
                self.rendererDegraded = true
                logger.warning("Renderer marked degraded after \(count) consecutive failures")
            }
        }
    }

    private nonisolated func didRenderSucceed() {
        renderFailureLock.withLock { $0 = 0 }
    }

    init(videoRenderer: VideoRenderer) {
        self.videoRenderer = videoRenderer
    }

    enum MediaBackend {
        case avFoundationDirect
        case ffmpegPreferred
        case avFoundationFallback
    }

    private static let avFoundationDirectExtensions: Set<String> = ["mp4", "mov", "m4v"]
    private static let ffmpegPreferredExtensions: Set<String> = [
        "flv", "mkv", "webm", "ts", "ogv", "wmv", "avi", "3gp", "rm"
    ]

    /// Returns the preferred backend for a given file extension.
    static func backend(for ext: String) -> MediaBackend {
        if avFoundationDirectExtensions.contains(ext) { return .avFoundationDirect }
        if ffmpegPreferredExtensions.contains(ext) { return .ffmpegPreferred }
        return .avFoundationFallback
    }

    private func shouldUseAVFoundation(for info: MediaInfo) -> Bool {
        let supportedCodecs = ["h264", "hevc", "prores", "aac", "alac"]
        return info.videoTracks.allSatisfy { supportedCodecs.contains($0.codec.lowercased()) }
    }
}

extension MediaPipeline: AudioTappable, AudioTapProvider {
    var audioTap: AudioTap? {
        get { decoder?.audioTap }
        set { decoder?.audioTap = newValue }
    }
}
