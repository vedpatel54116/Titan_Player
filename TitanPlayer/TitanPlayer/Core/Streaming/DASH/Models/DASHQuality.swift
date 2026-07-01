import Foundation

struct DASHQuality: Identifiable, Hashable, Sendable {
    let id: String
    let bandwidth: Int
    let width: Int?
    let height: Int?
    let codec: String?
    let mimeType: String?
    let baseUrl: String?

    var resolutionLabel: String {
        guard let w = width, let h = height else { return "unknown" }
        return "\(w)x\(h)"
    }
}

extension DASHQuality {
    static func sortedByBandwidth(_ qualities: [DASHQuality]) -> [DASHQuality] {
        qualities.sorted { $0.bandwidth < $1.bandwidth }
    }
}
