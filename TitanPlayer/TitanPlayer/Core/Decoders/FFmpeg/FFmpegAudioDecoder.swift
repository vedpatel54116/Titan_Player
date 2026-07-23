import Foundation
import CoreMedia
import Combine
import os.log

// MARK: - FFmpegAudioDecoder

/// Audio decoder stub for the compressed surround-sound codecs **AC-3**,
/// **E-AC-3** and **DTS**.
///
/// # Why this exists
///
/// Titan Player demuxes MKV/MKA/MP4 containers through FFmpeg's `libavformat`
/// and can decode *video* frames via VideoToolbox + a software fallback, but
/// the **audio** side for the lossy surround families is not yet wired to
/// FFmpeg's `libavcodec` decode path. This type is the seam where that work
/// will land: it recognises AC-3 / E-AC-3 / DTS tracks and reports the single
/// hard limitation clearly.
///
/// # Status: stubbed
///
/// Real decode (opening an `AVCodecContext`, feeding `AVPacket`s, pulling
/// `AVFrame`s, resampling to the engine's `AVAudioFormat`) is **not** implemented
/// yet. The type is fully functional as a *capability probe and policy gate*:
///
/// - It identifies AC-3 / E-AC-3 / DTS tracks by codec string.
/// - Because Titan Player performs **no bitstream passthrough**, an MKV
///   (or other container) carrying AC-3 / E-AC-3 / DTS *surround* cannot be
///   handed to a receiver/HDMI sink intact. ``decode(_:)`` therefore surfaces
///   this as ``MediaError/code`` ``MediaError/ErrorCode/unsupportedFormat`` so
///   the pipeline can fall back to a decoder it does support or inform the user.
/// - It still emits the right telemetry (``TelemetryEvent/compatibilityModeActivated``
///   and ``TelemetryEvent/audioFormatUsed``) so the gap is measurable rather
///   than silent.
///
/// # Concurrency model
///
/// The decoder is a `final actor`, which makes it genuinely `Sendable` (no
/// `@unchecked`) and serialises all state mutation. The only non-`Sendable`
/// dependency — `TelemetryManager` (a `@MainActor` `TelemetryProviding`) — is
/// never stored; telemetry is emitted through a `Sendable` ``TelemetrySink``
/// that hops to the main actor. System-pressure observation runs on the main
/// actor via a small ``AudioPressureObserver`` and feeds the actor a `Sendable`
/// snapshot.
///
/// # Lifecycle
///
/// ```swift
/// let decoder = FFmpegAudioDecoder(configuration: .default)
/// try await decoder.attachPressureObservation()        // thermal/memory
/// try await decoder.configure(for: track, container: "MKV")
/// let frame = try await decoder.decode(packet)          // or throws .formatUnsupported
/// try await decoder.detach()                            // cancel + cleanup
/// ```
final actor FFmpegAudioDecoder {

    // MARK: - Configuration

    /// Runtime configuration for the audio decoder.
    struct Configuration: Sendable, Equatable {
        /// Wall-clock budget for a single ``decode(_:)`` call. `0` means
        /// "no timeout" (the decode runs until it finishes or is cancelled).
        let decodeTimeout: TimeInterval
        /// When `true`, surround codecs that cannot be passed through are
        /// decoded to a silent placeholder frame instead of throwing. Used by
        /// tests and by callers that only need the pipeline to advance.
        let allowStubDecode: Bool

        static let `default` = Configuration(
            decodeTimeout: 5.0,
            allowStubDecode: false
        )
    }

    // MARK: - AudioCodec

    /// The compressed-surround codec families this decoder understands.
    enum AudioCodec: Sendable, Equatable, CustomStringConvertible {
        case ac3
        case eac3
        case dts
        /// Any codec string we do not special-case.
        case other(String)

        /// Parses a FFmpeg codec name (e.g. `"ac3"`, `"eac3"`, `"dca"`/`"dts"`)
        /// into a ``AudioCodec``.
        init(parsing name: String) {
            switch name.lowercased() {
            case "ac3": self = .ac3
            case "eac3", "ec3": self = .eac3
            case "dts", "dca", "dtshd", "dts-hd": self = .dts
            default: self = .other(name)
            }
        }

        var isSurroundBitstream: Bool {
            switch self {
            case .ac3, .eac3, .dts: return true
            default: return false
            }
        }

        var description: String {
            switch self {
            case .ac3: return "AC-3"
            case .eac3: return "E-AC-3"
            case .dts: return "DTS"
            case .other(let name): return name
            }
        }
    }

    // MARK: - State

    /// Internal lifecycle state of the decoder.
    enum State: Sendable, Equatable {
        case idle
        case configured
        case decoding
        case finished
    }

    // MARK: - SystemPressureSnapshot

    /// A point-in-time snapshot of system thermal and memory pressure.
    ///
    /// Kept as a `Sendable` value type so the actor can store the latest
    /// reading and consult it on every ``decode(_:)`` call to decide whether to
    /// abort gracefully rather than allocate decode work the OS will soon
    /// throttle.
    struct SystemPressureSnapshot: Sendable, Equatable {
        enum Thermal: Sendable, Equatable { case nominal, fair, serious, critical }
        enum Memory: Sendable, Equatable { case normal, warning, urgent, critical }

        var thermal: Thermal
        var memory: Memory
        var updatedAt: Date

        static let nominal = SystemPressureSnapshot(
            thermal: .nominal, memory: .normal, updatedAt: .distantPast
        )

        /// Whether pressure is high enough that a decode should bail out rather
        /// than risk a thermal trip or jetsam termination.
        var shouldDegrade: Bool {
            thermal == .serious || thermal == .critical || memory == .critical
        }
    }

    // MARK: - TelemetrySink

    /// A `Sendable` bridge to ``TelemetryProviding`` so the actor never stores
    /// a non-`Sendable` telemetry reference.
    ///
    /// The default sink hops to the main actor and records through
    /// `TelemetryManager.shared` — Sentry is never referenced directly. Errors
    /// are mapped back onto ``TelemetryEvent/playbackFailed`` via
    /// ``MediaError/telemetryErrorCode`` so buckets stay stable.
    struct TelemetrySink: Sendable {
        let record: @Sendable (TelemetryEvent) -> Void

        static let `default` = TelemetrySink { event in
            Task { @MainActor in TelemetryManager.shared.record(event) }
        }

        /// Records a ``MediaError`` as a `playbackFailed` telemetry event
        /// without ever touching Sentry directly.
        func record(_ error: MediaError) {
            record(.playbackFailed(
                codec: error.codec ?? "unknown",
                resolution: error.resolution ?? "unknown",
                errorCode: error.telemetryErrorCode,
                source: error.source
            ))
        }
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.titanplayer", category: "FFmpegAudioDecoder")

    private let configuration: Configuration
    private let telemetry: TelemetrySink

    private(set) var state: State = .idle

    /// The codec family of the configured track, if any.
    private var codec: AudioCodec?
    /// The codec string attached to telemetry (e.g. `"ac3"`).
    private var codecLabel: String?
    /// Playback origin, used to bucket telemetry.
    private let source: PlaybackSource

    /// `true` once a surround bitstream codec is configured inside a container
    /// that Titan Player cannot bitstream-passthrough (e.g. MKV).
    private(set) var isPassthroughSupported: Bool = true

    /// Tap fired with each decoded `AudioFrame` (mirrors `MediaDecoding`).
    var audioTap: (@Sendable (AudioFrame) -> Void)?

    /// Latest observed system pressure.
    private var pressure: SystemPressureSnapshot = .nominal
    /// Live pressure observer (main-actor bound, `@unchecked Sendable`).
    private var pressureObserver: AudioPressureObserver?
    /// Tracks whether observation is currently active so ``detach()`` is safe.
    private var isObserving = false

    // MARK: - Initialization

    /// Creates an audio decoder.
    ///
    /// - Parameters:
    ///   - configuration: Runtime tunables (timeout, stub-decode toggle).
    ///   - telemetry: A `Sendable` telemetry sink; defaults to the shared
    ///     `TelemetryManager` bridge.
    ///   - source: Playback origin for telemetry bucketing.
    init(
        configuration: Configuration = .default,
        telemetry: TelemetrySink = .default,
        source: PlaybackSource = .local
    ) {
        self.configuration = configuration
        self.telemetry = telemetry
        self.source = source
    }

    // MARK: - Capability probing

    /// The codec families this decoder is designed to recognise.
    static let supportedCodecs: [AudioCodec] = [.ac3, .eac3, .dts]

    /// Whether `codec` can be bitstream-passed-through inside `container`.
    ///
    /// Titan Player performs **no** passthrough for any container today, so
    /// every compressed-surround codec reports `false` (the gap this type
    /// documents). The `container` parameter is retained so a future
    /// passthrough path can special-case formats that *do* carry a clean
    /// bitstream.
    ///
    /// - Parameters:
    ///   - codec: The parsed codec family.
    ///   - container: Upper-cased container tag (e.g. `"MKV"`, `"MP4"`).
    /// - Returns: `true` only when a lossless/bitstream path exists.
    nonisolated static func isPassthroughSupported(for codec: AudioCodec, container: String) -> Bool {
        guard codec.isSurroundBitstream else { return true }
        // No container currently supports bitstream passthrough of AC-3 / E-AC-3 / DTS.
        _ = container
        return false
    }

    // MARK: - Configuration

    /// Configures the decoder for an audio track.
    ///
    /// Detects AC-3 / E-AC-3 / DTS and, when the container cannot carry a
    /// bitstream passthrough, records a ``TelemetryEvent/compatibilityModeActivated``
    /// event and flips ``isPassthroughSupported`` to `false`.
    ///
    /// - Parameters:
    ///   - track: The audio track metadata from the demuxer.
    ///   - container: Upper-cased container tag (e.g. `"MKV"`). Defaults to `"MKV"`
    ///     because that is the surround-in-a-container case this type targets.
    /// - Throws: ``MediaError`` only on preconditions (already-configured,
    ///   invalid track); codec recognition itself never throws.
    func configure(for track: AudioTrackInfo, container: String = "MKV") throws {
        guard state == .idle || state == .finished else {
            throw MediaError(
                code: .decodingFailed,
                source: source,
                message: "FFmpegAudioDecoder.configure called while in \(state) state"
            )
        }
        guard track.channels > 0, track.sampleRate > 0 else {
            throw MediaError(
                code: .decodingFailed,
                source: source,
                message: "FFmpegAudioDecoder: invalid audio track (channels=\(track.channels), rate=\(track.sampleRate))"
            )
        }

        let parsed = AudioCodec(parsing: track.codec)
        codec = parsed
        codecLabel = track.codec

        let passthrough = Self.isPassthroughSupported(for: parsed, container: container.uppercased())
        isPassthroughSupported = passthrough

        if !passthrough, parsed.isSurroundBitstream {
            let format: TelemetryAudioFormat = track.channels >= 6 ? .surround5_1 : .stereo
            telemetry.record(.audioFormatUsed(
                format: format,
                sampleRate: track.sampleRate,
                bitDepth: 16
            ))
            telemetry.record(.compatibilityModeActivated(
                reason: "no_surround_passthrough:\(parsed)",
                source: source
            ))
            logger.warning("No bitstream passthrough for \(parsed.description) in \(container); decode will surface .formatUnsupported")
        }

        state = .configured
    }

    // MARK: - Decoding

    /// Decodes a single audio packet.
    ///
    /// For a configured AC-3 / E-AC-3 / DTS surround track the decode throws
    /// ``MediaError/code`` ``MediaError/ErrorCode/unsupportedFormat`` because
    /// Titan Player has no passthrough path (the documented impact). When
    /// ``Configuration/allowStubDecode`` is `true`, a silent placeholder
    /// ``AudioFrame`` is returned instead so the pipeline can still advance.
    ///
    /// Cancellation, thermal/memory pressure, and the configured decode timeout
    /// are all honoured and mapped onto ``MediaError``.
    ///
    /// - Parameter packet: The compressed audio packet from the demuxer.
    /// - Returns: A decoded ``AudioFrame`` (silent placeholder when stubbing).
    /// - Throws: ``MediaError`` on cancellation, timeout, system pressure, or
    ///   unsupported passthrough.
    func decode(_ packet: MediaPacket) async throws -> AudioFrame {
        try Task.checkCancellation()

        guard state == .configured || state == .decoding else {
            throw MediaError(
                code: .decodingFailed,
                source: source,
                message: "FFmpegAudioDecoder.decode called in \(state) state (configure first)"
            )
        }

        // Pressure gate: bail before allocating work the OS will throttle.
        if pressure.shouldDegrade {
            let error: MediaError
            if pressure.thermal == .serious || pressure.thermal == .critical {
                error = MediaError.thermalPressure(source: source)
            } else {
                error = MediaError.memoryPressure(source: source)
            }
            telemetry.record(error)
            throw error
        }

        state = .decoding
        defer { if state == .decoding { state = .configured } }

        let frame: AudioFrame
        do {
            frame = try await withThrowingTaskGroup(of: AudioFrame.self) { group in
                group.addTask { [self] in
                    try Task.checkCancellation()
                    return try self.decodeSynchronously(packet)
                }
                group.addTask { [self] in
                    try await self.guardDeadline()
                    throw CancellationError()
                }
                guard let result = try await group.next() else { throw CancellationError() }
                group.cancelAllRemainingTasks()
                return result
            }
        } catch {
            throw mapError(error)
        }

        if let tap = audioTap {
            tap(frame)
        }
        return frame
    }

    /// Synchronous decode work (runs inside the timeout task group).
    private func decodeSynchronously(_ packet: MediaPacket) throws -> AudioFrame {
        guard let codec else {
            throw MediaError(
                code: .decodingFailed,
                source: source,
                message: "FFmpegAudioDecoder: no codec configured"
            )
        }

        // The stubbed impact: no passthrough for MKV (or any) surround.
        if !isPassthroughSupported, codec.isSurroundBitstream {
            guard configuration.allowStubDecode else {
                throw MediaError(
                    code: .unsupportedFormat,
                    source: source,
                    message: "No bitstream passthrough for \(codec.description) surround (container carries compressed bitstream Titan Player cannot forward)"
                )
            }
            logger.debug("Stub-decoding \(codec.description) packet to silent frame (allowStubDecode)")
        }

        // Placeholder PCM frame. Real libavcodec wiring replaces this branch.
        let channelCount = max(1, 2)
        let sampleRate = 48_000
        let sampleCount = 1_024
        let buffer = [Float](repeating: 0.0, count: channelCount * sampleCount)

        return AudioFrame(
            buffer: buffer,
            format: AudioFormat(
                sampleRate: sampleRate,
                channels: channelCount,
                isInterleaved: true
            ),
            timestamp: packet.timestamp,
            duration: packet.duration
        )
    }

    /// Races the decode work against the configured timeout, throwing
    /// ``MediaError/Kind/timedOut`` if the budget is exceeded.
    private func guardDeadline() async throws {
        let budget = configuration.decodeTimeout
        if budget > 0 {
            try await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            throw MediaError(
                kind: .timedOut,
                source: source,
                codec: codecLabel,
                message: "FFmpegAudioDecoder: decode exceeded \(budget)s budget"
            )
        }
        // No timeout: park until cancelled so the sibling work task wins.
        try await Task.sleep(nanoseconds: .max)
        throw CancellationError()
    }

    // MARK: - Lifecycle

    /// Flushes any buffered decode state. No-op for the stub.
    func flush() {
        logger.debug("FFmpegAudioDecoder.flush (stub)")
    }

    /// Resets the decoder back to idle, discarding configuration.
    func reset() {
        state = .idle
        codec = nil
        codecLabel = nil
        isPassthroughSupported = true
        audioTap = nil
    }

    // MARK: - System pressure

    /// Begins observing thermal and memory pressure, emitting each as a
    /// ``MediaError``-equivalent gate on the next ``decode(_:)``.
    ///
    /// Must be called from the actor; the observer itself is created on the
    /// main actor because AppKit/Foundation pressure notifications require it.
    func attachPressureObservation() async {
        guard !isObserving else { return }
        let observer = await MainActor.run {
            AudioPressureObserver { [weak self] snapshot in
                Task { await self?.applyPressure(snapshot) }
            }
        }
        pressureObserver = observer
        isObserving = true
    }

    /// Stops pressure observation and releases the observer.
    func detach() {
        pressureObserver?.cancel()
        pressureObserver = nil
        isObserving = false
    }

    /// Applies a freshly observed pressure snapshot (called from the observer
    /// hop). Never throws and is safe to call after ``detach()``.
    nonisolated func applyPressure(_ snapshot: SystemPressureSnapshot) {
        Task { await _applyPressure(snapshot) }
    }

    private func _applyPressure(_ snapshot: SystemPressureSnapshot) {
        pressure = snapshot
    }

    // MARK: - Error mapping

    /// Maps an arbitrary decode error onto the centralized ``MediaError``.
    ///
    /// - `CancellationError` → ``MediaError/Kind/cancelled``
    /// - already-``MediaError`` values pass through unchanged
    /// - everything else → ``MediaError/Kind/decodingFailed``
    private func mapError(_ error: some Error) -> MediaError {
        if let mediaError = error as? MediaError {
            return mediaError
        }
        if error is CancellationError {
            return MediaError(kind: .cancelled, source: source, codec: codecLabel,
                              message: "FFmpegAudioDecoder operation cancelled")
        }
        return MediaError(
            error,
            source: source,
            codec: codecLabel
        )
    }

    deinit {
        // Actor `deinit` is nonisolated; hop to the actor to release the
        // main-actor-bound pressure observer so it does not leak Combine
        // subscriptions after teardown.
        Task { await detach() }
    }
}

// MARK: - AudioPressureObserver

/// Main-actor bound observer that forwards thermal/memory pressure changes to
/// the actor via a `@Sendable` callback.
///
/// AppKit/Foundation pressure notifications must be observed on the main
/// actor/run loop, so this helper is `@MainActor`. It is declared
/// `@unchecked Sendable` because every use is confined to the main actor and it
/// is only ever created/owned by the `FFmpegAudioDecoder` actor, which always
/// talks to it through `MainActor.run`.
@MainActor
final class AudioPressureObserver: @unchecked Sendable {
    private var cancellables: Set<AnyCancellable> = []
    private var memorySource: DispatchSourceMemoryPressure?
    private let onUpdate: @Sendable (FFmpegAudioDecoder.SystemPressureSnapshot) -> Void

    init(onUpdate: @Sendable @escaping (FFmpegAudioDecoder.SystemPressureSnapshot) -> Void) {
        self.onUpdate = onUpdate
        observeThermal()
        observeMemory()
    }

    private func observeThermal() {
        NotificationCenter.default
            .publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .sink { [weak self] _ in self?.push() }
            .store(in: &cancellables)
    }

    private func observeMemory() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main
        )
        source.setEventHandler { [weak self] in self?.push() }
        source.resume()
        memorySource = source
        push()
    }

    private func push() {
        let thermal: FFmpegAudioDecoder.SystemPressureSnapshot.Thermal
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .nominal
        }

        let memory: FFmpegAudioDecoder.SystemPressureSnapshot.Memory
        if let source = memorySource {
            switch source.data {
            case .critical: memory = .critical
            case .warning: memory = .warning
            default: memory = .normal
            }
        } else {
            memory = .normal
        }

        onUpdate(.init(thermal: thermal, memory: memory, updatedAt: Date()))
    }

    func cancel() {
        cancellables.removeAll()
        memorySource?.cancel()
        memorySource = nil
    }
}
