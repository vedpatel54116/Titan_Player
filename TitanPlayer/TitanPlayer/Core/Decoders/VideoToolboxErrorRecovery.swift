import Foundation
@preconcurrency import Combine
import VideoToolbox
import CoreMedia
import os

// MARK: - VideoToolboxErrorRecovery

/// Coordinates recovery of a VideoToolbox decompression session after it is
/// invalidated out from under the decoder.
///
/// Titan Player's `VideoToolboxDecoder` creates a `VTDecompressionSession` once
/// and reuses it for the lifetime of a track. When the system sleeps/wakes, or
/// enters a thermal/memory-pressure state, that session can be invalidated by
/// the OS while the decoder still holds a reference to it. Without recovery the
/// next `VTDecompressionSessionDecodeFrame` silently fails and playback
/// **stalls** — no error propagates to the UI and the frame pipeline freezes.
///
/// This type owns the *recovery policy* (it does not own the `VTDecompressionSession`
/// itself — the decoder does). It decides:
///
/// - whether a failure is **recoverable** (transient decode/session errors) vs.
///   **persistent** (unsupported format, explicit cancellation);
/// - whether recovery should be **deferred** because the system is under
///   critical thermal or memory pressure;
/// - how long to **back off** between attempts using an exponential schedule;
/// - when the attempt **budget** is exhausted and recovery should give up.
///
/// Every failure is funneled through the centralized ``MediaError`` enum and
/// reported only through a ``TelemetryProviding`` bridge (``RecoveryTelemetrySink``)
/// — Sentry is never referenced directly. Recovery progress is also surfaced as
/// a Combine `AnyPublisher` of ``RecoveryEvent`` for UI/debug consumers.
///
/// ### Example
/// ```swift
/// let recovery = VideoToolboxErrorRecovery()
/// let frame: CMSampleBuffer = try await recovery.recover(context: .init(codec: "hevc")) {
///     decoder.invalidateSessionUnlocked()
///     try decoder.createDecompressionSession(for: track, isHDR: track.isHDR)
///     return try await decoder.decode(packet)
/// }
/// ```
final class VideoToolboxErrorRecovery: Sendable {

    // MARK: Lifecycle configuration

    /// Tuning knobs for the recovery policy.
    struct Configuration: Sendable {
        /// Maximum number of consecutive recovery attempts before giving up.
        var maxRecoveryAttempts: Int = 5
        /// Initial backoff between attempts.
        var baseBackoff: Duration = .milliseconds(120)
        /// Upper bound for the exponential backoff schedule.
        var maxBackoff: Duration = .seconds(2)
        /// Backoff growth factor applied per failed attempt.
        var backoffFactor: Double = 2.0
        /// When `true`, a small randomized jitter is added to the backoff to
        /// avoid thundering-herd retries across multiple decoders.
        var jitter: Bool = false

        static let `default` = Configuration()
    }

    /// Context attached to every recovery decision for telemetry and reporting.
    struct RecoveryContext: Sendable {
        var codec: String?
        var resolution: String?
        var source: PlaybackSource = .local
    }

    /// Discrete recovery outcomes, emitted on ``recoveryEvents``.
    enum RecoveryEvent: Sendable {
        /// Recovery was granted and an attempt is about to be made.
        case attemptGranted(kind: MediaError.Kind)
        /// A recovery attempt succeeded.
        case recovered
        /// Recovery was abandoned after exhausting the attempt budget.
        case gaveUp(MediaError)
        /// Recovery was deferred because the system is under critical pressure.
        case deferredForPressure(MediaError)
        /// The session was invalidated (e.g. sleep/wake) and recovery armed.
        case sessionInvalidated(reason: SessionInvalidationReason)
    }

    /// Why a decompression session was invalidated, used to classify telemetry.
    enum SessionInvalidationReason: Sendable {
        /// System sleep/wake cycle invalidated the session.
        case sleepWake
        /// App was backgrounded / resumed.
        case appLifecycle
        /// OS memory-pressure notification fired.
        case memoryWarning
        /// OS thermal-state notification fired.
        case thermalState
        /// Caller-requested explicit invalidation.
        case explicit
    }

    // MARK: Private state

    private struct State: @unchecked Sendable {
        var totalAttempts: Int = 0
        var consecutiveFailures: Int = 0
        var lastRecoveryAt: Date?
        var lastError: MediaError?
        var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
        var memory: MemoryPressureLevel = .normal
        let subject: PassthroughSubject<RecoveryEvent, Never>
    }

