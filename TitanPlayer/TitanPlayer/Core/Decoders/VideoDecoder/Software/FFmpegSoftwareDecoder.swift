import Foundation
import CoreMedia
import CoreVideo
import Libavcodec
import Libavutil
import Libswscale
import os

// swiftlint:disable identifier_name
// FFmpeg C enum constants may not bridge from xcframeworks when building
// via the Xcode project (only via SPM).  Provide raw-value fallbacks.
#if !SWIFT_PACKAGE
private let _AV_PIX_FMT_P010LE = AVPixelFormat(rawValue: 126)
private let _AV_PIX_FMT_NV12   = AVPixelFormat(rawValue: 23)
private let _AV_CODEC_ID_H264        = AVCodecID(rawValue: 27)
private let _AV_CODEC_ID_HEVC        = AVCodecID(rawValue: 173)
private let _AV_CODEC_ID_VP9         = AVCodecID(rawValue: 167)
private let _AV_CODEC_ID_AV1         = AVCodecID(rawValue: 32779)
private let _AV_CODEC_ID_MPEG2VIDEO  = AVCodecID(rawValue: 2)
private let _AV_CODEC_ID_VC1         = AVCodecID(rawValue: 70)
private let _AV_INPUT_BUFFER_PADDING_SIZE = 32
private let _FF_THREAD_FRAME: Int32 = 1
#else
private let _AV_PIX_FMT_P010LE = AV_PIX_FMT_P010LE
private let _AV_PIX_FMT_NV12   = AV_PIX_FMT_NV12
private let _AV_CODEC_ID_H264        = AV_CODEC_ID_H264
private let _AV_CODEC_ID_HEVC        = AV_CODEC_ID_HEVC
private let _AV_CODEC_ID_VP9         = AV_CODEC_ID_VP9
private let _AV_CODEC_ID_AV1         = AV_CODEC_ID_AV1
private let _AV_CODEC_ID_MPEG2VIDEO  = AV_CODEC_ID_MPEG2VIDEO
private let _AV_CODEC_ID_VC1         = AV_CODEC_ID_VC1
private let _AV_INPUT_BUFFER_PADDING_SIZE = AV_INPUT_BUFFER_PADDING_SIZE
private let _FF_THREAD_FRAME = FF_THREAD_FRAME
#endif

// MARK: - FFmpeg Software Decoder

// SAFETY: All mutable state is protected by `lock` (OSAllocatedUnfairLock).
// All access paths acquire the lock before reading or writing.
final class FFmpegSoftwareDecoder: VideoDecoding, @unchecked Sendable {
    let outputFormat: DecoderOutputFormat = .pixelBuffer
    let capabilities: DecoderCapabilities
    private(set) var state: DecoderState = .idle

    private let lock = OSAllocatedUnfairLock()

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var swsContext: UnsafeMutablePointer<SwsContext>?
    private var currentCodec: VideoCodec?
    private var trackWidth: Int = 0
    private var trackHeight: Int = 0
    private var trackIsHDR: Bool = false

    private var decodedQueue: [CVPixelBuffer] = []

    private var decodeTimings: [TimeInterval] = []
    private let maxTimingSamples = 100

    init() {
        self.capabilities = DecoderCapabilities(from: SoftwareCapabilities.query())
    }

    // MARK: - Configuration

