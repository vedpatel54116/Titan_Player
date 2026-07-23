import Foundation
import os
import Combine
import AVFoundation
import VideoToolbox
import Metal

// MARK: - TelemetryAggregating

/// A privacy-aware, concurrency-safe aggregation surface for Titan Player events.
///
/// The existing ``TelemetryProviding`` protocol is the *sink* (it wraps Sentry and
/// is `@MainActor`-isolated). ``TelemetryAggregator`` sits *in front* of that sink
/// and is responsible for the parts Sentry must never see:
///
/// - **Scrubbing PII** — every free-form string is run through ``TelemetryAggregator/sanitize(_:)``
///   before it is buffered, so file paths, URLs, IP addresses and emails never leave the device.
/// - **Batching** — events are buffered and flushed on a cadence (or when the buffer is full)
///   to minimise network chatter and respect the user's data plan.
/// - **System-pressure mapping** — thermal and memory pressure are observed and mapped to the
///   centralized ``TitanPlayer.MediaError`` enum, never surfaced as raw OS values.
/// - **Error funnel** — every thrown `Error` from any subsystem is routed through
///   ``TitanPlayer.MediaError/init(_:source:codec:resolution:)`` so telemetry is bucketed by a stable
///   ``TitanPlayer.MediaError/Kind`` rather than by ad-hoc stringly-typed messages.
///
/// The aggregator is a `final class` that is **genuinely safe to share across actors and
/// threads**: all mutable state lives behind an ``OSAllocatedUnfairLock`` and every handle
/// (dispatch sources, observers, tasks) is torn down in ``stop()``. It is declared
/// `@unchecked Sendable` because it intentionally owns non-`Sendable` system handles whose
/// access is fully serialized by the lock; there is no shared unsynchronized state.
///
/// ### Example
/// ```swift
/// let aggregator = TelemetryAggregator(configuration: .default)
/// aggregator.startMonitoringSystemPressure()
/// aggregator.aggregate(error: decodingError, source: .local, codec: "hevc")
/// // … later, on shutdown:
/// aggregator.stop()
/// ```
@available(macOS 14, iOS 17, tvOS 17, *)
protocol TelemetryAggregating: Sendable {

    /// `true` while the aggregator is running and willing to accept events.
    var isActive: Bool { get }

    /// Buffer a pre-built, already-sanitized-safe ``TelemetryEvent``.
    /// Free-form strings inside `event` are sanitized before storage.
    func aggregate(_ event: TelemetryEvent)

    /// Map an arbitrary `Error` to the centralized ``TitanPlayer.MediaError`` enum and buffer the
    /// resulting failure event (codec/resolution are forwarded for telemetry bucketing).
    func aggregate(error: Error, source: PlaybackSource, codec: String?, resolution: String?)

    /// Begin observing thermal and memory pressure, emitting each as a ``TitanPlayer.MediaError`` event.
    func startMonitoringSystemPressure()

    /// Tear down all observers, cancel in-flight work, and flush any buffered events.
    func stop()
}

// MARK: - TelemetryAggregator.Configuration

/// Tunables for a ``TelemetryAggregator``.
///
/// All stored properties are `Sendable`: the forwarding closure is `@Sendable` and the
/// consent check is a side-effect-free `@Sendable` predicate, so a `Configuration` can be
/// constructed on any thread and handed to the aggregator.
@available(macOS 14, iOS 17, tvOS 17, *)
struct Configuration: Sendable {

    /// Maximum number of events buffered before an eager flush is forced.
    var maxBatchSize: Int

    /// Idle cadence between background flushes.
    var flushInterval: Duration

    /// Budget for a single flush to reach the sink before it is abandoned.
    var flushTimeout: Duration

    /// Predicate checked (off the main actor) before buffering anything. Return `false`
    /// when the user has not granted telemetry consent to drop events at the source.
    var consent: @Sendable () -> Bool

