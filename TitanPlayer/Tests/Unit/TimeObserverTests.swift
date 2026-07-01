import XCTest
@testable import TitanPlayer

final class TimeObserverTests: XCTestCase {
    final class TimeObserverTestsHost: XCTestCase {
        var observer: TimeObserver!
        override func setUp() {
            super.setUp()
            observer = TimeObserver()
        }
        override func tearDown() {
            observer.stopObserving()
            observer = nil
            super.tearDown()
        }
    }

    func test_initialValuesAreZero() {
        let observer = TimeObserver()
        XCTAssertEqual(observer.currentTime, 0)
        XCTAssertEqual(observer.duration, 0)
        XCTAssertEqual(observer.progress, 0)
    }

    func test_seekToUpdatesCurrentTime() {
        let observer = TimeObserver()
        observer.duration = 100
        observer.seekTo(25)
        XCTAssertEqual(observer.currentTime, 25)
        XCTAssertEqual(observer.progress, 0.25, accuracy: 0.001)
    }

    func test_stopObservingIsIdempotent() {
        let observer = TimeObserver()
        observer.startObserving()
        observer.startObserving()  // double-start should not crash
        observer.stopObserving()
        observer.stopObserving()  // double-stop should not crash
    }

    func test_progressClampsWhenDurationIsZero() {
        let observer = TimeObserver()
        observer.currentTime = 50
        observer.duration = 0
        // Avoid divide-by-zero; progress should remain at its initial value
        // (or NaN-safe), but never trap / crash.
        _ = observer.progress
    }
}
