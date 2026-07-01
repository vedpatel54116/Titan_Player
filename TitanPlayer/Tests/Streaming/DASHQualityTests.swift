import XCTest
@testable import TitanPlayer

final class DASHQualityTests: XCTestCase {
    func testSortedByBandwidthAscending() {
        let a = DASHQuality(id: "high", bandwidth: 5_000_000, width: 1920, height: 1080, codec: "h264", mimeType: nil, baseUrl: nil)
        let b = DASHQuality(id: "low", bandwidth: 1_000_000, width: 640, height: 360, codec: "h264", mimeType: nil, baseUrl: nil)
        let c = DASHQuality(id: "mid", bandwidth: 2_500_000, width: 1280, height: 720, codec: "h264", mimeType: nil, baseUrl: nil)

        let sorted = DASHQuality.sortedByBandwidth([a, b, c])
        XCTAssertEqual(sorted.map(\.id), ["low", "mid", "high"])
    }

    func testResolutionLabelWithDimensions() {
        let q = DASHQuality(id: "1", bandwidth: 1_000_000, width: 1280, height: 720, codec: nil, mimeType: nil, baseUrl: nil)
        XCTAssertEqual(q.resolutionLabel, "1280x720")
    }

    func testResolutionLabelWithoutDimensions() {
        let q = DASHQuality(id: "1", bandwidth: 1_000_000, width: nil, height: nil, codec: nil, mimeType: nil, baseUrl: nil)
        XCTAssertEqual(q.resolutionLabel, "unknown")
    }

    func testHashableConformance() {
        let a = DASHQuality(id: "1", bandwidth: 1_000_000, width: nil, height: nil, codec: nil, mimeType: nil, baseUrl: nil)
        let b = DASHQuality(id: "1", bandwidth: 1_000_000, width: nil, height: nil, codec: nil, mimeType: nil, baseUrl: nil)
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 1)
    }
}
