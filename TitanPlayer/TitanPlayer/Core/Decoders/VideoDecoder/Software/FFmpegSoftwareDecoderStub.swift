import Foundation
import CoreMedia
import CoreVideo

#if !TITAN_HAS_FFMPEG
// Compile-time stand-in for `FFmpegSoftwareDecoder` when TitanPlayer is built
// without the optional local FFmpeg xcframework. It lets the decoder-selection
// machinery (DecoderSelector / AdaptiveDecoderManager) and `swift test` compile
// on machines that have not run `make ffmpeg`. The real implementation lives in
// FFmpegSoftwareDecoder.swift, compiled only when `TITAN_HAS_FFMPEG` is set.
final class FFmpegSoftwareDecoder: VideoDecoding, @unchecked Sendable {
    let outputFormat: DecoderOutputFormat = .pixelBuffer
    let capabilities: DecoderCapabilities = .default
    private(set) var state: DecoderState = .idle

    func configure(for track: VideoTrackInfo) async throws {
        state = .configured
    }

    func decode(_ packet: MediaPacket) async throws -> DecoderOutput {
        throw DecoderError.unsupportedCodec(
            "FFmpeg software decoder unavailable (built without FFmpeg)"
        )
    }

    func invalidate() async {
        state = .idle
    }
}
#endif
