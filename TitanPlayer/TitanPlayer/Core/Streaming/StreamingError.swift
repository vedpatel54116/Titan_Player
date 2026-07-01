import Foundation

enum StreamingError: Error, LocalizedError, Equatable {
    case invalidURL
    case assetLoadFailed(String)
    case downloadFailed(String)
    case downloadNotSupported(URL)
    case dashNotSupported(URL)
    case mismatchedExpectedBitrate

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The streaming URL is invalid."
        case .assetLoadFailed(let msg):
            return "Asset could not be loaded: \(msg)"
        case .downloadFailed(let msg):
            return "Download failed: \(msg)"
        case .downloadNotSupported(let url):
            return "Download not supported for \(url.absoluteString)"
        case .dashNotSupported(let url):
            return "DASH playback is not supported in this build (\(url.lastPathComponent))"
        case .mismatchedExpectedBitrate:
            return "Bitrate does not match an available variant."
        }
    }
}
