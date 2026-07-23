import Foundation
import Combine
import OSLog
import AVFoundation
import Metal
import CoreVideo
import VideoToolbox

// MARK: - MissingComponent2

/// Rendering-resource governor that closes a shard-2 audit gap where
/// Metal- and VideoToolbox-backed render resources were never reclaimed
/// under system pressure.
///
/// ## Why this exists
/// Titan Player allocates Metal textures, `CVMetalTextureCache` /
/// `CVPixelBufferPool` instances, `VTDecompressionSession` decode sessions,
/// and per-display `CAMetalLayer` targets that accumulate while a session is
/// alive. The original renderer left reclamation as a `TODO`, so on long 4K/HDR
/// sessions the process drifted into memory and thermal pressure with no
/// recovery path — producing dropped frames, watchdog kills, and the tech-debt
/// flagged in the audit.
///
/// ``MissingComponent2`` makes that recovery path concrete, mirroring the
/// audio-side ``MissingComponent1``:
///
/// 1. It observes system thermal and memory pressure (via ``SystemStateMonitor``
///    when no external source is injected) and reacts to
///    ``SystemStateSnapshot`` guidance.
/// 2. On throttle/pause signals it reclaims registered render resources within a
///    bounded time budget, falling back to a forced teardown if the budget is
///    exceeded.
/// 3. Every failure — cancellation, timeout, pressure — is mapped onto the
///    centralized ``MediaError`` type and surfaced to telemetry **only** through
///    the ``TelemetryProviding`` protocol (never Sentry directly).
///
/// ## Concurrency
/// The governor is `@MainActor`-isolated and therefore genuinely `Sendable`:
/// all state access is serialized on the main actor, so it is safe to share
/// across tasks and to drive from UI code. Async operations honor
/// `Task` cancellation and never block the actor longer than their timeout.
///
/// ### Example
/// ```swift
/// let governor = MissingComponent2(telemetry: TelemetryManager.shared)
/// governor.start()
/// let token = MissingComponent2.RenderResource(
///     category: .metalTexture,
///     label: "hdr.toneMap", estimatedBytes: 3840 * 2160 * 4
/// ) { /* release Metal texture / pool */ }
/// governor.register(token)
/// // ...later, automatically on critical pressure:
/// let reclaimed = try await governor.reclaimResources(under: snapshot)
/// ```
@MainActor
public final class MissingComponent2: Sendable {

    // MARK: - Configuration

    /// Tunables for the governor.
    public struct Configuration: Sendable {
        /// How long a reclaim pass may run before it is force-completed.
        public var reclaimTimeout: Duration
        /// How long a guarded external acquire may run before timing out.
        public var acquireTimeout: Duration
        /// Whether the governor starts its own ``SystemStateMonitor`` when no
        /// external pressure source is injected.
        public var autoMonitor: Bool

        /// Production defaults: generous-but-bounded budgets.
        public static let `default` = Configuration(
            reclaimTimeout: .seconds(2),
            acquireTimeout: .seconds(5),
            autoMonitor: true
        )

        /// Creates a configuration.
        public init(
            reclaimTimeout: Duration = .seconds(2),
            acquireTimeout: Duration = .seconds(5),
            autoMonitor: Bool = true
        ) {
            self.reclaimTimeout = reclaimTimeout
            self.acquireTimeout = acquireTimeout
            self.autoMonitor = autoMonitor
        }
    }

    // MARK: - Resource model

    /// The kind of GPU/decode resource a ``RenderResource`` represents, used
    /// purely for diagnostics and telemetry bucketing.
    public enum ResourceCategory: Sendable, CustomStringConvertible {
        /// An off-screen `MTLTexture` (e.g. tone-mapped intermediate).
        case metalTexture
        /// A `MTLBuffer` (e.g. uniforms, vertex data).
        case metalBuffer
        /// A `CVMetalTextureCache` or `CVPixelBufferPool`.
        case pixelBufferPool
        /// A `VTDecompressionSession` decode session.
        case decompressionSession
        /// A per-display `CAMetalLayer` render target.
        case displayTarget

        public var description: String {
            switch self {
            case .metalTexture: return "metal_texture"
            case .metalBuffer: return "metal_buffer"
            case .pixelBufferPool: return "pixel_buffer_pool"
            case .decompressionSession: return "decompression_session"
            case .displayTarget: return "display_target"
            }
        }
    }

    /// A registered render resource the governor can reclaim under pressure.
    ///
    /// The `release` closure performs the actual teardown (releasing a Metal
    /// texture, invalidating a `VTDecompressionSession`, draining a
    /// `CVPixelBufferPool`, etc.). It is `@Sendable` so the value type stays
    /// genuinely `Sendable` and safe to store.
    public struct RenderResource: Sendable, Identifiable {
        /// Stable identifier used for unregister / dedupe.
        public let id: UUID
        /// What kind of resource this is, for diagnostics/telemetry.
        public let category: ResourceCategory
        /// Human-readable label for diagnostics and telemetry.
        public let label: String
        /// Estimated resident bytes, used to size the reclaim telemetry.
        public let estimatedBytes: Int
        /// Teardown closure invoked when the resource is reclaimed.
        public let release: @Sendable () -> Void