    private let lock: OSAllocatedUnfairLock<State>
    private let telemetry: RecoveryTelemetrySink
    private let configuration: Configuration
    private let logger = Logger(subsystem: "com.titanplayer", category: "VideoToolboxErrorRecovery")

    // MARK: Initialization

    /// Creates a recovery coordinator.
    ///
    /// - Parameters:
    ///   - telemetry: Telemetry sink. Defaults to ``RecoveryTelemetrySink/default``
    ///     which hops to the main actor and records via `TelemetryManager.shared`.
    ///   - configuration: Recovery policy tuning. Defaults to ``Configuration/default``.
    init(
        telemetry: RecoveryTelemetrySink = .default,
        configuration: Configuration = .default
    ) {
        self.telemetry = telemetry
        self.configuration = configuration
        let subject = PassthroughSubject<RecoveryEvent, Never>()
        self.lock = OSAllocatedUnfairLock(initialState: State(subject: subject))
    }

    // MARK: - Publisher

    /// A stream of recovery decisions for UI/debug consumers. Replays nothing;
    /// subscribe before triggering recovery to observe events.
    var recoveryEvents: AnyPublisher<RecoveryEvent, Never> {
        lock.withLock { $0.subject.eraseToAnyPublisher() }
    }

    // MARK: - Error classification

    /// Maps an arbitrary decode/session error onto the centralized ``MediaError``.
    ///
    /// Mapping order (most-specific first):
    /// 1. Already-``MediaError`` values pass through (with codec/resolution
    ///    attached when missing).
    /// 2. ``CancellationError`` → ``MediaError/Kind/cancelled``.
    /// 3. ``DecoderError`` refines by severity (transient decode failures vs.
    ///    persistent format errors).
    /// 4. `VTToolboxErrorDomain` / `OSStatus` decode failures (including
    ///    `kVTInvalidSessionErr`, the canonical sleep/wake invalidation).
    /// 5. `MTL*` renderer domains.
    /// 6. Fallback to ``MediaError/init(_:source:codec:resolution:)``.
    ///
    /// - Parameters:
    ///   - error: The raw error thrown by the decode path.
    ///   - context: Codec/resolution/source metadata for telemetry.
    /// - Returns: A classified ``MediaError``.
    func classify(_ error: some Error, context: RecoveryContext = .init()) -> MediaError {
        if let mediaError = error as? MediaError {
            return attachContext(to: mediaError, context: context)
        }

        if error is CancellationError {
            return MediaError(
                kind: .cancelled,
                source: context.source,
                codec: context.codec,
                resolution: context.resolution
            )
        }

        if let decoderError = error as? DecoderError {
            return classifyDecoderError(decoderError, context: context)
        }

        let ns = error as NSError
        if ns.domain == "VTToolboxErrorDomain" {
            return classifyVTStatus(ns.code, context: context)
        }
        if ns.domain.hasPrefix("MTL") {
            return MediaError(
                kind: .rendererFailure,
                source: context.source,
                underlyingDomain: ns.domain,
                underlyingCode: ns.code,
                underlyingMessage: ns.localizedDescription,
                codec: context.codec,
                resolution: context.resolution
            )
        }

        return MediaError(
            error,
            source: context.source,
            codec: context.codec,
            resolution: context.resolution
        )
    }

    /// Whether a classified error represents a recoverable (transient) failure.
    ///
    /// Persistent failures — unsupported formats and explicit cancellation —
    /// are never retried. Decode/session failures are recoverable; timeouts are
    /// retried up to the budget.
    func isRecoverable(_ mediaError: MediaError) -> Bool {
        switch mediaError.kind {
        case .decodingFailed, .timedOut:
            return true
        case .thermalPressure, .memoryPressure:
            // Recoverable once pressure clears, but gated — see ``beginRecovery``.
            return true
        case .formatUnsupported, .cancelled, .unknown, .invalidURL,
             .assetLoadFailed, .noPlayableTracks, .audioOutputFailed,
             .rateNotSupported, .seekFailed, .networkUnavailable, .rendererFailure,
             .drmUnauthorized:
            return false
        }
    }

    // MARK: - Pressure gating

    /// Updates the last-known thermal state. Call from a `ProcessInfo`
    /// thermal-state observer so recovery can defer while the system is hot.
    func updateThermalState(_ state: ProcessInfo.ThermalState) {
        lock.withLock { $0.thermal = state }
    }

    /// Updates the last-known memory-pressure level. Call from a
    /// `DispatchSource` memory-pressure observer.
    func updateMemoryPressure(_ level: MemoryPressureLevel) {
        lock.withLock { $0.memory = level }
    }

