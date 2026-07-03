import Foundation
import CoreGraphics

struct PlaybackSample: Sendable, Equatable {
    let timestamp: Date
    let decoderName: String
    let resolution: CGSize
    let fps: Double
    let frameDropRate: Double
    let thermalState: SystemState.ThermalState
    let powerMode: PowerMode
    let codecName: String
    let cpuUsage: Double
    let batteryLevel: Double

    init(
        timestamp: Date,
        decoderName: String,
        resolution: CGSize,
        fps: Double,
        frameDropRate: Double,
        thermalState: SystemState.ThermalState,
        powerMode: PowerMode,
        codecName: String,
        cpuUsage: Double = 0,
        batteryLevel: Double = 1.0
    ) {
        self.timestamp = timestamp
        self.decoderName = decoderName
        self.resolution = resolution
        self.fps = fps
        self.frameDropRate = frameDropRate
        self.thermalState = thermalState
        self.powerMode = powerMode
        self.codecName = codecName
        self.cpuUsage = cpuUsage
        self.batteryLevel = batteryLevel
    }
}

// SAFETY: All mutable state is protected by `lock` (NSLock). Access is
// serialised, so this type is safe to share across concurrency domains.
final class PlaybackHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [PlaybackSample] = []
    let maxSamples: Int

    init(maxSamples: Int = 300) {
        self.maxSamples = maxSamples
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return buffer.count
    }

    func append(_ sample: PlaybackSample) {
        lock.lock()
        buffer.append(sample)
        if buffer.count > maxSamples {
            buffer.removeFirst(buffer.count - maxSamples)
        }
        lock.unlock()
    }

    func recent(seconds window: TimeInterval, now: Date = Date()) -> [PlaybackSample] {
        lock.lock(); defer { lock.unlock() }
        let cutoff = now.addingTimeInterval(-window)
        return buffer.filter { $0.timestamp >= cutoff }
    }

    func all() -> [PlaybackSample] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}
