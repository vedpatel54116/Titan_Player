import AVFAudio
import Foundation
import OSLog

// MARK: - RoomProfile

/// A preset describing the acoustic character of a virtual space.
///
/// Each profile approximates an image-source early-reflection pattern (a handful
/// of discrete, delayed taps) plus a diffuse late-reverberation tail. The old
/// `RoomSimulation` used a single exponential decay convolved against the whole
/// signal, which produced a "swishy" tail with no sense of room geometry. These
/// presets restore the early-reflection structure that makes spatial audio read
/// as a real environment.
enum RoomProfile: Sendable, CaseIterable {
    /// A small listening room (short RT60, tight reflections).
    case small
    /// A medium living-room / studio (default).
    case medium
    /// A large rehearsal / dubbing room.
    case large
    /// A concert hall (long RT60, dense tail).
    case hall
    /// A cathedral (very long RT60, pronounced early slap).
    case cathedral

    // MARK: Acoustic configuration

    /// The concrete acoustic parameters backing this profile.
    var configuration: RoomAcousticsConfiguration {
        switch self {
        case .small:
            RoomAcousticsConfiguration(
                rt60: 0.3,
                earlyReflections: [
                    .init(delay: 0.005, gain: 0.55),
                    .init(delay: 0.011, gain: 0.38),
                    .init(delay: 0.017, gain: 0.26),
                    .init(delay: 0.023, gain: 0.18),
                ]
            )
        case .medium:
            RoomAcousticsConfiguration(
                rt60: 0.6,
                earlyReflections: [
                    .init(delay: 0.008, gain: 0.50),
                    .init(delay: 0.018, gain: 0.34),
                    .init(delay: 0.029, gain: 0.24),
                    .init(delay: 0.041, gain: 0.17),
                    .init(delay: 0.053, gain: 0.11),
                ]
            )
        case .large:
            RoomAcousticsConfiguration(
                rt60: 1.1,
                earlyReflections: [
                    .init(delay: 0.010, gain: 0.48),
                    .init(delay: 0.022, gain: 0.33),
                    .init(delay: 0.038, gain: 0.24),
                    .init(delay: 0.055, gain: 0.17),
                    .init(delay: 0.074, gain: 0.12),
                    .init(delay: 0.093, gain: 0.08),
                ]
            )
        case .hall:
            RoomAcousticsConfiguration(
                rt60: 1.8,
                earlyReflections: [
                    .init(delay: 0.012, gain: 0.46),
                    .init(delay: 0.027, gain: 0.32),
                    .init(delay: 0.046, gain: 0.23),
                    .init(delay: 0.066, gain: 0.16),
                    .init(delay: 0.089, gain: 0.11),
                    .init(delay: 0.112, gain: 0.07),
                ]
            )
        case .cathedral:
            RoomAcousticsConfiguration(
                rt60: 3.0,
                earlyReflections: [
                    .init(delay: 0.014, gain: 0.44),
                    .init(delay: 0.031, gain: 0.31),
                    .init(delay: 0.054, gain: 0.22),
                    .init(delay: 0.079, gain: 0.16),
                    .init(delay: 0.106, gain: 0.11),
                    .init(delay: 0.135, gain: 0.07),
                    .init(delay: 0.167, gain: 0.05),
                ]
            )
        }
    }
}

// MARK: - RoomAcousticsConfiguration

/// Sendable, value-type description of a room's reverberation.
struct RoomAcousticsConfiguration: Sendable {
    /// Reverberation time (seconds) for the diffuse tail to decay ~60 dB.
    let rt60: TimeInterval
    /// Discrete early-reflection taps (image-source approximation).
    let earlyReflections: [EarlyReflectionTap]
}

// MARK: - EarlyReflectionTap

/// A single early reflection: a delayed, attenuated copy of the input.
struct EarlyReflectionTap: Sendable {
    /// Arrival delay after the direct sound, in seconds.
    let delay: TimeInterval
    /// Linear gain of the tap relative to the direct sound (0…1).
    let gain: Float
}

// MARK: - RoomSimulation

