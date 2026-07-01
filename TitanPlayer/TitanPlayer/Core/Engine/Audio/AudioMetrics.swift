import Foundation

final class AudioMetrics {
    var latency: TimeInterval = 0
    var cpuUsage: Double = 0
    var memoryUsage: UInt64 = 0
    var bufferUnderruns: Int = 0
    var bufferOverruns: Int = 0

    private var startTime: TimeInterval = 0

    init() {
        startTime = Date().timeIntervalSince1970
    }

    func updateLatency(_ latency: TimeInterval) {
        self.latency = latency
    }

    func updateCPUUsage(_ usage: Double) {
        self.cpuUsage = usage
    }

    func updateMemoryUsage(_ usage: UInt64) {
        self.memoryUsage = usage
    }

    func recordBufferUnderrun() {
        bufferUnderruns += 1
    }

    func recordBufferOverrun() {
        bufferOverruns += 1
    }

    func reset() {
        latency = 0
        cpuUsage = 0
        memoryUsage = 0
        bufferUnderruns = 0
        bufferOverruns = 0
    }
}
