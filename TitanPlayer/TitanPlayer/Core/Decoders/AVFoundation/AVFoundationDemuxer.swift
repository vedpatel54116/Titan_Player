import AVFoundation
import CoreMedia

class AVFoundationDemuxer: MediaDemuxing {
    private var asset: AVURLAsset?
    private var assetReader: AVAssetReader?
    private var videoOutput: AVAssetReaderTrackOutput?
    private var audioOutput: AVAssetReaderTrackOutput?
    private var startTime: CMTime = .zero
    
    func open(url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        self.asset = asset
        
        guard let reader = try? AVAssetReader(asset: asset) else {
            throw MediaError(code: .decodingFailed, message: "Failed to create asset reader")
        }
        self.assetReader = reader
        
        let duration = try await asset.load(.duration)
        var videoTracks: [VideoTrackInfo] = []
        var audioTracks: [AudioTrackInfo] = []
        
        // Simplified track loading - in production, use proper async APIs
        videoTracks.append(VideoTrackInfo(
            codec: "h264",
            width: 1920,
            height: 1080,
            frameRate: 30.0,
            isHDR: false,
            extradata: nil
        ))
        
        audioTracks.append(AudioTrackInfo(
            codec: "aac",
            sampleRate: 44100,
            channels: 2,
            language: nil
        ))
        
        return MediaInfo(
            duration: duration,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            subtitleTracks: [],
            format: url.pathExtension.uppercased()
        )
    }
    
    func nextPacket() async throws -> MediaPacket {
        guard let reader = assetReader, reader.status == .reading else {
            throw MediaError(code: .decodingFailed, message: "Reader not ready")
        }
        
        if let output = videoOutput, let sampleBuffer = output.copyNextSampleBuffer() {
            let timestamp = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer)
            let duration = CMSampleBufferGetOutputDuration(sampleBuffer)
            
            guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                throw MediaError(code: .decodingFailed, message: "No data buffer")
            }
            
            var length: Int = 0
            let _ = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: nil)
            
            return MediaPacket(
                streamIndex: 0,
                data: Data(),
                timestamp: timestamp,
                duration: duration,
                isKeyFrame: true
            )
        }
        
        throw MediaError(code: .decodingFailed, message: "No more packets")
    }
    
    func seek(to time: CMTime) async throws {
        startTime = time
    }
    
    func close() {
        assetReader?.cancelReading()
        assetReader = nil
    }
}
