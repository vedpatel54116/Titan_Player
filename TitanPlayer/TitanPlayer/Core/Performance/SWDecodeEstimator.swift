import Foundation
import CoreGraphics

struct SWDecodeEstimator: Sendable {

    /// Per-codec estimated SW decode time at 1080p (seconds).
    /// Values are empirical averages for modern Mac hardware.
    private static let baseTimes: [String: TimeInterval] = [
        "h264":    0.008,
        "hevc":    0.012,
        "vp9":     0.015,
        "av1":     0.020,
        "unknown": 0.012
    ]

    private static let hd1080Pixels: Double = 1920 * 1080

    /// Returns `true` when software decode is predicted to be faster than
    /// the current hardware decode path by a meaningful margin.
    ///
    /// - Parameters:
    ///   - codec: Codec identifier string (e.g. "h264", "hevc").
    ///   - resolution: Current playback resolution.
    ///   - hwDecodeTime: Observed average HW decode time from `PerformanceMetrics`.
    func shouldPreferSW(codec: String, resolution: CGSize, hwDecodeTime: TimeInterval) -> Bool {
        let estimatedSW = estimatedSWDecodeTime(codec: codec, resolution: resolution)
        return hwDecodeTime * 1.5 >= estimatedSW
    }

    /// Estimates software decode time for the given codec and resolution.
    func estimatedSWDecodeTime(codec: String, resolution: CGSize) -> TimeInterval {
        let base = Self.baseTimes[codec.lowercased()] ?? Self.baseTimes["unknown"]!
        let pixels = resolution.width * resolution.height
        let scaleFactor = pixels / Self.hd1080Pixels
        return base * scaleFactor
    }
}