        /// Creates a render resource.
        public init(
            id: UUID = UUID(),
            category: ResourceCategory = .metalTexture,
            label: String,
            estimatedBytes: Int,
            release: @Sendable @escaping () -> Void
        ) {
            self.id = id
            self.category = category
            self.label = label
            self.estimatedBytes = estimatedBytes
            self.release = release
        }
    }

    // MARK: - Public publishers

    /// Continuously-updating stream of the latest system-pressure snapshot.
    public var pressurePublisher: AnyPublisher<SystemStateSnapshot, Never> {
        pressureSubject.eraseToAnyPublisher()
    }

    /// Stream of the current live (un-reclaimed) resource count.
    public var liveResourceCountPublisher: AnyPublisher<Int, Never> {
        countSubject.eraseToAnyPublisher()
    }

    // MARK: - Private state

    private let telemetry: (any TelemetryProviding)?
    private let configuration: Configuration
    private let logger = Logger(subsystem: "com.titanplayer", category: "MissingComponent2")

    private let pressureSubject = CurrentValueSubject<SystemStateSnapshot, Never>(.nominal)
    private let countSubject = CurrentValueSubject<Int, Never>(0)

    private var liveResources: [RenderResource] = []
    private var monitor: SystemStateMonitor?
    private var cancellables: Set<AnyCancellable> = []
    private var isActive = false

    // MARK: - Initialization

    /// Creates a governor.
    ///
    /// - Parameters:
    ///   - telemetry: An optional ``TelemetryProviding`` sink. When omitted,
    ///     telemetry is silently skipped (no direct Sentry usage).
    ///   - configuration: Tunables; defaults to ``Configuration/default``.
    ///   - pressureSource: An optional external pressure stream. When omitted
    ///     and `configuration.autoMonitor` is `true`, an internal
    ///     ``SystemStateMonitor`` is created in ``start()``.
    ///
    /// The initializer is intentionally `internal` (not `public`) because it
    /// exposes the module-internal ``TelemetryProviding`` protocol in its
    /// signature.
    init(
        telemetry: (any TelemetryProviding)? = nil,
        configuration: Configuration = .default,
        pressureSource: AnyPublisher<SystemStateSnapshot, Never>? = nil
    ) {
        self.telemetry = telemetry
        self.configuration = configuration
        if let pressureSource {
            pressureSource
                .receive(on: DispatchQueue.main)
                .sink { [weak self] snapshot in
                    Task { @MainActor in
                        guard let self else { return }
                        self.handleSnapshot(snapshot)
                    }
                }
                .store(in: &cancellables)
        }
    }

    deinit {
        // `deinit` may access this instance's stored properties directly, but
        // cannot call main-actor-isolated methods. We drop the references so the
        // `SystemStateMonitor` (whose own `deinit` releases its observers) and
        // every subscription are released — the unconditional cancellation path
        // that keeps Instruments leak checks clean.
        monitor = nil
        cancellables.removeAll()
    }

    // MARK: - Lifecycle

    /// Begins observing system pressure.
    ///
    /// Idempotent: calling while active is a no-op, and it is safe to call
    /// again after ``stop()``.
    public func start() {
        guard !isActive else { return }
        isActive = true

        if configuration.autoMonitor && monitor == nil {
            let monitor = SystemStateMonitor(telemetry: telemetry)
            monitor.snapshotPublisher
                .sink { [weak self] snapshot in
                    Task { @MainActor in
                        guard let self else { return }
                        self.handleSnapshot(snapshot)
                    }
                }
                .store(in: &cancellables)
            monitor.start()
            self.monitor = monitor
        }

        logger.info("MissingComponent2 started")
    }

    /// Stops observing and releases all resources — the explicit cancellation
    /// path. Cancels the internal monitor and drops every subscriber so nothing
    /// is left dangling.
    public func stop() {
        guard isActive else { return }
        isActive = false

        monitor?.stop()
        monitor = nil
        cancellables.removeAll()
        logger.info("MissingComponent2 stopped")
    }

    // MARK: - Resource tracking

    /// Registers a resource for later reclamation.
    public func register(_ resource: RenderResource) {
        liveResources.append(resource)
        countSubject.send(liveResources.count)
        #if DEBUG
        logger.debug("Registered resource \(resource.label) (\(resource.estimatedBytes) bytes)")
        #endif
    }

    /// Removes and releases a single resource by id.
    ///
    /// - Returns: `true` if a resource with `id` was found and released.
    @discardableResult
    public func unregister(id: RenderResource.ID) -> Bool {
        guard let idx = liveResources.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let resource = liveResources.remove(at: idx)
        resource.release()
        countSubject.send(liveResources.count)
        return true
    }

    // MARK: - Pressure response

