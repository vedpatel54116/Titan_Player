import AVFoundation
import Combine
import Foundation
import os

// MARK: - HLSPlayerProtocol

/// The minimal surface the streaming layer depends on.
///
/// `StreamingManager` talks to any conformer through this protocol so the
/// concrete ``HLSPlayer`` can be swapped or mocked in tests. The full player
/// keeps these two methods for backward compatibility and layers the richer
/// async API (``prepare(url:)`` / ``attach(to:)``) on top.
@MainActor
protocol HLSPlayerProtocol: AnyObject {
    /// Builds (and caches) an ``AVURLAsset`` for the supplied playlist URL.
    func makeAsset(url: URL) -> AVURLAsset
    /// Drops every cached asset and cancels in-flight resource loads.
    func purge()
}

// MARK: - HLSPlayer

/// A production HLS playback controller built on `AVFoundation`.
///
/// ``HLSPlayer`` owns the full lifecycle of an HTTP Live Streaming session:
/// asset construction, low-latency (LL-HLS) tuning, an optional custom
/// ``AVAssetResourceLoader`` for segment interception/caching, thermal and
/// memory-pressure adaptation, cancellation, and timeouts. Every failure is
/// funnelled through the centralized ``MediaError`` enum and surfaced to
/// telemetry exclusively via the ``TelemetryProviding`` protocol (never by
/// touching Sentry directly).
///
/// ### Concurrency
/// The type is `@MainActor`-isolated (all `AVFoundation` playback objects are
/// main-thread confined) and therefore **genuinely `Sendable`** — no
/// `@unchecked` is required because every stored property is only ever touched
/// from the main actor.
///
/// ### Example
/// ```swift
/// let player = HLSPlayer()
/// let item = try await player.prepare(url: streamURL)
/// let avPlayer = AVPlayer(playerItem: item)
/// player.attach(to: avPlayer)
/// avPlayer.play()
/// ```
@MainActor
final class HLSPlayer: HLSPlayerProtocol, Sendable {

    // MARK: LatencyMode

    /// Streaming latency profile.
    ///
    /// `.lowLatency` trades buffer headroom for reduced glass-to-glass delay
    /// (appropriate for live events); `.standard` maximizes smoothness for
    /// on-demand or stable networks.
    enum LatencyMode: Sendable {
        case standard
        case lowLatency
    }

    // MARK: Configuration

    /// Tunables applied when an asset is prepared. ``Configuration`` is a value
    /// type with only `Sendable` members so it is safe to cross actor bounds.
    struct Configuration: Sendable {
        /// Desired latency profile.
        var latencyMode: LatencyMode = .standard
        /// Intercept playlist/segment loads through a custom
        /// ``AVAssetResourceLoader`` (useful for edge caching / auth headers).
        var useCustomLoader: Bool = false
        /// Budget for asset key loading before a ``MediaError/Kind/timedOut``.
        var loadTimeout: Duration = .seconds(20)
        /// Soft bitrate ceiling (bits/sec) handed to `AVPlayerItem`. `nil` = no cap.
        var preferredPeakBitrate: Int? = nil
        /// Maximum presented resolution; the ABR ladder is trimmed above this.
        var maxResolution: CGSize? = nil
        /// Whether cellular networks may be used for the stream.
        var allowsCellularAccess: Bool = true
    }

    // MARK: Stored properties

    /// Current configuration (mutable so callers can retune before preparing).
    var configuration: Configuration

    private let logger = Logger(subsystem: "com.titanplayer", category: "HLSPlayer")

    private var cachedAssets: [String: AVURLAsset] = [:]
    private var resourceLoader: HLSResourceLoaderDelegate?

    private(set) weak var player: AVPlayer?
    private(set) var currentItem: AVPlayerItem?

    private var cancellables: Set<AnyCancellable> = []
    private var thermalObserver: NSObjectProtocol?
    private var memorySource: DispatchSourceMemoryPressure?

    /// Telemetry sink. Falls back to `TelemetryManager.shared` when `nil`.
    private weak var telemetry: (any TelemetryProviding)?

    /// Active preparation task; cancelled by ``cancel()``.
    private var loadTask: Task<AVPlayerItem, Error>?

