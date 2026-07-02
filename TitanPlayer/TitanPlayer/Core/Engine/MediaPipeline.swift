import Foundation
import Combine
import CoreMedia
import os

@MainActor
class MediaPipeline: ObservableObject {
    @Published var playState: PlaybackState = .idle
    @Published var mediaInfo: MediaInfo?
    @Published var playbackRate: Float = 1.0
    
    private var demuxer: MediaDemuxing?
    private var decoder: MediaDecoding?
    private let timeObserver = TimeObserver()
    private let videoRenderer: VideoRenderer
    weak var synchronizationProvider: SynchronizationProvider?
    var renderer: (any FrameRendering)? { videoRenderer }

    private let pipelineQueue = DispatchQueue(label: "com.titanplayer.pipeline", qos: .userInitiated)
    private let syncTolerance: TimeInterval = 0.04  // 40ms tolerance
    private let syncSleepInterval: TimeInterval = 0.001  // 1ms sleep when ahead
    private var packetTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.titanplayer", category: "MediaPipeline")
    
    var currentTime: Double { timeObserver.currentTime }
    var duration: Double { timeObserver.duration }
    var progress: Double { timeObserver.progress }
    
    func setPlaybackRate(_ rate: Float) {
        playbackRate = max(0.25, min(4.0, rate))
    }
    
    func openFile(url: URL, adaptiveManager: AdaptiveDecoderManager? = nil) async throws {
        playState = .loading
        let ext = url.pathExtension.lowercased()
        logger.info("openFile called for: \(url.path, privacy: .public) (ext: \(ext, privacy: .public))")

        if Self.shouldUseAVFoundationDirectly(for: ext) {
            // Standard container formats — skip FFmpeg probing entirely
            logger.info("Backend: AVFoundation (direct) for \(ext, privacy: .public)")
            let avDemuxer = AVFoundationDemuxer()
            do {
                logger.info("Starting AVFoundation demuxing for: \(url.path, privacy: .public)")
                let info = try await avDemuxer.open(url: url)
                self.mediaInfo = info
                timeObserver.duration = info.duration.seconds
                demuxer = avDemuxer
                decoder = AVFoundationDecoder()
                if let videoTrack = info.videoTracks.first {
                    try decoder?.configure(for: videoTrack)
                    logger.info("Decoder configured for video track: \(videoTrack.codec, privacy: .public)")
                }
                playState = .paused
                logger.info("AVFoundation (direct) demuxing completed, state set to paused")
                return
            } catch let error as MediaError {
                let detailed = "\(error.message) — \(ext.uppercased()) file: \(url.lastPathComponent)"
                logger.error("AVFoundation demuxing failed: \(detailed, privacy: .public)")
                throw MediaError(code: error.code, message: detailed)
            }
        }

        if Self.shouldTryFFmpegFirst(for: ext) {
            // Containers where FFmpeg may have better demuxing — try FFmpeg, fall back to AVFoundation
            logger.info("Backend: attempting FFmpeg for \(ext, privacy: .public)")
            let probeDemuxer = FFmpegDemuxer()
            do {
                logger.info("Starting FFmpeg demuxing for: \(url.path, privacy: .public)")
                let info = try await probeDemuxer.open(url: url)
                self.mediaInfo = info
                timeObserver.duration = info.duration.seconds
                logger.info("FFmpeg demuxing successful, \(info.videoTracks.count, privacy: .public) video track(s), \(info.audioTracks.count, privacy: .public) audio track(s)")

                if let videoTrack = info.videoTracks.first, let manager = adaptiveManager {
                    try await manager.configure(for: videoTrack)
                    demuxer = probeDemuxer
                    decoder = VideoDecodingAdapter(decoder: manager.activeDecoder!)
                    logger.info("Adaptive decoder configured for video track")
                } else {
                    demuxer = probeDemuxer
                    decoder = FFmpegDecoder()
                    logger.info("FFmpeg decoder configured")
                }

                if let videoTrack = info.videoTracks.first {
                    try decoder?.configure(for: videoTrack)
                    logger.info("Decoder configured for video track: \(videoTrack.codec, privacy: .public)")
                }
                logger.info("Backend: FFmpeg succeeded for \(ext, privacy: .public)")
                playState = .paused
                return
            } catch {
                logger.warning("Backend: FFmpeg failed for \(ext, privacy: .public), falling back to AVFoundation — \(error.localizedDescription, privacy: .public)")
                probeDemuxer.close()
            }
        }

        // Fallback: use AVFoundation
        logger.info("Backend: AVFoundation (fallback) for \(ext, privacy: .public)")
        let avDemuxer = AVFoundationDemuxer()
        do {
            logger.info("Starting AVFoundation (fallback) demuxing for: \(url.path, privacy: .public)")
            let info = try await avDemuxer.open(url: url)
            self.mediaInfo = info
            timeObserver.duration = info.duration.seconds
            demuxer = avDemuxer
            decoder = AVFoundationDecoder()
            if let videoTrack = info.videoTracks.first {
                try decoder?.configure(for: videoTrack)
                logger.info("Decoder configured for video track: \(videoTrack.codec, privacy: .public)")
            }
            playState = .paused
            logger.info("AVFoundation (fallback) demuxing completed, state set to paused")
            return
        } catch let error as MediaError {
            let detailed = "\(error.message) — \(ext.uppercased()) file: \(url.lastPathComponent)"
            logger.error("AVFoundation (fallback) demuxing failed: \(detailed, privacy: .public)")
            throw MediaError(code: error.code, message: detailed)
        }
    }
    
