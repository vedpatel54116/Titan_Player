import XCTest
import CoreGraphics
@testable import TitanPlayer

final class AdaptiveQualityControllerTests: XCTestCase {

    private let fourK = CGSize(width: 3840, height: 2160)
    private let hd1080 = CGSize(width: 1920, height: 1080)

    private func makeSettings(
        decoderIsHW: Bool = true,
        resolution: CGSize,
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

    private let okMetrics = PerformanceMetrics(
        averageDecodeTime: 0.005,
        frameDropRate: 0.0,
        isDegraded: false
    )
    private let degradedMetrics = PerformanceMetrics(
        averageDecodeTime: 0.05,
        frameDropRate: 0.08,
        isDegraded: true
    )

    private var nominalState: SystemState { SystemStateFixture.nominal() }

    // MARK: - Rule 1: decoder bias

    func test_emits_prefer_hardware_false_when_metrics_degraded_and_thermal_fair() async {
        var s = nominalState; s.thermalState = .fair
        let actions = await AdaptiveQualityController().evaluate(
            systemState: s, prediction: .zero, metrics: degradedMetrics,
            mode: .performance, settings: makeSettings(resolution: hd1080)
        )
        XCTAssertTrue(actions.contains(.preferHardware(false)))
    }

    func test_emits_prefer_hardware_false_for_battery_mode() async {
        let actions = await AdaptiveQualityController().evaluate(
            systemState: nominalState, prediction: .zero, metrics: okMetrics,
            mode: .battery, settings: makeSettings(resolution: hd1080)
        )
        XCTAssertTrue(actions.contains(.preferHardware(false)))
    }

    func test_emits_prefer_hardware_true_for_performance_mode_nominal() async {
        let actions = await AdaptiveQualityController().evaluate(
            systemState: nominalState, prediction: .zero, metrics: okMetrics,
            mode: .performance, settings: makeSettings(
                decoderIsHW: false, resolution: hd1080
            )
        )
        XCTAssertTrue(actions.contains(.preferHardware(true)))
    }

    // MARK: - Rule 2: render resolution cap

    func test_emits_downscale_to_1080_for_high_thermal_risk_with_existing_4k() async {
        let pred = ResourcePrediction(
            cpuUsageEstimate: 0, memoryMBEstimate: 0,
            batteryDrainPctPerHour: 0, thermalRiskScore: 0.8, confidence: 1
        )
        let actions = await AdaptiveQualityController().evaluate(
            systemState: nominalState, prediction: pred, metrics: okMetrics,
            mode: .performance, settings: makeSettings(resolution: fourK)
        )
        XCTAssertTrue(actions.contains(.downscaleRenderTo(.p1080)))
    }

    func test_emits_downscale_to_720_for_battery_mode() async {
        let actions = await AdaptiveQualityController().evaluate(
            systemState: nominalState, prediction: .zero, metrics: okMetrics,
            mode: .battery, settings: makeSettings(resolution: fourK)
        )
        XCTAssertTrue(actions.contains(.downscaleRenderTo(.p720)))
        XCTAssertTrue(actions.contains(.downscaleRenderTo(.p1080)))
    }

    func test_does_not_downscale_for_performance_mode() async {
        let pred = ResourcePrediction(
            cpuUsageEstimate: 0, memoryMBEstimate: 0,
            batteryDrainPctPerHour: 0, thermalRiskScore: 0.9, confidence: 1
        )
        let actions = await AdaptiveQualityController().evaluate(
            systemState: nominalState, prediction: pred, metrics: okMetrics,
            mode: .performance, settings: makeSettings(resolution: fourK)
        )
        XCTAssertFalse(actions.contains(where: {
            if case .downscaleRenderTo = $0 { return true }
            return false
        }))
    }

    // MARK: - Rule 3: streaming bitrate cap

    func test_emits_stream_prefer_bitrate_for_high_thermal_risk_streaming() async {
        let pred = ResourcePrediction(
            cpuUsageEstimate: 0, memoryMBEstimate: 0,
            batteryDrainPctPerHour: 0, thermalRiskScore: 0.6, confidence: 1
        )
        let actions = await AdaptiveQualityController().evaluate(
            systemState: nominalState, prediction: pred, metrics: okMetrics,
            mode: .performance, settings: makeSettings(resolution: hd1080, isStreaming: true)
        )
        XCTAssertTrue(actions.contains(.streamPreferBitrate(5_000_000)))
    }

    func test_emits_stream_prefer_bitrate_for_battery_streaming() async {
        let actions = await AdaptiveQualityController().evaluate(
            systemState: nominalState, prediction: .zero, metrics: okMetrics,
            mode: .battery, settings: makeSettings(resolution: hd1080, isStreaming: true)
        )
        XCTAssertTrue(actions.contains(.streamPreferBitrate(2_500_000)))
    }

    // MARK: - Rule 4: audio complexity

    func test_emits_reduce_audio_complexity_for_battery_mode() async {
        let actions = await AdaptiveQualityController().evaluate(
            systemState: nominalState, prediction: .zero, metrics: okMetrics,
            mode: .battery, settings: makeSettings(resolution: hd1080, audioEngineActive: true)
        )
        XCTAssertTrue(actions.contains(.reduceAudioComplexity(.simplified)))
    }

    // MARK: - Rule 5: prefetch deferral

    func test_emits_defer_prefetch_for_high_frame_drop_rate() async {
        let actions = await AdaptiveQualityController().evaluate(
            systemState: nominalState, prediction: .zero, metrics: degradedMetrics,
            mode: .performance, settings: makeSettings(resolution: hd1080)
        )
        XCTAssertTrue(actions.contains(.deferPrefetch(seconds: 2)))
    }

    // MARK: - Negatives / dedup / ordering

    func test_returns_no_actions_when_balanced_and_nominal() async {
        let actions = await AdaptiveQualityController().evaluate(
            systemState: nominalState, prediction: .zero, metrics: okMetrics,
            mode: .balanced, settings: makeSettings(resolution: hd1080)
        )
        XCTAssertTrue(actions.isEmpty)
    }

    func test_returns_deduplicated_action_list() async {
        // Force dual triggers that emit the same .downscaleRenderTo(.p720) only once.
        let pred = ResourcePrediction(
            cpuUsageEstimate: 0, memoryMBEstimate: 0,
            batteryDrainPctPerHour: 0, thermalRiskScore: 0.99, confidence: 1
        )
        let actions = await AdaptiveQualityController().evaluate(
            systemState: nominalState, prediction: pred, metrics: degradedMetrics,
            mode: .battery, settings: makeSettings(resolution: fourK, isStreaming: true)
        )
        let downscaleCount = actions.filter {
            if case .downscaleRenderTo = $0 { return true }
            return false
        }.count
        XCTAssertEqual(downscaleCount, 1)
    }
}
