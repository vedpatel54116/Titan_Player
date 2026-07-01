import Foundation
import CoreGraphics

struct CurrentPlaybackSettings: Sendable, Equatable {
    let decoderIsHW: Bool
    let resolution: CGSize
    let currentBitrate: Int
    let isStreaming: Bool
    let audioEngineActive: Bool

    init(
        decoderIsHW: Bool,
        resolution: CGSize,
        currentBitrate: Int,
        isStreaming: Bool,
        audioEngineActive: Bool
    ) {
        self.decoderIsHW = decoderIsHW
        self.resolution = resolution
        self.currentBitrate = currentBitrate
        self.isStreaming = isStreaming
        self.audioEngineActive = audioEngineActive
    }
}

struct ResourcePredictor: Sendable {

    init() {}

    func predict(
        history: PlaybackHistory,
        currentSystemState: SystemState
    ) -> ResourcePrediction {
        let window = history.recent(seconds: 60)
        guard !window.isEmpty else { return .zero }

        let cpuValues = window.map { $0.cpuUsage }
        let cpu = meanPlusStdev(cpuValues, factor: 1.5)

        let memory = medianPixelsToMB(window)

        let drain: Double = 0    // Battery regression deferred; PlaybackSample does not yet
                                 // carry batteryLevel historically.

        let base = thermalBase(currentSystemState.thermalState)
        let thermalRisk = min(1.0, base + (cpu > 0.7 ? 0.2 : 0))

        let confidence = min(1.0, Double(window.count) / 60.0)

        return ResourcePrediction(
            cpuUsageEstimate: cpu,
            memoryMBEstimate: memory,
            batteryDrainPctPerHour: drain,
            thermalRiskScore: thermalRisk,
            confidence: confidence
        )
    }

    // MARK: - Helpers

    private func meanPlusStdev(_ values: [Double], factor: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let stdev = sqrt(variance)
        return max(0, min(1, mean + factor * stdev))
    }

    private func medianPixelsToMB(_ samples: [PlaybackSample]) -> Int {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples
            .map { $0.resolution.width * $0.resolution.height }
            .sorted()
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 0
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
        return Int(Double(median) / 6.0 / 1024.0 / 1024.0)
    }

    private func thermalBase(_ state: SystemState.ThermalState) -> Double {
        switch state {
        case .nominal:  return 0.0
        case .fair:     return 0.3
        case .serious:  return 0.7
        case .critical: return 1.0
        }
    }
}
