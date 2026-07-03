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
            let colorSpace = Self.detectColorSpace(from: sampleBuffer)
            let videoFrame = VideoFrame(
                pixelBuffer: pixelBuffer,
                timestamp: packet.timestamp,
                duration: packet.duration,
                colorSpace: colorSpace,
                sampleBuffer: sampleBuffer
            )
            return .video(videoFrame)
        case .pixelBuffer(let pixelBuffer):
            let videoFrame = VideoFrame(
                pixelBuffer: pixelBuffer,
                timestamp: packet.timestamp,
                duration: packet.duration,
                colorSpace: .sRGB,
                sampleBuffer: nil
            )
            return .video(videoFrame)
        }
    }

    private static func detectColorSpace(from sampleBuffer: CMSampleBuffer) -> ColorSpace {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return .sRGB
        }
        if let colorPrimaries = CMFormatDescriptionGetExtension(
            formatDesc,
            extensionKey: kCMFormatDescriptionExtension_ColorPrimaries
        ) as? String {
            if colorPrimaries == (kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String) {
                return .bt2020
            }
        }
        return .sRGB
    }

    func flush() async { await decoder.flush() }
    func reset() async { await decoder.reset() }
}
