import CoreMedia
import CoreVideo
import Foundation

/// A `VideoDecoding` implementation that needs no FFmpeg and produces solid
/// colour `CVPixelBuffer`s. Used by the test suite so `swift test` can run on
/// CI machines that have not built the local FFmpeg xcframeworks.
final class FakeVideoDecoder: VideoDecoding, @unchecked Sendable {
    let outputFormat: DecoderOutputFormat = .pixelBuffer
    let capabilities: DecoderCapabilities = .default

    private let lock = OSAllocatedUnfairLock<DecoderState>(initialState: .idle)
    var state: DecoderState { lock.withLock { $0 } }

    var negotiatedPixelFormat: OSType? { kCVPixelFormatType_32BGRA }

    private let width: Int
    private let height: Int
    private let color: (r: UInt8, g: UInt8, b: UInt8)

    init(width: Int = 1280, height: Int = 720, color: (UInt8, UInt8, UInt8) = (0, 128, 255)) {
        self.width = width
        self.height = height
        self.color = color
    }

    func configure(for track: VideoTrackInfo) async throws {
        lock.withLock { $0 = .configured }
    }

    func decode(_ packet: MediaPacket) async throws -> DecoderOutput {
        let current = lock.withLock { (s: DecoderState) -> DecoderState in
            if s == .idle { return .idle }
            return .decoding
        }
        guard current != .idle else {
            throw DecoderError.sessionNotConfigured
        }
        let buffer = try Self.makeSolidColorBuffer(width: width, height: height, color: color)
        return .pixelBuffer(buffer)
    }

    func invalidate() async {
        lock.withLock { $0 = .idle }
    }

    // MARK: - Helpers

    static func makeSolidColorBuffer(
        width: Int,
        height: Int,
        color: (r: UInt8, g: UInt8, b: UInt8)
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw DecoderError.bufferCreationFailed(status)
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw DecoderError.bufferCreationFailed(-1)
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                ptr[offset + 0] = color.b
                ptr[offset + 1] = color.g
                ptr[offset + 2] = color.r
                ptr[offset + 3] = 255
            }
        }
        return buffer
    }
}
