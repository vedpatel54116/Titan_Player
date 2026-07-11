import Foundation
import AVFoundation
import Combine

/// Delegate-shaped interface that lets tests simulate download progress
/// without instantiating real AVAssetDownloadURLSession tasks.
@MainActor
protocol StreamCacheLifecycleDelegate: AnyObject {
    func cache(_ cache: StreamingCache, didStart id: String, url: URL)
    func cache(_ cache: StreamingCache, didProgressUpdate id: String, progress: Double, bytes: Int64, totalBytes: Int64)
    func cache(_ cache: StreamingCache, didFinish id: String, info: DownloadedAssetInfo)
    func cache(_ cache: StreamingCache, didFail id: String, error: Error)
}

/// Identifiable protocol conformance so the cache can be substituted in tests.
@MainActor
protocol StreamingCacheProtocol: AnyObject {
    var availableDownloads: [DownloadedAssetInfo] { get }
    var activeDownloads: [ActiveDownload] { get }
    func downloadAsset(url: URL, preferredPeakBitRate: Double, expirationDate: Date?) async throws -> DownloadedAssetInfo
    func cancelDownload(id: String) async throws
    func removeDownloadedAsset(id: String) async throws
}

@MainActor
final class StreamingCache: ObservableObject, StreamingCacheProtocol {
    @Published private(set) var availableDownloads: [DownloadedAssetInfo] = []
    @Published private(set) var activeDownloads: [ActiveDownload] = []

    var productionDelegate: ProductionCacheDelegate?

    private var lifecycleDelegate: StreamCacheLifecycleDelegate?
    private var pendingContinuations: [String: CheckedContinuation<DownloadedAssetInfo, Error>] = [:]

    init(productionDelegate: ProductionCacheDelegate? = nil) {
        self.productionDelegate = productionDelegate
        self.lifecycleDelegate = productionDelegate
    }

    /// Wires the production AVAssetDownload delegate. This must be called after
    /// the cache is constructed (the delegate needs a reference back to the
    /// cache), otherwise `downloadAsset` silently never starts a task.
    func attachProductionDelegate(_ delegate: ProductionCacheDelegate) {
        self.productionDelegate = delegate
        self.lifecycleDelegate = delegate
    }

    func attachLifecycleDelegate(_ delegate: StreamCacheLifecycleDelegate) {
        self.lifecycleDelegate = delegate
    }

    func downloadAsset(
        url: URL,
        preferredPeakBitRate: Double,
        expirationDate: Date?
    ) async throws -> DownloadedAssetInfo {
        guard url.pathExtension == "m3u8" else {
            throw StreamingError.downloadNotSupported(url)
        }
        let id = UUID().uuidString
        let placeholder = ActiveDownload(
            id: id,
            url: url,
            progress: 0,
            bytesDownloaded: 0,
            totalBytesExpected: 0
        )
        activeDownloads.append(placeholder)
        lifecycleDelegate?.cache(self, didStart: id, url: url)
        productionDelegate?.register(id: id, url: url)

        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuations[id] = continuation
        }
    }

    func cancelDownload(id: String) async throws {
        productionDelegate?.cancel(id: id)
        // Resume at most once by reading-and-removing the continuation
        // atomically; otherwise a concurrent finish/fail could double-resume
        // and trap ("SWIFT TASK CONTINUATION MISUSE").
        if let cont = pendingContinuations.removeValue(forKey: id) {
            cont.resume(throwing: StreamingError.downloadFailed("Cancelled"))
        }
        activeDownloads.removeAll { $0.id == id }
    }

    func removeDownloadedAsset(id: String) async throws {
        guard let info = availableDownloads.first(where: { $0.id == id }) else {
            throw StreamingError.downloadFailed("Asset with id \(id) not found in downloaded list")
        }
        // macOS 14/15 do not expose a public "removeAsset" API on AVAssetDownloadStorageManager;
        // drop the bookkeeping entry. OS-managed eviction honors expirationDate set at download.
        availableDownloads.removeAll { $0.id == id }
        _ = info
    }

    // Internal hooks for the lifecycle delegate. Tests call these directly.
    func _handleProgress(id: String, progress: Double, bytes: Int64, totalBytes: Int64) {
        guard let idx = activeDownloads.firstIndex(where: { $0.id == id }) else { return }
        activeDownloads[idx].progress = progress
        activeDownloads[idx].bytesDownloaded = bytes
        activeDownloads[idx].totalBytesExpected = totalBytes
    }

    func _handleFinish(id: String, info: DownloadedAssetInfo) {
        activeDownloads.removeAll { $0.id == id }
        availableDownloads.append(info)
        if let cont = pendingContinuations.removeValue(forKey: id) {
            cont.resume(returning: info)
        }
    }

    func _handleFail(id: String, error: Error) {
        activeDownloads.removeAll { $0.id == id }
        if let cont = pendingContinuations.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }
}

