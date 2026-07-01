import Foundation
@testable import TitanPlayer

@MainActor
final class MockStreamingCache: StreamingCacheProtocol {
    var downloads: [DownloadedAssetInfo] = []
    var active: [ActiveDownload] = []
    var lastDownload: URL?

    var availableDownloads: [DownloadedAssetInfo] { downloads }
    var activeDownloads: [ActiveDownload] { active }

    func downloadAsset(url: URL, preferredPeakBitRate: Double, expirationDate: Date?) async throws -> DownloadedAssetInfo {
        lastDownload = url
        let info = DownloadedAssetInfo(
            id: UUID().uuidString,
            originalURL: url,
            bookmarkData: Data(),
            downloadedAt: Date(),
            expirationDate: expirationDate,
            byteSize: 100,
            primaryVariantBitrate: Int(preferredPeakBitRate)
        )
        downloads.append(info)
        return info
    }

    func cancelDownload(id: String) async throws {
        downloads.removeAll { $0.id == id }
        active.removeAll { $0.id == id }
    }

    func removeDownloadedAsset(id: String) async throws {
        downloads.removeAll { $0.id == id }
    }
}
