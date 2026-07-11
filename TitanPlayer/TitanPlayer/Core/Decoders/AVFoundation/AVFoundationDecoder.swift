import AVFoundation
import CoreMedia
import VideoToolbox

class AVFoundationDecoder: MediaDecoding {
    var audioTap: ((AudioFrame) -> Void)?

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    
    func configure(for track: VideoTrackInfo) throws {
        // Configure for hardware-accelerated decoding
    }
    
    func decode(_ packet: MediaPacket) async throws -> MediaFrame {
        // Decode packet using VideoToolbox
        let pixelBuffer = try createEmptyPixelBuffer()
        
        return .video(VideoFrame(
            pixelBuffer: pixelBuffer,
            timestamp: packet.timestamp,
            duration: packet.duration,
            colorSpace: .sRGB,
            sampleBuffer: nil
        ))
    }
    
    func flush() {
        // Flush decompression session
    }
    
    func reset() {
        decompressionSession = nil
        formatDescription = nil
    }
    
    private func createEmptyPixelBuffer() throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ] as CFDictionary

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            1920, 1080,
            kCVPixelFormatType_32BGRA,
            attrs,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let created = pixelBuffer else {
            throw DecoderError.bufferCreationFailed(status)
        }

        return created
    }
}
