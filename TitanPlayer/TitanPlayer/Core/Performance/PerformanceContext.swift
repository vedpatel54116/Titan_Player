import Foundation

struct PerformanceContext: Sendable {
    let systemState: SystemState
    let metrics: PerformanceMetrics
    let prediction: ResourcePrediction
    let mode: PowerMode
    let settings: CurrentPlaybackSettings

    init(
        systemState: SystemState,
        metrics: PerformanceMetrics,
        prediction: ResourcePrediction,
        mode: PowerMode,
        settings: CurrentPlaybackSettings
    ) {
        self.systemState = systemState
        self.metrics = metrics
        self.prediction = prediction
        self.mode = mode
        self.settings = settings
    }
}
