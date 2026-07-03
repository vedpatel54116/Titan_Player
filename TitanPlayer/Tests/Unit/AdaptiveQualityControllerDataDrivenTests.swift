import XCTest
import CoreGraphics
@testable import TitanPlayer

final class AdaptiveQualityControllerDataDrivenTests: XCTestCase {

    private let hd1080 = CGSize(width: 1920, height: 1080)
    private let fourK = CGSize(width: 3840, height: 2160)

    private func makeSettings(
        decoderIsHW: Bool = true,
        resolution: CGSize = CGSize(width: 1920, height: 1080)
    ) -> CurrentPlaybackSettings {
        CurrentPlaybackSettings(
            decoderIsHW: decoderIsHW,
            resolution: resolution,
            currentBitrate: 8_000_000,
            isStreaming: false,
            audioEngineActive: true
        )
    }

    private var hotCPUState: SystemState {
        var s = SystemStateFixture.nominal()
        s.cpuUsage = 0.80
        s.thermalState = .fair
        return s
    }

    // MARK: - Test 1: HW slow, SW fast → switch to SW

    func test_hotCPU_thermal_HW_swFasterSwitchesToSW() {
        let metrics = PerformanceMetrics(averageDecodeTime: 0.020, frameDropRate: 0.0, isDegraded: false)
        let actions = AdaptiveQualityController().evaluate(
            systemState: hotCPUState, prediction: .zero, metrics: metrics,
            mode: .balanced, settings: makeSettings(resolution: hd1080)
        )
        XCTAssertTrue(actions.contains(.preferHardware(false)),
            "Expected .preferHardware(false) when SW is faster than HW, got: \(actions)")
    }

    // MARK: - Test 2: HW fast, SW slow → downscale instead

    func test_hotCPU_thermal_HW_swSlower_staysHW_downscalesInstead() {
        let metrics = PerformanceMetrics(averageDecodeTime: 0.003, frameDropRate: 0.0, isDegraded: false)
        let actions = AdaptiveQualityController().evaluate(
            systemState: hotCPUState, prediction: .zero, metrics: metrics,
            mode: .balanced, settings: makeSettings(resolution: fourK)
        )
        XCTAssertFalse(actions.contains(.preferHardware(false)),
            "Should NOT emit .preferHardware(false) when HW is faster, got: \(actions)")
        XCTAssertTrue(actions.contains(.downscaleRenderTo(.p1080)),
            "Expected .downscaleRenderTo(.p1080) as lighter alternative, got: \(actions)")
    }

    // MARK: - Test 3: Battery mode always prefers SW

    func test_battery_mode_prefersSW() {
        let metrics = PerformanceMetrics(averageDecodeTime: 0.001, frameDropRate: 0.0, isDegraded: false)
        let actions = AdaptiveQualityController().evaluate(
            systemState: SystemStateFixture.nominal(), prediction: .zero, metrics: metrics,
            mode: .battery, settings: makeSettings(resolution: hd1080)
        )
        XCTAssertTrue(actions.contains(.preferHardware(false)),
            "Battery mode should always prefer SW, got: \(actions)")
    }

    // MARK: - Test 4: Performance mode upswitch requires cooldown

    func test_performance_mode_upswitchRequiresCooldown() {
        let controller = AdaptiveQualityController()

        let degradedMetrics = PerformanceMetrics(averageDecodeTime: 0.05, frameDropRate: 0.08, isDegraded: true)
        var state = SystemStateFixture.nominal()
        state.thermalState = .fair
        _ = controller.evaluate(
            systemState: state, prediction: .zero, metrics: degradedMetrics,
            mode: .balanced, settings: makeSettings(resolution: hd1080)
        )

        let okMetrics = PerformanceMetrics(averageDecodeTime: 0.005, frameDropRate: 0.0, isDegraded: false)
        let nominalState = SystemStateFixture.nominal()
        let actionsBeforeCooldown = controller.evaluate(
            systemState: nominalState, prediction: .zero, metrics: okMetrics,
            mode: .performance, settings: makeSettings(decoderIsHW: false, resolution: hd1080)
        )
        XCTAssertFalse(actionsBeforeCooldown.contains(.preferHardware(true)),
            "Should NOT upswitch before cooldown elapses, got: \(actionsBeforeCooldown)")
    }
}
