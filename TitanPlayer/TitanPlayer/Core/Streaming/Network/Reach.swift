import Foundation

public enum Reach: Equatable, Codable, Sendable {
    case offline
    case wifi
    case cellular
    case wired

    var displayLabel: String {
        switch self {
        case .offline:  return "Offline"
        case .wifi:     return "Wi-Fi"
        case .cellular: return "Cellular"
        case .wired:    return "Ethernet"
        }
    }
}