    func configure(for track: VideoTrackInfo) async throws {
        try lock.withLock {
            guard let videoCodec = VideoCodec(rawValue: track.codec),
                  SoftwareCapabilities.isCodecSupported(videoCodec) else {
                state = .error(.unsupportedCodec(track.codec))
                throw DecoderError.unsupportedCodec(track.codec)
            }

            currentCodec = videoCodec
            trackWidth = track.width
            trackHeight = track.height
            trackIsHDR = track.isHDR

            teardownCodecContext()

            let codecID = FFmpegSoftwareDecoder.avCodecID(for: videoCodec)
            guard let codec = avcodec_find_decoder(codecID) else {
                state = .error(.unsupportedCodec(track.codec))
                throw DecoderError.unsupportedCodec(track.codec)
            }

            guard let ctx = avcodec_alloc_context3(codec) else {
                state = .error(.softwareFailure)
                throw DecoderError.softwareFailure
            }
            codecContext = ctx
            ctx.pointee.width = Int32(track.width)
            ctx.pointee.height = Int32(track.height)
            ctx.pointee.pix_fmt = track.isHDR ? _AV_PIX_FMT_P010LE : _AV_PIX_FMT_NV12
            ctx.pointee.thread_count = 0
            ctx.pointee.thread_type = _FF_THREAD_FRAME

            // Copy extradata (SPS/PPS/VPS) into codec context
            if let extradata = track.extradata, !extradata.isEmpty {
                let extradataSize = extradata.count
                let buffer = av_mallocz(extradataSize + Int(_AV_INPUT_BUFFER_PADDING_SIZE))
                guard let buffer = buffer else {
                    teardownCodecContext()
                    state = .error(.softwareFailure)
                    throw DecoderError.softwareFailure
                }
                extradata.withUnsafeBytes { rawBuffer in
                    if let base = rawBuffer.baseAddress {
                        memcpy(buffer, base, extradataSize)
                    }
                }
                ctx.pointee.extradata = buffer.assumingMemoryBound(to: UInt8.self)
                ctx.pointee.extradata_size = Int32(extradataSize)
            }

            let openStatus = avcodec_open2(codecContext, codec, nil)
            guard openStatus == 0 else {
                teardownCodecContext()
                state = .error(.softwareFailure)
                throw DecoderError.softwareFailure
            }

            state = .configured
        }
    }

    // MARK: - Decoding

    func decode(_ packet: MediaPacket) async throws -> DecoderOutput {
        try lock.withLock {
            guard let codecContext = codecContext else {
                throw DecoderError.sessionNotConfigured
            }

            let startTime = CFAbsoluteTimeGetCurrent()

            var avPacketOpt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
            guard let avPacket = avPacketOpt else {
                throw DecoderError.softwareFailure
            }
            defer { av_packet_free(&avPacketOpt) }

            let dataCount = packet.data.count
            let bufStatus = av_new_packet(avPacket, Int32(dataCount))
            guard bufStatus == 0 else {
                throw DecoderError.softwareFailure
            }

            packet.data.withUnsafeBytes { rawBuffer in
                if let base = rawBuffer.baseAddress {
                    memcpy(avPacket.pointee.data, base, dataCount)
                }
            }

            avPacket.pointee.pts = Int64(packet.timestamp.value)
            avPacket.pointee.dts = Int64(packet.timestamp.value)
            avPacket.pointee.duration = Int64(packet.duration.value)
            avPacket.pointee.flags = packet.isKeyFrame ? AV_PKT_FLAG_KEY : 0

            let sendStatus = avcodec_send_packet(codecContext, avPacket)
            let eagain = -Int32(EAGAIN)
            if sendStatus != 0 && sendStatus != eagain {
                recordTimingUnlocked(CFAbsoluteTimeGetCurrent() - startTime)
                throw DecoderError.softwareFailure
            }

            while true {
                var frameOpt: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
                guard let frame = frameOpt else { break }
                let recvStatus = avcodec_receive_frame(codecContext, frame)
                if recvStatus == 0 {
                    if let pixelBuffer = convertFrameToPixelBuffer(frame) {
                        decodedQueue.append(pixelBuffer)
                    }
                } else {
                    av_frame_free(&frameOpt)
                    break
                }
                av_frame_free(&frameOpt)
            }

            recordTimingUnlocked(CFAbsoluteTimeGetCurrent() - startTime)

            guard let output = decodedQueue.first else {
                throw DecoderError.noFramesDecoded
            }
            decodedQueue.removeFirst()

            return .pixelBuffer(output)
        }
    }

    // MARK: - Lifecycle

    func flush() async {
        lock.withLock {
            state = .flushing
            if let codecContext = codecContext {
                avcodec_flush_buffers(codecContext)
            }
            decodedQueue.removeAll()
            state = .configured
        }
    }

    func reset() async {
        await flush()
    }

    func invalidate() async {
        lock.withLock {
            teardownCodecContext()
            decodedQueue.removeAll()
            currentCodec = nil
            trackWidth = 0
            trackHeight = 0
            trackIsHDR = false
            state = .idle
        }
    }

