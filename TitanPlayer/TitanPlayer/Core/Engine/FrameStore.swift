import Foundation
import Combine
@preconcurrency import Metal
import CoreMedia
import CoreVideo
import OSLog

// MARK: - FrameStoreConfiguration

/// Tunable limits for the frame cache. Every field is a value type, so the
/// configuration is trivially `Sendable` and safe to share across domains.
struct FrameStoreConfiguration: Sendable {
    /// Soft upper bound on the number of retained decoded frames. Exceeding this
    /// triggers least-recently-used eviction.
    var maxCapacity: Int
    /// Floor the cache is never evicted below, even under critical pressure.
    var minimumCapacity: Int
    /// Default deadline applied to blocking cache operations.
    var operationTimeout: Duration

    init(
        maxCapacity: Int = 8,
        minimumCapacity: Int = 2,
        operationTimeout: Duration = .seconds(2)
    ) {
        self.maxCapacity = max(1, maxCapacity)
        self.minimumCapacity = max(1, minimumCapacity)
        self.operationTimeout = operationTimeout
    }

    static let `default` = FrameStoreConfiguration()
}

// MARK: - RetainedPixelBuffer

/// A `Sendable` owner for a non-`Sendable` `CVPixelBuffer`.
///
/// `Unmanaged` is not `Sendable` for an arbitrary `Instance`, so this wrapper is
/// explicitly `@unchecked Sendable`: the `+1` retain taken in `init` guarantees
/// the buffer stays alive for exactly as long as this value exists, and
/// ``release()`` must be called once when the owning cache entry is dropped.
/// This is the mechanism that prevents VideoToolbox from recycling a buffer
/// that the renderer or an in-flight Metal command buffer is still using.
struct RetainedPixelBuffer: @unchecked Sendable {
    private let reference: Unmanaged<CVPixelBuffer>

    init(_ buffer: CVPixelBuffer) {
        self.reference = .passRetained(buffer)
    }

    /// The live buffer. Valid until ``release()`` is called.
    var buffer: CVPixelBuffer { reference.takeUnretainedValue() }

    /// Balance the `+1` retain taken at init.
    func release() {
        reference.release()
    }
}

// MARK: - IncomingFrame

/// `Sendable` crossing type for delivering a decoded frame into the actor.
///
/// A `VideoFrame` is not `Sendable` (it carries a `CVPixelBuffer`), so callers
/// build an `IncomingFrame` at their own isolation — wrapping the buffer in a
/// ``RetainedPixelBuffer`` — and pass the resulting `Sendable` value across the
/// actor boundary.
struct IncomingFrame: Sendable {
    let retained: RetainedPixelBuffer
    let pts: CMTime
    let duration: CMTime
    let colorSpace: ColorSpace
}

// MARK: - CachedFrame

/// A `Sendable` view of a retained decoded frame returned by the cache.
///
/// Consumers read ``pixelBuffer`` on their own isolation domain; the actor
/// guarantees the buffer stays alive until the corresponding cache entry is
/// evicted or explicitly released.
struct CachedFrame: Sendable {
    /// Monotonically increasing token identifying this cache entry.
    let token: UInt64
    /// Presentation timestamp of the decoded frame.
    let pts: CMTime
    /// Frame duration, used by the renderer for pacing.
    let duration: CMTime
    /// Color space the buffer was decoded in.
    let colorSpace: ColorSpace
    /// Retained backing buffer. Access ``pixelBuffer`` rather than the box.
    let retained: RetainedPixelBuffer

    /// The live, still-retained `CVPixelBuffer`. Safe to use on any isolation
    /// domain for the lifetime of this value.
    var pixelBuffer: CVPixelBuffer { retained.buffer }
}

// MARK: - FrameStore