    /// `true` when the system is currently under critical pressure and recovery
    /// should be deferred rather than spending cycles recreating a session.
    var isUnderCriticalPressure: Bool {
        lock.withLock {
            $0.thermal == .critical || $0.memory == .critical
        }
    }

    // MARK: - Session invalidation

    /// Records that the decompression session was invalidated and arms recovery.
    ///
    /// Sleep/wake is the canonical trigger: `VTDecompressionSession` objects are
    /// torn down by the OS across a power-state transition, and the decoder must
    /// recreate them. This method resets the consecutive-failure budget (a fresh
    /// invalidation is a legitimate recovery opportunity, not a stall) and emits
    /// ``RecoveryEvent/sessionInvalidated(reason:)``.
    ///
    /// - Parameters:
    ///   - reason: Why the session was considered invalid.
    ///   - context: Telemetry metadata.
    func reportSessionInvalidation(
        reason: SessionInvalidationReason,
        context: RecoveryContext = .init()
    ) {
        lock.withLock { state in
            // A fresh invalidation resets the stall budget so recovery is allowed.
            state.consecutiveFailures = 0
            state.lastRecoveryAt = Date()
        }
        telemetry.record(.playbackFailed(
            codec: context.codec ?? "unknown",
            resolution: context.resolution ?? "unknown",
            errorCode: "vt_session_invalidated",
            source: context.source
        ))
        lock.withLock { $0.subject.send(.sessionInvalidated(reason: reason)) }

        #if DEBUG
        logger.debug("Session invalidated (reason=\(String(describing: reason))); recovery armed")
        #endif
    }

    // MARK: - Low-level recovery gates

    /// Decides whether an attempt should proceed, applying the pressure gate,
    /// attempt budget, cancellation check, and backoff.
    ///
    /// Call this *before* recreating the session. On return the caller should
    /// recreate the session and then call ``noteRecoverySucceeded()`` or
    /// ``noteRecoveryFailed(with:)``.
    ///
    /// - Parameters:
    ///   - error: The failure that triggered recovery.
    ///   - context: Telemetry metadata.
    /// - Returns: The recovery decision.
    /// - Throws: A ``MediaError`` (`.cancelled`, `.thermalPressure`,
    ///   `.memoryPressure`, the original failure, or a gave-up error) when
    ///   recovery cannot proceed.
    func beginRecovery(
        for error: some Error,
        context: RecoveryContext = .init()
    ) async throws -> RecoveryDecision {
        let mediaError = classify(error, context: context)

        if mediaError.kind == .cancelled {
            throw mediaError
        }

        guard isRecoverable(mediaError) else {
            recordFailure(mediaError, event: .gaveUp(mediaError))
            throw mediaError
        }

        // Pressure gate: defer rather than burn cycles recreating a session.
        if isUnderCriticalPressure {
            let pressureError: MediaError = lock.withLock { state in
                state.thermal == .critical
                    ? MediaError.thermalPressure(state: state.thermal, source: context.source)
                    : MediaError.memoryPressure(availableBytes: nil, source: context.source)
            }
            recordFailure(pressureError, event: .deferredForPressure(pressureError))
            throw pressureError
        }

        // Cancellation may have arrived between the failure and now.
        if Task.isCancelled {
            throw MediaError(kind: .cancelled, source: context.source,
                             codec: context.codec, resolution: context.resolution)
        }

        let attempt = lock.withLock { state -> Int in
            let attempt = state.consecutiveFailures
            state.consecutiveFailures += 1
            state.totalAttempts += 1
            state.lastError = mediaError
            state.lastRecoveryAt = Date()
            return attempt
        }

        // Budget exhausted — give up.
        if attempt >= configuration.maxRecoveryAttempts {
            recordFailure(mediaError, event: .gaveUp(mediaError))
            throw mediaError
        }

        recordAttemptGranted(mediaError)
        try await backoff(after: attempt)
        return .proceed
    }

    /// Marks the most recent recovery attempt as successful, resetting the
    /// consecutive-failure budget so future stalls start fresh.
    func noteRecoverySucceeded() {
        lock.withLock { $0.consecutiveFailures = 0 }
        lock.withLock { $0.subject.send(.recovered) }
    }

    /// Marks the most recent recovery attempt as failed.
    func noteRecoveryFailed(with error: MediaError) {
        lock.withLock { $0.lastError = error }
    }

    /// Resets all recovery counters and pressure state. Call when (re)configuring
    /// a fresh track so a prior track's stall history does not carry over.
    func reset() {
        lock.withLock { state in
            state.totalAttempts = 0
            state.consecutiveFailures = 0
            state.lastRecoveryAt = nil
            state.lastError = nil
        }
    }

