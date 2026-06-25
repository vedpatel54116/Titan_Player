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
    
    private let pipelineQueue = DispatchQueue(label: "com.titanplayer.pipeline", qos: .userInitiated)
    private var packetTask: Task<Void, Never>?
    
    var currentTime: Double { timeObserver.currentTime }
    var duration: Double { timeObserver.duration }
    var progress: Double { timeObserver.progress }
    
    func setPlaybackRate(_ rate: Float) {
        playbackRate = max(0.25, min(4.0, rate))
    }
    
    func openFile(url: URL) async {
        playState = .loading
        
        do {
            // Probe file to determine backend
            let probeDemuxer = FFmpegDemuxer()
            let info = try await probeDemuxer.open(url: url)
            probeDemuxer.close()
            
            self.mediaInfo = info
            timeObserver.duration = info.duration.seconds
            
            // Select appropriate backend
            if shouldUseAVFoundation(for: info) {
                demuxer = AVFoundationDemuxer()
                decoder = AVFoundationDecoder()
            } else {
                demuxer = FFmpegDemuxer()
                decoder = FFmpegDecoder()
            }
            
            // Open with selected backend
            _ = try await demuxer?.open(url: url)
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
    
    private func processFrame(_ frame: MediaFrame) {
        // Route frame to appropriate renderer
    }
    
    private func shouldUseAVFoundation(for info: MediaInfo) -> Bool {
        // Determine if AVFoundation can handle this format
        let supportedCodecs = ["h264", "hevc", "prores", "aac", "alac"]
        return info.videoTracks.allSatisfy { supportedCodecs.contains($0.codec.lowercased()) }
    }
}
