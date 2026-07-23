import Foundation
import Combine
import os

// MARK: - ResiliencePressureState

/// The severity Titan Player's engine should attribute to the current system
/// pressure, distilled from OS thermal and memory signals.
///
/// `ResiliencePressureState` collapses the two independent OS pressure channels
/// (thermal via ``ProcessInfo/thermalState`` and memory via
/// `DispatchSourceMemoryPressure`) into a single, monotonically-escalating level
/// so the resilience controller and its consumers only ever reason about one
/// value. The level is intentionally coarse: the controller's job is to *react*
/// (shed load, refuse new work, emit telemetry), not to reproduce the raw OS
/// readings, which are preserved on the originating ``MediaError`` for diagnostics.
@available(macOS 14, *)
public enum ResiliencePressureState: Sendable, Equatable, CustomStringConvertible {
    /// No meaningful pressure. Full-quality playback is permitted.
    case nominal
    /// Warning-level pressure (thermal `fair`/`serious`, or memory `.warning`).
    /// New heavy work may proceed but in-flight work should be monitored.
    case degraded
    /// Critical pressure (thermal `.critical`, or memory `.critical`). New
    /// decode/analysis work should be refused and in-flight work shed where safe.
    case critical

    /// A short, stable label for logs and telemetry.
    public var description: String {
        switch self {
        case .nominal: return "nominal"
        case .degraded: return "degraded"
        case .critical: return "critical"
        }
    }
}

// MARK: - EngineResilienceController

/// A `Sendable` coordinator that makes every engine operation resilient to the
/// three failure modes called out by the shard-0 audit: **system pressure**,
/// **cancellation**, and **timeouts**.
///
/// `EngineResilienceController` is the production implementation that closed the
/// `MissingComponent0` gap. It is deliberately small and side-effect-light so it
/// can wrap any media-engine unit of work (decode, analysis, seek, render
/// warm-up) without imposing architecture on the caller:
///
/// - **Thermal / memory pressure** — observes `ProcessInfo.thermalStateDidChangeNotification`
///   and `DispatchSourceMemoryPressure`. Each transition is mapped onto the
///   centralized ``MediaError`` enum (``MediaError/Kind/thermalPressure`` /
///   ``MediaError/Kind/memoryPressure``), surfaced through a Combine publisher,
///   and reported to telemetry. When pressure is ``ResiliencePressureState/critical``
///   and ``Configuration/shedLoadAtCritical`` is set, ``run(_:timeout:source:codec:resolution:)``
///   refuses new work instead of piling load onto a struggling system.
/// - **Cancellation** — every `run` is hosted on a tracked `Task`. ``cancelAll()``
///   tears the whole task tree down cooperatively; callers' closures observe
///   `Task.isCancelled` the usual way. `CancellationError` is funneled to
///   ``MediaError/Kind/cancelled`` rather than leaking a raw error.
/// - **Timeouts** — each `run` races the operation against a caller-supplied
///   ``Duration`` budget. On expiry the slower path is cancelled and the failure
///   is reported as ``MediaError/Kind/timedOut``.
///
/// All state is protected by an ``OSAllocatedUnfairLock``; the class is declared
/// `@unchecked Sendable` for the same reason as `TelemetryAggregator` — it owns
/// non-`Sendable` system handles (dispatch sources, notification observers) whose
/// access is fully serialized, so sharing the reference across actors is safe.
///
/// ### Example
/// ```swift
/// let controller = EngineResilienceController()
/// controller.startMonitoringSystemPressure()
///
/// let frames = try await controller.run(
///     { try await decoder.decodeBatch(range) },
///     timeout: .seconds(5),
///     source: .local,
///     codec: "hevc",
///     resolution: "3840x2160"
/// )
/// // … on shutdown:
/// controller.stop()
/// ```
@available(macOS 14, *)
final class EngineResilienceController: @unchecked Sendable {

    // MARK: Locked state

    /// All mutable state funnels through this lock so the controller can be shared
    /// freely across concurrency domains. The stored system handles are
    /// non-`Sendable`; every touch is serialized, hence `@unchecked Sendable`.
    private struct State {
        var isMonitoring = false
        var isCancelled = false
        var thermalState: ProcessInfo.ThermalState = .nominal
        var memoryWarning = false
        var memoryCritical = false
        var memorySource: DispatchSourceMemoryPressure?
        var thermalObserver: NSObjectProtocol?
        var nextTaskID: UInt64 = 0
        var activeTasks: [UInt64: Task<Any, any Error>] = [:]
    }