/// Realistic room simulation for spatial audio.
///
/// ## Overview
/// `RoomSimulation` replaces the previous naive single-tap delay reverb. It
/// models a room as a short set of **early reflections** (discrete, delayed
/// taps derived from the selected ``RoomProfile``) followed by a **diffuse late
/// tail** (exponentially-decaying low-passed noise). The two are summed into a
/// per-sample-rate impulse response that is convolved against each channel,
/// then mixed against the dry signal by `amount`.
///
/// ## Concurrency & isolation
    /// The class is a non-isolated `Sendable` reference type so its DSP hot path
    /// ``applyReverb(_:amount:)`` can be called synchronously from the audio render
    /// graph (e.g. ``SpatialRenderer``). Because the ``TelemetryProviding``
    /// protocol is `@MainActor`-isolated, the telemetry sink is **not** stored on
    /// the instance; instead it is passed into ``recordDiagnostics(using:)`` at
    /// call time, keeping the type genuinely `Sendable` (no `@unchecked`) and
    /// Instruments-clean (no retain cycles, no leaked observers).
///
/// ## System pressure, cancellation & timeouts
/// - **Thermal / memory pressure:** on each ``applyReverb(_:amount:)`` call the
///   simulator reads `ProcessInfo.thermalState` and the last
///   ``SystemStateSnapshot`` pushed via ``applySystemState(_:)``. Under
///   pressure it gracefully degrades — shortening to early reflections only and
///   reducing wet level — instead of throwing or stalling. The DSP path itself
///   is non-isolated so it can run on the audio render thread.
/// - **Cancellation:** cooperative `Task.isCancelled` checks inside the
///   convolution loop throw ``MediaError/kind`` `.cancelled`.
/// - **Timeouts:** the async ``render(_:amount:timeout:)`` entry point enforces
///   a soft budget and throws `.timedOut`; the sync path is unconditionally
///   bounded by the cached, capped impulse response length.
final class RoomSimulation: Sendable {

    // MARK: Tunables

    /// Hard cap on the diffuse tail length (seconds) to keep per-buffer
    /// convolution within a real-time-ish budget regardless of profile RT60.
    private let maxTailSeconds: Double = 0.5

    /// Wet-level multiplier applied when the system is under pressure.
    private let degradedWetScale: Float = 0.4

    // MARK: Immutable configuration

    private let profile: RoomProfile
    private let logger = Logger(subsystem: "com.titanplayer.audio", category: "RoomSimulation")

    // MARK: Guarded shared state (Sendable-safe)

    /// Cache of full (early + tail) impulse responses, keyed by sample rate.
    private let irCache = OSAllocatedUnfairLock<[Double: [Float]]>(initialState: [:])

    /// Cache of early-reflections-only impulse responses, keyed by sample rate.
    /// Used when the system is under pressure to drop the expensive tail.
    private let earlyIRCache = OSAllocatedUnfairLock<[Double: [Float]]>(initialState: [:])

    /// Runtime bookkeeping shared between the isolated config surface and the
    /// `nonisolated` DSP path.
    private let runtime = OSAllocatedUnfairLock<RuntimeState>(initialState: .init())

    // MARK: Initialization

    /// Creates a room simulator.
    ///
    /// - Parameter profile: The acoustic preset. Defaults to ``RoomProfile/medium``.
    init(profile: RoomProfile = .medium) {
        self.profile = profile
    }

    // MARK: - Public synchronous API

