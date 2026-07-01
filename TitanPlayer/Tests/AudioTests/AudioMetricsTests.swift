import XCTest
@testable import TitanPlayer

final class AudioMetricsTests: XCTestCase {
    func testAudioMetricsInitialization() {
        let metrics = AudioMetrics()

        XCTAssertEqual(metrics.latency, 0)
        XCTAssertEqual(metrics.cpuUsage, 0)
        XCTAssertEqual(metrics.memoryUsage, 0)
    }

    func testAudioMetricsUpdates() {
        let metrics = AudioMetrics()

        metrics.updateLatency(0.05)
        metrics.updateCPUUsage(0.02)

        XCTAssertEqual(metrics.latency, 0.05)
        XCTAssertEqual(metrics.cpuUsage, 0.02)
    }
}
