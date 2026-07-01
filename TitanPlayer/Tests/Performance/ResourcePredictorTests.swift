import XCTest
import CoreGraphics
@testable import TitanPlayer

final class ResourcePredictorTests: XCTestCase {

    private func makeSample(cpu: Double) -> PlaybackSample {
        PlaybackSample(
            timestamp: Date(),
            decoderName: "X",
            resolution: CGSize(width: 1920, height: 1080),
            fps: 60,
            frameDropRate: 0.01,
            thermalState: .nominal,
            powerMode: .auto,
            codecName: "h264",
            cpuUsage: cpu
        )
    }

    func test_predict_returns_zero_for_empty_history() {
        let p = ResourcePredictor()
        let prediction = p.predict(
            history: PlaybackHistory(maxSamples: 100),
            currentSystemState: SystemStateFixture.nominal()
        )
        XCTAssertEqual(prediction, .zero)
    }

    func test_predict_cpu_estimate_uses_mean_plus_stdev() {
        let history = PlaybackHistory(maxSamples: 100)
        // 6 samples: 0.1,0.2,0.3,0.4,0.5,0.6 → mean=0.35, stdev≈0.187, mean+1.5*stdev≈0.631
        for cpu in [0.1, 0.2, 0.3, 0.4, 0.5, 0.6] {
            history.append(makeSample(cpu: cpu))
        }
        let pred = ResourcePredictor().predict(
            history: history,
            currentSystemState: SystemStateFixture.nominal()
        )
        XCTAssertEqual(pred.cpuUsageEstimate, 0.631, accuracy: 0.02)
    }

    func test_predict_thermal_risk_clamped_at_one() {
        var s = SystemStateFixture.nominal()
        s.thermalState = .critical
        let history = PlaybackHistory(maxSamples: 100)
        history.append(makeSample(cpu: 0.1))
        let pred = ResourcePredictor().predict(history: history, currentSystemState: s)
        XCTAssertEqual(pred.thermalRiskScore, 1.0)
    }

    func test_predict_confidence_scales_with_samples() {
        let history = PlaybackHistory(maxSamples: 100)
        for _ in 0..<30 {
            history.append(makeSample(cpu: 0.2))
        }
        let pred = ResourcePredictor().predict(
            history: history,
            currentSystemState: SystemStateFixture.nominal()
        )
        XCTAssertEqual(pred.confidence, 0.5, accuracy: 0.01)
    }

    func test_predict_battery_drain_zero_in_v1() {
        let history = PlaybackHistory(maxSamples: 100)
        for _ in 0..<10 {
            history.append(makeSample(cpu: 0.1))
        }
        let pred = ResourcePredictor().predict(
            history: history,
            currentSystemState: SystemStateFixture.nominal()
        )
        XCTAssertEqual(pred.batteryDrainPctPerHour, 0)
    }
}
