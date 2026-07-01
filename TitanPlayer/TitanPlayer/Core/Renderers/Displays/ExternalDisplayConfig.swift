import AppKit
import Foundation

struct ExternalDisplayConfig: Codable, Hashable, Identifiable {
    let stableID: String
    let displayName: String
    let colorSpaceName: String?
    let colorGamut: ColorGamut
    let refreshRate: Float
    let hdrSupported: Bool
    let maxEDRLuminance: Float
    let lastSeenAt: Date

    var id: String { stableID }

    var isAirPlayReceiver: Bool { !stableID.hasPrefix("cgdid:") }
}

extension ExternalDisplayConfig {
    static func cgDisplayID(_ id: UInt32) -> String { "cgdid:\(id)" }

    static func airPlay(name: String, size: CGSize, locale: String = "en") -> String {
        "airplay:\(name)|\(Int(size.width))x\(Int(size.height))|\(locale)"
    }
}
