import Foundation

enum StreamingError: Error, LocalizedError, Equatable {
    case invalidURL
    case assetLoadFailed(String)
    case downloadFailed(String)
    case downloadNotSupported(URL)
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
        case .mismatchedExpectedBitrate:
            return "Bitrate does not match an available variant."
        }
    }
}
