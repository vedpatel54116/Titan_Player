import Foundation

enum PlaybackError: Error, LocalizedError {
    case invalidURL
    case assetLoadFailed(Error)
    case noPlayableTracks
    case decodingFailed(Error)
    case audioOutputFailed(Error)
    case rateNotSupported
    case seekFailed
    
    var code: Int {
        switch self {
        case .invalidURL: return 1
        case .assetLoadFailed: return 2
        case .noPlayableTracks: return 3
        case .decodingFailed: return 4
        case .audioOutputFailed: return 5
        case .rateNotSupported: return 6
        case .seekFailed: return 7
        }
    }
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .assetLoadFailed: return "Asset load failed"
        case .noPlayableTracks: return "No playable tracks found"
        case .decodingFailed: return "Decoding failed"
        case .audioOutputFailed: return "Audio output failed"
        case .rateNotSupported: return "Rate not supported"
        case .seekFailed: return "Seek failed"
        }
    }
}