/// Actor-isolated, `Sendable` frame cache for decoded VideoToolbox frames.
///
/// # Overview
/// `FrameStore` owns the lifetime of decoded video frames (their backing
/// `CVPixelBuffer`s) so that VideoToolbox can never recycle a buffer that is
/// still referenced by the renderer or an in-flight Metal command buffer. The
/// previous design exposed a plain `@MainActor` struct holding only the
/// post-tone-map `MTLTexture`; decoded source buffers were handed around from
/// multiple isolation domains without any ownership, which produced the
/// use-after-free class of bugs this type eliminates.
///
/// The type serves two distinct surfaces:
///
/// 1. **Synchronous mirror (``latestTexture``, ``frameID``, ``frameIDPublisher``, ``update(_:)``)** —
///    A lock-protected, `@unchecked Sendable` snapshot of the most recent
///    *rendered* texture. This is the backward-compatible fast path consumed by
///    the synchronous `MTKViewDelegate` draw loop and the analysis manager,
///    which cannot `await` inside a draw call.
///
/// 2. **Actor-isolated frame cache (``store(_:)``, ``cachedFrame(for:)``,
///    ``currentCachedFrame()``, ``release(_:)``, ``flush()``)** — The authoritative,
///    race-free store of retained decoded frames. Every entry keeps a `+1`
///    retain on its `CVPixelBuffer` for as long as it lives in the cache, which
///    is what prevents the use-after-free.
///
/// All fallible operations map their failures onto the centralized ``MediaError``
/// enum, and notable lifecycle events (pressure-driven eviction, timeouts,
/// cancellations) are surfaced through ``TelemetryManager`` via the
/// `TelemetryProviding` protocol — never by touching Sentry directly.
actor FrameStore {

    // MARK: - Public Synchronous Mirror API

    /// Most recently delivered *rendered* texture. Safe to read from any thread;
    /// backed by a lock-protected mirror, never the actor's isolated state.
    nonisolated var latestTexture: MTLTexture? { mirror.texture }

    /// Monotonic identifier of the most recently delivered texture.
    nonisolated var frameID: UInt64 { mirror.frameID }

    /// Publishes ``frameID`` whenever a new texture is delivered via ``update(_:)``.
    nonisolated var frameIDPublisher: AnyPublisher<UInt64, Never> { mirror.publisher }

    /// Deliver a freshly rendered texture to the mirror. Non-isolated so it can
    /// be called from the synchronous Metal draw path without `await`.
    ///
    /// - Parameter texture: The post-tone-map texture to expose for mirroring and
    ///   analysis. The store retains it until the next delivery.
    nonisolated func update(_ texture: MTLTexture) {
        mirror.deliver(texture)
    }

    // MARK: - Frame Cache (Actor-Isolated)

    /// Retain and store a decoded frame.
    ///
    /// - Parameter frame: The `Sendable` ``IncomingFrame`` whose `pixelBuffer`
    ///   will be retained for the lifetime of the cache entry.
    /// - Returns: The cache token used to later retrieve or release the frame.
    /// - Throws: ``MediaError`` if the operation is cancelled or times out.
    func store(_ frame: IncomingFrame) async throws -> UInt64 {
        try throwIfCancelled()
        return try await withTimeout { await self.performStore(frame) }
    }

    /// Retrieve a previously stored frame by token.
    ///
    /// - Parameter token: The token returned from ``store(_:)``.
    /// - Returns: A `Sendable` ``CachedFrame`` snapshot, or `nil` if the entry
    ///   has been evicted or never existed.
    /// - Throws: ``MediaError`` on cancellation or timeout.
    func cachedFrame(for token: UInt64) async throws -> CachedFrame? {
        try throwIfCancelled()
        return try await withTimeout { await self.performCachedFrame(for: token) }
    }

    /// The most recently stored frame, if any.
    ///
    /// - Throws: ``MediaError`` on cancellation or timeout.
    func currentCachedFrame() async throws -> CachedFrame? {
        try throwIfCancelled()
        return try await withTimeout { await self.performCurrentCachedFrame() }
    }

    /// Explicitly drop a frame, releasing its `CVPixelBuffer` retain.
    ///
    /// - Parameter token: The token returned from ``store(_:)``.
    /// - Throws: ``MediaError`` on cancellation.
    func release(_ token: UInt64) async throws {
        try throwIfCancelled()
        try await withTimeout { await self.performRelease(token) }
    }

    /// Drop every cached frame and release all retained buffers. Used on seek,
    /// stop, and teardown to guarantee no dangling `CVPixelBuffer` references.
    ///
    /// - Throws: ``MediaError`` on cancellation.
    func flush() async throws {
        try throwIfCancelled()
        try await withTimeout { await self.performFlush() }
    }

    /// Current number of retained frames.
    var count: Int { cache.count }

    /// Current soft capacity ceiling.
    var capacity: Int {
        get { _capacity }
        set { _capacity = max(configuration.minimumCapacity, newValue) }
    }

    // MARK: - System Condition Monitoring

    /// Handle a memory-pressure signal by shrinking the cache toward the floor.
    ///
    /// - Parameter level: Normalized pressure in `0...1` (`0.5` warning,
    ///   `1.0` critical).
    func handleMemoryPressure(level: Double) async {
        let critical = level >= 0.9
        let target = critical
            ? max(configuration.minimumCapacity, _capacity / 4)
            : max(configuration.minimumCapacity, _capacity / 2)
        let evicted = trim(to: target)
        if evicted > 0 {
            logger.warning("FrameStore evicted \(evicted) frame(s) due to memory pressure (\(level, format: .fixed(precision: 2)))")
        }
        record(.frameCacheEvicted(count: evicted, reason: critical ? "memory-critical" : "memory-warning"))
    }

    /// Handle a thermal-state change by re-sizing the cache and, under critical
    /// load, evicting down to the new ceiling.
    ///
    /// - Parameter state: The current ``ProcessInfo/ThermalState``.
    func handleThermalState(_ state: ProcessInfo.ThermalState) async {
        switch state {
        case .critical:
            _capacity = max(configuration.minimumCapacity, configuration.maxCapacity / 4)
        case .serious:
            _capacity = max(configuration.minimumCapacity, configuration.maxCapacity / 2)
        default:
            _capacity = configuration.maxCapacity
        }
        if state == .critical {
            let evicted = trim(to: _capacity)
            if evicted > 0 {
                logger.warning("FrameStore evicted \(evicted) frame(s) due to critical thermal state")
            }
            record(.frameCacheEvicted(count: evicted, reason: "thermal-critical"))
        }
    }

    // MARK: - Cancellation & Timeouts

    /// Map task cancellation onto ``MediaError`` before performing work.
    private func throwIfCancelled() throws {
        if Task.isCancelled {
            throw MediaError(code: .decodingFailed, message: "FrameStore operation cancelled")
        }
    }

    /// Run an operation with a deadline. On timeout the operation's task is
    /// cancelled and a ``MediaError`` is thrown.
    private func withTimeout<T: Sendable>(
        operation: @escaping @Sendable () async -> T
    ) async throws -> T {
        let deadline = configuration.operationTimeout
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw MediaError(
                    code: .decodingFailed,
                    message: "FrameStore operation exceeded timeout (\(deadline))"
                )
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw MediaError(code: .decodingFailed, message: "FrameStore operation produced no result")
            }
            // Drain the losing task so cancellation propagates cleanly.
            _ = try? await group.next()
            return result
        }
    }

    // MARK: - Telemetry

    /// Emit a telemetry event through ``TelemetryManager`` (via
    /// `TelemetryProviding`), hopping to the main actor. This indirection keeps
    /// Sentry out of the frame store and centralizes reporting policy.
    private func record(_ event: TelemetryEvent) {
        Task { await MainActor.run { TelemetryManager.shared.record(event) } }
    }

    // MARK: - Private Cache Operations

    private func performStore(_ frame: IncomingFrame) -> UInt64 {
        let token = nextToken
        nextToken &+= 1

        let entry = CacheEntry(
            token: token,
            pts: frame.pts,
            duration: frame.duration,
            colorSpace: frame.colorSpace,
            retained: frame.retained,
            enqueuedAt: Date()
        )
        cache[token] = entry

        let overflow = cache.count - capacity
        if overflow > 0 {
            evictLeastRecentlyUsed(count: overflow)
        }
        return token
    }

    private func performCachedFrame(for token: UInt64) -> CachedFrame? {
        cache[token].map { $0.asCachedFrame }
    }

    private func performCurrentCachedFrame() -> CachedFrame? {
        cache.values.max(by: { $0.enqueuedAt < $1.enqueuedAt })?.asCachedFrame
    }

    private func performRelease(_ token: UInt64) {
        if let entry = cache.removeValue(forKey: token) {
            entry.retained.release()
        }
    }

    private func performFlush() {
        for entry in cache.values { entry.retained.release() }
        cache.removeAll()
    }

    // MARK: - Initialization & Teardown

    /// Create a frame store with the supplied configuration and begin observing
    /// system thermal and memory-pressure conditions.
    ///
    /// - Parameter configuration: Cache sizing and timeout tuning.
    init(configuration: FrameStoreConfiguration = .default) {
        self.configuration = configuration
        self._capacity = configuration.maxCapacity

        self.mirror = RenderMirror()
        self.monitorController = MonitorController()
        self.memoryMonitor = MemoryPressureMonitor { [continuation = self.monitorController.continuation] level in
            continuation.yield(level)
        }
        self.monitorController.start(actor: self)
    }

    // MARK: - Private State

    private let configuration: FrameStoreConfiguration
    private var _capacity: Int
    private var nextToken: UInt64 = 0
    private var cache: [UInt64: CacheEntry] = [:]

    private let mirror: RenderMirror
    private let memoryMonitor: MemoryPressureMonitor
    private let monitorController: MonitorController

    private let logger = Logger(subsystem: "com.titanplayer", category: "FrameStore")

    // MARK: - Private Helpers

    private func trim(to target: Int) -> Int {
        guard cache.count > target else { return 0 }
        let excess = cache.count - target
        evictLeastRecentlyUsed(count: excess)
        return excess
    }

    private func evictLeastRecentlyUsed(count: Int) {
        let victims = cache.values
            .sorted { $0.enqueuedAt < $1.enqueuedAt }
            .prefix(count)
        for victim in victims {
            if cache.removeValue(forKey: victim.token) != nil {
                victim.retained.release()
            }
        }
    }

    fileprivate func runMonitoring() async {
        let thermal = NotificationCenter.default
            .notifications(named: ProcessInfo.thermalStateDidChangeNotification)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in thermal {
                    await self.handleThermalState(ProcessInfo.processInfo.thermalState)
                }
            }
            group.addTask { [stream = self.monitorController.stream] in
                for await level in stream {
                    await self.handleMemoryPressure(level: level)
                }
            }
        }
    }
}

