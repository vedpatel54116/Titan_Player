import Foundation

public struct ResourcePrediction: Sendable, Equatable {
    public var cpuUsageEstimate: Double
    public var memoryMBEstimate: Int
    public var batteryDrainPctPerHour: Double
    public var thermalRiskScore: Double
    public var confidence: Double

    public init(
        cpuUsageEstimate: Double,
        memoryMBEstimate: Int,
        batteryDrainPctPerHour: Double,
        thermalRiskScore: Double,
        confidence: Double
    ) {
        self.cpuUsageEstimate = max(0, min(1, cpuUsageEstimate))
        self.memoryMBEstimate = max(0, memoryMBEstimate)
        self.batteryDrainPctPerHour = max(0, batteryDrainPctPerHour)
        self.thermalRiskScore = max(0, min(1, thermalRiskScore))
        self.confidence = max(0, min(1, confidence))
    }

    public static let zero = ResourcePrediction(
        cpuUsageEstimate: 0,
        memoryMBEstimate: 0,
        batteryDrainPctPerHour: 0,
        thermalRiskScore: 0,
        confidence: 0
    )
}
