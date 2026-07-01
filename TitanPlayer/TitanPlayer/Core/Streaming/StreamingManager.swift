import Foundation
import AVFoundation
import Combine

enum StreamingRoutingExtension {
    case m3u8, mpd, other

    init(url: URL) {
        switch url.pathExtension.lowercased() {
        case "m3u8": self = .m3u8
        case "mpd":  self = .mpd
        default:     self = .other
        }
    }

    var isHLS: Bool { self == .m3u8 }
}

enum StreamingState: Equatable {
    case idle
    case ready
    case error(String)
}

@MainActor
final class StreamingManager: ObservableObject {
    @Published private(set) var streamingState: StreamingState = .idle
    @Published private(set) var currentQuality: StreamingQuality = .auto
    @Published private(set) var availableQualities: [StreamingQuality] = []
    @Published private(set) var bufferingProgress: Double = 0
    @Published private(set) var reach: Reach = .offline
    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal

    let hlsPlayer: any HLSPlayerProtocol
    let cache: any StreamingCacheProtocol
    let monitor: any NetworkMonitorProtocol
    let statsPublisher: any StatsPublisherProtocol

    @Published private(set) var observedBitrate: Double = 0
    @Published private(set) var stallCount: Int = 0

    private weak var player: AVPlayer?
    private var variantObserver: HLSVariantObserver?
    private var cancellables: Set<AnyCancellable> = []

    init(
        hlsPlayer: any HLSPlayerProtocol,
        cache: any StreamingCacheProtocol,
        networkMonitor: any NetworkMonitorProtocol,
        statsPublisher: any StatsPublisherProtocol
    ) {
        self.hlsPlayer = hlsPlayer
        self.cache = cache
        self.monitor = networkMonitor
        self.statsPublisher = statsPublisher
        forwardMonitor()
    }

    /// Convenience initializer that constructs default production components.
    static func makeDefault() -> StreamingManager {
        StreamingManager(
            hlsPlayer: HLSPlayer(),
            cache: StreamingCache(),
            networkMonitor: NetworkMonitor(),
            statsPublisher: PlaybackStatsPublisher()
        )
    }

    private func forwardMonitor() {
        guard let monitor = monitor as? NetworkMonitor else { return }
        monitor.$reach.assign(to: \.reach, on: self).store(in: &cancellables)
        monitor.$thermalState.assign(to: \.thermalState, on: self).store(in: &cancellables)
    }

    func isStreaming(_ ext: StreamingRoutingExtension) -> Bool {
        ext.isHLS
    }

    func load(url: URL) {
        switch StreamingRoutingExtension(url: url) {
        case .m3u8:
            let asset = hlsPlayer.makeAsset(url: url)
            streamingState = .ready
            currentQuality = .auto
            availableQualities = []
            _ = asset
        case .mpd:
            let dashPlayer = DASHPlayerFactory.player(for: url)
            Task {
                do {
                    let session = try await dashPlayer.streamSession(for: url)
                    _ = session
                    streamingState = .ready
                    currentQuality = .auto
                    availableQualities = await dashPlayer.currentVariants
                } catch {
                    streamingState = .error(error.localizedDescription)
                }
            }
        case .other:
            streamingState = .idle
        }
    }

    func attach(player: AVPlayer) {
        self.player = player
        bindStats()
    }

    func detach() {
        player = nil
        variantObserver?.detach()
        variantObserver = nil
        statsPublisher.detach()
        streamingState = .idle
        currentQuality = .auto
        availableQualities = []
        bufferingProgress = 0
        observedBitrate = 0
        stallCount = 0
    }

    private func bindStats() {
        guard let player else { return }
        statsPublisher.attach(item: player.currentItem ?? AVPlayerItem(url: URL(fileURLWithPath: "/")))
    }

    // MARK: - Performance adaptation seam

    func setPreferredPeakBitrate(_ bitrate: Int) {
        guard let item = player?.currentItem else { return }
        let target = Double(bitrate)
        if item.preferredPeakBitRate != target {
            item.preferredPeakBitRate = target
        }
    }
}

extension StreamingState {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}
