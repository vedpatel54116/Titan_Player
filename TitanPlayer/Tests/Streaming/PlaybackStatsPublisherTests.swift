import XCTest
import AVFoundation
import Combine
@testable import TitanPlayer

@MainActor
final class PlaybackStatsPublisherTests: XCTestCase {
    private var publisher: PlaybackStatsPublisher!
    private var item: MockAccessLogItem!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        publisher = PlaybackStatsPublisher(timerInterval: 0.05)   // fast for tests
        item = MockAccessLogItem()
        cancellables = []
    }

    override func tearDown() {
        publisher.detach()
        cancellables = []
        publisher = nil
        item = nil
        super.tearDown()
    }

    func testAttachStartsPublishing() {
        item.observedBitrate = 5_000_000
        publisher.attach(provider: item)

        let exp = expectation(description: "bitrate published")
        var received: Double = 0
        publisher.$observedBitrate
            .dropFirst()
            .sink { val in
                received = val
                exp.fulfill()
            }
            .store(in: &cancellables)

        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(received, 5_000_000)
    }

    func testStallCountFlows() {
        item.observedBitrate = 1_000_000
        item.numberOfStalls = 3
        publisher.attach(provider: item)
        let exp = expectation(description: "stalls published")
        publisher.$stallCount
            .dropFirst()
            .sink { val in
                if val == 3 { exp.fulfill() }
            }
            .store(in: &cancellables)
        wait(for: [exp], timeout: 1.0)
    }

    func testDetachStopsTimer() {
        publisher.attach(provider: item)
        publisher.detach()
        let expectation = XCTestExpectation(description: "no update")
        expectation.isInverted = true
        publisher.$observedBitrate
            .dropFirst()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)
        item.observedBitrate = 99
        wait(for: [expectation], timeout: 0.5)
    }
}
