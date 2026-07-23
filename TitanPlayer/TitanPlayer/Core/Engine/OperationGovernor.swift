import Foundation
import Combine
import OSLog

// MARK: - OperationGovernor

/// Guards async decode/render operations against hangs, cancellation, and
/// system-pressure induced failures.
///
/// ## Why this exists
/// Titan Player's engine runs decode, seek, and render work that can stall
/// indefinitely (a wedged decoder, a lost GPU, a starved network) or keep
/// running while the OS is throttling the device. ``SystemStateMonitor`` makes
/// pressure *observable*; ``OperationGovernor`` *acts* on it by wrapping each
/// operation with a timeout and a cancellation path, translating every thrown
/// failure into the centralized ``MediaError`` type, and reporting outcomes
/// through the injected ``TelemetryProviding`` sink.
///
/// ## Lifecycle
/// 1. Create a governor (optionally injecting a ``TelemetryProviding`` sink and
///    a default timeout).
/// 2. Optionally ``attach(_:)`` a ``SystemStateMonitor`` so critical thermal or
///    memory pressure aborts the in-flight operation.
/// 3. Call ``run(_:timeout:source:context:)`` for each unit of work.
/// 4. Tear down with ``cancelAll()`` (or `deinit`); this is the explicit
///    cancellation path and releases the pressure subscription so nothing is
///    left dangling for Instruments leak checks.
///
/// ## Concurrency
/// The type is `@MainActor`-isolated and therefore genuinely `Sendable`: all
/// mutable state is touched only on the main actor, and the wrapped operation
/// itself is dispatched to a detached task so decode/render work does not block
/// the main thread. Telemetry flows exclusively through ``TelemetryProviding``
/// — Sentry is never referenced directly.
@MainActor
final class OperationGovernor: Sendable {

    // MARK: - Configuration

    /// Tunables for a ``OperationGovernor``.
    ///
    /// `telemetry` is `@MainActor`-isolated and therefore not `Sendable`; this
    /// struct is intentionally *not* `Sendable` and is only ever constructed and
    /// read on the main actor.
    struct Configuration {
        /// The timeout applied to ``run(_:timeout:source:context:)`` when the
        /// caller does not supply its own. Defaults to 30 seconds.
        var defaultTimeout: Duration
        /// When `true`, a critical system-pressure snapshot from an attached
        /// ``SystemStateMonitor`` cancels the active operation. Defaults to `true`.
        var abortOnCriticalPressure: Bool
        /// An optional telemetry sink. When `nil`, telemetry is silently skipped
        /// (no direct Sentry usage).
        var telemetry: (any TelemetryProviding)?

        init(
            defaultTimeout: Duration = .seconds(30),
            abortOnCriticalPressure: Bool = true,
            telemetry: (any TelemetryProviding)? = nil
        ) {
            self.defaultTimeout = defaultTimeout
            self.abortOnCriticalPressure = abortOnCriticalPressure
            self.telemetry = telemetry
        }
    }

    // MARK: - Public API

    /// Wraps `operation` so it cannot hang past `timeout`, is cancellable, and
    /// reports every failure through ``MediaError`` + telemetry.
    ///
    /// - Parameters:
    ///   - operation: The async work to perform. Must be `@Sendable` and return a
    ///     `Sendable` result; it runs on a detached task off the main actor.
    ///   - timeout: Optional override for ``Configuration/defaultTimeout``.
    ///   - source: Playback origin, used to bucket telemetry.
    ///   - context: A short label for the operation, used in logs/telemetry.
    /// - Returns: The value produced by `operation`.
    /// - Throws: A ``MediaError`` — `.timedOut` on timeout, `.cancelled` on
    ///   cancellation, `.thermalPressure`/`.memoryPressure` when aborted by
    ///   system pressure, or the classified underlying error otherwise.
    func run<T: Sendable>(
        _ operation: @escaping () async throws -> T,
        timeout: Duration? = nil,
        source: PlaybackSource = .local,
        context: String = #function
    ) async throws -> T {
        let effectiveTimeout = timeout ?? config.defaultTimeout
        clearPressureAbort()

        return try await withThrowingTaskGroup(of: T.self) { [weak self] group in
            guard let self else {
                throw MediaError(
                    kind: .unknown,
                    source: source,
                    message: "OperationGovernor was deallocated mid-run."
                )
            }

            group.addTask { @MainActor in
                let handle = Task.detached { try await operation() }
                self.registerCanceller { handle.cancel() }
                defer { self.clearCanceller() }
                return try await withTaskCancellationHandler {
                    try await handle.value
                } onCancel: {
                    handle.cancel()
                }
            }

            group.addTask { @MainActor in
                try await Task.sleep(for: effectiveTimeout)
                throw MediaError(
                    kind: .timedOut,
                    source: source,
                    underlyingDomain: "TitanPlayer.OperationGovernor",
                    underlyingMessage: "Operation \"\(context)\" exceeded its \(effectiveTimeout) budget.",
                    message: "Operation \"\(context)\" timed out."
                )
            }

            do {
                guard let first = try await group.next() else {
                    throw MediaError(
                        kind: .unknown,
                        source: source,
                        message: "Operation \"\(context)\" produced no result."
                    )
                }
                group.cancelAll()
                self.clearPressureAbort()
                #if DEBUG
                self.logger.debug("Operation succeeded: \(context)")
                #endif
                return first
            } catch {
                let abortedReason = self.pressureAbortReason
                self.clearPressureAbort()
                let mapped = self.mapFailure(error, pressureAbortReason: abortedReason, source: source, context: context)
                self.recordFailure(mapped, context: context, source: source)
                throw mapped
            }
        }
    }

