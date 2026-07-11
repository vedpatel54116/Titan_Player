import AVFoundation
import Combine
import Foundation

@MainActor
protocol ExternalPlaybackMonitoring: AnyObject {
    var isExternalPlaybackActive: Bool { get }
}

extension AVPlayer: ExternalPlaybackMonitoring {
    nonisolated var isExternalPlaybackActive: Bool {
        // AVPlayer's stored property is observable via KVO; we expose it lazily.
        MainActor.assumeIsolated { rawValue }
    }

    private var rawValue: Bool {
        // Use the official API; KVO-compliant.
        self.value(forKey: "externalPlaybackActive") as? Bool ?? false
    }
}

@MainActor
final class MockExternalPlaybackMonitor: ExternalPlaybackMonitoring {
    private let subject: CurrentValueSubject<Bool, Never>
    var isExternalPlaybackActive: Bool { subject.value }
    var publisher: AnyPublisher<Bool, Never> { subject.eraseToAnyPublisher() }

    init(initial: Bool = false) { self.subject = CurrentValueSubject(initial) }

    func setActive(_ value: Bool) { subject.send(value) }
}

@MainActor
final class AirPlayController: ObservableObject {
    @Published private(set) var isExternalPlaybackActive: Bool = false
    @Published private(set) var currentAudioDelayOffset: TimeInterval = 0

    private let monitor: ExternalPlaybackMonitoring
    private let defaultDelay: TimeInterval
    private let subject = PassthroughSubject<Bool, Never>()
    private var cancellable: AnyCancellable?
    private var kvoObserver: NSKeyValueObservation?
    private var userOverride: TimeInterval?

    init(
        monitor: ExternalPlaybackMonitoring,
        defaultDelay: TimeInterval = 0.08
    ) {
        self.monitor = monitor
        self.defaultDelay = defaultDelay
        if let mock = monitor as? MockExternalPlaybackMonitor {
            cancellable = mock.publisher
                .removeDuplicates()
                .sink { [weak self] _ in self?.refresh() }
        } else if let player = monitor as? AVPlayer {
            // The real AVPlayer exposes `externalPlaybackActive` via KVO. Observe
            // it so AirPlay routing changes during playback update our state,
            // mirroring the mock path (which previously was the only one wired).
            kvoObserver = player.observe(\.isExternalPlaybackActive, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        refresh()
    }

    deinit {
        cancellable?.cancel()
        kvoObserver?.invalidate()
    }

    func refresh() {
        let active = monitor.isExternalPlaybackActive
        if active == isExternalPlaybackActive { return }
        isExternalPlaybackActive = active
        if active {
            currentAudioDelayOffset = userOverride ?? defaultDelay
        } else {
            currentAudioDelayOffset = userOverride ?? 0
        }
    }

    func setAudioDelayOffset(_ offset: TimeInterval) {
        userOverride = offset
        currentAudioDelayOffset = offset
    }
}
