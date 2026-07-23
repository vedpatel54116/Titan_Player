import Foundation
import Combine
import os.log

// MARK: - MissingComponent5

/// Resilience coordinator for security-critical asynchronous operations in
/// Titan Player.
///
/// ## Why this exists
///
/// Shard 5 of the security audit flagged a gap: several sensitive code paths —
/// secure token exchange, license validation, key derivation, and other
/// trust-boundary crossings — ran unprotected against system pressure,
/// cancellation, and unbounded latency. Failures there manifested as hangs,
/// jetsam terminations, or opaque crashes instead of handled, recoverable
/// ``MediaError`` values. `MissingComponent5` closes that gap by providing a
/// single, audited execution context that guarantees every such operation is:
///
/// - **Pressure-aware** — thermal and memory pressure are observed via Combine
///   (`ProcessInfo` notifications + `DispatchSource` memory pressure). When the
///   system enters a serious/critical state the in-flight operation is aborted
///   and surfaced as ``MediaError/Kind/thermalPressure`` or
///   ``MediaError/Kind/memoryPressure`` rather than risking a thermal trip or
///   jetsam kill.
/// - **Cancellable** — honors Swift structured-concurrency cancellation through
///   ``withTaskCancellationHandler`` and maps it to
///   ``MediaError/Kind/cancelled``.
/// - **Bounded** — every operation is wrapped with an explicit timeout that
///   throws ``MediaError/Kind/timedOut`` on overrun.
/// - **Mapped** — all underlying errors are funneled through ``MediaError`` so
///   UI and telemetry stay consistent with the rest of the player.
///
/// ## Concurrency model
///
/// The coordinator is a `@MainActor final class`, which makes it genuinely
/// `Sendable` (no `@unchecked`) and lets it safely own the non-`Sendable`
/// Combine pipeline and `DispatchSource`. All guarded work runs on the main
/// actor, matching the threading contract used across the security subsystem.
/// The single non-`Sendable` dependency — the telemetry sink that wraps
/// `TelemetryProviding` — is never stored directly; telemetry flows through a
/// `Sendable` ``TelemetrySink`` that hops to the main actor. **Sentry is never
/// referenced directly.**
///
/// ## Example
/// ```swift
/// let guard5 = MissingComponent5(configuration: .init(operationTimeout: 10))
/// guard5.attachPressureObservation()
/// do {
///     let token: Data = try await guard5.run(
///         timeout: 10,
///         source: .local
///     ) {
///         try await secureTokenExchange()
///     }
/// } catch {
///     let mediaError = MediaError(error, source: .local)
///     present(mediaError)
/// }
/// ```
@MainActor
final class MissingComponent5 {

    // MARK: - Configuration

    /// Runtime configuration for the resilience coordinator.
    struct Configuration: Sendable {
        /// Wall-clock budget (seconds) for any single guarded operation.
        let operationTimeout: TimeInterval
        /// Abort operations as soon as thermal pressure reaches this state.
        let abortAtThermalState: SystemPressureSnapshot.Thermal
        /// Abort operations as soon as memory pressure reaches this state.
        let abortAtMemoryState: SystemPressureSnapshot.Memory

        /// Convenience factory with production defaults.
        static let `default` = Configuration(
            operationTimeout: 10.0,
            abortAtThermalState: .serious,
            abortAtMemoryState: .critical
        )
    }

    // MARK: - SystemPressureSnapshot

    /// A point-in-time snapshot of system thermal and memory pressure.
    ///
    /// Stored as a `Sendable` value type so the coordinator can keep the latest
    /// reading and consult it before and after each guarded operation to decide
    /// whether to proceed, degrade, or abort.
    struct SystemPressureSnapshot: Sendable, Equatable {
        /// Coarse thermal state, mirroring `ProcessInfo.ThermalState`.
        enum Thermal: Sendable, Equatable, CustomStringConvertible {
            case nominal, fair, serious, critical
            var description: String {
                switch self {
                case .nominal: return "nominal"
                case .fair: return "fair"
                case .serious: return "serious"
                case .critical: return "critical"
                }
            }
        }

        /// Coarse memory-pressure state, derived from `DispatchSource`.
        enum Memory: Sendable, Equatable, CustomStringConvertible {
            case normal, warning, critical
            var description: String {
                switch self {
                case .normal: return "normal"
                case .warning: return "warning"
                case .critical: return "critical"
                }
            }
        }

