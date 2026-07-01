import Foundation

public enum PowerMode: String, Sendable, Equatable, Codable {
    case unknown
    case auto
    case performance
    case balanced
    case battery
}

extension PowerMode {
    init(userChoice: PowerMode, systemState: SystemState, isExternalPower: Bool) {
        switch userChoice {
        case .auto, .unknown:
            self = .derived(from: systemState, isExternalPower: isExternalPower)
        case .performance, .balanced, .battery:
            self = userChoice
        }
    }

    static func derived(from state: SystemState, isExternalPower: Bool) -> PowerMode {
        if state.isLowPowerMode { return .battery }
        if state.batteryState == .discharging && state.batteryLevel < 0.20 { return .battery }
        if state.thermalState == .critical { return .battery }

        if isExternalPower {
            return .performance
        }

        switch state.thermalState {
        case .nominal:  return .performance
        case .fair:     return .balanced
        case .serious:  return .balanced
        case .critical: return .battery
        }
    }
}
