import XCTest
import CoreGraphics
@testable import TitanPlayer

@MainActor
final class PerformanceOptimizerTests: XCTestCase {

    final class RecordingAdapter: AdaptiveSubsystemAdapting {
        var calls: [[QualityAction]] = []
        func apply(_ actions: [QualityAction], context: PerformanceContext) {
            calls.append(actions)
        }
    }

    private func makeSettings(
        decoderIsHW: Bool = true,
        resolution: CGSize = CGSize(width: 1920, height: 1080),
        currentBitrate: Int = 8_000_000,
        isStreaming: Bool = false,
        audioEngineActive: Bool = true
    ) -> CurrentPlaybackSettings {
        CurrentPlaybackSettings(
            decoderIsHW: decoderIsHW,
            resolution: resolution,
            currentBitrate: currentBitrate,
            isStreaming: isStreaming,
            audioEngineActive: audioEngineActive
        )
    }

    func test_init_publishes_thermal_state_from_network_monitor() {
        let monitor = MockPerformanceMonitor()
        let net = MockNetworkMonitor()
        net.inject(.nominal)
        let opt = PerformanceOptimizer(
            monitor: monitor,
            networkMonitor: net,
            history: PlaybackHistory(),
            adapters: []
        )
        XCTAssertEqual(opt.thermalState, .nominal)
    }

    func test_optimize_publishes_power_mode_and_prediction() {
        let monitor = MockPerformanceMonitor()
        let net = MockNetworkMonitor()
        monitor.inject(.nominal)
        net.inject(.nominal)
        let opt = PerformanceOptimizer(
            monitor: monitor,
            networkMonitor: net,
            history: PlaybackHistory(),
            adapters: []
        )
        opt.observe(settings: makeSettings())
        opt.optimizeForCurrentState()
        XCTAssertEqual(opt.powerMode, .performance)
        XCTAssertGreaterThanOrEqual(opt.prediction.confidence, 0)
    }

    func test_optimize_applies_actions_through_adapters() {
        let monitor = MockPerformanceMonitor()
        let net = MockNetworkMonitor()
        monitor.inject(.critical)
        net.inject(.critical)
        monitor.injectBattery(state: .discharging, level: 0.05)

        let adapter = RecordingAdapter()
        let opt = PerformanceOptimizer(
            monitor: monitor, networkMonitor: net,
            history: PlaybackHistory(), adapters: [adapter]
        )
        opt.observe(settings: makeSettings(
            decoderIsHW: true,
            resolution: CGSize(width: 3840, height: 2160),
            currentBitrate: 8_000_000,
            isStreaming: true,
            audioEngineActive: true
        ))
        opt.optimizeForCurrentState()

        XCTAssertFalse(adapter.calls.isEmpty)
        let flat = adapter.calls.flatMap { $0 }
        XCTAssertTrue(flat.contains(where: {
            if case .preferHardware = $0 { return true } else { return false }
        }))
        XCTAssertTrue(flat.contains(where: {
            if case .downscaleRenderTo = $0 { return true } else { return false }
        }))
        XCTAssertTrue(flat.contains(where: {
            if case .streamPreferBitrate = $0 { return true } else { return false }
        }))
        XCTAssertTrue(flat.contains(where: {
            if case .reduceAudioComplexity = $0 { return true } else { return false }
        }))
    }

    func test_force_power_mode_battery_overrides_auto_derivation() {
        let monitor = MockPerformanceMonitor()
        let net = MockNetworkMonitor()
        monitor.inject(.nominal)
        net.inject(.nominal)
        let opt = PerformanceOptimizer(
            monitor: monitor, networkMonitor: net,
            history: PlaybackHistory(), adapters: []
        )
        opt.observe(settings: makeSettings())
        opt.forcePowerMode(.battery)
        opt.optimizeForCurrentState()
        XCTAssertEqual(opt.powerMode, .battery)
    }

    func test_force_power_mode_performance_overrides_critical_thermal() {
        let monitor = MockPerformanceMonitor()
        let net = MockNetworkMonitor()
        monitor.inject(.critical)
        net.inject(.critical)
        let opt = PerformanceOptimizer(
            monitor: monitor, networkMonitor: net,
            history: PlaybackHistory(), adapters: []
        )
        opt.observe(settings: makeSettings())
        opt.forcePowerMode(.performance)
        opt.optimizeForCurrentState()
        XCTAssertEqual(opt.powerMode, .performance)
    }

    func test_history_appends_a_sample_per_optimize_call() {
        let monitor = MockPerformanceMonitor()
        let net = MockNetworkMonitor()
        monitor.inject(.nominal); net.inject(.nominal)
        let opt = PerformanceOptimizer(
            monitor: monitor, networkMonitor: net,
            history: PlaybackHistory(maxSamples: 10), adapters: []
        )
        opt.observe(settings: makeSettings())
        for _ in 0..<3 { opt.optimizeForCurrentState() }
        XCTAssertEqual(opt.historyCount, 3)
    }

    func test_optimize_idempotent_when_state_unchanged() {
        let monitor = MockPerformanceMonitor()
        let net = MockNetworkMonitor()
        monitor.inject(.nominal)
        net.inject(.nominal)
        let adapter = RecordingAdapter()
        let opt = PerformanceOptimizer(
            monitor: monitor, networkMonitor: net,
            history: PlaybackHistory(), adapters: [adapter]
        )
        opt.observe(settings: makeSettings())
        opt.optimizeForCurrentState()
        let firstCall = adapter.calls.first
        opt.optimizeForCurrentState()
        XCTAssertEqual(firstCall, adapter.calls.last)
    }
}
