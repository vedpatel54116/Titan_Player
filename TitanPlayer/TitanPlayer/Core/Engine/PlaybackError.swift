import Foundation

enum PlaybackError: Error, LocalizedError {
    case invalidURL
    case assetLoadFailed(Error)
    case assetLoadFailedWithStatus(OSStatus, Error)
    case noPlayableTracks
    case decodingFailed(Error, retryable: Bool = false)
    case audioOutputFailed(Error)
    case rateNotSupported
    case seekFailed
    case networkTimeout
    case audioFormatUnsupported
    case gpuDeviceLost
    case drmUnsupported
    
    var code: Int {
        switch self {
        case .invalidURL: return 1
        case .assetLoadFailed: return 2
        case .assetLoadFailedWithStatus: return 8
        case .noPlayableTracks: return 3
        case .decodingFailed: return 4
        case .audioOutputFailed: return 5
        case .rateNotSupported: return 6
        case .seekFailed: return 7
        case .networkTimeout: return 9
        case .audioFormatUnsupported: return 10
        case .gpuDeviceLost: return 11
        case .drmUnsupported: return 12
        }
    }
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .assetLoadFailed: return "Asset load failed"
        case .assetLoadFailedWithStatus: return "Asset load failed"
        case .noPlayableTracks: return "No playable tracks found"
        case .decodingFailed: return "Decoding failed"
        case .audioOutputFailed: return "Audio output failed"
        case .rateNotSupported: return "Rate not supported"
        case .seekFailed: return "Seek failed"
        case .networkTimeout: return "Network request timed out."
        case .audioFormatUnsupported: return "The audio format is not supported."
        case .gpuDeviceLost: return "GPU device lost."
        case .drmUnsupported: return "DRM protection is not supported."
        }
    }
}
