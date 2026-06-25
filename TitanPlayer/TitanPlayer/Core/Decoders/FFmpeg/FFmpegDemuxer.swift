import Foundation
import CoreMedia

class FFmpegDemuxer: MediaDemuxing {
    private var isOpen = false
    
    func open(url: URL) async throws -> MediaInfo {
        FFmpegBridge.initialize()
        
        guard FFmpegBridge.openFormatContext(url: url.path) else {
            throw MediaError(code: .fileNotFound, message: "Failed to open file: \(url.lastPathComponent)")
        }
        
        let result = FFmpegBridge.findStreamInfo()
        guard result >= 0 else {
            throw MediaError(code: .unsupportedFormat, message: "Failed to find stream info")
        }
        
        let videoIndex = FFmpegBridge.findBestStream(type: 0) // AVMEDIA_TYPE_VIDEO
        let audioIndex = FFmpegBridge.findBestStream(type: 1) // AVMEDIA_TYPE_AUDIO
        
        isOpen = true
        
        return MediaInfo(
            duration: CMTime(seconds: 0, preferredTimescale: 600), // Placeholder
            videoTracks: [],
            audioTracks: [],
            subtitleTracks: [],
            format: url.pathExtension.uppercased()
        )
    }
    
    func nextPacket() async throws -> MediaPacket {
        guard isOpen else {
            throw MediaError(code: .decodingFailed, message: "Demuxer not opened")
        }
        
        guard let result = FFmpegBridge.readFrame() else {
            throw MediaError(code: .decodingFailed, message: "Failed to read frame")
        }
        
        return MediaPacket(
            streamIndex: 0,
            data: result.data,
            timestamp: CMTime(value: result.timestamp, timescale: 600),
            duration: CMTime(value: result.duration, timescale: 600),
            isKeyFrame: result.isKeyFrame
        )
    }
    
    func seek(to time: CMTime) async throws {
        let timestamp = Int64(time.seconds * 600)
        FFmpegBridge.seekFrame(timestamp: timestamp, flags: 0)
    }
    
    func close() {
        isOpen = false
    }
}
