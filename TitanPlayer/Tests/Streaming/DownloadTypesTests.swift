import XCTest
@testable import TitanPlayer

final class DownloadTypesTests: XCTestCase {
    func testDownloadedAssetInfoRoundTripsCoder() throws {
        let url = URL(string: "https://example.com/x.m3u8")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let exp = Date(timeIntervalSince1970: 1_900_000_000)
        let info = DownloadedAssetInfo(
            id: "task-1",
            originalURL: url,
            bookmarkData: Data([0xAA, 0xBB]),
            downloadedAt: now,
            expirationDate: exp,
            byteSize: 123_456,
            primaryVariantBitrate: 5_000_000
        )
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(DownloadedAssetInfo.self, from: data)
        XCTAssertEqual(decoded, info)
    }

    func testActiveDownloadHashIncludesProgress() {
        let url = URL(string: "https://example.com/x.m3u8")!
        let a = ActiveDownload(id: "1", url: url, progress: 0.3, bytesDownloaded: 100, totalBytesExpected: 1000)
        let b = ActiveDownload(id: "1", url: url, progress: 0.7, bytesDownloaded: 700, totalBytesExpected: 1000)
        XCTAssertNotEqual(a, b)
    }

    func testActiveDownloadIdentifiable() {
        let url = URL(string: "https://example.com/x.m3u8")!
        let a = ActiveDownload(id: "42", url: url, progress: 0.5, bytesDownloaded: 50, totalBytesExpected: 100)
        XCTAssertEqual(a.id, "42")
    }
}
