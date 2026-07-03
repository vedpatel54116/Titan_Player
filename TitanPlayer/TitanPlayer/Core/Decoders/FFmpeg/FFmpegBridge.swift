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

    func openFormatContext(url: String) -> (success: Bool, errorMessage: String?) {
        close()

        var context: UnsafeMutablePointer<AVFormatContext>?
        let cURL = url.withCString { strdup($0) }
        defer { free(cURL) }

        let status = avformat_open_input(&context, cURL, nil, nil)
        guard status == 0, let ctx = context else {
            var errorBuf = [Int8](repeating: 0, count: 256)
            av_strerror(status, &errorBuf, 256)
            let errorString = String(cString: errorBuf)
            return (false, "FFmpeg: \(errorString)")
        }

        formatContext = ctx
        return (true, nil)
    }

    func findStreamInfo() -> (success: Bool, errorMessage: String?) {
        guard let ctx = formatContext else {
            return (false, "FFmpeg: Format context not initialized")
        }
        let status = avformat_find_stream_info(ctx, nil)
        guard status >= 0 else {
            var errorBuf = [Int8](repeating: 0, count: 256)
            av_strerror(status, &errorBuf, 256)
            let errorString = String(cString: errorBuf)
            return (false, "FFmpeg: \(errorString)")
        }
        return (true, nil)
    }

    func findBestStream(type: Int32) -> Int32 {
        guard let ctx = formatContext else { return -1 }
        return av_find_best_stream(ctx, AVMediaType(rawValue: type), -1, -1, nil, 0)
    }

    struct StreamMetadata {
        let index: Int32
        let codecType: Int32   // AVMediaType raw value
        let codecName: String
        let width: Int32
        let height: Int32
        let sampleRate: Int32
        let channels: Int32
        let extradata: Data?
    }

    func getStreamMetadata() -> [StreamMetadata] {
        guard let ctx = formatContext else { return [] }

        let streamCount = Int(ctx.pointee.nb_streams)
        guard streamCount > 0, let streams = ctx.pointee.streams else { return [] }

        var results: [StreamMetadata] = []

        for i in 0..<streamCount {
            guard let stream = streams[i]?.pointee else { continue }
            let codecpar = stream.codecpar.pointee

            let codecID = codecpar.codec_id
            let codecName: String
            if let name = avcodec_get_name(codecID) {
                codecName = String(cString: name)
            } else {
                codecName = "unknown"
            }

            let extradata: Data?
            if let ed = codecpar.extradata, codecpar.extradata_size > 0 {
                extradata = Data(bytes: ed, count: Int(codecpar.extradata_size))
            } else {
                extradata = nil
            }

            results.append(StreamMetadata(
                index: Int32(i),
                codecType: codecpar.codec_type.rawValue,
                codecName: codecName,
                width: codecpar.width,
                height: codecpar.height,
                sampleRate: codecpar.sample_rate,
                channels: codecpar.ch_layout.nb_channels,
                extradata: extradata
            ))
        }

        return results
    }

    func getDuration() -> Int64 {
        guard let ctx = formatContext else { return 0 }
        let duration = ctx.pointee.duration
        return duration != Int64.min ? duration : 0
    }

    func readFrame() -> (data: Data, timestamp: Int64, duration: Int64, isKeyFrame: Bool, streamIndex: Int32)? {
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
        let streamIndex = pkt.stream_index

        return (data: data, timestamp: timestamp, duration: duration, isKeyFrame: isKeyFrame, streamIndex: streamIndex)
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