    func openStream(session: DASHStreamSession) async {
        playState = .loading

        do {
            let info = try await session.open()
            self.mediaInfo = info
            timeObserver.duration = info.duration.seconds

            self.demuxer = session

            if let videoTrack = info.videoTracks.first {
                decoder = FFmpegDecoder()
                try decoder?.configure(for: videoTrack)
            }

            playState = .paused
        } catch {
            playState = .error(error.localizedDescription)
        }
    }
    
    func play() {
        guard playState == .paused || playState == .idle else { return }
        playState = .playing
        timeObserver.startObserving()
        startPacketReading()
    }
    
    func pause() {
        guard playState == .playing else { return }
        playState = .paused
        timeObserver.stopObserving()
        packetTask?.cancel()
    }
    
    func seek(to time: Double) async {
        playState = .seeking
        timeObserver.seekTo(time)
        
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        try? await demuxer?.seek(to: cmTime)
        
        if playState == .seeking {
            playState = .playing
        }
    }
    
    func stop() {
        packetTask?.cancel()
        timeObserver.stopObserving()
        demuxer?.close()
        decoder?.reset()
        playState = .idle
    }
    
    private func startPacketReading() {
        logger.info("Starting packet reading loop")
        packetTask = Task { [weak self] in
            guard let self = self else { return }
            
            var frameCount = 0
            while !Task.isCancelled {
                guard let packet = try? await self.demuxer?.nextPacket() else {
                    self.logger.info("No more packets available, ending packet reading loop")
                    break
                }
                
                if let frame = try? await self.decoder?.decode(packet) {
                    frameCount += 1
                    if frameCount == 1 {
                        self.logger.info("First frame decoded successfully")
                    }
                    await MainActor.run {
                        self.processFrame(frame)
                    }
                }
            }
            self.logger.info("Packet reading loop ended, total frames decoded: \(frameCount)")
        }
    }
    
    private func shouldDropFrame(_ framePTS: TimeInterval) -> Bool {
        guard let provider = synchronizationProvider else { return false }
        let audioTime = provider.audioCurrentTime
        let drift = framePTS - audioTime
        // Drop frame if it's behind audio clock beyond tolerance
        return drift < -syncTolerance
    }
    
    private func sleepIfAhead(framePTS: TimeInterval) {
        guard let provider = synchronizationProvider else { return }
        let audioTime = provider.audioCurrentTime
        let drift = framePTS - audioTime
        // Sleep if video is ahead of audio beyond tolerance
        if drift > syncTolerance {
            let sleepTime = min(drift - syncTolerance, 0.05) // Cap at 50ms
            Thread.sleep(forTimeInterval: sleepTime)
        }
    }
    
    private func processFrame(_ frame: MediaFrame) {
        if case let .video(videoFrame) = frame {
            let framePTS = CMTimeGetSeconds(videoFrame.timestamp)
            
            // Synchronization check
            if shouldDropFrame(framePTS) {
                // Frame is behind audio clock, drop it
                return
            }
            
            sleepIfAhead(framePTS: framePTS)
            
            if let provider = synchronizationProvider {
                let audioTime = provider.audioCurrentTime
                timeObserver.updateDrift(audioTime: audioTime, videoTime: framePTS)
            }
            
            timeObserver.update(to: videoFrame.timestamp)
            let currentRenderer = renderer
            Task { @MainActor in
                try? await currentRenderer?.render(videoFrame)
            }
        }
    }

    // Test seam — exposes processFrame to XCTest without making it `public`.
    func processFrameForTest(_ frame: MediaFrame) {
        processFrame(frame)
    }
    
    func shouldDropFrameForTest(_ framePTS: TimeInterval) -> Bool {
        shouldDropFrame(framePTS)
    }
    
    init(videoRenderer: VideoRenderer) {
        self.videoRenderer = videoRenderer
    }

    private static let avFoundationDirectExtensions: Set<String> = ["mp4", "mov", "m4v", "mkv"]
    private static let ffmpegPreferredExtensions: Set<String> = ["flv"]

    /// Standard container formats that AVFoundation handles reliably — bypass FFmpeg entirely.
    static func shouldUseAVFoundationDirectly(for ext: String) -> Bool {
        avFoundationDirectExtensions.contains(ext)
    }

    /// Containers where FFmpeg has better demuxing support — try FFmpeg first, fall back to AVFoundation.
    static func shouldTryFFmpegFirst(for ext: String) -> Bool {
        ffmpegPreferredExtensions.contains(ext)
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
