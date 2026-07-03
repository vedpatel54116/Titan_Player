import Foundation

enum PlaybackError: Error, LocalizedError {
    case invalidURL
    case assetLoadFailed(Error)
    case assetLoadFailedWithStatus(OSStatus, Error)
    case noPlayableTracks
    case decodingFailed(Error)
    case audioOutputFailed(Error)
    case rateNotSupported
    case seekFailed
    
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
        }
    }
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The file URL is invalid."
        case .assetLoadFailed(let error): return "Asset load failed: \(error.localizedDescription)"
        case .assetLoadFailedWithStatus(let status, let error):
            return "Asset load failed: OSStatus \(status) — \(error.localizedDescription)"
        case .noPlayableTracks: return "No playable video or audio tracks found — the codec may be unsupported."
        case .decodingFailed(let error): return "Decoding failed: \(error.localizedDescription)"
        case .audioOutputFailed(let error): return "Audio output failed: \(error.localizedDescription)"
        case .rateNotSupported: return "The playback rate is not supported."
        case .seekFailed: return "Seeking within the file failed."
        }
    }
}
