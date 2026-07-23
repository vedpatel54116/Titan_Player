import Foundation

struct VideoCodecInfo: Codable, Hashable, Sendable {
    let codec: String
    let profile: String?
    let bitDepth: Int?
    let colorSpace: String?
}
