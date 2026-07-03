import Foundation
import CoreGraphics

final class AdaptiveQualityController: @unchecked Sendable {
    private var lastActionTimes: [QualityAction: Date] = [:]
    private let cooldown: TimeInterval = 5.0
    private let decoderSwitchCooldown: TimeInterval = 10.0
    private let swDecodeEstimator = SWDecodeEstimator()
    private var lastSWSwitchTime: Date?

    init() {}

    func evaluate(
        systemState: SystemState,
        prediction: ResourcePrediction,
        metrics: PerformanceMetrics,
        mode: PowerMode,
        settings: CurrentPlaybackSettings
    ) -> [QualityAction] {
        var actions: [QualityAction] = []
        var seen = Set<QualityAction>()

        func add(_ a: QualityAction, cooldown: TimeInterval) {
            guard seen.insert(a).inserted else { return }
            if let lastTime = lastActionTimes[a] {
                guard Date().timeIntervalSince(lastTime) >= cooldown else { return }
            }
            lastActionTimes[a] = Date()
            if case .preferHardware(false) = a {
                lastSWSwitchTime = Date()
            }
            actions.append(a)
        }

        let now = Date()

        func isOnCooldown(_ a: QualityAction) -> Bool {
            guard let lastTime = lastActionTimes[a] else { return false }
            return now.timeIntervalSince(lastTime) < decoderSwitchCooldown
        }

        let pixels = Int(settings.resolution.width * settings.resolution.height)

        // Rule 1 — decoder bias
        let cpuHigh = systemState.cpuUsage > 0.70
        let thermalHot = systemState.thermalState != .nominal
        let isDegraded = metrics.isDegraded || metrics.frameDropRate > 0.05

        if isDegraded,
           settings.decoderIsHW {
            add(.preferHardware(false), cooldown: decoderSwitchCooldown)
        } else if cpuHigh && thermalHot && settings.decoderIsHW {
            if swDecodeEstimator.shouldPreferSW(
                codec: "unknown",
                resolution: settings.resolution,
                hwDecodeTime: metrics.averageDecodeTime
            ) {
                add(.preferHardware(false), cooldown: decoderSwitchCooldown)
            } else {
                add(.downscaleRenderTo(.p1080), cooldown: cooldown)
            }
        } else if mode == .battery, settings.decoderIsHW {
            add(.preferHardware(false), cooldown: decoderSwitchCooldown)
        }
        let swCooldownSatisfied: Bool = {
            guard let lastSW = lastSWSwitchTime else { return true }
            return Date().timeIntervalSince(lastSW) >= decoderSwitchCooldown
        }()

        if mode == .performance,
           !settings.decoderIsHW,
           systemState.thermalState == .nominal,
           !cpuHigh,
           systemState.cpuUsage < 0.50,
           swCooldownSatisfied,
           !isOnCooldown(.preferHardware(true)) {
            add(.preferHardware(true), cooldown: decoderSwitchCooldown)
        }

        // Rule 2 — render resolution cap
        let highRisk = prediction.thermalRiskScore > 0.7
        if (highRisk || mode == .battery),
           let cap = ResolutionCap.p1080.maxPixels,
           pixels > cap {
            add(.downscaleRenderTo(.p1080), cooldown: cooldown)
        }
        if mode == .battery,
           let cap = ResolutionCap.p720.maxPixels,
           pixels > cap {
            add(.downscaleRenderTo(.p720), cooldown: cooldown)
        }

        // Rule 3 — streaming bitrate cap
        let streamingHighRisk = prediction.thermalRiskScore > 0.5
        if streamingHighRisk, settings.isStreaming {
            add(.streamPreferBitrate(min(settings.currentBitrate, 5_000_000)), cooldown: cooldown)
        }
        if mode == .battery, settings.isStreaming {
            add(.streamPreferBitrate(min(settings.currentBitrate, 2_500_000)), cooldown: cooldown)
        }

        // Rule 4 — audio complexity
        if (mode == .battery || prediction.thermalRiskScore > 0.6),
           settings.audioEngineActive {
            add(.reduceAudioComplexity(.simplified), cooldown: cooldown)
        }

        // Rule 5 — prefetch deferral
        if metrics.frameDropRate > 0.05 {
            add(.deferPrefetch(seconds: 2), cooldown: cooldown)
        }

        return actions
    }
}