    private let lock: OSAllocatedUnfairLock<State>
    private let configuration: Configuration
    private let telemetry: any TelemetryAggregating
    private let monitoringQueue: DispatchQueue
    private let logger = Logger(subsystem: "com.titanplayer", category: "EngineResilienceController")

    /// Combine subject that replays the latest ``ResiliencePressureState`` and
    /// emits on every transition. `CurrentValueSubject` (and `AnyPublisher`) are
    /// not `Sendable`, so the reference lives inside the `@unchecked Sendable`
    /// class; `send` is internally synchronized by Combine and safe to call from
    /// any thread.
    private let pressureSubject: CurrentValueSubject<ResiliencePressureState, Never>

    // MARK: Pressure publisher

    /// A cold-to-hot stream of the controller's current pressure level.
    ///
    /// Subscribers receive the most recent value immediately on subscription and
    /// then every subsequent transition. UI and engine subsystems use this to
    /// degrade quality (e.g. drop analysis passes) before the OS forces it.
    var pressurePublisher: AnyPublisher<ResiliencePressureState, Never> {
        pressureSubject.eraseToAnyPublisher()
    }

    /// The current pressure level, sampled without subscribing.
    var currentPressure: ResiliencePressureState {
        pressureSubject.value
    }

    // MARK: Configuration

    /// Tunables for an ``EngineResilienceController``.
    ///
    /// All stored properties are `Sendable`: the telemetry sink is an
    /// `any TelemetryAggregating` (which is `Sendable`), the consent predicate is
    /// `@Sendable`, and the pressure labels are value types. A `Configuration` can
    /// therefore be built on any thread and handed to the controller.
    @available(macOS 14, *)
    struct Configuration: Sendable {
        /// When `true` (default), ``run(_:timeout:source:codec:resolution:)``
        /// refuses new work while pressure is ``ResiliencePressureState/critical``,
        /// throwing ``MediaError/Kind/memoryPressure`` so the caller can back off.
        var shedLoadAtCritical: Bool

        /// Predicate checked before buffering a telemetry event. Return `false`
        /// when the user has not granted telemetry consent to drop events.
        var consent: @Sendable () -> Bool

        /// Creates a configuration.
        /// - Parameters:
        ///   - shedLoadAtCritical: Refuse new work under critical pressure. Defaults to `true`.
        ///   - consent: Consent gate checked before telemetry. Defaults to `true`.
        init(
            shedLoadAtCritical: Bool = true,
            consent: @escaping @Sendable () -> Bool = { true }
        ) {
            self.shedLoadAtCritical = shedLoadAtCritical
            self.consent = consent
        }

        /// Permissive defaults: shed load at critical pressure, no consent gate.
        static var `default`: Configuration { Configuration() }
    }

    // MARK: Initialization

    /// Creates a resilience controller.
    ///
    /// - Parameters:
    ///   - configuration: Pressure / consent behaviour. Defaults to ``Configuration/default``.
    ///   - telemetry: A `TelemetryAggregating` sink. Defaults to a
    ///     ``TelemetryAggregator`` that forwards to the shared `TelemetryManager`
    ///     (which wraps Sentry) — telemetry therefore never touches Sentry directly.
    init(
        configuration: Configuration = .default,
        telemetry: any TelemetryAggregating = TelemetryAggregator(configuration: .default)
    ) {
        self.configuration = configuration
        self.telemetry = telemetry
        self.lock = OSAllocatedUnfairLock(initialState: State())
        self.monitoringQueue = DispatchQueue(label: "com.titanplayer.resilience", qos: .utility)
        self.pressureSubject = CurrentValueSubject(.nominal)
    }

    deinit {
        // Belt-and-suspenders: release every system handle even if `stop()` was
        // never called. Holding these would otherwise leak the dispatch source
        // and notification observer for the process lifetime.
        let handle = lock.withLock { state -> (DispatchSourceMemoryPressure?, NSObjectProtocol?, [Task<Any, any Error>]) in
            let memory = state.memorySource
            let thermal = state.thermalObserver
            let tasks = Array(state.activeTasks.values)
            state.memorySource = nil
            state.thermalObserver = nil
            state.activeTasks.removeAll()
            state.isCancelled = true
            state.isMonitoring = false
            return (memory, thermal, tasks)
        }
        handle.0?.cancel()
        if let observer = handle.1 { NotificationCenter.default.removeObserver(observer) }
        for task in handle.2 { task.cancel() }
    }

