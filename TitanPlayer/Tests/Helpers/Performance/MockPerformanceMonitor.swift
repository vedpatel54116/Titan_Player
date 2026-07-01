import Foundation
@testable import TitanPlayer

final class MockPerformanceMonitor: PerformanceMonitorProtocol {
    private(set) var currentSystemState: SystemState = SystemState()
    private(set) var recentMetrics: PerformanceMetrics =
        PerformanceMetrics(averageDecodeTime: 0, frameDropRate: 0, isDegraded: false)

    func inject(_ thermal: SystemState.ThermalState) {
        currentSystemState.thermalState = thermal
    }
    func injectLowPower(_ v: Bool) { currentSystemState.isLowPowerMode = v }
    func injectCpu(_ v: Double) { currentSystemState.cpuUsage = v }
    func injectBattery(state: SystemState.BatteryState, level: Double) {
        currentSystemState.batteryState = state
        currentSystemState.batteryLevel = level
    }
    func injectMetrics(_ m: PerformanceMetrics) { recentMetrics = m }
}
