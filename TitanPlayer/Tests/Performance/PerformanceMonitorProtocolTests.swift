import XCTest
@testable import TitanPlayer

final class PerformanceMonitorProtocolTests: XCTestCase {
    func test_performance_monitor_conforms_to_protocol() {
        let monitor: any PerformanceMonitorProtocol = PerformanceMonitor()
        _ = monitor.currentSystemState
        _ = monitor.recentMetrics
    }

    func test_inject_state_overrides_current() {
        let monitor = PerformanceMonitor()
        var s = SystemStateFixture.nominal()
        s.thermalState = .critical
        monitor._testInject(state: s)
        XCTAssertEqual(monitor.currentSystemState.thermalState, .critical)
    }

    func test_inject_metrics_overrides_recent() {
        let monitor = PerformanceMonitor()
        let m = PerformanceMetrics(averageDecodeTime: 0.05, frameDropRate: 0.10, isDegraded: true)
        monitor._testInject(metrics: m)
        XCTAssertEqual(monitor.recentMetrics.frameDropRate, 0.10)
    }

    func test_cpu_sample_call_is_safe_and_updates_state() {
        let monitor = PerformanceMonitor()
        let before = monitor.currentSystemState.cpuUsage
        monitor.sampleCPUUsage()
        XCTAssertGreaterThanOrEqual(monitor.currentSystemState.cpuUsage, 0)
        XCTAssertLessThanOrEqual(monitor.currentSystemState.cpuUsage, 1.0)
        _ = before
    }
}
