import Foundation
import CoreMedia
import os

class FFmpegDemuxer: MediaDemuxing {
    private var isOpen = false
    private let bridge = FFmpegBridge()
    private let demuxLock = OSAllocatedUnfairLock()

    func open(url: URL) async throws -> MediaInfo {
        FFmpegBridge.initialize()

        let openResult = bridge.openFormatContext(url: url.path)
        guard openResult.success else {
            let detail = openResult.errorMessage ?? "FFmpeg: Unknown error opening format context"
            throw MediaError(code: .fileNotFound, message: "\(detail) — \(url.lastPathComponent)")
        }

        let infoResult = bridge.findStreamInfo()
        guard infoResult.success else {
            let detail = infoResult.errorMessage ?? "FFmpeg: Unknown error finding stream info"
            throw MediaError(code: .unsupportedFormat, message: "\(detail) — \(url.lastPathComponent)")
        }

        let streams = bridge.getStreamMetadata()

        var videoTracks: [VideoTrackInfo] = []
        var audioTracks: [AudioTrackInfo] = []
        var subtitleTracks: [SubtitleTrackInfo] = []

        for stream in streams {
            // AVMEDIA_TYPE_VIDEO = 0, AVMEDIA_TYPE_AUDIO = 1, AVMEDIA_TYPE_SUBTITLE = 3
            switch stream.codecType {
            case 0: // video
                let track = VideoTrackInfo(
                    codec: stream.codecName,
                    width: Int(stream.width),
                    height: Int(stream.height),
                    frameRate: 0,
                    isHDR: false,
                    extradata: stream.extradata
                )
                videoTracks.append(track)
            case 1: // audio
                let track = AudioTrackInfo(
                    codec: stream.codecName,
                    sampleRate: Int(stream.sampleRate),
                    channels: Int(stream.channels),
                    language: nil
                )
                audioTracks.append(track)
            case 3: // subtitle
                let track = SubtitleTrackInfo(
                    codec: stream.codecName,
                    language: nil,
                    isForced: false
                )
                subtitleTracks.append(track)
            default:
                break
            }
        }

        let durationUs = bridge.getDuration()
        let avTimeBase: Int64 = 1_000_000
        let durationSeconds = Double(durationUs) / Double(avTimeBase)
        let duration = CMTime(seconds: durationSeconds, preferredTimescale: 600)

        isOpen = true

        return MediaInfo(
            duration: duration,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks,
            format: url.pathExtension.uppercased()
        )
    }

    func nextPacket() async throws -> MediaPacket {
        guard isOpen else {
            throw MediaError(code: .decodingFailed, message: "Demuxer not opened")
        }

        return try demuxLock.withLock {
            guard let result = bridge.readFrame() else {
                throw MediaError(code: .decodingFailed, message: "Failed to read frame")
            }

            guard Int(result.streamIndex) >= 0 else {
                throw MediaError(code: .decodingFailed, message: "Invalid stream index \(result.streamIndex)")
            }

            return MediaPacket(
                streamIndex: Int(result.streamIndex),
                data: result.data,
                timestamp: CMTime(value: result.timestamp, timescale: 600),
                duration: CMTime(value: result.duration, timescale: 600),
                isKeyFrame: result.isKeyFrame
            )
        }
    }

    func seek(to time: CMTime) async throws {
        let timestamp = Int64(time.seconds * 600)
        demuxLock.withLock {
            _ = bridge.seekFrame(timestamp: timestamp, flags: 0)
        }
    }

    func close() {
        isOpen = false
        bridge.close()
    }
}