    // MARK: - Private Helpers

    private func teardownCodecContext() {
        if let sws = swsContext {
            var swsPtr: UnsafeMutablePointer<SwsContext>? = sws
            sws_free_context(&swsPtr)
            swsContext = nil
        }
        if let ctx = codecContext {
            var ctxPtr: UnsafeMutablePointer<AVCodecContext>? = ctx
            avcodec_free_context(&ctxPtr)
            codecContext = nil
        }
    }

    private func convertFrameToPixelBuffer(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        guard width > 0, height > 0 else { return nil }

        let srcFormat = AVPixelFormat(rawValue: frame.pointee.format)

        guard let pixelBuffer = createPixelBuffer(width: width, height: height) else { return nil }

        ensureScaler(srcWidth: width, srcHeight: height, srcFormat: srcFormat)
        guard let sws = swsContext else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])

        let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        let srcData: [UnsafePointer<UInt8>?] = [
            frame.pointee.data.0.map { UnsafePointer($0) },
            frame.pointee.data.1.map { UnsafePointer($0) },
            frame.pointee.data.2.map { UnsafePointer($0) },
            frame.pointee.data.3.map { UnsafePointer($0) },
        ]
        let srcStride: [Int32] = [
            frame.pointee.linesize.0,
            frame.pointee.linesize.1,
            frame.pointee.linesize.2,
            frame.pointee.linesize.3,
        ]

        var dstData: [UnsafeMutablePointer<UInt8>?] = [
            yBase?.assumingMemoryBound(to: UInt8.self),
            uvBase?.assumingMemoryBound(to: UInt8.self),
            nil, nil,
        ]
        var dstStride: [Int32] = [Int32(yStride), Int32(uvStride), 0, 0]

        srcData.withUnsafeBufferPointer { srcPtr in
            srcStride.withUnsafeBufferPointer { srcStridePtr in
                dstData.withUnsafeMutableBufferPointer { dstPtr in
                    dstStride.withUnsafeMutableBufferPointer { dstStridePtr in
                        _ = sws_scale(
                            sws,
                            srcPtr.baseAddress,
                            srcStridePtr.baseAddress,
                            0, Int32(height),
                            dstPtr.baseAddress,
                            dstStridePtr.baseAddress
                        )
                    }
                }
            }
        }

        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        return pixelBuffer
    }

    private func ensureScaler(srcWidth: Int, srcHeight: Int, srcFormat: AVPixelFormat) {
        if swsContext != nil { return }
        let dstFormat: AVPixelFormat = trackIsHDR ? _AV_PIX_FMT_P010LE : _AV_PIX_FMT_NV12
        swsContext = sws_getContext(
            Int32(srcWidth), Int32(srcHeight), srcFormat,
            Int32(srcWidth), Int32(srcHeight), dstFormat,
            Int32(bitPattern: SWS_BILINEAR.rawValue),
            nil, nil, nil
        )
    }

    private func createPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let pixelFormat: OSType = trackIsHDR
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attrs as CFDictionary,
            &pixelBuffer
        )

        return status == noErr ? pixelBuffer : nil
    }

    private func recordTimingUnlocked(_ timing: TimeInterval) {
        decodeTimings.append(timing)
        if decodeTimings.count > maxTimingSamples {
            decodeTimings.removeFirst()
        }
    }

    var averageDecodeTime: TimeInterval {
        lock.withLock {
            guard !decodeTimings.isEmpty else { return 0 }
            return decodeTimings.reduce(0, +) / Double(decodeTimings.count)
        }
    }

    // MARK: - Codec Mapping

    static func avCodecID(for codec: VideoCodec) -> AVCodecID {
        switch codec {
        case .h264:   return _AV_CODEC_ID_H264
        case .hevc:   return _AV_CODEC_ID_HEVC
        case .vp9:    return _AV_CODEC_ID_VP9
        case .av1:    return _AV_CODEC_ID_AV1
        case .mpeg2:  return _AV_CODEC_ID_MPEG2VIDEO
        case .vc1:    return _AV_CODEC_ID_VC1
        }
    }
}