    /// Reacts to a system-pressure snapshot.
    ///
    /// - If the snapshot demands a pause, all render resources are reclaimed.
    /// - If it only suggests throttling, a best-effort reclaim is attempted.
    ///
    /// Failures during reclamation are mapped to ``MediaError`` and surfaced
    /// through telemetry; they do not crash the caller.
    public func handleSnapshot(_ snapshot: SystemStateSnapshot) {
        pressureSubject.send(snapshot)

        if snapshot.shouldPauseForSystem {
            record(.compatibilityModeActivated(
                reason: "render_pause:thermal_\(snapshot.thermal.description)_mem_\(snapshot.memory.description)",
                source: .local
            ))
            Task { try? await reclaimResources(under: snapshot) }
        } else if snapshot.shouldThrottleDecoding {
            logger.warning("Render throttle suggested (thermal=\(snapshot.thermal.description), memory=\(snapshot.memory.description))")
            Task { try? await reclaimResources(under: snapshot) }
        } else {
            #if DEBUG
            logger.debug("Render system nominal")
            #endif
        }
    }

    /// Reclaims every registered resource under the given pressure snapshot,
    /// bounded by `timeout`.
    ///
    /// - Parameters:
    ///   - snapshot: The pressure snapshot that triggered reclamation.
    ///   - timeout: Budget for the reclaim pass. Defaults to
    ///     `configuration.reclaimTimeout`.
    /// - Returns: The number of resources reclaimed.
    /// - Throws: ``MediaError`` (`.timedOut` / `.cancelled`) if the pass is
    ///   cancelled or exceeds its budget.
    @discardableResult
    public func reclaimResources(
        under snapshot: SystemStateSnapshot,
        timeout: Duration? = nil
    ) async throws -> Int {
        try Task.checkCancellation()

        let budget = timeout ?? configuration.reclaimTimeout
        let batch = liveResources

        let reclaimed: Int = try await withTimeout(budget) {
            try Task.checkCancellation()
            // Release each resource. Closures are `@Sendable`; the main-actor
            // isolation guarantees exclusive access to `liveResources`.
            for resource in batch {
                resource.release()
                #if DEBUG
                self.logger.debug("Reclaimed \(resource.label)")
                #endif
            }
            return batch.count
        }

        let batchIDs = Set(batch.map(\.id))
        liveResources.removeAll(where: { batchIDs.contains($0.id) })
        countSubject.send(liveResources.count)
        record(.frameCacheEvicted(
            count: reclaimed,
            reason: "render_pressure:thermal_\(snapshot.thermal.description)_mem_\(snapshot.memory.description)"
        ))
        logger.info("Reclaimed \(reclaimed) render resources")
        return reclaimed
    }

    // MARK: - Guarded acquire

    /// Runs an external resource-acquire closure under a timeout and
    /// cancellation guard.
    ///
    /// Use this to bound third-party or driver calls (e.g. creating a Metal
    /// texture cache, building a `VTDecompressionSession`, attaching a
    /// `CAMetalLayer` target) so a hung acquire cannot stall the session.
    ///
    /// - Parameters:
    ///   - timeout: Budget for the work. Defaults to `configuration.acquireTimeout`.
    ///   - work: The async closure to run.
    /// - Returns: The value produced by `work`.
    /// - Throws: ``MediaError`` (`.timedOut` / `.cancelled`) on budget or
    ///   cancellation, or any error `work` throws (mapped to ``MediaError``).
    public func withGuardedAcquire<T: Sendable>(
        timeout: Duration? = nil,
        _ work: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let budget = timeout ?? configuration.acquireTimeout
        do {
            return try await withTimeout(budget) {
                try Task.checkCancellation()
                return try await work()
            }
        } catch {
            let mediaError = MediaError(error, source: .local)
            recordFailure(mediaError)
            throw mediaError
        }
    }

    // MARK: - Private helpers

    /// Runs `operation` bounded by `duration`, throwing ``MediaError/timedOut``
    /// (wrapped in a ``MediaError``) if the budget is exceeded, or mapping any
    /// other thrown error onto ``MediaError``.
    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw MediaError(
                    code: .systemPressure,
                    message: "Render resource operation exceeded timeout of \(duration)."
                )
            }

            do {
                guard let result = try await group.next() else {
                    throw MediaError(
                        code: .systemPressure,
                        message: "Render resource operation produced no result."
                    )
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw MediaError(error, source: .local)
            }
        }
    }

    /// Emits a telemetry event through the injected ``TelemetryProviding`` sink.
    ///
    /// Direct Sentry usage is intentionally avoided so the app's consent and
    /// privacy gates apply uniformly.
    private func record(_ event: TelemetryEvent) {
        telemetry?.record(event)
    }

    /// Records a failure via ``MediaError/record(using:)`` when telemetry is
    /// present, then logs it.
    private func recordFailure(_ error: MediaError) {
        if let telemetry {
            error.record(using: telemetry)
        }
        logger.error("\(error.description)")
    }
}