// MARK: - CacheEntry

/// Internal, `Sendable` cache node. Holds a retained `CVPixelBuffer` so the
/// backing VideoToolbox buffer stays alive for the entry's entire lifetime.
private struct CacheEntry: Sendable {
    let token: UInt64
    let pts: CMTime
    let duration: CMTime
    let colorSpace: ColorSpace
    let retained: RetainedPixelBuffer
    let enqueuedAt: Date

    var asCachedFrame: CachedFrame {
        CachedFrame(
            token: token,
            pts: pts,
            duration: duration,
            colorSpace: colorSpace,
            retained: retained
        )
    }
}

// MARK: - RenderMirror

/// Lock-protected, `@unchecked Sendable` snapshot of the latest rendered
/// texture and its monotonic `frameID`.
///
/// `@unchecked` is required because the value type is the non-`Sendable`
/// `MTLTexture`, but every access is serialized through an
/// `OSAllocatedUnfairLock`, and the texture is kept alive via a `+1` retain in
/// an `Unmanaged` (which *is* `Sendable`). This is what lets the synchronous
/// `MTKViewDelegate` draw loop read the latest frame without `await` and
/// without a data race.
private final class RenderMirror: @unchecked Sendable {
    private struct Snapshot: @unchecked Sendable {
        let texture: Unmanaged<MTLTexture>?
        let frameID: UInt64
    }

