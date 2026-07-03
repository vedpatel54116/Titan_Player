import Foundation
import CoreVideo
import CoreMedia

class FFmpegDecoder: MediaDecoding {
    var audioTap: ((AudioFrame) -> Void)?

    func configure(for track: VideoTrackInfo) throws {
        // Find and open appropriate codec
    }
    
    func decode(_ packet: MediaPacket) async throws -> MediaFrame {
        var pixelBuffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary
        
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            1920, 1080,
            kCVPixelFormatType_32BGRA,
            attrs,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw MediaError(code: .decodingFailed, message: "FFmpegDecoder: CVPixelBufferCreate failed (\(status))")
        }
        
        return .video(VideoFrame(
            pixelBuffer: pixelBuffer,
            timestamp: packet.timestamp,
            duration: packet.duration,
            colorSpace: .sRGB,
            sampleBuffer: nil
        ))
    }
    
    func flush() {
        // Flush codec context
    }
    
    func reset() {
        // Reset decoder state
    }
}
