import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

@MainActor
enum H264_4KCPUAndMemoryBenchmark {
    /// Run a single playback session against `fixtureURL`, sampling CPU and
    /// memory at the cadence defined by `BenchmarkMetricsCollector`. Returns
    /// aggregated metrics for assertion against the baseline ceilings.
    static func run(
        forSeconds seconds: Double,
        fixtureURL: URL,
        probe: EnginePerformanceProbe
    ) async throws -> BenchmarkMetrics {
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw BenchmarkError.fixtureMissing(fixtureURL.path)
        }

        let collector = BenchmarkMetricsCollector()
        collector.start(proxy: probe)
        defer { _ = collector.stop() }

        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: fixtureURL)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.playImmediately(atRate: 1.0)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        player.pause()
        #endif

        probe.refreshFromSystem()
        return collector.stop()
    }

    enum BenchmarkError: Error, CustomStringConvertible {
        case fixtureMissing(String)
        var description: String {
            switch self {
            case .fixtureMissing(let s): return "fixture not found: \(s)"
            }
        }
    }
}
