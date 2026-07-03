import XCTest
import CoreMedia
@testable import TitanPlayer

final class TimeObserverTests: XCTestCase {

    // MARK: - update(to:) sets currentTime from PTS

    func test_update_setsCurrentTimeFromPTS() {
        let observer = TimeObserver()
        let cmTime = CMTime(seconds: 3.5, preferredTimescale: 600)
        observer.update(to: cmTime)
        XCTAssertEqual(observer.currentTime, 3.5, accuracy: 0.001)
    }

    func test_update_doesNotAcceptWallClockValue() {
        let observer = TimeObserver()
        let wallClockTime = Date().timeIntervalSince1970
        observer.update(to: CMTime(seconds: wallClockTime, preferredTimescale: 600))
        // The PTS passed in should be used directly, not overridden by Date()
        XCTAssertEqual(observer.currentTime, wallClockTime, accuracy: 0.001)
    }

    // MARK: - seekTo sets currentTime

    func test_seekTo_setsCurrentTime() {
        let observer = TimeObserver()
        observer.duration = 100
        observer.seekTo(42.5)
        XCTAssertEqual(observer.currentTime, 42.5, accuracy: 0.001)
    }

    func test_seekTo_updatesProgress() {
        let observer = TimeObserver()
        observer.duration = 200
        observer.seekTo(50)
        XCTAssertEqual(observer.progress, 0.25, accuracy: 0.001)
    }

    // MARK: - progress is zero when duration is zero

    func test_progress_zeroWhenDurationZero() {
        let observer = TimeObserver()
        observer.update(to: CMTime(seconds: 50, preferredTimescale: 600))
        observer.duration = 0
        // progress should not crash and should remain 0 (guard prevents division)
        XCTAssertEqual(observer.progress, 0)
    }

    func test_progress_zeroWhenBothZero() {
        let observer = TimeObserver()
        XCTAssertEqual(observer.progress, 0)
    }

    // MARK: - updateDrift publishes drift value

    func test_updateDrift_publishesDriftValue() {
        let observer = TimeObserver()
        observer.updateDrift(audioTime: 1.0, videoTime: 1.04)
        XCTAssertEqual(observer.audioVideoDrift, 0.04, accuracy: 0.001)
    }

    func test_updateDrift_negativeDrift() {
        let observer = TimeObserver()
        observer.updateDrift(audioTime: 2.0, videoTime: 1.5)
        XCTAssertEqual(observer.audioVideoDrift, -0.5, accuracy: 0.001)
    }

    func test_updateDrift_zeroDrift() {
        let observer = TimeObserver()
        observer.updateDrift(audioTime: 3.0, videoTime: 3.0)
        XCTAssertEqual(observer.audioVideoDrift, 0.0)
    }

    // MARK: - Idempotent start/stop

    func test_stopObservingIsIdempotent() {
        let observer = TimeObserver()
        observer.startObserving()
        observer.startObserving()
        observer.stopObserving()
        observer.stopObserving()
    }

    // MARK: - Initial values

    func test_initialValuesAreZero() {
        let observer = TimeObserver()
        XCTAssertEqual(observer.currentTime, 0)
        XCTAssertEqual(observer.duration, 0)
        XCTAssertEqual(observer.progress, 0)
        XCTAssertEqual(observer.audioVideoDrift, 0)
    }
}