    /// Applies room reverberation to a PCM buffer.
    ///
    /// Combines early reflections and a diffuse tail via convolution, then
    /// cross-fades the wet result with the dry input by `amount`. This is the
    /// backward-compatible entry point used by ``SpatialRenderer``.
    ///
    /// - Parameters:
    ///   - buffer: The source `AVAudioPCMBuffer`. Must carry float data.
    ///   - amount: Wet mix in `0…1` (values outside are clamped).
    /// - Returns: A new `AVAudioPCMBuffer` with reverberation applied.
    /// - Throws: ``MediaError`` for unsupported formats, cancellation, or
    ///   unexpected internal failures.
    func applyReverb(
        _ buffer: AVAudioPCMBuffer,
        amount: Float
    ) throws -> AVAudioPCMBuffer {
        guard let format = optionalFormat(buffer),
              format.commonFormat == .pcmFormatFloat32 || format.commonFormat == .pcmFormatFloat64 else {
            throw MediaError(
                kind: .audioOutputFailed,
                source: .local,
                message: "RoomSimulation requires a float PCM format."
            )
        }

        guard let output = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            throw MediaError(
                kind: .audioOutputFailed,
                source: .local,
                message: "RoomSimulation failed to allocate the output buffer."
            )
        }
        output.frameLength = buffer.frameLength

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return output }

        // Determine pressure-driven degradation for this call.
        let pressure = self.currentPressure()
        let useTail = !pressure.isDegraded
        let wet = clamp(Float(amount) * (pressure.isDegraded ? degradedWetScale : 1), 0, 1)

        let sampleRate = buffer.format.sampleRate
        let ir = self.impulseResponse(sampleRate: sampleRate, includeTail: useTail)

        let channelCount = Int(buffer.format.channelCount)
        guard let inData = buffer.floatChannelData,
              let outData = output.floatChannelData else {
            throw MediaError(
                kind: .audioOutputFailed,
                source: .local,
                message: "RoomSimulation could not access float channel data."
            )
        }

        for channel in 0..<channelCount {
            let input = inData[channel]
            let outputPtr = outData[channel]
            for n in 0..<frameCount {
                if Task.isCancelled {
                    throw MediaError(kind: .cancelled, source: .local,
                                     message: "RoomSimulation was cancelled mid-render.")
                }
                var acc: Float = 0
                for k in 0..<ir.count {
                    let idx = n - k
                    guard idx >= 0 else { break }
                    acc += input[idx] * ir[k]
                }
                let dry = input[n]
                outputPtr[n] = dry * (1 - wet) + acc * wet
            }
        }

        self.noteProcessed(frames: frameCount, degraded: pressure.isDegraded)
        return output
    }

    // MARK: - Public asynchronous API

    /// Applies room reverberation with cancellation and a soft timeout.
    ///
    /// This is the preferred entry point for callers already inside a `Task`.
    /// It checks for cancellation up front and enforces `timeout` as a budget
    /// for the (synchronous) DSP work.
    ///
    /// - Parameters:
    ///   - buffer: The source buffer.
    ///   - amount: Wet mix in `0…1`.
    ///   - timeout: Maximum allowed wall-clock budget. Defaults to 1 second.
    /// - Returns: A reverberated buffer.
    /// - Throws: ``MediaError`` with `.cancelled` or `.timedOut` as appropriate.
    func render(
        _ buffer: AVAudioPCMBuffer,
        amount: Float,
        timeout: Duration = .seconds(1)
    ) async throws -> AVAudioPCMBuffer {
        try Task.checkCancellation()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let result = try applyReverb(buffer, amount: amount)
        if ContinuousClock.now > deadline {
            throw MediaError(
                kind: .timedOut,
                source: .local,
                message: "RoomSimulation exceeded its \(timeout) processing budget."
            )
        }
        return result
    }

    // MARK: - System pressure

    /// Pushes the latest system health snapshot.
    ///
    /// Call this from a `@MainActor` observer (such as ``SystemStateMonitor``)
    ///   so the DSP path can degrade gracefully under pressure.
    /// - Parameter snapshot: The most recent ``SystemStateSnapshot``.
    @MainActor func applySystemState(_ snapshot: SystemStateSnapshot) {
        runtime.withLock { $0.systemState = snapshot }
        #if DEBUG
        logger.debug("RoomSimulation received system state (thermal=\(snapshot.thermal.description), memory=\(snapshot.memory.description))")
        #endif
    }

    // MARK: - Telemetry

    /// Emits a telemetry event for pressure-driven degradation, if any occurred
    /// since the last flush.
    ///
    /// Telemetry is sent **only** through the ``TelemetryProviding`` protocol
    /// (which wraps Sentry) — Sentry is never referenced here. Pass a sink such
    /// as `TelemetryManager.shared`; when `sink` is `nil` nothing is recorded.
    ///
    /// - Parameter sink: A telemetry sink (e.g. `TelemetryManager.shared`).
    @MainActor func recordDiagnostics(using sink: (any TelemetryProviding)? = nil) {
        guard let target = sink else { return }
        let state = runtime.withLock { $0 }
        guard state.degradedFrames > 0, !state.degradationReported else { return }

        let reason = "audio_room_sim_degraded:thermal_\(state.systemState.thermal.description)"
        target.record(.compatibilityModeActivated(reason: reason, source: .local))
        runtime.withLock { $0.degradationReported = true }
        logger.warning("RoomSimulation degraded by system pressure (thermal=\(state.systemState.thermal.description), memory=\(state.systemState.memory.description))")
    }

    // MARK: - Private: pressure resolution

    private struct Pressure: Sendable {
        let isDegraded: Bool
    }

    /// Reads current pressure from `ProcessInfo` plus the last pushed snapshot.
    ///
    /// Touches only `Sendable` values: the runtime lock guards a `Sendable`
    /// snapshot, and `ProcessInfo` is thread-safe, so this is safe to call from
    /// the synchronous DSP path.
    private func currentPressure() -> Pressure {
        let thermal = ThermalLevel(ProcessInfo.processInfo.thermalState)
        let memory = runtime.withLock { $0.systemState.memory }
        let degraded = thermal == .serious || thermal == .critical
            || memory == .warning || memory == .critical
        return Pressure(isDegraded: degraded)
    }

    private func noteProcessed(frames: Int, degraded: Bool) {
        runtime.withLock {
            $0.totalFrames += frames
            if degraded { $0.degradedFrames += frames }
        }
    }

    // MARK: - Private: impulse response

    /// Returns a cached impulse response for `sampleRate`, generating and caching
    /// one on first use.
    private func impulseResponse(sampleRate: Double, includeTail: Bool) -> [Float] {
        let cache = includeTail ? irCache : earlyIRCache
        if let cached = cache.withLock({ $0[sampleRate] }) {
            return cached
        }
        let ir = Self.buildImpulseResponse(sampleRate: sampleRate,
                                           configuration: profile.configuration,
                                           includeTail: includeTail,
                                           maxTailSeconds: maxTailSeconds)
        cache.withLock { $0[sampleRate] = ir }
        return ir
    }

    /// Synthesizes an impulse response: discrete early-reflection taps plus an
    /// optional exponentially-decaying, low-passed noise tail.
    ///
    /// Pure function (no `self` access) so it can run on any thread during cache
    /// population.
    private static func buildImpulseResponse(
        sampleRate: Double,
        configuration: RoomAcousticsConfiguration,
        includeTail: Bool,
        maxTailSeconds: Double
    ) -> [Float] {
        let cfg = configuration
        let tailSeconds = includeTail ? min(cfg.rt60, maxTailSeconds) : 0
        let tailLength = Int(tailSeconds * sampleRate)
        var ir: [Float] = tailLength > 0 ? .init(repeating: 0, count: tailLength) : [Float](repeating: 0, count: 1)

        if tailLength > 0 {
            let tau = max(cfg.rt60 / 6.91, 1e-3)
            var last: Float = 0
            for i in 0..<tailLength {
                let t = Double(i) / sampleRate
                let envelope = Float(exp(-t / tau))
                let white = Float.random(in: -1...1)
                last = last * 0.85 + white * 0.15
                ir[i] += last * envelope
            }
        }

        for tap in cfg.earlyReflections {
            let idx = Int(tap.delay * sampleRate)
            guard idx < ir.count else { continue }
            ir[idx] += Float(tap.gain)
        }

        return normalize(ir)
    }

    /// Scales the IR so its peak magnitude is 1.0, preventing wet blow-ups.
    private static func normalize(_ ir: [Float]) -> [Float] {
        guard let peak = ir.max(by: { abs($0) < abs($1) }), abs(peak) > 1e-6 else {
            return ir
        }
        return ir.map { $0 / abs(peak) }
    }
}

// MARK: - RuntimeState

/// Sendable bookkeeping shared between the isolated config surface and the
/// DSP path. All mutations go through ``OSAllocatedUnfairLock``.
private struct RuntimeState: Sendable {
    var systemState: SystemStateSnapshot = .nominal
    var totalFrames: Int = 0
    var degradedFrames: Int = 0
    var degradationReported: Bool = false
}

// MARK: - Helpers

private func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
    min(max(value, lower), upper)
}

private func optionalFormat(_ buffer: AVAudioPCMBuffer) -> AVAudioFormat? {
    buffer.format
}
