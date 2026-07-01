import Foundation
@testable import TitanPlayer

enum SystemStateFixture {
    static func nominal() -> SystemState {
        var s = SystemState()
        s.thermalState = .nominal
        s.cpuUsage = 0.10
        s.gpuUsage = 0.05
        s.batteryLevel = 1.0
        s.batteryState = .charging
        s.isLowPowerMode = false
        s.isHardwareAvailable = true
        return s
    }
}

extension SystemState {
    func with(thermal: SystemState.ThermalState) -> SystemState {
        var copy = self
        copy.thermalState = thermal
        return copy
    }
    func with(isLowPowerMode: Bool) -> SystemState {
        var copy = self
        copy.isLowPowerMode = isLowPowerMode
        return copy
    }
}
