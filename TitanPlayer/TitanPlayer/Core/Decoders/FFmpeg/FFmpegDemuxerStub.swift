import Foundation
import CoreMedia

#if !TITAN_HAS_FFMPEG
// Compile-time stand-in for `FFmpegDemuxer` when TitanPlayer is built without
// the optional local FFmpeg xcframework. The real implementation (which wraps
// FFmpegBridge) lives in FFmpegDemuxer.swift and is compiled only when
// `TITAN_HAS_FFMPEG` is set.
class FFmpegDemuxer: MediaDemuxing {
    weak var hdrMetadataDelegate: HDRSideDataDelegate?

    func open(url: URL) async throws -> MediaInfo {
        throw MediaError(
            code: .unsupportedFormat,
            message: "FFmpegDemuxer unavailable (built without FFmpeg)"
        )
    }

    func nextPacket() async throws -> MediaPacket {
        throw MediaError(
            code: .decodingFailed,
            message: "FFmpegDemuxer unavailable (built without FFmpeg)"
        )
    }

    func seek(to time: CMTime) async throws {}

    func close() {}
}
#endif
