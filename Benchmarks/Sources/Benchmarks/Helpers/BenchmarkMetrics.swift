import Foundation

/// Result of a benchmark run: averaged CPU usage and peak resident memory.
struct BenchmarkMetrics: Sendable {
    let cpuAverage: Double
    let memoryPeakBytes: Int64

    static let zero = BenchmarkMetrics(cpuAverage: 0, memoryPeakBytes: 0)
}

/// Samples `proxy.cpuUsage` and `proxy.memoryUsage` periodically while
/// `start()` is in flight, returning aggregated metrics on `stop()`.
@MainActor
final class BenchmarkMetricsCollector {
    private var samples: [Double] = []
    private var peakBytes: Int64 = 0
    private var timer: Timer?
    private let interval: TimeInterval
    private weak var proxy: EnginePerformanceProbe?

    init(interval: TimeInterval = 0.1) {
        self.interval = interval
    }

    func start(proxy: EnginePerformanceProbe) {
        self.proxy = proxy
        samples.removeAll(keepingCapacity: true)
        peakBytes = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let proxy = proxy else { return }
        proxy.refreshFromSystem()
        samples.append(proxy.cpuUsage)
        if proxy.memoryUsage > peakBytes {
            peakBytes = proxy.memoryUsage
        }
    }

    func stop() -> BenchmarkMetrics {
        timer?.invalidate()
        timer = nil
        let avg = samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count)
        return BenchmarkMetrics(cpuAverage: avg, memoryPeakBytes: peakBytes)
    }
}
