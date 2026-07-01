import XCTest
@testable import TitanPlayer

@MainActor
final class DASHABRControllerTests: XCTestCase {
    private let lowQuality = DASHQuality(id: "low", bandwidth: 1_000_000, width: 640, height: 360, codec: nil, mimeType: nil, baseUrl: nil)
    private let midQuality = DASHQuality(id: "mid", bandwidth: 2_500_000, width: 1280, height: 720, codec: nil, mimeType: nil, baseUrl: nil)
    private let highQuality = DASHQuality(id: "high", bandwidth: 5_000_000, width: 1920, height: 1080, codec: nil, mimeType: nil, baseUrl: nil)

    func testStartsAtLowestQuality() {
        let controller = DASHABRController(qualities: [lowQuality, midQuality, highQuality], initial: lowQuality)
        XCTAssertEqual(controller.currentQuality.id, "low")
    }

    func testStartsAtSpecifiedInitial() {
        let controller = DASHABRController(qualities: [lowQuality, midQuality, highQuality], initial: midQuality)
        XCTAssertEqual(controller.currentQuality.id, "mid")
    }

    func testAvailableQualitiesSortedAscending() {
        let controller = DASHABRController(qualities: [highQuality, lowQuality, midQuality], initial: lowQuality)
        XCTAssertEqual(controller.availableQualities.map(\.id), ["low", "mid", "high"])
    }

    func testSwitchUpAfterConsecutiveHighSamples() {
        let controller = DASHABRController(qualities: [lowQuality, midQuality, highQuality], initial: lowQuality)

        for _ in 0..<3 {
            controller.recordThroughput(bytesDownloaded: 500_000, durationSeconds: 0.2)
        }

        XCTAssertEqual(controller.currentQuality.id, "mid")
    }

    func testSwitchDownWhenThroughputDrops() {
        let controller = DASHABRController(qualities: [lowQuality, midQuality, highQuality], initial: highQuality)

        controller.recordThroughput(bytesDownloaded: 10_000, durationSeconds: 0.1)

        XCTAssertEqual(controller.currentQuality.id, "high")
    }

    func testForceQuality() {
        let controller = DASHABRController(qualities: [lowQuality, midQuality, highQuality], initial: lowQuality)
        controller.forceQuality(highQuality)
        XCTAssertEqual(controller.currentQuality.id, "high")
    }

    func testForceQualityInvalidIdIgnored() {
        let controller = DASHABRController(qualities: [lowQuality, midQuality, highQuality], initial: lowQuality)
        let unknown = DASHQuality(id: "unknown", bandwidth: 999, width: nil, height: nil, codec: nil, mimeType: nil, baseUrl: nil)
        controller.forceQuality(unknown)
        XCTAssertEqual(controller.currentQuality.id, "low")
    }

    func testCooldownPreventsRapidSwitching() {
        let controller = DASHABRController(qualities: [lowQuality, midQuality, highQuality], initial: lowQuality)

        for _ in 0..<3 {
            controller.recordThroughput(bytesDownloaded: 500_000, durationSeconds: 0.2)
        }
        XCTAssertEqual(controller.currentQuality.id, "mid")

        controller.recordThroughput(bytesDownloaded: 10_000, durationSeconds: 0.1)
        XCTAssertEqual(controller.currentQuality.id, "mid")
    }
}
