import Foundation
@testable import TitanPlayer

@MainActor
final class MockLifecycleDriver: StreamCacheLifecycleDelegate {
    weak var cache: StreamingCache?
    var didStartCalls: [(String, URL)] = []
    var didProgress: [(String, Double, Int64, Int64)] = []
    var didFinish: [(String, DownloadedAssetInfo)] = []
    var didFail: [(String, Error)] = []

    func runLifecycle(on cache: StreamingCache, identifier: String, url: URL) async {
        self.cache = cache
        cache._handleProgress(id: identifier, progress: 0.0, bytes: 0, totalBytes: 0)
        let info = DownloadedAssetInfo(
            id: identifier,
            originalURL: url,
            bookmarkData: Data([0x00]),
            downloadedAt: Date(),
            expirationDate: nil,
            byteSize: 50_000_000,
            primaryVariantBitrate: 5_000_000
        )
        cache._handleFinish(id: identifier, info: info)
    }

    func cache(_ cache: StreamingCache, didStart id: String, url: URL) {
        didStartCalls.append((id, url))
    }
    func cache(_ cache: StreamingCache, didProgressUpdate id: String, progress: Double, bytes: Int64, totalBytes: Int64) {
        didProgress.append((id, progress, bytes, totalBytes))
        cache._handleProgress(id: id, progress: progress, bytes: bytes, totalBytes: totalBytes)
    }
    func cache(_ cache: StreamingCache, didFinish id: String, info: DownloadedAssetInfo) {
        didFinish.append((id, info))
        cache._handleFinish(id: id, info: info)
    }
    func cache(_ cache: StreamingCache, didFail id: String, error: Error) {
        didFail.append((id, error))
        cache._handleFail(id: id, error: error)
    }
}