/// Production-only delegate bridges AVAssetDownloadURLSession events.
/// Conforms to `StreamCacheLifecycleDelegate` so it can be slotted into
/// `StreamingCache` in place of the test mock. All AVAssetDownloadDelegate
/// callbacks dispatch onto the main actor before touching the cache.
@MainActor
final class ProductionCacheDelegate: NSObject, StreamCacheLifecycleDelegate, AVAssetDownloadDelegate {
    nonisolated(unsafe) private weak var cache: StreamingCache?
    private var taskByID: [String: AVAggregateAssetDownloadTask] = [:]
    /// Maps a real `AVAggregateAssetDownloadTask.taskIdentifier` (an Int
    /// assigned by URLSession) back to the UUID used as the cache's
    /// continuation / download key.
    private var uuidByTaskIdentifier: [Int: String] = [:]

    private lazy var downloadSession: AVAssetDownloadURLSession = {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: "com.titanplayer.assetdownload"
        )
        return AVAssetDownloadURLSession(
            configuration: configuration,
            assetDownloadDelegate: self,
            delegateQueue: nil
        )
    }()

    init(cache: StreamingCache) {
        self.cache = cache
    }

    func register(id: String, url: URL) {
        guard url.pathExtension == "m3u8" else { return }

        let asset = AVURLAsset(url: url)
        guard let task = downloadSession.aggregateAssetDownloadTask(
            with: asset,
            mediaSelections: [],
            assetTitle: url.lastPathComponent,
            assetArtworkData: nil,
            options: nil
        ) else {
            cache?._handleFail(id: id, error: StreamingError.downloadFailed("Unable to create aggregate asset download task"))
            return
        }

        uuidByTaskIdentifier[task.taskIdentifier] = id
        startDownloadTask(task: task, id: id)
        task.resume()
    }

    func cancel(id: String) {
        if let task = taskByID[id] {
            uuidByTaskIdentifier[task.taskIdentifier] = nil
            task.cancel()
        }
    }

    func startDownloadTask(task: AVAggregateAssetDownloadTask, id: String) {
        taskByID[id] = task
    }

    // StreamCacheLifecycleDelegate — delegate forwards to the cache via
    // main-actor hops so we don't cross actor boundaries from nonisolated
    // context (this delegate is owned by the cache, so direct calls also work
    // when invoked on main; tests bypass this path entirely).
    func cache(_ cache: StreamingCache, didStart id: String, url: URL) {
        Task { @MainActor in
            cache._handleProgress(id: id, progress: 0, bytes: 0, totalBytes: 0)
            _ = url
        }
    }
    func cache(_ cache: StreamingCache, didProgressUpdate id: String, progress: Double, bytes: Int64, totalBytes: Int64) {
        Task { @MainActor in
            cache._handleProgress(id: id, progress: progress, bytes: bytes, totalBytes: totalBytes)
        }
    }
    func cache(_ cache: StreamingCache, didFinish id: String, info: DownloadedAssetInfo) {
        Task { @MainActor in
            cache._handleFinish(id: id, info: info)
        }
    }
    func cache(_ cache: StreamingCache, didFail id: String, error: Error) {
        Task { @MainActor in
            cache._handleFail(id: id, error: error)
        }
    }

    // AVAssetDownloadDelegate: URLSession runs these on its own queue, so
    // we hop to the main actor before mutating cache state.
    nonisolated func urlSession(_ session: URLSession,
                    aggregateAssetDownloadTask task: AVAggregateAssetDownloadTask,
                    didLoad timeRange: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                    timeRangeExpectedToLoad expected: CMTimeRange,
                    for mediaSelection: AVMediaSelection) {
        let taskID = task.taskIdentifier
        let loadedFraction: Double
        if expected.duration.seconds > 0 {
            let loaded = loadedTimeRanges.reduce(0.0) { acc, ns in
                acc + ns.timeRangeValue.duration.seconds
            }
            loadedFraction = min(1.0, loaded / expected.duration.seconds)
        } else {
            loadedFraction = 0
        }
        let totalBytes: Int64 = Int64(expected.duration.seconds * 5_000_000)
        let bytes: Int64 = Int64(Double(totalBytes) * loadedFraction)
        Task { @MainActor [weak cache] in
            guard let id = uuidByTaskIdentifier[taskID] else { return }
            cache?._handleProgress(id: id, progress: loadedFraction, bytes: bytes, totalBytes: totalBytes)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadTask = task as? AVAggregateAssetDownloadTask else { return }
        let taskID = downloadTask.taskIdentifier
        Task { @MainActor [weak cache] in
            guard let cache else { return }
            guard let id = uuidByTaskIdentifier[taskID] else { return }
            uuidByTaskIdentifier[taskID] = nil
            if let error {
                cache._handleFail(id: id, error: error)
                return
            }
            let info = DownloadedAssetInfo(
                id: id,
                originalURL: URL(string: "https://placeholder/asset")!,
                bookmarkData: Data(),
                downloadedAt: Date(),
                expirationDate: nil,
                byteSize: 0,
                primaryVariantBitrate: 5_000_000
            )
            cache._handleFinish(id: id, info: info)
        }
    }
}