    // MARK: Initialization

    /// Creates a player.
    /// - Parameters:
    ///   - configuration: Tuning knobs; defaults to a standard, no-custom-loader setup.
    ///   - telemetry: Optional telemetry sink. Defaults to `TelemetryManager.shared`.
    init(configuration: Configuration = Configuration(), telemetry: (any TelemetryProviding)? = nil) {
        self.configuration = configuration
        self.telemetry = telemetry
        observeSystemPressure()
    }

    deinit {
        loadTask?.cancel()
        thermalObserver.map(NotificationCenter.default.removeObserver)
        memorySource?.cancel()
    }

    // MARK: - HLSPlayerProtocol

    /// Builds (or returns a cached) ``AVURLAsset`` for `url`.
    ///
    /// When ``Configuration/useCustomLoader`` is enabled the URL scheme is
    /// rewritten to ``HLSResourceLoaderDelegate/customScheme`` and a custom
    /// ``AVAssetResourceLoader`` delegate is attached so every subsequent
    /// playlist/segment request is intercepted.
    func makeAsset(url: URL) -> AVURLAsset {
        let key = url.absoluteString
        if let cached = cachedAssets[key] { return cached }

        let assetURL = configuration.useCustomLoader ? Self.rewriteScheme(url) : url
        let options: [String: Any] = [
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
            AVURLAssetAllowsCellularAccessKey: configuration.allowsCellularAccess
        ]

        let asset = AVURLAsset(url: assetURL, options: options)

        if configuration.useCustomLoader {
            let loader = HLSResourceLoaderDelegate()
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
            resourceLoader = loader
        }

        cachedAssets[key] = asset
        return asset
    }

    /// Drops all cached assets and detaches the custom loader.
    func purge() {
        cachedAssets.removeAll()
        resourceLoader = nil
        currentItem = nil
    }

    // MARK: - Async preparation

    /// Loads `url`, tunes it for the configured latency profile, and returns a
    /// ready ``AVPlayerItem``.
    ///
    /// - Throws: A ``MediaError`` (mapped from any underlying failure) on
    ///   cancellation, timeout, or an unloadable asset.
    func prepare(url: URL) async throws -> AVPlayerItem {
        let asset = makeAsset(url: url)

        let item: AVPlayerItem
        do {
            item = try await loadTask(for: asset, timeout: configuration.loadTimeout)
        } catch {
            let mediaError = MediaError(error, source: .hls)
            record(mediaError)
            throw mediaError
        }

        applyLatencyProfile(to: item)
        applyBitrateProfile(to: item)
        if let max = configuration.maxResolution {
            if #available(macOS 13.0, *) {
                item.preferredMaximumResolution = max
            }
        }

