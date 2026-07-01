import Foundation
import CoreGraphics

struct AdaptiveQualityController: Sendable {

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

        func add(_ a: QualityAction) {
            if seen.insert(a).inserted { actions.append(a) }
        }

        let pixels = Int(settings.resolution.width * settings.resolution.height)

        // Rule 1 — decoder bias
        if metrics.isDegraded,
           settings.decoderIsHW,
           systemState.thermalState != .nominal {
            add(.preferHardware(false))
        }
        if mode == .battery, settings.decoderIsHW {
            add(.preferHardware(false))
        }
        if mode == .performance,
           !settings.decoderIsHW,
           systemState.thermalState == .nominal {
            add(.preferHardware(true))
        }

        // Rule 2 — render resolution cap
        let highRisk = prediction.thermalRiskScore > 0.7
        if (highRisk || mode == .battery),
           let cap = ResolutionCap.p1080.maxPixels,
           pixels > cap {
            add(.downscaleRenderTo(.p1080))
        }
        if mode == .battery,
           let cap = ResolutionCap.p720.maxPixels,
           pixels > cap {
            add(.downscaleRenderTo(.p720))
        }

        // Rule 3 — streaming bitrate cap
        let streamingHighRisk = prediction.thermalRiskScore > 0.5
        if streamingHighRisk, settings.isStreaming {
            add(.streamPreferBitrate(min(settings.currentBitrate, 5_000_000)))
        }
        if mode == .battery, settings.isStreaming {
            add(.streamPreferBitrate(min(settings.currentBitrate, 2_500_000)))
        }

        // Rule 4 — audio complexity
        if (mode == .battery || prediction.thermalRiskScore > 0.6),
           settings.audioEngineActive {
            add(.reduceAudioComplexity(.simplified))
        }

        // Rule 5 — prefetch deferral
        if metrics.frameDropRate > 0.05 {
            add(.deferPrefetch(seconds: 2))
        }

        return actions
    }
}