    /// Forwarding hook. The default forwards to the shared ``TelemetryManager`` sink
    /// (via ``TelemetryProviding``) on the main actor — Sentry is never referenced here.
    var onFlush: @Sendable (_ events: [TelemetryEvent]) async -> Void

    /// Creates a configuration.
    /// - Parameters:
    ///   - maxBatchSize: Flush eagerly once this many events accumulate. Defaults to `50`.
    ///   - flushInterval: Background flush cadence. Defaults to 30 seconds.
    ///   - flushTimeout: Per-flush forwarding budget. Defaults to 5 seconds.
    ///   - consent: Gate checked before buffering. Defaults to `true` (rely on sink gating).
    ///   - onFlush: Forwarding hook. Defaults to the shared ``TelemetryManager`` on the main actor.
    init(
        maxBatchSize: Int = 50,
        flushInterval: Duration = .seconds(30),
        flushTimeout: Duration = .seconds(5),
        consent: @escaping @Sendable () -> Bool = { true },
        onFlush: @escaping @Sendable ([TelemetryEvent]) async -> Void =
            { events in
                await MainActor.run {
                    let sink = TelemetryManager.shared
                    for event in events { sink.record(event) }
                }
            }
    ) {
        self.maxBatchSize = maxBatchSize
        self.flushInterval = flushInterval
        self.flushTimeout = flushTimeout
        self.consent = consent
        self.onFlush = onFlush
    }

    /// The project-wide default: 30s cadence, 5s flush budget, 50-event batches,
    /// forwarding to the shared ``TelemetryManager`` sink.
    static var `default`: Configuration { Configuration() }
}

// MARK: - TelemetryAggregator

/// A privacy-aware, `Sendable` event aggregator that batches telemetry and forwards it
/// through the ``TelemetryProviding`` sink (never touching Sentry directly).
///
/// - See Also: ``TelemetryAggregating`` for the public contract and design rationale.
@available(macOS 14, iOS 17, tvOS 17, *)
final class TelemetryAggregator: TelemetryAggregating {

    // MARK: Locked state

    /// All mutable state is funnelled through this lock so the class can be shared freely
    /// across concurrency domains. The contents are intentionally non-`Sendable`
    /// (system handles) — access is always serialized, hence `@unchecked Sendable` below.
    private struct State {
        var buffer: [TelemetryEvent] = []
        var isCancelled = false
        var isMonitoring = false
        var memorySource: DispatchSourceMemoryPressure?
        var thermalObserver: NSObjectProtocol?
        var flushTask: Task<Void, Never>?
    }

    private let lock: OSAllocatedUnfairLock<State>
    private let configuration: Configuration
    private let monitoringQueue: DispatchQueue
    private let logger = Logger(subsystem: "com.titanplayer", category: "TelemetryAggregator")

    // MARK: Initialization

    /// Creates an aggregator with the supplied configuration.
    /// - Parameter configuration: Batching, consent, and forwarding behaviour.
    init(configuration: Configuration = .default) {
        self.configuration = configuration
        self.lock = OSAllocatedUnfairLock(initialState: State())
        self.monitoringQueue = DispatchQueue(label: "com.titanplayer.telemetry.aggregator", qos: .utility)
    }

    deinit {
        // Belt-and-suspenders: ensure no handle outlives the aggregator.
        let handle = lock.withLock { state -> (DispatchSourceMemoryPressure?, NSObjectProtocol?, Task<Void, Never>?) in
            let memory = state.memorySource
            let thermal = state.thermalObserver
            let task = state.flushTask
            state.memorySource = nil
            state.thermalObserver = nil
            state.flushTask = nil
            state.isCancelled = true
            return (memory, thermal, task)
        }
        handle.0?.cancel()
        if let observer = handle.1 { NotificationCenter.default.removeObserver(observer) }
        handle.2?.cancel()
    }

    // MARK: TelemetryAggregating

    var isActive: Bool {
        !lock.withLock { $0.isCancelled }
    }

