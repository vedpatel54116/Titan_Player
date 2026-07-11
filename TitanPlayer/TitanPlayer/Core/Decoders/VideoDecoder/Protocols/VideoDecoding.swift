import Foundation
import CoreMedia
import CoreVideo

// MARK: - Decoder Error

enum DecoderError: Error, LocalizedError, Sendable {
    case unsupportedCodec(String)
    case sessionNotConfigured
    case bufferCreationFailed(OSStatus)
    case noFramesDecoded
    case hardwareFailure
    case softwareFailure
    case noDecodersAvailable
    
    enum ErrorSeverity: Sendable {
        case transient
        case persistent
    }
    
    var severity: ErrorSeverity {
        switch self {
        case .sessionNotConfigured, .bufferCreationFailed:
            return .transient
        case .unsupportedCodec, .noFramesDecoded:
            return .persistent
        case .hardwareFailure:
            return .transient
        case .softwareFailure:
            return .persistent
        case .noDecodersAvailable:
            return .persistent
        }
    }
    
    var errorDescription: String? {
        switch self {
        case .unsupportedCodec(let codec):
            return "Unsupported codec: \(codec)"
        case .sessionNotConfigured:
            return "Decoder session not configured"
        case .bufferCreationFailed(let status):
            return "Buffer creation failed with status: \(status)"
        case .noFramesDecoded:
            return "No frames decoded"
        case .hardwareFailure:
            return "Hardware decoding failed"
        case .softwareFailure:
            return "Software decoding failed"
        case .noDecodersAvailable:
            return "No decoders available for the selected track"
        }
    }
}

// MARK: - Video Decoding Protocol

protocol VideoDecoding: AnyObject, Sendable {
    var outputFormat: DecoderOutputFormat { get }
    var capabilities: DecoderCapabilities { get }
    var state: DecoderState { get }

    /// The actual pixel format negotiated/used for output buffers, if known.
    /// Used by the Decoder Health panel. Defaults to `nil`.
    var negotiatedPixelFormat: OSType? { get }

    func configure(for track: VideoTrackInfo) async throws
    func decode(_ packet: MediaPacket) async throws -> DecoderOutput
    func flush() async
    func reset() async
    func invalidate() async
}

// MARK: - Default Implementations

extension VideoDecoding {
    func flush() async {}
    func reset() async {}
    var negotiatedPixelFormat: OSType? { nil }
}
