import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import os

// MARK: - VideoToolbox Decoder

final class VideoToolboxDecoder: VideoDecoding, @unchecked Sendable {
    let outputFormat: DecoderOutputFormat = .sampleBuffer
    let capabilities: DecoderCapabilities
    private(set) var state: DecoderState = .idle

    private let lock = OSAllocatedUnfairLock()
    private let decoderLogger = Logger(subsystem: "com.titanplayer", category: "VideoToolboxDecoder")

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var pixelBufferPool: CVPixelBufferPool?

    // Documented value of `kVTVideoDecoderBadDataErr` (-12909). Defined
    // locally so we don't depend on the exact SDK symbol availability.
    private let videoDecoderBadDataErr: OSStatus = -12909

    // The pixel format actually negotiated for the decompression session.
    private var _negotiatedPixelFormat: OSType?
    var negotiatedPixelFormat: OSType? { lock.withLock { _negotiatedPixelFormat } }

    private(set) var isUsingHardwareAcceleration: Bool = false

    private var pendingContinuation: CheckedContinuation<CMSampleBuffer, Error>?

    private var decodeTimings: [TimeInterval] = []
    private let maxTimingSamples = 100

    init() {
        self.capabilities = DecoderCapabilities(from: HardwareCapabilities.query())
    }

    // MARK: - Configuration

    func configure(for track: VideoTrackInfo) async throws {
        try configureSync(for: track)
    }

    private func configureSync(for track: VideoTrackInfo) throws {
        try lock.withLock {
            guard let videoCodec = VideoCodec(rawValue: track.codec),
                  HardwareCapabilities.isCodecSupported(videoCodec) else {
                state = .error(.unsupportedCodec(track.codec))
                throw DecoderError.unsupportedCodec(track.codec)
            }

            invalidateSessionUnlocked()

            guard let formatDesc = ParameterSetParser.parseFormatDescription(
                extradata: track.extradata,
                codec: videoCodec,
                width: track.width,
                height: track.height
            ) else {
                state = .error(.bufferCreationFailed(-1))
                throw DecoderError.bufferCreationFailed(-1)
            }
            formatDescription = formatDesc

            let (session, negotiatedFormat) = try createDecompressionSession(for: track, isHDR: track.isHDR)
            self.session = session
            self._negotiatedPixelFormat = negotiatedFormat

            isUsingHardwareAcceleration = queryHardwareUsage(session: session)

            pixelBufferPool = createPixelBufferPool(for: track, pixelFormat: negotiatedFormat)

            state = .configured
        }
    }

    // MARK: - Decoding

