import Foundation
import Darwin

enum MacModelIdentifier: String, CaseIterable, Sendable {
    case intelUnknown = "intel.unknown"
    case macMiniM1 = "Macmini9,1"
    case macBookProIntel2018Baseline = "MacBookPro15,1"
    case macBookProM1Pro = "MacBookPro17,1"
    case macBookProM1Max = "MacBookPro18,1"
    case macBookProM2Pro = "MacBookPro19,1"
    case macBookProM2Max = "MacBookPro19,2"
    case macBookProM3Pro = "MacBookPro21,1"
    case macBookProM4Pro = "MacBookPro16,3"
    case macMiniM2 = "Macmini14,2"
    case macMiniM4 = "Macmini16,1"
    case iMacM1 = "iMac21,1"
    case macStudioM1Ultra = "Mac13,2"
    case macStudioM2Ultra = "Mac14,3"
    case macProM2Ultra = "Mac14,13"

    var isAppleSilicon: Bool {
        switch self {
        case .intelUnknown, .macBookProIntel2018Baseline:
            return false
        default:
            return true
        }
    }

    var shortLabel: String {
        switch self {
        case .intelUnknown: return "Intel (unknown)"
        case .macBookProIntel2018Baseline: return "MBP Intel 2018"
        case .macMiniM1: return "Mac mini M1"
        case .macBookProM1Pro: return "MBP M1 Pro"
        case .macBookProM1Max: return "MBP M1 Max"
        case .macBookProM2Pro: return "MBP M2 Pro"
        case .macBookProM2Max: return "MBP M2 Max"
        case .macBookProM3Pro: return "MBP M3 Pro"
        case .macBookProM4Pro: return "MBP M4 Pro"
        case .macMiniM2: return "Mac mini M2"
        case .macMiniM4: return "Mac mini M4"
        case .iMacM1: return "iMac M1"
        case .macStudioM1Ultra: return "Mac Studio M1 Ultra"
        case .macStudioM2Ultra: return "Mac Studio M2 Ultra"
        case .macProM2Ultra: return "Mac Pro M2 Ultra"
        }
    }

    private static var injected: MacModelIdentifier?

    static func _testInject(_ value: MacModelIdentifier?) {
        injected = value
    }

    static func detect() -> MacModelIdentifier {
        if let injected = injected { return injected }
        let raw = sysctlString("hw.model") ?? ""
        if let parsed = parse(raw) {
            return parsed
        }
        if raw.range(of: "arm64", options: .caseInsensitive) != nil {
            return .macMiniM1
        }
        return .intelUnknown
    }

    static func parse(_ raw: String) -> MacModelIdentifier? {
        if raw.isEmpty { return nil }
        if let match = MacModelIdentifier(rawValue: raw) { return match }
        if raw.range(of: "MacBookPro15", options: .caseInsensitive) != nil {
            return .macBookProIntel2018Baseline
        }
        if raw.range(of: "arm64", options: .caseInsensitive) != nil {
            return .macMiniM1
        }
        return nil
    }

    private static func sysctlString(_ key: String) -> String? {
        var size: size_t = 0
        if sysctlbyname(key, nil, &size, nil, 0) != 0 { return nil }
        var buf = [CChar](repeating: 0, count: max(size, 1))
        let rc = sysctlbyname(key, &buf, &size, nil, 0)
        guard rc == 0 else { return nil }
        return String(cString: buf)
    }
}
