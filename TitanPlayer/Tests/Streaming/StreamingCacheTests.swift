import XCTest
import Combine
@testable import TitanPlayer

@MainActor
final class StreamingCacheTests: XCTestCase {
    private var cache: StreamingCache!
    private var driver: MockLifecycleDriver!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        driver = MockLifecycleDriver()
        cache = StreamingCache(productionDelegate: nil)
        cache.attachLifecycleDelegate(driver)
        cancellables = []
    }

    override func tearDown() {
        cancellables = []
        cache = nil
        driver = nil
        super.tearDown()
    }

    private func startThenComplete(identifier: String) async throws -> DownloadedAssetInfo? {
        var received: Result<DownloadedAssetInfo, Error>?
        let url = URL(string: "https://example.com/\(identifier).m3u8")!
        let exp = expectation(description: "finish")
        Task {
            do {
                let res = try await cache.downloadAsset(url: url, preferredPeakBitRate: 0, expirationDate: nil)
                received = .success(res)
            } catch {
                received = .failure(error)
            }
            exp.fulfill()
        }
        await driver.runLifecycle(on: cache, identifier: identifier, url: url)
        await fulfillment(of: [exp], timeout: 1.0)
        return try received?.get()
    }

    func testDownloadHLSFinishesAndPublishesAvailable() async throws {
        let info = try await startThenComplete(identifier: "test-1")
        XCTAssertEqual(info?.byteSize, 50_000_000)
        XCTAssertTrue(cache.availableDownloads.contains(where: { $0.id == "test-1" }))
    }

    func testDownloadNonHLSURLThrows() async {
        let url = URL(string: "https://example.com/x.mp4")!
        do {
            _ = try await cache.downloadAsset(url: url, preferredPeakBitRate: 0, expirationDate: nil)
            XCTFail("Expected throw")
        } catch let err as StreamingError {
            if case .downloadNotSupported = err { /* ok */ } else { XCTFail("Wrong: \(err)") }
        } catch {
            XCTFail("Wrong type: \(error)")
        }
    }

    func testRemoveDownloadedAssetClearsIt() async throws {
        _ = try await startThenComplete(identifier: "test-rm")
        try await cache.removeDownloadedAsset(id: "test-rm")
        XCTAssertFalse(cache.availableDownloads.contains(where: { $0.id == "test-rm" }))
    }
}