    func decode(_ packet: MediaPacket) async throws -> DecoderOutput {
        let startTime = CFAbsoluteTimeGetCurrent()

        let sampleBuffer: CMSampleBuffer = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<CMSampleBuffer, Error>) in
            self.submitPacket(packet, continuation: continuation)
        }

        recordTimingSync(CFAbsoluteTimeGetCurrent() - startTime)
        return .sampleBuffer(sampleBuffer)
    }

    private struct SessionData: @unchecked Sendable {
        let session: VTDecompressionSession?
        let formatDesc: CMVideoFormatDescription?
        let pool: CVPixelBufferPool?
    }

    private func submitPacket(_ packet: MediaPacket,
                              continuation: CheckedContinuation<CMSampleBuffer, Error>) {
        let data = lock.withLock {
            SessionData(session: self.session, formatDesc: self.formatDescription, pool: self.pixelBufferPool)
        }
        let session = data.session
        let formatDesc = data.formatDesc
        let pool = data.pool

        lock.withLock { self.pendingContinuation = continuation }

        guard let session = session, let formatDescription = formatDesc else {
            lock.withLock { self.pendingContinuation = nil }
            continuation.resume(throwing: DecoderError.sessionNotConfigured)
            return
        }

        let bufferManager = ZeroCopyBufferManager(pixelBufferPool: pool)
        let sampleBuffer: CMSampleBuffer
        do {
            sampleBuffer = try bufferManager.createSampleBuffer(
                from: packet,
                formatDescription: formatDescription
            )
        } catch {
            lock.withLock { self.pendingContinuation = nil }
            continuation.resume(throwing: error)
            return
        }

        let decodeFlags: VTDecodeFrameFlags = [
            ._EnableAsynchronousDecompression,
            ._1xRealTimePlayback,
        ]

        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: decodeFlags,
            frameRefcon: Unmanaged.passUnretained(self).toOpaque(),
            infoFlagsOut: nil
        )

        if status != noErr {
            lock.withLock { self.pendingContinuation = nil }
            continuation.resume(throwing: DecoderError.hardwareFailure)
        }
    }

    // MARK: - Lifecycle

    func flush() async {
        lock.withLock {
            state = .flushing
            if let session = session {
                VTDecompressionSessionWaitForAsynchronousFrames(session)
            }
            state = .configured
        }
    }

    func reset() async {
        await flush()
    }

    func invalidate() async {
        let pending = lock.withLock {
            let cont = pendingContinuation
            pendingContinuation = nil
            invalidateSessionUnlocked()
            state = .idle
            return cont
        }
        // Resume any in-flight decode continuation so the awaiting task does
        // not hang forever after the session is torn down.
        if let pending {
            pending.resume(throwing: CancellationError())
        }
    }

    private func invalidateSessionUnlocked() {
        if let session = session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        pixelBufferPool = nil
        isUsingHardwareAcceleration = false
    }

    // MARK: - Private Helpers

    private func createDecompressionSession(for track: VideoTrackInfo,
                                            isHDR: Bool) throws -> (VTDecompressionSession, OSType) {
        guard let formatDescription = formatDescription else {
            throw DecoderError.sessionNotConfigured
        }

        let decoderSpecification: [String: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String: true
        ]

        // Prefer VideoRange; if the decoder rejects the data (e.g. full-range
        // encoded source flagged as video-range), retry with FullRange.
        let preferredFormat: OSType = isHDR
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let fallbackFormat: OSType = isHDR
            ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

        let candidateFormats = [preferredFormat, fallbackFormat]

        for candidate in candidateFormats {
            let destinationAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: candidate,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]

            var session: VTDecompressionSession?
            var outputCallback = VTDecompressionOutputCallbackRecord(
                decompressionOutputCallback: videoToolboxDecompressionCallback,
                decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
            )

            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: formatDescription,
                decoderSpecification: decoderSpecification as CFDictionary,
                imageBufferAttributes: destinationAttributes as CFDictionary,
                outputCallback: &outputCallback,
                decompressionSessionOut: &session
            )

            if status == noErr, let session = session {
                VTSessionSetProperty(
                    session,
                    key: kVTDecompressionPropertyKey_RealTime,
                    value: kCFBooleanTrue as CFPropertyList
                )
                return (session, candidate)
            }

            // The decoder explicitly rejected the data format — try the next
            // candidate (FullRange) before giving up.
            if status == videoDecoderBadDataErr {
                #if DEBUG
                decoderLogger.debug("VTDecompressionSessionCreate rejected format \(candidate, privacy: .public) with bad-data err, retrying next candidate")
                #endif
                continue
            }

            throw DecoderError.hardwareFailure
        }

        throw DecoderError.hardwareFailure
    }

    private func queryHardwareUsage(session: VTDecompressionSession) -> Bool {
        var property: Unmanaged<CFBoolean>?
        let status = VTSessionCopyProperty(
            session,
            key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
            allocator: kCFAllocatorDefault,
            valueOut: &property
        )
        if status == noErr, let value = property?.takeRetainedValue() {
            return value == kCFBooleanTrue
        }
        return false
    }

    private func createPixelBufferPool(for track: VideoTrackInfo, pixelFormat: OSType) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: track.width,
            kCVPixelBufferHeightKey as String: track.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            attributes as CFDictionary,
            &pool
        )
        return status == noErr ? pool : nil
    }

    private func recordTimingSync(_ timing: TimeInterval) {
        lock.withLock {
            decodeTimings.append(timing)
            if decodeTimings.count > maxTimingSamples {
                decodeTimings.removeFirst()
            }
        }
    }

    var averageDecodeTime: TimeInterval {
        lock.withLock {
            guard !decodeTimings.isEmpty else { return 0 }
            return decodeTimings.reduce(0, +) / Double(decodeTimings.count)
        }
    }

    // MARK: - Callback Handling

    fileprivate func handleDecompressionOutput(status: OSStatus,
                                               infoFlags: VTDecodeInfoFlags,
                                               imageBuffer: CVImageBuffer?,
                                               presentationTimeStamp: CMTime,
                                               presentationDuration: CMTime) {
        let continuation = lock.withLock { () -> CheckedContinuation<CMSampleBuffer, Error>? in
            let cont = pendingContinuation
            pendingContinuation = nil
            return cont
        }

        guard let continuation = continuation else { return }

        if status != noErr {
            continuation.resume(throwing: DecoderError.hardwareFailure)
            return
        }

        guard let imageBuffer = imageBuffer else {
            continuation.resume(throwing: DecoderError.noFramesDecoded)
            return
        }

        let formatDescription = lock.withLock { self.formatDescription }
        guard let formatDescription else {
            continuation.resume(throwing: DecoderError.sessionNotConfigured)
            return
        }

        var timingInfo = CMSampleTimingInfo(
            duration: presentationDuration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: imageBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        if createStatus == noErr, let sampleBuffer = sampleBuffer {
            continuation.resume(returning: sampleBuffer)
        } else {
            continuation.resume(throwing: DecoderError.bufferCreationFailed(createStatus))
        }
    }
}

// MARK: - Decompression Callback

private func videoToolboxDecompressionCallback(
    decompressionOutputRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefcon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    presentationTimeStamp: CMTime,
    presentationDuration: CMTime
) {
    guard let refCon = decompressionOutputRefCon else { return }
    let decoder = Unmanaged<VideoToolboxDecoder>
        .fromOpaque(refCon)
        .takeUnretainedValue()
    decoder.handleDecompressionOutput(
        status: status,
        infoFlags: infoFlags,
        imageBuffer: imageBuffer,
        presentationTimeStamp: presentationTimeStamp,
        presentationDuration: presentationDuration
    )
}
