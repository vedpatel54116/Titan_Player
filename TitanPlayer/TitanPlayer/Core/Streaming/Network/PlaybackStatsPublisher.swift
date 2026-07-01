import Foundation
import AVFoundation
import Combine

protocol AccessLogProviding {
    var observedBitrate: Double { get }
    var indicatedBitrate: Double { get }
    var numberOfStalls: Int { get }
    var numberOfDroppedFrames: Int { get }
}

@MainActor
final class PlaybackStatsPublisher: ObservableObject {
    @Published private(set) var observedBitrate: Double = 0
    @Published private(set) var indicatedBitrate: Double = 0
    @Published private(set) var stallCount: Int = 0
    @Published private(set) var numberOfDroppedFrames: Int = 0

    private let timerInterval: TimeInterval
    private var provider: (any AccessLogProviding)?
    private var timer: Timer?

    init(timerInterval: TimeInterval = 1.0) {
        self.timerInterval = timerInterval
    }

    func attach(item: AVPlayerItem) {
        attach(provider: AVPlayerItemAccessLogProvider(item: item))
    }

    func attach(provider: any AccessLogProviding) {
        self.provider = provider
        startTimer()
    }

    func detach() {
        timer?.invalidate()
        timer = nil
        provider = nil
        observedBitrate = 0
        indicatedBitrate = 0
        stallCount = 0
        numberOfDroppedFrames = 0
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: timerInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
    }

    private func sample() {
        guard let provider else { return }
        observedBitrate = provider.observedBitrate
        indicatedBitrate = provider.indicatedBitrate
        stallCount = provider.numberOfStalls
        numberOfDroppedFrames = provider.numberOfDroppedFrames
    }
}

/// Production adapter — reads the last access-log event.
@MainActor
struct AVPlayerItemAccessLogProvider: AccessLogProviding {
    let item: AVPlayerItem

    var observedBitrate: Double {
        item.accessLog()?.events.last?.observedBitrate ?? 0
    }
    var indicatedBitrate: Double {
        item.accessLog()?.events.last?.indicatedBitrate ?? 0
    }
    var numberOfStalls: Int {
        item.accessLog()?.events.last?.numberOfStalls ?? 0
    }
    var numberOfDroppedFrames: Int {
        item.accessLog()?.events.last?.numberOfDroppedVideoFrames ?? 0
    }
}

protocol StatsPublisherProtocol: AnyObject {
    func attach(item: AVPlayerItem)
    func detach()
}
extension PlaybackStatsPublisher: StatsPublisherProtocol {}