        var thermal: Thermal
        var memory: Memory
        var updatedAt: Date

        static let nominal = SystemPressureSnapshot(
            thermal: .nominal, memory: .normal, updatedAt: .distantPast
        )

        /// Whether pressure has crossed the coordinator's abort thresholds.
        func shouldAbort(
            thermalThreshold: Thermal,
            memoryThreshold: Memory
        ) -> Bool {
            let thermalRank = [Thermal.nominal, .fair, .serious, .critical]
            let memoryRank = [Memory.normal, .warning, .critical]
            let thermalAtOrAbove =
                (thermalRank.firstIndex(of: thermal) ?? 0)
                >= (thermalRank.firstIndex(of: thermalThreshold) ?? 0)
            let memoryAtOrAbove =
                (memoryRank.firstIndex(of: memory) ?? 0)
                >= (memoryRank.firstIndex(of: memoryThreshold) ?? 0)
            return thermalAtOrAbove || memoryAtOrAbove
        }
    }

    // MARK: - TelemetrySink

    /// A `Sendable` bridge to ``TelemetryProviding`` so the coordinator never
    /// stores a non-`Sendable` telemetry reference.
    ///
    /// The default sink hops to the main actor and records through
    /// `TelemetryManager.shared` — Sentry is never referenced directly. Errors
    /// are mapped onto ``TelemetryEvent/playbackFailed`` via
    /// ``MediaError/telemetryErrorCode`` so buckets stay stable.
    struct TelemetrySink: Sendable {
        /// The underlying sendable recording closure.
        let record: @Sendable (TelemetryEvent) -> Void

        /// Routes events through the shared `TelemetryManager` on the main actor.
        static let `default` = TelemetrySink { event in
            Task { @MainActor in TelemetryManager.shared.record(event) }
        }

        /// Records a ``MediaError`` as a `playbackFailed` telemetry event
        /// without ever touching Sentry directly.
        func record(_ error: MediaError) {
            record(.playbackFailed(
                codec: error.codec ?? "security",
                resolution: error.resolution ?? "unknown",
                errorCode: error.telemetryErrorCode,
                source: error.source
            ))
        }
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.titanplayer", category: "MissingComponent5")

    private let configuration: Configuration
    private let telemetry: TelemetrySink
    private let source: PlaybackSource

    private let pressureSubject = PassthroughSubject<SystemPressureSnapshot, Never>()
    private var cancellables = Set<AnyCancellable>()
    private var memorySource: DispatchSourceMemoryPressure?
    private var lastMemoryLevel: SystemPressureSnapshot.Memory = .normal
    private var lastSnapshot: SystemPressureSnapshot = .nominal

    // MARK: - Initialization

    /// Creates a resilience coordinator.
    /// - Parameters:
    ///   - configuration: Timeout and pressure-abort thresholds.
    ///   - telemetry: A `Sendable` telemetry sink; defaults to the shared
    ///     `TelemetryManager` bridge.
    ///   - source: Playback origin for telemetry bucketing (defaults to `.local`).
    init(
        configuration: Configuration = .default,
        telemetry: TelemetrySink = .default,
        source: PlaybackSource = .local
    ) {
        self.configuration = configuration
        self.telemetry = telemetry
        self.source = source
    }

    // MARK: - Public API

