import Foundation

// MARK: - Software Capabilities

struct SoftwareCapabilities: Sendable {
    let supportedCodecs: Set<VideoCodec>
    let maxResolution: CGSize
    let supportsHDR: Bool
    let supportsHardwareAcceleration: Bool
    
    // MARK: - Query Capabilities
    
    static func query() -> SoftwareCapabilities {
        return SoftwareCapabilities(
            supportedCodecs: Set(VideoCodec.allCases),
            maxResolution: CGSize(width: 8192, height: 4320),
            supportsHDR: true,
            supportsHardwareAcceleration: false
        )
    }
    
    // MARK: - Codec Support
    
    static func isCodecSupported(_ codec: VideoCodec) -> Bool {
        // FFmpeg supports all codecs
        return true
    }
}
