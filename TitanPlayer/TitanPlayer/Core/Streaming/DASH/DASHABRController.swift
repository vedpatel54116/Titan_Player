import Foundation
import Combine

@MainActor
final class DASHABRController: ObservableObject {
    @Published private(set) var currentQuality: DASHQuality
    @Published private(set) var availableQualities: [DASHQuality]

    private var throughputSamples: [Double] = []
    private var consecutiveAboveThreshold = 0
    private var lastSwitchTime: Date = .distantPast
    private let cooldownSeconds: TimeInterval = 5.0
    private let switchUpThreshold: Double = 1.5
    private let switchUpConsecutive: Int = 3
    private let emaAlpha: Double = 0.3
    private let maxSamples = 10

    private(set) var estimatedThroughput: Double = 0

    init(qualities: [DASHQuality], initial: DASHQuality?) throws {
        let sorted = DASHQuality.sortedByBandwidth(qualities)
        guard let initialQuality = initial ?? sorted.first else {
            throw StreamingError.dashNotSupported(URL(string: "dash://empty-manifest")!)
        }
        self._availableQualities = Published(initialValue: sorted)
        self._currentQuality = Published(initialValue: initialQuality)
    }

    func recordThroughput(bytesDownloaded: Int, durationSeconds: Double) {
        guard durationSeconds > 0 else { return }
        let throughput = Double(bytesDownloaded) * 8 / durationSeconds

        if estimatedThroughput == 0 {
            estimatedThroughput = throughput
        } else {
            estimatedThroughput = emaAlpha * throughput + (1 - emaAlpha) * estimatedThroughput
        }

        throughputSamples.append(throughput)
        if throughputSamples.count > maxSamples {
            throughputSamples.removeFirst()
        }

        evaluateQualitySwitch()
    }

    func forceQuality(_ quality: DASHQuality) {
        guard availableQualities.contains(where: { $0.id == quality.id }) else { return }
        currentQuality = quality
        lastSwitchTime = Date()
        consecutiveAboveThreshold = 0
    }

    private func evaluateQualitySwitch() {
        let now = Date()
        guard now.timeIntervalSince(lastSwitchTime) >= cooldownSeconds else { return }

        let currentBandwidth = Double(currentQuality.bandwidth)

        if estimatedThroughput > switchUpThreshold * currentBandwidth {
            consecutiveAboveThreshold += 1
            if consecutiveAboveThreshold >= switchUpConsecutive {
                switchUp()
            }
        } else {
            consecutiveAboveThreshold = 0
            if estimatedThroughput < currentBandwidth {
                switchDown()
            }
        }
    }

    private func switchUp() {
        guard let currentIndex = availableQualities.firstIndex(where: { $0.id == currentQuality.id }),
              currentIndex + 1 < availableQualities.count else { return }

        let candidate = availableQualities[currentIndex + 1]
        if estimatedThroughput > Double(candidate.bandwidth) * 1.2 {
            currentQuality = candidate
            lastSwitchTime = Date()
            consecutiveAboveThreshold = 0
        }
    }

    private func switchDown() {
        let safetyMargin = estimatedThroughput * 0.8
        if let bestFit = availableQualities.last(where: { Double($0.bandwidth) <= safetyMargin }),
           bestFit.id != currentQuality.id {
            currentQuality = bestFit
            lastSwitchTime = Date()
            consecutiveAboveThreshold = 0
        }
    }
}
