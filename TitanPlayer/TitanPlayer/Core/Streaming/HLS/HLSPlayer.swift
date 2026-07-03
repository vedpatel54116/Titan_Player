import AVFoundation
import Foundation

protocol HLSPlayerProtocol: AnyObject {
    func makeAsset(url: URL) -> AVURLAsset
    func purge()
}

// SAFETY: `cachedAssets` is only accessed from callers that are
// serialised by the caller's concurrency model (e.g. @MainActor).
// No concurrent mutation occurs.
final class HLSPlayer: HLSPlayerProtocol, @unchecked Sendable {
    private var cachedAssets: [String: AVURLAsset] = [:]

    func makeAsset(url: URL) -> AVURLAsset {
        let key = url.absoluteString
        if let cached = cachedAssets[key] { return cached }
        let options: [String: Any] = [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ]
        let asset = AVURLAsset(url: url, options: options)
        cachedAssets[key] = asset
        return asset
    }

    func purge() {
        cachedAssets.removeAll()
    }
}
