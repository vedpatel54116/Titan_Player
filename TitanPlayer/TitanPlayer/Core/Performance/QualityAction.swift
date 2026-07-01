import Foundation

public enum QualityAction: Sendable, Equatable, Hashable {
    case preferHardware(Bool)
    case downscaleRenderTo(ResolutionCap)
    case streamPreferBitrate(Int)
    case reduceAudioComplexity(AudioMode)
    case deferPrefetch(seconds: Int)
}

public enum ResolutionCap: Sendable, Equatable, Hashable, Codable, CaseIterable {
    case original
    case p2160
    case p1080
    case p720

    public var maxPixels: Int? {
        switch self {
        case .original: return nil
        case .p2160:    return 3840 * 2160
        case .p1080:    return 1920 * 1080
        case .p720:     return 1280 *  720
        }
    }
}

public enum AudioMode: Sendable, Equatable, Hashable, Codable, CaseIterable {
    case full
    case simplified
}