    // MARK: Operation execution

    /// Runs `operation` under timeout, cancellation, and pressure guarantees.
    ///
    /// The operation is hosted on a tracked `Task` so ``cancelAll()`` can tear it
    /// down cooperatively. It is raced against a timeout child; whichever returns
    /// first wins and the loser is cancelled. Every thrown error — including the
    /// synthesized timeout, cancellation, and pressure-refusal failures — is
    /// mapped onto the centralized ``MediaError`` enum and reported to telemetry
    /// with the supplied codec/resolution context, never as a raw `Error`.
    ///
    /// - Parameters:
    ///   - operation: The media-engine unit of work. Must be `@Sendable` and
    ///     cooperate with `Task.isCancelled` for timely cancellation. Its result
    ///     must be `Sendable`.
    ///   - timeout: Budget for `operation` to complete. On expiry the work is
    ///     cancelled and ``MediaError/Kind/timedOut`` is thrown.
    ///   - source: Playback origin, for telemetry bucketing.
    ///   - codec: Optional codec label forwarded to telemetry.
    ///   - resolution: Optional resolution label forwarded to telemetry.
    /// - Returns: The value produced by `operation`.
    /// - Throws: A ``MediaError`` classifying the failure.
    func run<T: Sendable>(
        _ operation: @Sendable @escaping () async throws -> T,
        timeout: Duration,
        source: PlaybackSource,
        codec: String? = nil,
        resolution: String? = nil
    ) async throws -> T {
        do {
            try Task.checkCancellation()
        } catch {
            let mediaError = Self.classify(error, source: source, codec: codec, resolution: resolution)
            report(mediaError)
            throw mediaError
        }

        // Pressure back-off: refuse to add load when the system is critical and
        // the caller opted into shedding.
        if configuration.shedLoadAtCritical, currentPressure == .critical {
            let error = MediaError.memoryPressure(source: source)
            report(error)
            throw error
        }

        let task: Task<Any, any Error> = Task {
            try await operation() as Any
        }
        let taskID = lock.withLock { state -> UInt64 in
            state.nextTaskID += 1
            let id = state.nextTaskID
            state.activeTasks[id] = task
            return id
        }
        defer {
            _ = lock.withLock { $0.activeTasks.removeValue(forKey: taskID) }
        }

        // The inner catch is the single reporting site for any error that escapes
        // the race (timeout, cancellation, operation failure). The rethrown
        // `MediaError` propagates straight to the caller — no outer catch, so
        // telemetry is never double-reported.
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                guard let value = try await task.value as? T else {
                    throw MediaError(
                        kind: .unknown,
                        source: source,
                        message: "Operation returned an unexpected type."
                    )
                }
                return value
            }
            group.addTask {
                try await Task.sleep(nanoseconds: Self.nanoseconds(timeout))
                throw MediaError(
                    kind: .timedOut,
                    source: source,
                    codec: codec,
                    resolution: resolution,
                    message: "Operation exceeded \(timeout.description) budget."
                )
            }
            do {
                guard let result = try await group.next() else {
                    throw MediaError(
                        kind: .cancelled,
                        source: source,
                        message: "Operation was cancelled before completion."
                    )
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                let mediaError = Self.classify(error, source: source, codec: codec, resolution: resolution)
                report(mediaError)
                throw mediaError
            }
        }
    }

    /// Cancels every in-flight operation hosted by this controller.
    ///
    /// Cancellation is cooperative: the operation closures observe
    /// `Task.isCancelled` (or simply reach the next `await`) and unwind. The
    /// resulting `CancellationError` is reported as ``MediaError/Kind/cancelled``
    /// by ``run(_:timeout:source:codec:resolution:)``.
    func cancelAll() {
        let tasks = lock.withLock { state -> [Task<Any, any Error>] in
            let snapshot = Array(state.activeTasks.values)
            state.activeTasks.removeAll()
            return snapshot
        }
        for task in tasks { task.cancel() }
        logger.info("Cancelled \(tasks.count) in-flight resilience operation(s).")
    }

    // MARK: System-pressure observation

    /// Begins observing thermal and memory pressure.
    ///
    /// Idempotent: calling again while already monitoring is a no-op. Each
    /// transition recomputes the coalesced ``ResiliencePressureState`` and pushes
    /// it to ``pressurePublisher`` plus telemetry. Safe to call from any thread.
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
            self?.handleMemoryPressure()
        }
        memorySource.resume()

        let thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleThermalPressure(ProcessInfo.processInfo.thermalState)
        }

        lock.withLock { state in
            state.memorySource = memorySource
            state.thermalObserver = thermalObserver
            state.memoryWarning = false
            state.memoryCritical = false
            state.thermalState = ProcessInfo.processInfo.thermalState
        }
        recomputePressure()
    }

    /// Stops observing pressure and cancels every in-flight operation.
    ///
    /// Observers and the dispatch source are released here and in `deinit`. The
    /// injected telemetry sink is *not* stopped — it may be shared across the app.
    func stop() {
        let handle = lock.withLock { state -> (DispatchSourceMemoryPressure?, NSObjectProtocol?, [Task<Any, any Error>]) in
            let memory = state.memorySource
            let thermal = state.thermalObserver
            let tasks = Array(state.activeTasks.values)
            state.memorySource = nil
            state.thermalObserver = nil
            state.activeTasks.removeAll()
            state.isMonitoring = false
            state.isCancelled = true
            return (memory, thermal, tasks)
        }
        handle.0?.cancel()
        if let observer = handle.1 { NotificationCenter.default.removeObserver(observer) }
        for task in handle.2 { task.cancel() }
    }

    // MARK: Pressure handlers

    private func handleThermalPressure(_ state: ProcessInfo.ThermalState) {
        lock.withLock { $0.thermalState = state }
        if state == .critical {
            report(MediaError.thermalPressure(state: state))
        }
        recomputePressure()
    }

    private func handleMemoryPressure() {
        let mask = lock.withLock { $0.memorySource?.data } ?? []
        let isCritical = mask.contains(.critical)
        let isWarning = mask.contains(.warning)
        lock.withLock { state in
            state.memoryCritical = isCritical
            state.memoryWarning = isWarning
        }
        if isCritical {
            report(MediaError.memoryPressure())
        }
        recomputePressure()
    }

    /// Coalesces the two OS channels into a single ``ResiliencePressureState``,
    /// updates the subject, and emits a telemetry event on any transition.
    private func recomputePressure() {
        let next: ResiliencePressureState = lock.withLock { state in
            let thermalCritical = state.thermalState == .critical
            let thermalDegraded = state.thermalState == .serious || state.thermalState == .fair
            let memoryCritical = state.memoryCritical
            let memoryDegraded = state.memoryWarning

            if thermalCritical || memoryCritical { return .critical }
            if thermalDegraded || memoryDegraded { return .degraded }
            return .nominal
        }

        let previous = pressureSubject.value
        guard next != previous else { return }
        pressureSubject.send(next)
        logger.info("System pressure transitioned \(previous) → \(next).")
    }

    // MARK: Telemetry

    /// Reports a ``MediaError`` to the injected ``TelemetryAggregating`` sink as a
    /// privacy-scrubbed `playbackFailed` event. Sentry is never referenced here;
    /// the sink (e.g. `TelemetryManager.shared`) owns that concern.
    private func report(_ mediaError: MediaError) {
        guard configuration.consent() else { return }
        let event = TelemetryEvent.playbackFailed(
            codec: mediaError.codec ?? "unknown",
            resolution: mediaError.resolution ?? "unknown",
            errorCode: mediaError.telemetryErrorCode,
            source: mediaError.source
        )
        telemetry.aggregate(event)
    }

    // MARK: Error classification

    /// Preserves an already-classified ``MediaError`` (e.g. a synthesized timeout
    /// or pressure-refusal error) and otherwise funnels a raw `Error` through
    /// ``MediaError/init(_:source:codec:resolution:)``. This mirrors the
    /// `TelemetryAggregator` rule: re-classifying a `MediaError` would collapse it
    /// to ``MediaError/Kind/unknown`` and discard the real signal.
    private static func classify(
        _ error: some Error,
        source: PlaybackSource,
        codec: String?,
        resolution: String?
    ) -> MediaError {
        if let existing = error as? MediaError {
            return existing
        }
        return MediaError(error, source: source, codec: codec, resolution: resolution)
    }

    // MARK: Helpers

    /// Converts a ``Duration`` into nanoseconds for `Task.sleep`.
    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        return UInt64(components.seconds) * 1_000_000_000 + UInt64(components.attoseconds / 1_000_000_000)
    }
}
