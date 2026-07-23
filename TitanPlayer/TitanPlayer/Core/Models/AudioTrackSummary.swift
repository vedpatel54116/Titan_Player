import Foundation

struct AudioTrackSummary: Codable, Hashable, Sendable {
    let codec: String
    let channels: Int
    let sampleRate: Double
    let language: String?
}
