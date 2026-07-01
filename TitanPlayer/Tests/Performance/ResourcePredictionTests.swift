import XCTest
@testable import TitanPlayer

final class ResourcePredictionTests: XCTestCase {
    func test_zero_constant_is_all_zero() {
        let z = ResourcePrediction.zero
        XCTAssertEqual(z.cpuUsageEstimate, 0)
        XCTAssertEqual(z.memoryMBEstimate, 0)
        XCTAssertEqual(z.batteryDrainPctPerHour, 0)
        XCTAssertEqual(z.thermalRiskScore, 0)
        XCTAssertEqual(z.confidence, 0)
    }

    func test_init_clamps_cpu_to_unit_interval() {
        let p = ResourcePrediction(
            cpuUsageEstimate: 1.5,
            memoryMBEstimate: 0,
            batteryDrainPctPerHour: 0,
            thermalRiskScore: 0,
            confidence: 0
        )
        XCTAssertEqual(p.cpuUsageEstimate, 1.0)

        let p2 = ResourcePrediction(
            cpuUsageEstimate: -0.5,
            memoryMBEstimate: 0,
            batteryDrainPctPerHour: 0,
            thermalRiskScore: 0,
            confidence: 0
        )
        XCTAssertEqual(p2.cpuUsageEstimate, 0.0)
    }

    func test_init_clamps_confidence_below_one_for_many_samples() {
        let p = ResourcePrediction(
            cpuUsageEstimate: 0,
            memoryMBEstimate: 0,
            batteryDrainPctPerHour: 0,
            thermalRiskScore: 0,
            confidence: 99.0
        )
        XCTAssertEqual(p.confidence, 1.0)
    }
}