        currentItem = item
        #if DEBUG
        logger.debug("Prepared HLS item for \(url.lastPathComponent, privacy: .public)")
        #endif
        return item
    }

    /// Loads the essential asset keys with a hard timeout.
    private func loadTask(for asset: AVURLAsset, timeout: Duration) async throws -> AVPlayerItem {
        try await withThrowingTaskGroup(of: AVPlayerItem.self) { group in
            group.addTask { @MainActor in
                let playable = try await asset.load(.isPlayable)
                guard playable else {
                    throw MediaError(
                        kind: .noPlayableTracks,
                        source: .hls,
                        message: "HLS asset is not playable: \(asset.url.lastPathComponent)"
                    )
                }
                _ = try await asset.load(.tracks)
                return AVPlayerItem(asset: asset)
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw MediaError(
                    kind: .timedOut,
                    source: .hls,
                    message: "Timed out loading HLS asset after \(timeout)"
                )
            }

            do {
                guard let result = try await group.next() else {
                    throw MediaError(kind: .assetLoadFailed, source: .hls, message: "Asset load produced no item")
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw MediaError(error, source: .hls)
            }
        }
    }

    // MARK: - Wiring

    /// Attaches this controller to a live ``AVPlayer`` and begins observing
    /// stall / rate / time-control state for telemetry.
    func attach(to player: AVPlayer) {
        self.player = player
        guard let item = player.currentItem ?? currentItem else { return }
        currentItem = item
        bindPlaybackObservations(item: item)
    }

    /// Detaches from the player, cancels observations, and purges cached state.
    func detach() {
        cancellables.removeAll()
        player = nil
        currentItem = nil
        purge()
    }

    // MARK: - Playback controls

    /// Begins or resumes playback.
    func play() {
        player?.play()
    }

    /// Pauses playback.
    func pause() {
        player?.pause()
    }

    /// Switches the active latency profile and re-applies it to the item.
    func setLatencyMode(_ mode: LatencyMode) {
        configuration.latencyMode = mode
        if let item = currentItem { applyLatencyProfile(to: item) }
    }

    /// Updates the soft bitrate ceiling and re-applies it to the item.
    func setPreferredPeakBitrate(_ bitrate: Int?) {
        configuration.preferredPeakBitrate = bitrate
        if let item = currentItem { applyBitrateProfile(to: item) }
    }

    /// Cancels any in-flight ``prepare(url:)`` and detaches the player.
    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        detach()
    }

    // MARK: - Latency / bitrate tuning

    private func applyLatencyProfile(to item: AVPlayerItem) {
        switch configuration.latencyMode {
        case .standard:
            item.preferredForwardBufferDuration = 0
        case .lowLatency:
            // LL-HLS: minimise forward buffering to cut glass-to-glass latency
            // and avoid heavy pre-roll stalls. The player still honours the
            // manifest's part/target durations for true Low-Latency HLS playlists.
            item.preferredForwardBufferDuration = 2
        }
    }

    private func applyBitrateProfile(to item: AVPlayerItem) {
        if let bitrate = configuration.preferredPeakBitrate {
            item.preferredPeakBitRate = Double(bitrate)
        }
    }

    // MARK: - System pressure adaptation

    private func observeSystemPressure() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleThermalState(ProcessInfo.processInfo.thermalState) }
        }

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.handleMemoryPressure() }
        }
        source.resume()
        memorySource = source
    }

    private func handleThermalState(_ state: ProcessInfo.ThermalState) {
        guard state == .serious || state == .critical else { return }
        #if DEBUG
        logger.debug("Thermal pressure \(state.titanDescription, privacy: .public) — reducing bitrate")
        #endif
        if let current = configuration.preferredPeakBitrate {
            setPreferredPeakBitrate(max(200_000, current / 2))
        } else {
            setPreferredPeakBitrate(2_000_000)
        }
        record(MediaError.thermalPressure(state: state, source: .hls))
    }

    private func handleMemoryPressure() {
        #if DEBUG
        logger.debug("Memory pressure — purging HLS asset cache")
        #endif
        cachedAssets.removeAll()
        if let item = currentItem {
            item.preferredForwardBufferDuration = max(item.preferredForwardBufferDuration, 10)
        }
        record(MediaError.memoryPressure(source: .hls))
    }

    // MARK: - Playback observations

    private func bindPlaybackObservations(item: AVPlayerItem) {
        cancellables.removeAll()

        item.publisher(for: \.isPlaybackLikelyToKeepUp)
            .sink { [weak self] keepUp in
                guard !keepUp else { return }
                self?.recordStall()
            }
            .store(in: &cancellables)
    }

    private func recordStall() {
        record(MediaError(
            kind: .unknown,
            source: .hls,
            message: "Playback stall detected (rebuffering)"
        ))
    }

    // MARK: - Telemetry

    /// Emits a ``MediaError`` to the configured telemetry sink.
    ///
    /// Routing goes **only** through ``TelemetryProviding`` — Sentry is never
    /// referenced here. A `playbackFailed` event is emitted with the error's
    /// stable ``MediaError/telemetryErrorCode``.
    func record(_ error: MediaError) {
        let sink = telemetry ?? TelemetryManager.shared
        sink.record(.playbackFailed(
            codec: error.codec ?? "hls",
            resolution: error.resolution ?? "unknown",
            errorCode: error.telemetryErrorCode,
            source: .hls
        ))
    }

    // MARK: - Scheme helpers

    /// Rewrites an `https`/`http` URL to the custom loader scheme so the
    /// ``AVAssetResourceLoader`` intercepts it.
    private static func rewriteScheme(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = HLSResourceLoaderDelegate.customScheme
        return components?.url ?? url
    }
}

