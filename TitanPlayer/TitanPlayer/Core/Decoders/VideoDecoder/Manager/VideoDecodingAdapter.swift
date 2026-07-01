import Foundation
import CoreMedia
import CoreVideo

/// Bridges a `VideoDecoding` conformer to the `MediaDecoding` protocol
/// so MediaPipeline can use VideoToolboxDecoder / FFmpegSoftwareDecoder.
final class VideoDecodingAdapter: MediaDecoding {
    private let decoder: VideoDecoding
    var audioTap: AudioTap?

    init(decoder: VideoDecoding) {
        self.decoder = decoder
    }

    func configure(for track: VideoTrackInfo) throws {
        // No-op: the underlying decoder is already configured by AdaptiveDecoderManager
        // before this adapter is created.
    }

    func decode(_ packet: MediaPacket) async throws -> MediaFrame {
        let output = try await decoder.decode(packet)
        switch output {
        case .sampleBuffer(let sampleBuffer):
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                throw DecoderError.noFramesDecoded
            }
            let videoFrame = VideoFrame(
                pixelBuffer: pixelBuffer,
                timestamp: packet.timestamp,
                duration: packet.duration,
                colorSpace: .sRGB
            )
            return .video(videoFrame)
        case .pixelBuffer(let pixelBuffer):
            let videoFrame = VideoFrame(
                pixelBuffer: pixelBuffer,
                timestamp: packet.timestamp,
                duration: packet.duration,
                colorSpace: .sRGB
            )
            return .video(videoFrame)
        }
    }

    func flush() async { await decoder.flush() }
    func reset() async { await decoder.reset() }
}