    /// The total number of recovery attempts made since the last ``reset()``.
    var totalAttempts: Int { lock.withLock { $0.totalAttempts } }

    /// The current consecutive-failure count (0 after a successful recovery).
    var consecutiveFailures: Int { lock.withLock { $0.consecutiveFailures } }

    // MARK: - High-level recovery orchestration

    /// Runs `operation`, transparently retrying it after recovering from
    /// transient failures (session invalidation, decode errors, timeouts).
    ///
    /// The closure is responsible for recreating the decompression session on
    /// each attempt — typically by invalidating the stale session and building a
    /// new one, then performing the decode. Persistent failures and exhaustion
    /// of the attempt budget rethrow the classified ``MediaError``.
    ///
    /// - Parameters:
    ///   - context: Telemetry metadata.
    ///   - operation: The guarded work (session recreate + decode).
    /// - Returns: The value produced by `operation` on its successful attempt.
    /// - Throws: A classified ``MediaError`` when recovery is impossible.
    func recover<T>(
        context: RecoveryContext = .init(),
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let maxAttempts = configuration.maxRecoveryAttempts
        for attempt in 0...maxAttempts {
            do {
                let result = try await operation()
                noteRecoverySucceeded()
                return result
            } catch {
                let mediaError = classify(error, context: context)

                if mediaError.kind == .cancelled {
                    throw mediaError
                }
                guard isRecoverable(mediaError) else {
                    recordFailure(mediaError, event: .gaveUp(mediaError))
                    throw mediaError
                }
                if isUnderCriticalPressure {
                    let pressureError: MediaError = lock.withLock { state in
                        state.thermal == .critical
                            ? MediaError.thermalPressure(state: state.thermal, source: context.source)
                            : MediaError.memoryPressure(availableBytes: nil, source: context.source)
                    }
                    recordFailure(pressureError, event: .deferredForPressure(pressureError))
                    throw pressureError
                }

                lock.withLock { state in
                    state.consecutiveFailures += 1
                    state.totalAttempts += 1
                    state.lastError = mediaError
                    state.lastRecoveryAt = Date()
                }

                if attempt >= maxAttempts {
                    recordFailure(mediaError, event: .gaveUp(mediaError))
                    throw mediaError
                }
                recordAttemptGranted(mediaError)
                try await backoff(after: attempt)
            }
        }
        // Unreachable: the loop always returns or throws.
        throw MediaError(kind: .unknown, source: context.source,
                         codec: context.codec, resolution: context.resolution)
    }

    // MARK: - Timeout