    /// Cancels the currently in-flight operation (if any) and releases the
    /// pressure subscription. Safe to call repeatedly.
    func cancelAll() {
        activeCanceller?()
        activeCanceller = nil
        pressureCancellable?.cancel()
        pressureCancellable = nil
        clearPressureAbort()
        #if DEBUG
        logger.debug("OperationGovernor cancelled all and detached from pressure source")
        #endif
    }

    /// Subscribes to a ``SystemStateMonitor`` so critical pressure aborts the
    /// active operation. Replaces any previous subscription.
    ///
    /// - Parameter monitor: The monitor whose ``SystemStateMonitor/snapshotPublisher``
    ///   this governor observes.
    func attach(_ monitor: SystemStateMonitor) {
        pressureCancellable?.cancel()
        pressureCancellable = monitor.snapshotPublisher
            .sink { [weak self] snapshot in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.config.abortOnCriticalPressure, snapshot.shouldPauseForSystem else {
                        if snapshot.shouldPauseForSystem {
                            self.recordCriticalPressure(snapshot)
                        }
                        return
                    }
                    let kind: MediaError.Kind =
                        snapshot.thermal == .critical ? .thermalPressure : .memoryPressure
                    self.beginPressureAbort(kind: kind, snapshot: snapshot)
                }
            }
    }

    // MARK: - Private state

    private let config: Configuration
    private let telemetry: (any TelemetryProviding)?
    private let logger = Logger(subsystem: "com.titanplayer", category: "OperationGovernor")

    private var pressureCancellable: (any Cancellable)?
    private var activeCanceller: (() -> Void)?
    private var pressureAbortReason: MediaError.Kind?

    // MARK: - Initialization

    /// Creates a governor.
    /// - Parameter configuration: Tunables; defaults to a 30s timeout with no
    ///   telemetry sink.
    init(configuration: Configuration = .init()) {
        self.config = configuration
        self.telemetry = configuration.telemetry
    }

    deinit {
        // `@MainActor` class `deinit` is main-actor-isolated, so the
        // non-`Sendable` `Cancellable` can be released directly.
        pressureCancellable?.cancel()
    }

    // MARK: - Pressure handling

    private func beginPressureAbort(kind: MediaError.Kind, snapshot: SystemStateSnapshot) {
        pressureAbortReason = kind
        logger.warning("System pressure critical (thermal=\(snapshot.thermal.description), memory=\(snapshot.memory.description)) — aborting active operation.")
        activeCanceller?()
    }

    private func recordCriticalPressure(_ snapshot: SystemStateSnapshot) {
        guard let telemetry else { return }
        telemetry.record(.compatibilityModeActivated(
            reason: "system_pressure:\(snapshot.thermal.description)_mem:\(snapshot.memory.description)",
            source: .local
        ))
    }

    private func clearPressureAbort() {
        pressureAbortReason = nil
    }

    // MARK: - Cancellation bookkeeping

    private func registerCanceller(_ canceller: @escaping () -> Void) {
        activeCanceller = canceller
    }

    private func clearCanceller() {
        activeCanceller = nil
    }

    // MARK: - Error mapping

    /// Classifies an arbitrary failure from the task group into a ``MediaError``.
    ///
    /// Order is most-specific-first: an explicit pressure abort wins, then
    /// `CancellationError`, then an already-``MediaError``, with the underlying
    /// error funneled through ``MediaError/init(_:source:)`` as the fallback.
    private func mapFailure(
        _ error: Error,
        pressureAbortReason: MediaError.Kind?,
        source: PlaybackSource,
        context: String
    ) -> MediaError {
        if let reason = pressureAbortReason {
            return MediaError(
                kind: reason,
                source: source,
                underlyingDomain: "TitanPlayer.OperationGovernor",
                underlyingMessage: "Operation \"\(context)\" aborted by system pressure.",
                message: "Operation \"\(context)\" was aborted due to system pressure."
            )
        }
        if error is CancellationError {
            return MediaError(
                kind: .cancelled,
                source: source,
                underlyingDomain: "TitanPlayer.OperationGovernor",
                underlyingMessage: "Operation \"\(context)\" was cancelled.",
                message: "Operation \"\(context)\" was cancelled."
            )
        }
        if let mediaError = error as? MediaError {
            return mediaError
        }
        return MediaError(error, source: source)
    }

    // MARK: - Telemetry

    /// Emits a failure to the injected ``TelemetryProviding`` sink.
    ///
    /// Sentry is never touched directly — every signal funnels through
    /// `telemetry.record(_:)` so consent and privacy gates apply uniformly.
    private func recordFailure(_ error: MediaError, context: String, source: PlaybackSource) {
        logger.error("OperationGovernor failure [\(context)]: \(error.description)")
        guard let telemetry else { return }
        telemetry.record(.playbackFailed(
            codec: "operation",
            resolution: context,
            errorCode: error.telemetryErrorCode,
            source: source
        ))
    }
}
