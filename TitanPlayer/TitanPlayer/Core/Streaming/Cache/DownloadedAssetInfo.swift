import Foundation

struct DownloadedAssetInfo: Codable, Hashable, Identifiable {
    let id: String
    let originalURL: URL
    let bookmarkData: Data
    let downloadedAt: Date
    let expirationDate: Date?
    let byteSize: Int64
    let primaryVariantBitrate: Int
}