    private let lock = OSAllocatedUnfairLock<Snapshot>(
        initialState: Snapshot(texture: nil, frameID: 0)
    )

    private let subject = PassthroughSubject<UInt64, Never>()

    var texture: MTLTexture? {
        lock.withLock { $0.texture?.takeUnretainedValue() }
    }

    var frameID: UInt64 {
        lock.withLock { $0.frameID }
    }

    var publisher: AnyPublisher<UInt64, Never> {
        subject.eraseToAnyPublisher()
    }

    /// Replace the snapshot, retaining the new texture and releasing the old
    /// one, then publish the new `frameID`.
    @discardableResult
    func deliver(_ texture: MTLTexture?) -> UInt64 {
        let next = lock.withLock { state -> UInt64 in
            if let old = state.texture { old.release() }
            let id = state.frameID &+ 1
            state = Snapshot(texture: texture.map { .passRetained($0) }, frameID: id)
            return id
        }
        subject.send(next)
        return next
    }
}

// MARK: - MemoryPressureMonitor

/// `Sendable` wrapper around a `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE` source.
///
/// The dispatch source runs on its own serial queue; its event handler only
/// forwards a normalized pressure level to a `@Sendable` closure, so it never
/// captures actor-isolated state. The actor consumes the forwarded levels via
/// the ``FrameStore``'s pressure stream, avoiding any retain cycle.
private final class MemoryPressureMonitor: @unchecked Sendable {
    private let source: DispatchSourceMemoryPressure

    init(handler: @escaping @Sendable (Double) -> Void) {
        let queue = DispatchQueue(label: "com.titanplayer.framestore.memorypressure")
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: queue
        )
        self.source = src
        src.setEventHandler { [handler] in
            let level: Double = src.mask.contains(.critical) ? 1.0 : 0.5
            handler(level)
        }
        src.resume()
    }

    deinit {
        source.cancel()
    }
}

// MARK: - MonitorController

/// `Sendable` owner for the monitoring lifecycle (stream, continuation, task).
///
/// Encapsulating these here lets the controller's own `deinit` cancel the
/// monitoring task and finish the pressure stream when the enclosing actor is
/// deallocated — actor `deinit` itself cannot touch actor-isolated state, so
/// this indirection is what makes teardown leak-free (a cancelled task also
/// tears down the otherwise-infinite thermal `NotificationCenter` loop).
private final class MonitorController: @unchecked Sendable {
    let stream: AsyncStream<Double>
    let continuation: AsyncStream<Double>.Continuation
    private var task: Task<Void, Never>?

    init() {
        let (stream, continuation) = AsyncStream<Double>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    func start(actor: FrameStore) {
        task = Task { [weak actor] in
            await actor?.runMonitoring()
        }
    }

    deinit {
        task?.cancel()
        continuation.finish()
    }
}
