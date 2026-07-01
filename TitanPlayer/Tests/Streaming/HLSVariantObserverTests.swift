import XCTest
import Combine
import CoreGraphics
@testable import TitanPlayer

@MainActor
final class HLSVariantObserverTests: XCTestCase {
    private var observer: HLSVariantObserver!
    private var item: MockPlayerItem!
    private var cancellables: Set<AnyCancellable>!

    override func setUp() {
        super.setUp()
        observer = HLSVariantObserver()
        item = MockPlayerItem()
        cancellables = []
    }

    override func tearDown() {
        cancellables = []
        observer = nil
        item = nil
        super.tearDown()
    }

    func testCurrentStartsAsAuto() {
        XCTAssertEqual(observer.current, .auto)
        XCTAssertTrue(observer.available.isEmpty)
    }

    func testAttachPublishesAvailableVariants() {
        item.currentVariants = [
            StreamingVariantSnapshot(resolution: CGSize(width: 1920, height: 1080), bitrate: 5_000_000, codec: "avc1.640028"),
            StreamingVariantSnapshot(resolution: CGSize(width: 1280, height: 720), bitrate: 2_500_000, codec: "avc1.640028")
        ]

        var received: [[StreamingQuality]] = []
        observer.$available
            .dropFirst()
            .sink { received.append($0) }
            .store(in: &cancellables)

        observer.attach(provider: item)

        let exp = expectation(description: "publish")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(received.isEmpty)
        let last = received.last ?? []
        XCTAssertEqual(last.count, 2)
    }

    func testSelectingVariantUpdatesCurrentAfterDebounce() {
        item.currentVariants = [
            StreamingVariantSnapshot(resolution: CGSize(width: 1920, height: 1080), bitrate: 5_000_000, codec: "avc1.640028")
        ]
        item.selectedVariant = item.currentVariants.first

        var received: [StreamingQuality] = []
        observer.$current
            .dropFirst()
            .sink { received.append($0) }
            .store(in: &cancellables)

        observer.attach(provider: item)

        let exp = expectation(description: "debounce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(received.contains { q in
            if case .variant(let res, let br, _) = q {
                return Int(res.height) == 1080 && br == 5_000_000
            }
            return false
        })
    }

    func testDetachStopsPublishing() {
        observer.attach(provider: item)
        observer.detach()
        item.currentVariants = [
            StreamingVariantSnapshot(resolution: CGSize(width: 1280, height: 720), bitrate: 2_500_000, codec: nil)
        ]
        item.selectedVariant = item.currentVariants.first
        let exp = expectation(description: "detach")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(observer.current, .auto)
        XCTAssertTrue(observer.available.isEmpty)
    }
}
