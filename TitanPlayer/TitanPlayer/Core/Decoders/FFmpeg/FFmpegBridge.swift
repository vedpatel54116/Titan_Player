import Foundation
import Libavformat
import Libavcodec
import Libavutil

final class FFmpegBridge {
    private var formatContext: UnsafeMutablePointer<AVFormatContext>?
    private var ioContext: UnsafeMutablePointer<AVIOContext>?

    deinit {
        close()
    }

    // MARK: - Public API

    static func initialize() {
        // FFmpeg 4.x+ auto-registers all formats/codecs at link time.
        // Network init is not needed (disabled at build time).
    }

    func openFormatContext(url: String) -> Bool {
        close()

        var context: UnsafeMutablePointer<AVFormatContext>?
        let cURL = url.withCString { strdup($0) }
        defer { free(cURL) }

        let status = avformat_open_input(&context, cURL, nil, nil)
        guard status == 0, let ctx = context else {
            return false
        }

        formatContext = ctx
        return true
    }

    func findStreamInfo() -> Int32 {
        guard let ctx = formatContext else { return -1 }
        return avformat_find_stream_info(ctx, nil)
    }

    func findBestStream(type: Int32) -> Int32 {
        guard let ctx = formatContext else { return -1 }
        return av_find_best_stream(ctx, AVMediaType(rawValue: type), -1, -1, nil, 0)
    }

    func readFrame() -> (data: Data, timestamp: Int64, duration: Int64, isKeyFrame: Bool)? {
        guard let ctx = formatContext else { return nil }

        var packetOpt: UnsafeMutablePointer<AVPacket>?
        guard let packet = av_packet_alloc() else { return nil }
        packetOpt = packet
        defer { av_packet_free(&packetOpt) }

        let status = av_read_frame(ctx, packet)
        guard status >= 0 else { return nil }

        let pkt = packet.pointee

        let data: Data
        if let buf = pkt.data, pkt.size > 0 {
            data = Data(bytes: buf, count: Int(pkt.size))
        } else {
            data = Data()
        }

        // AV_NOPTS_VALUE = Int64.min (0x8000000000000000)
        let noPTS = Int64.min
        let timestamp = pkt.pts != noPTS ? pkt.pts : pkt.dts
        let duration = pkt.duration
        let isKeyFrame = (pkt.flags & 1) != 0  // AV_PKT_FLAG_KEY = 0x0001

        return (data: data, timestamp: timestamp, duration: duration, isKeyFrame: isKeyFrame)
    }

    func seekFrame(timestamp: Int64, flags: Int32) -> Int32 {
        guard let ctx = formatContext else { return -1 }
        return av_seek_frame(ctx, -1, timestamp, flags)
    }

    func close() {
        if formatContext != nil {
            avformat_close_input(&formatContext)
        }
        if ioContext != nil {
            avio_closep(&ioContext)
        }
    }
}
