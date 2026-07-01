import Foundation

struct ActiveDownload: Codable, Hashable, Identifiable {
    let id: String
    let url: URL
    var progress: Double
    var bytesDownloaded: Int64
    var totalBytesExpected: Int64
}
