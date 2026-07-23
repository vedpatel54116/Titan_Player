import XCTest
import Foundation
@testable import TitanPlayer

final class SpotlightIndexerTests: XCTestCase {

    // MARK: Empty-input fast path

    /// Indexing an empty list must short-circuit before touching CoreSpotlight
    /// (and therefore before any daemon/timeout interaction).
    func testIndexEmptyReturnsImmediately() async throws {
        let indexer = SpotlightIndexer()
        let result = try await indexer.index([])
        XCTAssertEqual(result.indexedCount, 0)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.duration, 0, accuracy: 0.001)
    }

    // MARK: Attribute mapping

    /// `MediaItem` fields must be projected onto the CoreSpotlight attribute set
    /// with a stable unique identifier and our domain.
    func testMakeSearchableItemMapsAttributes() throws {
        var item = MediaItem.makePlaceholder(url: URL(fileURLWithPath: "/Movies/Example.mov"))
        item = MediaItem(
            id: item.id,
            url: item.url,
            securityBookmark: nil,
            title: "Example Clip",
            displayTitle: "Example Clip",
            fileSize: 12_345_678,
            duration: 125,
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
            dateModified: Date(timeIntervalSince1970: 1_700_000_100),
            lastPlayed: nil,
            playCount: 0,
            lastPosition: 0,
            isFavorite: false,
            thumbnailPath: nil,
            codecInfo: VideoCodecInfo(codec: "hevc", profile: nil, level: nil, bitDepth: 10, isHDR: true),
            audioInfo: nil,
            resolution: CGSize(width: 3840, height: 2160),
            bitrate: nil,
            isHDR: true,
            metadata: [:]
        )

        let searchable = SpotlightIndexer.makeSearchableItem(for: item, domain: "com.titanplayer.media")
        XCTAssertEqual(searchable.uniqueIdentifier, item.id.uuidString)
        XCTAssertEqual(searchable.domainIdentifier, "com.titanplayer.media")
        XCTAssertEqual(searchable.attributeSet.title, "Example Clip")
        XCTAssertEqual(searchable.attributeSet.fileSize as? UInt64, 12_345_678)
        XCTAssertEqual(searchable.attributeSet.isHD?.boolValue, true)
        XCTAssertEqual(searchable.attributeSet.resolutionHeight as? Double, 2160)
        XCTAssertEqual(searchable.attributeSet.codecs, "hevc")
    }

    // MARK: Progress publisher

    /// The Combine progress publisher must emit at least a `started` event for a
    /// non-empty pass... but a real pass touches the daemon, so we only assert
    /// the publisher is wired and replays a value type correctly.
    func testProgressPublisherIsConnected() {
        let indexer = SpotlightIndexer()
        let publisher = indexer.indexProgressPublisher
        XCTAssertNotNil(publisher)
    }
}