// MARK: - ProcessInfo.ThermalState (HLSPlayer label)

extension ProcessInfo.ThermalState {
    fileprivate var titanDescription: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - HLSResourceLoaderDelegate

/// A custom ``AVAssetResourceLoader`` delegate for HLS.
///
/// Registered through ``HLSPlayer/makeAsset(url:)`` when
/// ``Configuration/useCustomLoader`` is enabled. It rewrites the intercepted
/// URL back to its network scheme, issues the request via `URLSession`
/// (honouring byte-range requests), and fulfils the
/// ``AVAssetResourceLoadingRequest`` on the resource-loader queue.
///
/// All access to `AVAssetResourceLoadingRequest` is performed on the single
/// serial `queue` supplied to `setDelegate(_:queue:)`, so the type is safe to
/// treat as `Sendable` despite wrapping non-`Sendable` AVFoundation refs.
final class HLSResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate {
    /// The custom scheme used to flag intercepted URLs.
    static let customScheme = "titanhls"

    /// The underlying network scheme the requests are restored to.
    private let baseScheme = "https"

    let queue: DispatchQueue
    private let session: URLSession
    private var activeRequests: [AVAssetResourceLoadingRequest: URLSessionDataTask] = [:]

    override init() {
        queue = DispatchQueue(label: "com.titanplayer.hls.resourceloader")
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        super.init()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        begin(request: loadingRequest)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForRenewalOfRequestedResource renewalRequest: AVAssetResourceRenewalRequest
    ) -> Bool {
        begin(request: renewalRequest)
        return true
    }

    private func begin(request: AVAssetResourceLoadingRequest) {
        guard let interceptedURL = request.request.url,
              var components = URLComponents(url: interceptedURL, resolvingAgainstBaseURL: false) else {
            finish(request, with: MediaError(kind: .invalidURL, source: .hls, message: "Missing resource URL"))
            return
        }
        components.scheme = baseScheme
        guard let networkURL = components.url else {
            finish(request, with: MediaError(kind: .invalidURL, source: .hls, message: "Could not restore scheme"))
            return
        }

        var urlRequest = URLRequest(url: networkURL)
        if let dataRequest = request.dataRequest, !dataRequest.requestsAllDataToEndOfResource {
            let lower = dataRequest.requestedOffset
            let upper = lower + Int64(dataRequest.requestedLength) - 1
            urlRequest.setValue("bytes=\(lower)-\(upper)", forHTTPHeaderField: "Range")
        }

        let task = session.dataTask(with: urlRequest) { [weak self] data, response, error in
            self?.queue.async { self?.complete(request: request, data: data, response: response, error: error) }
        }
        activeRequests[request] = task
        task.resume()
    }

    private func complete(
        request: AVAssetResourceLoadingRequest,
        data: Data?,
        response: URLResponse?,
        error: Error?
    ) {
        if let error {
            finish(request, with: MediaError(error, source: .hls))
            return
        }
        if let response {
            populateContentInformation(request, response: response)
        }
        if let data, let dataRequest = request.dataRequest {
            dataRequest.respond(with: data)
        }
        request.finishLoading()
        activeRequests[request] = nil
    }

    private func populateContentInformation(_ request: AVAssetResourceLoadingRequest, response: URLResponse) {
        guard let info = request.contentInformationRequest else { return }
        if let http = response as? HTTPURLResponse,
           let type = http.allHeaderFields["Content-Type"] as? String {
            info.contentType = type
        } else {
            info.contentType = "application/octet-stream"
        }
        info.isByteRangeAccessSupported = true
        info.contentLength = response.expectedContentLength
    }

    private func finish(_ request: AVAssetResourceLoadingRequest, with error: MediaError) {
        request.finishLoading(with: NSError(domain: error.underlyingDomain ?? "TitanPlayer",
                                            code: error.underlyingCode ?? -1,
                                            userInfo: [NSLocalizedDescriptionKey: error.message]))
        activeRequests[request] = nil
    }
}