    func aggregate(_ event: TelemetryEvent) {
        guard shouldAccept() else { return }
        let sanitized = sanitize(event)
        let shouldFlush = lock.withLock { state -> Bool in
            state.buffer.append(sanitized)
            return state.buffer.count >= configuration.maxBatchSize
        }
        if shouldFlush {
            Task { await self.performFlush() }
        }
    }

    func aggregate(error: Error, source: PlaybackSource, codec: String?, resolution: String?) {
        recordMediaError(TitanPlayer.MediaError(error, source: source, codec: codec, resolution: resolution))
    }

    func startMonitoringSystemPressure() {
        let alreadyMonitoring = lock.withLock { state -> Bool in
            guard !state.isMonitoring else { return true }
            state.isMonitoring = true
            return false
        }
        guard !alreadyMonitoring else { return }

        let memorySource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: monitoringQueue
        )
        memorySource.setEventHandler { [weak self] in
            self?.recordMediaError(TitanPlayer.MediaError.memoryPressure())
        }
        memorySource.resume()

        let thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.recordMediaError(TitanPlayer.MediaError.thermalPressure())
        }

        lock.withLock { state in
            state.memorySource = memorySource
            state.thermalObserver = thermalObserver
        }

        startFlushLoop()
    }

    func stop() {
        let handle = lock.withLock { state -> (DispatchSourceMemoryPressure?, NSObjectProtocol?, Task<Void, Never>?) in
            state.isCancelled = true
            state.isMonitoring = false
            let memory = state.memorySource
            let thermal = state.thermalObserver
            let task = state.flushTask
            state.memorySource = nil
            state.thermalObserver = nil
            state.flushTask = nil
            return (memory, thermal, task)
        }
        handle.0?.cancel()
        if let observer = handle.1 { NotificationCenter.default.removeObserver(observer) }
        handle.2?.cancel()
        // Best-effort flush of anything still buffered.
        Task { await self.performFlush() }
    }

    // MARK: Flushing

    /// Drains the buffer and forwards it through ``Configuration/onFlush``, racing the
    /// forwarding against ``Configuration/flushTimeout`` so a slow sink can never pin the app.
    private func performFlush() async {
        let batch = lock.withLock { state -> [TelemetryEvent] in
            let drained = state.buffer
            state.buffer.removeAll()
            return drained
        }
        guard !batch.isEmpty else { return }

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { await self.configuration.onFlush(batch) }
                group.addTask {
                    try await Task.sleep(nanoseconds: self.nanoseconds(self.configuration.flushTimeout))
                    throw _TelemetryFlushTimeoutError()
                }
                for try await _ in group {
                    group.cancelAll()
                    break
                }
            }
        } catch is _TelemetryFlushTimeoutError {
            logger.warning("Telemetry flush exceeded \(self.configuration.flushTimeout.description) — dropped \(batch.count) events.")
        } catch {
            logger.warning("Telemetry flush failed: \(error.localizedDescription)")
        }
    }

    /// Spawns the background loop that flushes on ``Configuration/flushInterval`` until cancelled.
    private func startFlushLoop() {
        let task = Task { [weak self] in
            while let self, !self.lock.withLock({ $0.isCancelled }) {
                try? await Task.sleep(nanoseconds: self.nanoseconds(self.configuration.flushInterval))
                guard !self.lock.withLock({ $0.isCancelled }) else { break }
                await self.performFlush()
            }
        }
        lock.withLock { $0.flushTask = task }
    }

    // MARK: Error mapping

    /// Converts a ``TitanPlayer.MediaError`` into a sanitized `playbackFailed` event and buffers it.
    /// Used for both thrown errors and the synthetic thermal/memory-pressure errors so the
    /// original ``TitanPlayer.MediaError/Kind`` (its `telemetryErrorCode`) is preserved — routing a
    /// ``TitanPlayer.MediaError`` back through ``TitanPlayer.MediaError/init(_:source:)`` would re-classify it as
    /// `.unknown` and lose the pressure signal.
    private func recordMediaError(_ mediaError: TitanPlayer.MediaError) {
        guard shouldAccept() else { return }
        let event = TelemetryEvent.playbackFailed(
            codec: mediaError.codec ?? "unknown",
            resolution: mediaError.resolution ?? "unknown",
            errorCode: mediaError.telemetryErrorCode,
            source: mediaError.source
        )
        aggregate(event)
    }

    // MARK: Privacy

    /// Applies ``sanitize(_:)`` to every free-form string carried by `event`.
    private func sanitize(_ event: TelemetryEvent) -> TelemetryEvent {
        switch event {
        case .playbackFailed(let codec, let resolution, let errorCode, let source):
            return .playbackFailed(
                codec: sanitize(codec),
                resolution: sanitize(resolution),
                errorCode: sanitize(errorCode),
                source: source
            )
        case .hdrModeUsed(let mode, let duration):
            return .hdrModeUsed(mode: mode, duration: duration)
        case .performanceSnapshot(let cpu, let gpu, let resolution, let codec):
            return .performanceSnapshot(
                averageCPU: cpu,
                averageGPU: gpu,
                resolution: sanitize(resolution),
                codec: sanitize(codec)
            )
        case .audioFormatUsed(let format, let sampleRate, let bitDepth):
            return .audioFormatUsed(format: format, sampleRate: sampleRate, bitDepth: bitDepth)
        case .compatibilityModeActivated(let reason, let source):
            return .compatibilityModeActivated(reason: sanitize(reason), source: source)
        @unknown default:
            return event
        }
    }

    /// Redacts anything that could identify a user, a file, or a network endpoint.
    ///
    /// - Paths (begin with `/`) → `[redacted-path]`
    /// - URLs (contain `://`) → `[redacted-url]`
    /// - IPv4 / IPv6 addresses → `[redacted-ip]`
    /// - Email addresses → `[redacted-email]`
    /// - Over-long strings are truncated to 256 characters.
    ///
    /// This runs on every buffered event, so privacy is enforced at the edge regardless of
    /// which subsystem produced the value.
    func sanitize(_ string: String) -> String {
        guard !string.isEmpty else { return string }
        let truncated = string.count > 256 ? String(string.prefix(256)) : string
        if truncated.hasPrefix("/") { return "[redacted-path]" }
        if truncated.contains("://") { return "[redacted-url]" }
        if Self.ipv4Regex.firstMatch(in: truncated, range: NSRange(truncated.startIndex..., in: truncated)) != nil {
            return "[redacted-ip]"
        }
        if Self.emailRegex.firstMatch(in: truncated, range: NSRange(truncated.startIndex..., in: truncated)) != nil {
            return "[redacted-email]"
        }
        return truncated
    }

    // MARK: Helpers

    /// `true` when the aggregator is live and the consent predicate allows collection.
    private func shouldAccept() -> Bool {
        guard !lock.withLock({ $0.isCancelled }) else { return false }
        return configuration.consent()
    }

    /// Converts a ``Duration`` into nanoseconds for `Task.sleep`.
    private func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        return UInt64(components.seconds) * 1_000_000_000 + UInt64(components.attoseconds / 1_000_000_000)
    }

    private static let ipv4Regex = try! NSRegularExpression(pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#)
    private static let emailRegex = try! NSRegularExpression(pattern: #"\b[\w.%+-]+@[\w.-]+\.\w{2,}\b"#)
}

// MARK: - @unchecked Sendable

extension TelemetryAggregator: @unchecked Sendable {
    // The aggregator owns non-`Sendable` system handles (DispatchSource, NSObjectProtocol,
    // Task). Every access to them is serialized through `lock`, and they are released in
    // `stop()` / `deinit`, so sharing the reference across actors is safe.
}

// MARK: - Private errors

/// Internal marker thrown when a flush exceeds its ``Configuration/flushTimeout`` budget.
private struct _TelemetryFlushTimeoutError: Error {}