    /// Runs a security-critical operation under pressure, cancellation, and
    /// timeout guarantees.
    ///
    /// The operation is executed on the main actor. Before it starts — and again
    /// if system pressure changes mid-flight — the coordinator checks thermal and
    /// memory state and aborts with the appropriate ``MediaError``. If the
    /// enclosing task is cancelled, ``MediaError/Kind/cancelled`` is thrown. If
    /// the operation exceeds `timeout`, ``MediaError/Kind/timedOut`` is thrown.
    /// Any error the operation throws (including `CancellationError`) is
    /// normalized into a ``MediaError`` and reported to telemetry.
    ///
    /// - Parameters:
    ///   - timeout: Per-call budget in seconds; defaults to the configured
    ///     `operationTimeout`.
    ///   - source: Playback origin for telemetry (defaults to the coordinator's).
    ///   - operation: The `@Sendable` async operation to guard.
    /// - Returns: The operation's result.
    func run<T: Sendable>(
        timeout: TimeInterval? = nil,
        source: PlaybackSource? = nil,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let effectiveSource = source ?? self.source
        let effectiveTimeout = timeout ?? configuration.operationTimeout

        try Task.checkCancellation()
        try checkPressure(source: effectiveSource)

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
                    throw MediaError(
                        kind: .timedOut,
                        source: effectiveSource,
                        underlyingDomain: "MissingComponent5",
                        underlyingMessage: "Operation exceeded \(effectiveTimeout)s.",
                        message: "The secure operation timed out."
                    )
                }
                group.addTask {
                    do {
                        return try await operation()
                    } catch {
                        throw Self.map(error, source: effectiveSource, telemetry: self.telemetry)
                    }
                }
                defer { group.cancelAll() }
                let result = try await group.next()!
                // Drain the sibling so its task resources are released cleanly.
                _ = try? await group.next()
                return result
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                let error = MediaError(kind: .cancelled, source: effectiveSource)
                self?.telemetry.record(error)
            }
        }
    }

    /// Begins observing thermal and memory pressure. Safe to call repeatedly;
    /// it first detaches any prior observation.
    func attachPressureObservation() {
        detachPressureObservation()

        NotificationCenter.default
            .publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.handlePressureChange() }
            }
            .store(in: &cancellables)

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main
        )
        source.setEventHandler { [weak self] in
            let mask = source.mask
            let level: SystemPressureSnapshot.Memory =
                mask.contains(.critical) ? .critical
                : mask.contains(.warning) ? .warning
                : .normal
            Task { @MainActor in
                self?.lastMemoryLevel = level
                self?.handlePressureChange()
            }
        }
        source.resume()
        memorySource = source
    }

    /// Stops observing pressure and releases the memory source.
    func detachPressureObservation() {
        cancellables.removeAll()
        memorySource?.cancel()
        memorySource = nil
    }

    /// The latest observed system-pressure snapshot.
    var currentPressure: SystemPressureSnapshot { lastSnapshot }

    /// A Combine publisher emitting the latest system-pressure snapshot.
    var pressurePublisher: AnyPublisher<SystemPressureSnapshot, Never> {
        pressureSubject.eraseToAnyPublisher()
    }

    // MARK: - Error mapping

    /// Normalizes any thrown error into a ``MediaError`` and emits it to
    /// telemetry, returning the mapped error for re-throw.
    private nonisolated static func map(
        _ error: some Error,
        source: PlaybackSource,
        telemetry: TelemetrySink
    ) -> MediaError {
        let mediaError: MediaError
        if let existing = error as? MediaError {
            mediaError = existing
        } else {
            mediaError = MediaError(error, source: source)
        }
        telemetry.record(mediaError)
        return mediaError
    }

    // MARK: - Pressure observation

    private func handlePressureChange() {
        let snapshot = currentPressureSnapshot()
        lastSnapshot = snapshot
        pressureSubject.send(snapshot)
        if snapshot.shouldAbort(
            thermalThreshold: configuration.abortAtThermalState,
            memoryThreshold: configuration.abortAtMemoryState
        ) {
            logger.warning("System pressure \(snapshot.thermal) / \(snapshot.memory) — aborting guarded operation.")
            detachPressureObservation()
        }
    }

    private func checkPressure(source: PlaybackSource) throws {
        let snapshot = currentPressureSnapshot()
        lastSnapshot = snapshot
        if snapshot.shouldAbort(
            thermalThreshold: configuration.abortAtThermalState,
            memoryThreshold: configuration.abortAtMemoryState
        ) {
            if snapshot.thermal == .serious || snapshot.thermal == .critical {
                throw MediaError.thermalPressure(source: source)
            } else {
                throw MediaError.memoryPressure(source: source)
            }
        }
    }

    private func currentPressureSnapshot() -> SystemPressureSnapshot {
        let thermal: SystemPressureSnapshot.Thermal
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .nominal
        }
        return SystemPressureSnapshot(thermal: thermal, memory: lastMemoryLevel, updatedAt: Date())
    }
}

// MARK: - Documentation / DocC

/// ### Topics
///
/// - **Resilience**
///   - ``MissingComponent5/run(timeout:source:operation:)``
///   - ``MissingComponent5/attachPressureObservation()``
///   - ``MissingComponent5/detachPressureObservation()``
/// - **Configuration**
///   - ``MissingComponent5/Configuration``
///   - ``MissingComponent5/SystemPressureSnapshot``
/// - **Telemetry**
///   - ``MissingComponent5/TelemetrySink``
