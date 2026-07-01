import Foundation
import CoreGraphics

enum StreamingQuality: Hashable, Codable {
    case auto
    case variant(resolution: CGSize, bitrate: Int, codec: String?)

    var isAuto: Bool {
        if case .auto = self { return true }
        return false
    }

    var displayLabel: String {
        switch self {
        case .auto:
            return "Auto"
        case .variant(let res, let bitrate, _):
            let height = Int(res.height.rounded())
            let mbps = max(1, bitrate / 1_000_000)
            return "\(height)p · \(mbps) Mb/s"
        }
    }
}
