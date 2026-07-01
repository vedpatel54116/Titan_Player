import XCTest
@testable import TitanPlayer

final class PlaybackHistoryTests: XCTestCase {

    private func makeSample(_ id: Int, at time: TimeInterval = 0) -> PlaybackSample {
        PlaybackSample(
            timestamp: Date(timeIntervalSince1970: time),
            decoderName: "VideoToolboxDecoder",
            resolution: CGSize(width: 1920, height: 1080),
            fps: 60,
            frameDropRate: 0.01,
            thermalState: .nominal,
            powerMode: .performance,
            codecName: "h264"
        )
    }

    func test_history_appends_and_trims_max_samples() {
        let history = PlaybackHistory(maxSamples: 5)
        for i in 0..<10 { history.append(makeSample(i)) }
        XCTAssertEqual(history.count, 5)
        let all = history.all()
        XCTAssertEqual(all.count, 5)
    }

    func test_history_recent_filters_within_window() {
        let history = PlaybackHistory(maxSamples: 100)
        let now = Date()
        history.append(makeSample(1, at: now.timeIntervalSince1970 - 30))
        history.append(makeSample(2, at: now.timeIntervalSince1970 - 90))
        history.append(makeSample(3, at: now.timeIntervalSince1970 - 200))

        let recent = history.recent(seconds: 60, now: now)
        XCTAssertEqual(recent.count, 1)
    }

    func test_history_thread_safe_concurrent_appends() {
        let history = PlaybackHistory(maxSamples: 10_000)
        let expectation = XCTestExpectation(description: "all appends")
        expectation.expectedFulfillmentCount = 100
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            history.append(makeSample(i))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(history.count, 10_000)
    }
}
