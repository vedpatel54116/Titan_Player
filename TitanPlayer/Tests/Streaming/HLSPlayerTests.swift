import XCTest
import AVFoundation
@testable import TitanPlayer

final class HLSPlayerTests: XCTestCase {
    private var player: HLSPlayer!

    override func setUp() {
        super.setUp()
        player = HLSPlayer()
    }

    func testMakeAssetReturnsNonNilForHLSURL() {
        let url = URL(string: "https://example.com/master.m3u8")!
        let asset = player.makeAsset(url: url)
        XCTAssertNotNil(asset)
        XCTAssertEqual(asset.url, url)
    }

    func testMakeAssetCachesByAbsoluteURLString() {
        let url = URL(string: "https://example.com/master.m3u8")!
        let first = player.makeAsset(url: url)
        let second = player.makeAsset(url: url)
        XCTAssertTrue(first === second, "Repeated lookups for the same URL should return the cached asset")
    }

    func testDifferentURLsReturnDifferentAssets() {
        let a = player.makeAsset(url: URL(string: "https://example.com/a.m3u8")!)
        let b = player.makeAsset(url: URL(string: "https://example.com/b.m3u8")!)
        XCTAssertFalse(a === b)
    }

    func testPurgeClearsCache() {
        let url = URL(string: "https://example.com/master.m3u8")!
        let first = player.makeAsset(url: url)
        player.purge()
        let second = player.makeAsset(url: url)
        XCTAssertFalse(first === second, "After purge the next request should produce a fresh asset")
    }
}
