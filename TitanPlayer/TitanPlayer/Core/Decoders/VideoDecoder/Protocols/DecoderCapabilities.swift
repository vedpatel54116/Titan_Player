import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

// MARK: - Video Codec

enum VideoCodec: String, CaseIterable, Sendable {
    case h264 = "avc1"
    case hevc = "hvc1"
    case vp9 = "vp09"
    case av1 = "av01"
    case mpeg2 = "mp2v"
    case vc1 = "vc-1"
}

// MARK: - Decoder Output Format

enum DecoderOutputFormat: Sendable {
    case sampleBuffer
    case pixelBuffer
    case both
}

// MARK: - Decoder Output

enum DecoderOutput: @unchecked Sendable {
    case sampleBuffer(CMSampleBuffer)
    case pixelBuffer(CVImageBuffer)
}

// MARK: - Decoder State

enum DecoderState: Sendable {
    case idle
    case configured
    case decoding
    case flushing
    case error(DecoderError)
}

// MARK: - Decoder Capabilities

struct DecoderCapabilities: Sendable {
    let supportedCodecs: Set<VideoCodec>
    let maxResolution: CGSize
    let supportsHDR: Bool
    let supportsHardwareAcceleration: Bool
    let maxConcurrentDecodes: Int
    
    static let `default` = DecoderCapabilities(
        supportedCodecs: Self.querySupportedCodecs(),
        maxResolution: CGSize(width: 1920, height: 1080),
        supportsHDR: true,
        supportsHardwareAcceleration: MTLCreateSystemDefaultDevice() != nil,
        maxConcurrentDecodes: 1
    )

    private static func querySupportedCodecs() -> Set<VideoCodec> {
        var codecs: Set<VideoCodec> = [.h264]
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
            codecs.insert(.hevc)
        }
        if #available(macOS 13.0, *) {
            if VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) {
                codecs.insert(.av1)
            }
        }
        codecs.insert(.vp9)
        return codecs
    }
    
    init(supportedCodecs: Set<VideoCodec>,
         maxResolution: CGSize,
         supportsHDR: Bool,
         supportsHardwareAcceleration: Bool,
         maxConcurrentDecodes: Int = 1) {
        self.supportedCodecs = supportedCodecs
        self.maxResolution = maxResolution
        self.supportsHDR = supportsHDR
        self.supportsHardwareAcceleration = supportsHardwareAcceleration
        self.maxConcurrentDecodes = maxConcurrentDecodes
    }
    
    init(from hardwareCaps: HardwareCapabilities) {
        self.supportedCodecs = hardwareCaps.supportedCodecs
        self.maxResolution = hardwareCaps.maxResolution
        self.supportsHDR = hardwareCaps.supportsHDR
        self.supportsHardwareAcceleration = hardwareCaps.supportsHardwareAcceleration
        self.maxConcurrentDecodes = 2
    }
    
    init(from softwareCaps: SoftwareCapabilities) {
        self.supportedCodecs = softwareCaps.supportedCodecs
        self.maxResolution = softwareCaps.maxResolution
        self.supportsHDR = softwareCaps.supportsHDR
        self.supportsHardwareAcceleration = softwareCaps.supportsHardwareAcceleration
        self.maxConcurrentDecodes = 1
    }
}