    /// Races `operation` against `duration`, mapping a timeout or cancellation
    /// onto ``MediaError`` (``MediaError/Kind/timedOut`` / ``.cancelled``).
    ///
    /// - Parameters:
    ///   - duration: The time budget for `operation`.
    ///   - context: Telemetry metadata (used if the timeout is reported).
    ///   - operation: The work to bound.
    /// - Returns: The operation's result.
    /// - Throws: ``MediaError/timedOut`` on timeout, ``MediaError/cancelled`` on
    ///   cancellation, or the operation's own classified error.
    func withTimeout<T>(
        _ duration: Duration,
        context: RecoveryContext = .init(),
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: self.nanoseconds(from: duration))
                throw MediaError(
                    kind: .timedOut,
                    source: context.source,
                    underlyingDomain: "TitanPlayer",
                    underlyingMessage: "Recovery operation exceeded \(duration) budget.",
                    codec: context.codec,
                    resolution: context.resolution
                )
            }
            do {
                let result = try await group.next()!
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                if error is CancellationError {
                    throw MediaError(kind: .cancelled, source: context.source,
                                     codec: context.codec, resolution: context.resolution)
                }
                if let mediaError = error as? MediaError {
                    throw mediaError.kind == .timedOut ? mediaError : classify(error, context: context)
                }
                throw classify(error, context: context)
            }
        }
    }

    // MARK: - Private helpers

    /// The recovery decision returned by ``beginRecovery(for:context:)``.
    enum RecoveryDecision: Sendable {
        /// Proceed with session recreation and retry.
        case proceed
    }

    private func backoff(after attempt: Int) async throws {
        let raw = configuration.baseBackoff
            * pow(configuration.backoffFactor, Double(attempt))
        var backoff = min(raw, configuration.maxBackoff)

        if configuration.jitter {
            let jitterFraction = Double.random(in: 0...0.25)
            backoff += backoff * jitterFraction
        }

        do {
            try await Task.sleep(nanoseconds: nanoseconds(from: backoff))
        } catch is CancellationError {
            throw MediaError(kind: .cancelled, source: .local)
        } catch {
            throw classify(error)
        }
    }

    /// Converts a `Duration` to whole nanoseconds, preserving the `seconds`
    /// component (which a raw `attoseconds / 1e9` truncation would drop).
    private func nanoseconds(from duration: Duration) -> UInt64 {
        let components = duration.components
        return UInt64(components.seconds) * 1_000_000_000
            + UInt64(components.attoseconds / 1_000_000_000)
    }

    private func classifyDecoderError(
        _ error: DecoderError,
        context: RecoveryContext
    ) -> MediaError {
        let kind: MediaError.Kind
        switch error {
        case .unsupportedCodec, .noDecodersAvailable:
            kind = .formatUnsupported
        case .sessionNotConfigured, .bufferCreationFailed,
             .noFramesDecoded, .hardwareFailure, .softwareFailure:
            kind = .decodingFailed
        }
        return MediaError(
            kind: kind,
            source: context.source,
            underlyingDomain: "TitanPlayer.DecoderError",
            underlyingCode: nil,
            underlyingMessage: error.localizedDescription,
            codec: context.codec,
            resolution: context.resolution
        )
    }

    private func classifyVTStatus(
        _ status: Int,
        context: RecoveryContext
    ) -> MediaError {
        // Documented VideoToolbox status values. The session-invalidation case
        // (kVTInvalidSessionErr, -12900) is the canonical sleep/wake failure.
        let kind: MediaError.Kind
        switch status {
        case -12900: // kVTInvalidSessionErr
            kind = .decodingFailed
        case -12909: // kVTVideoDecoderBadDataErr
            kind = .decodingFailed
        case -12910: // kVTVideoDecoderBusyErr
            kind = .decodingFailed
        case -12911: // kVTVideoDecoderMalfunctionErr
            kind = .decodingFailed
        default:
            kind = .decodingFailed
        }
        return MediaError(
            kind: kind,
            source: context.source,
            underlyingDomain: "VTToolboxErrorDomain",
            underlyingCode: status,
            underlyingMessage: "VT status \(status)",
            codec: context.codec,
            resolution: context.resolution
        )
    }

    private func attachContext(
        to mediaError: MediaError,
        context: RecoveryContext
    ) -> MediaError {
        guard mediaError.codec == nil || mediaError.resolution == nil else {
            return mediaError
        }
        return MediaError(
            kind: mediaError.kind,
            source: mediaError.source,
            underlyingDomain: mediaError.underlyingDomain,
            underlyingCode: mediaError.underlyingCode,
            underlyingMessage: mediaError.underlyingMessage,
            codec: mediaError.codec ?? context.codec,
            resolution: mediaError.resolution ?? context.resolution,
            timestamp: mediaError.timestamp,
            message: mediaError.message
        )
    }

    private func recordAttemptGranted(_ mediaError: MediaError) {
        telemetry.record(.playbackFailed(
            codec: mediaError.codec ?? "unknown",
            resolution: mediaError.resolution ?? "unknown",
            errorCode: "vt_recovery_attempt:\(mediaError.telemetryErrorCode)",
            source: mediaError.source
        ))
        lock.withLock { $0.subject.send(.attemptGranted(kind: mediaError.kind)) }
    }

    private func recordFailure(_ mediaError: MediaError, event: RecoveryEvent) {
        telemetry.record(.playbackFailed(
            codec: mediaError.codec ?? "unknown",
            resolution: mediaError.resolution ?? "unknown",
            errorCode: mediaError.telemetryErrorCode,
            source: mediaError.source
        ))
        lock.withLock { $0.subject.send(event) }

        #if DEBUG
        logger.debug("Recovery failed: \(mediaError.description)")
        #endif
    }
}

// MARK: - RecoveryTelemetrySink

/// A `Sendable` bridge to ``TelemetryProviding`` so the recovery coordinator
/// never stores a non-`Sendable` telemetry reference.
///
/// The default sink hops to the main actor and records through
/// `TelemetryManager.shared` — Sentry is never referenced directly, matching
/// the pattern used by `SpotlightIndexer` and `FairPlayDRM`.
struct RecoveryTelemetrySink: Sendable {
    /// The recording closure. `@Sendable` so it is safe to invoke from any
    /// isolation context.
    let record: @Sendable (TelemetryEvent) -> Void

    /// The default sink: routes events to `TelemetryManager.shared` on the
    /// main actor.
    static let `default` = RecoveryTelemetrySink { event in
        Task { @MainActor in TelemetryManager.shared.record(event) }
    }

    /// Records a telemetry event through the configured sink.
    func record(_ event: TelemetryEvent) {
        record(event)
    }
}
