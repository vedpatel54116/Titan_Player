import Foundation
import Combine
import CoreMedia

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
    
    var currentTime: Double { timeObserver.currentTime }
    var duration: Double { timeObserver.duration }
    var progress: Double { timeObserver.progress }
    
    func setPlaybackRate(_ rate: Float) {
        playbackRate = max(0.25, min(4.0, rate))
    }
    
    func openFile(url: URL, adaptiveManager: AdaptiveDecoderManager? = nil) async throws {
        playState = .loading

        let probeDemuxer = FFmpegDemuxer()
        let info = try await probeDemuxer.open(url: url)

        self.mediaInfo = info
        timeObserver.duration = info.duration.seconds

        if let videoTrack = info.videoTracks.first, let manager = adaptiveManager {
            // Use AdaptiveDecoderManager for real decoding
            // configure() handles hardware→software fallback internally
            try await manager.configure(for: videoTrack)
            demuxer = probeDemuxer
            decoder = VideoDecodingAdapter(decoder: manager.activeDecoder!)
        } else if shouldUseAVFoundation(for: info) {
            probeDemuxer.close()
            let avDemuxer = AVFoundationDemuxer()
            decoder = AVFoundationDecoder()
            _ = try await avDemuxer.open(url: url)
            demuxer = avDemuxer
        } else {
            demuxer = probeDemuxer
            decoder = FFmpegDecoder()
        }

        if let videoTrack = info.videoTracks.first {
            try decoder?.configure(for: videoTrack)
        }

        playState = .paused
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
        packetTask = Task { [weak self] in
            guard let self = self else { return }
            
            while !Task.isCancelled {
                guard let packet = try? await self.demuxer?.nextPacket() else {
                    break
                }
                
                if let frame = try? await self.decoder?.decode(packet) {
                    await MainActor.run {
                        self.processFrame(frame)
                    }
                }
            }
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

    private func shouldUseAVFoundation(for info: MediaInfo) -> Bool {
        // Determine if AVFoundation can handle this format
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
