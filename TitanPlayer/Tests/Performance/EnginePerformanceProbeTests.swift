import XCTest
@testable import TitanPlayer

final class EnginePerformanceProbeTests: XCTestCase {
    @MainActor
    func test_cpuUsageReturnsZeroBeforeInjectedSample() {
        let probe = EnginePerformanceProbe()
        XCTAssertEqual(probe.cpuUsage, 0.0)
        XCTAssertEqual(probe.memoryUsage, 0)
    }

    @MainActor
    func test_memoryUsageReflectsInjectedBytes() {
        let probe = EnginePerformanceProbe()
        probe._testInject(bytes: 123_456)
        XCTAssertEqual(probe.memoryUsage, 123_456)
    }

    @MainActor
    func test_cpuUsageReflectsInjectedSample() {
        let probe = EnginePerformanceProbe()
        probe._testInject(cpu: 0.07)
        XCTAssertEqual(probe.cpuUsage, 0.07, accuracy: 1e-9)
    }

    @MainActor
    func test_initWithMonitorBindsCPUProviderToMonitor() {
        let stub = StubMonitor(state: SystemState(cpuUsage: 0.31))
        let probe = EnginePerformanceProbe(monitor: stub)
        XCTAssertEqual(probe.cpuUsage, 0.31, accuracy: 1e-9)
    }
}

private final class StubMonitor: PerformanceMonitorProtocol {
    private let state: SystemState
    private let metrics = PerformanceMetrics(averageDecodeTime: 0, frameDropRate: 0, isDegraded: false)
    init(state: SystemState) { self.state = state }
    var currentSystemState: SystemState { state }
    var recentMetrics: PerformanceMetrics { metrics }
}
