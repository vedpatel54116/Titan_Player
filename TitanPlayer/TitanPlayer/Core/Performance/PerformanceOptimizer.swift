import Foundation
import Combine
import CoreGraphics

@MainActor
final class PerformanceOptimizer: ObservableObject {

    @Published private(set) var powerMode: PowerMode = .unknown
    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    @Published private(set) var prediction: ResourcePrediction = .zero
    @Published private(set) var currentActions: [QualityAction] = []
    @Published private(set) var batteryState: SystemState.BatteryState = .unknown

    var historyCount: Int { history.count }

    private let monitor: any PerformanceMonitorProtocol
    private let networkMonitor: any NetworkMonitorProtocol
    private let history: PlaybackHistory
    private let adapters: [any AdaptiveSubsystemAdapting]
    private let predictor = ResourcePredictor()
    private let controller = AdaptiveQualityController()

    private var userChoice: PowerMode = .auto
    private var lastSettings: CurrentPlaybackSettings?
    private var lastDerivedMode: PowerMode = .unknown
    private var lastActions: [QualityAction] = []
    private var lastBatteryState: SystemState.BatteryState = .unknown

    init(
        monitor: any PerformanceMonitorProtocol,
        networkMonitor: any NetworkMonitorProtocol,
        history: PlaybackHistory,
        adapters: [any AdaptiveSubsystemAdapting]
    ) {
        self.monitor = monitor
        self.networkMonitor = networkMonitor
        self.history = history
        self.adapters = adapters
        self.thermalState = networkMonitor.thermalState
    }

    func observe(settings: CurrentPlaybackSettings?) {
        lastSettings = settings
    }

    func forcePowerMode(_ choice: PowerMode) {
        userChoice = choice
    }

    func optimizeForCurrentState() {
        let systemState = monitor.currentSystemState
        let metrics = monitor.recentMetrics
        let settings = lastSettings ?? defaultSettings()

        let mode = PowerMode(
            userChoice: userChoice,
            systemState: systemState,
            isExternalPower: isExternalPower(systemState)
        )

        powerMode = mode
        thermalState = networkMonitor.thermalState
        batteryState = systemState.batteryState
        lastBatteryState = systemState.batteryState

        let sample = PlaybackSample(
            timestamp: Date(),
            decoderName: settings.decoderIsHW ? "HW" : "SW",
            resolution: settings.resolution,
            fps: 60,
            frameDropRate: metrics.frameDropRate,
            thermalState: systemState.thermalState,
            powerMode: mode,
            codecName: "unknown",
            cpuUsage: systemState.cpuUsage
        )
        history.append(sample)

        let prediction = predictor.predict(
            history: history,
            currentSystemState: systemState
        )
        self.prediction = prediction

        let actions = controller.evaluate(
            systemState: systemState,
            prediction: prediction,
            metrics: metrics,
            mode: mode,
            settings: settings
        )
        currentActions = actions

        let ctx = PerformanceContext(
            systemState: systemState,
            metrics: metrics,
            prediction: prediction,
            mode: mode,
            settings: settings
        )
        for adapter in adapters {
            adapter.apply(actions, context: ctx)
        }

        lastDerivedMode = mode
        lastActions = actions
        
        // Record performance snapshot for telemetry (every cycle)
        let resolution = "\(Int(settings.resolution.width))x\(Int(settings.resolution.height))"
        TelemetryManager.shared.record(.performanceSnapshot(
            averageCPU: systemState.cpuUsage * 100,
            averageGPU: 0, // GPU usage not directly available from system state
            resolution: resolution,
            codec: settings.decoderIsHW ? "hardware" : "software"
        ))
    }

    static func makeDefault() -> PerformanceOptimizer {
        let monitor = PerformanceMonitor()
        let net = NetworkMonitor()
        return PerformanceOptimizer(
            monitor: monitor,
            networkMonitor: net,
            history: PlaybackHistory(),
            adapters: []
        )
    }

    private func isExternalPower(_ s: SystemState) -> Bool {
        s.batteryState == .charging || s.batteryState == .full
    }

    private func defaultSettings() -> CurrentPlaybackSettings {
        CurrentPlaybackSettings(
            decoderIsHW: false,
            resolution: CGSize(width: 1920, height: 1080),
            currentBitrate: 0,
            isStreaming: false,
            audioEngineActive: false
        )
    }
}
