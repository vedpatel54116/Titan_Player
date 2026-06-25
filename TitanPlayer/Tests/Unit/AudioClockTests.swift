import XCTest
@testable import TitanPlayer

final class AudioClockTests: XCTestCase {
    func testInitialTime() {
        let clock = AudioClock()
        XCTAssertEqual(clock.currentTime, 0, accuracy: 0.001)
    }
    
    func testTimeAdvancesWhenRunning() async {
        let clock = AudioClock()
        clock.start()
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        XCTAssertGreaterThan(clock.currentTime, 0.05)
        clock.stop()
    }
    
    func testTimePauseResume() async {
        let clock = AudioClock()
        clock.start()
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        clock.pause()
        let pausedTime = clock.currentTime
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(clock.currentTime, pausedTime, accuracy: 0.001)
        clock.resume()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertGreaterThan(clock.currentTime, pausedTime)
        clock.stop()
    }
    
    func testSeek() {
        let clock = AudioClock()
        clock.seek(to: 5.0)
        XCTAssertEqual(clock.currentTime, 5.0, accuracy: 0.001)
    }
    
    func testRateScaling() async {
        let clock = AudioClock()
        clock.rate = 2.0
        clock.start()
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms real time
        // Should advance ~200ms in clock time
        XCTAssertGreaterThan(clock.currentTime, 0.15)
        clock.stop()
    }
}
